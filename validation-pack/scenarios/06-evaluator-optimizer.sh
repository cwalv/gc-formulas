#!/usr/bin/env bash
# scenarios/06-evaluator-optimizer.sh
#
# Driver for scenario 06: evaluator-optimizer (Anthropic catalog pattern 6).
#
# Invoked by run-scenario.sh, which exports:
#   SCENARIO_ID — "06-evaluator-optimizer"
#   PACK_ROOT   — "/home/agent/validation-pack"
#
# What this driver does:
#   1. Substrate prep — formula symlink, ~/.beads discovery symlink, git identity.
#   2. Pour the evaluator-optimizer formula (single bead; pour=true so the step
#      bead is materialized as a persistent child).
#   3. Route step-iterate to validation/implementer as the initial assignee.
#   4. Write the expected predicate fixture BEFORE spawning agents.
#   5. Spawn implementer + evaluator sessions via shim_spawn.
#   6. Await step-iterate closed via shim_await (long timeout — up to 3 iterations).
#   7. Exit 0 on success; on failure/timeout dump diagnostics and exit 1.
#
# Shim model: this driver sources shims/${SHIM:-gc}.sh to get shim_spawn,
# shim_prime, shim_await. Swapping SHIM=ntm re-runs against a different
# orchestrator without touching this file.

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Prerequisites
# ---------------------------------------------------------------------------

: "${PACK_ROOT:?PACK_ROOT must be set by run-scenario.sh}"
: "${SCENARIO_ID:?SCENARIO_ID must be set by run-scenario.sh}"

cd "${PACK_ROOT}"

# Source the orchestrator shim (defaults to gc).
SHIM="${SHIM:-gc}"
SHIM_FILE="${PACK_ROOT}/shims/${SHIM}.sh"
if [[ ! -f "${SHIM_FILE}" ]]; then
    echo "[${SCENARIO_ID}] ERROR: shim not found: ${SHIM_FILE}" >&2
    exit 1
fi
# shellcheck source=shims/gc.sh
source "${SHIM_FILE}"

# ---------------------------------------------------------------------------
# 1. Substrate prep
# ---------------------------------------------------------------------------

# Formula search path: bd looks in .beads/formulas/ — symlink our formula in.
mkdir -p .beads/formulas
if [[ ! -e .beads/formulas/evaluator-optimizer.formula.toml ]]; then
    ln -s "${PACK_ROOT}/formulas/evaluator-optimizer.formula.toml" \
          .beads/formulas/evaluator-optimizer.formula.toml
fi

# bd discovery from /home/agent: symlink /home/agent/.beads → PACK_ROOT/.beads
# so both cwd contexts (driver and verifier) resolve the same substrate.
if [[ ! -e "${HOME}/.beads" ]]; then
    ln -sf "${PACK_ROOT}/.beads" "${HOME}/.beads"
fi

# bd embedded Dolt needs a git user.name for audit commits.
git config --local user.name  "agent" 2>/dev/null || true
git config --local user.email "agent@validation-pack.local" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Pour the formula (bd mol wisp → persistent bead DAG)
# ---------------------------------------------------------------------------

echo "[${SCENARIO_ID}] pouring formula evaluator-optimizer..."

# bd mol wisp (not wisp): pour creates persistent beads with proper blocker
# semantics. The container is destroyed after the scenario, so persistence
# is irrelevant, but pour avoids the bd ready ephemeral-exclusion issue
# documented in scenario 01.
WISP_JSON="$(bd mol wisp evaluator-optimizer \
    --var task="Write a one-line haiku about the color teal. Exactly three lines: five syllables, seven syllables, five syllables. No title, no attribution, no other text — only the haiku." \
    --var max_iterations="3" \
    --var assignee=implementer \
    --json)"

echo "[${SCENARIO_ID}] wisp output: ${WISP_JSON}"

# Parse root bead ID and step-iterate bead ID from id_mapping.
# id_mapping keys are formula-scoped: "evaluator-optimizer" (root) and
# "evaluator-optimizer.step-iterate" (step).
# Robust parse: bd may emit auto-import lines before the JSON blob;
# raw_decode locates the JSON object regardless of preceding text.
_parse_id() {
    local key="$1"
    printf '%s' "${WISP_JSON}" | python3 -c "
import json, sys
text = sys.stdin.read()
idx = text.index('{')
d = json.loads(text[idx:])
print(d['id_mapping']['${key}'])
"
}
BD_ROOT="$(_parse_id 'evaluator-optimizer')"
BD_STEP_ITERATE="$(_parse_id 'evaluator-optimizer.step-iterate')"

echo "[${SCENARIO_ID}] root=${BD_ROOT} step-iterate=${BD_STEP_ITERATE}"

# ---------------------------------------------------------------------------
# 3. Route step-iterate to validation/implementer (initial routing)
# ---------------------------------------------------------------------------
# Direct metadata write — avoids gc sling auto-convoy creation (only useful
# for parallel fan-out scenarios). Namespace: gc.routed_to=validation/<persona>
# matches the gc shim's pool query convention.

echo "[${SCENARIO_ID}] routing step-iterate to implementer..."
bd update "${BD_STEP_ITERATE}" --set-metadata gc.routed_to=validation/implementer
echo "[${SCENARIO_ID}]   routed ${BD_STEP_ITERATE} → validation/implementer"

# ---------------------------------------------------------------------------
# 4. Write expected predicate fixture BEFORE spawning agents
# ---------------------------------------------------------------------------
# verify_bead_state.py reads this file after the scenario to assert the
# bead DAG matches the expected shape.
#
# Predicate notes:
#
# closed_in_order: step-iterate must close with reason=approved OR
#   reason=max-iterations-reached. Both are valid terminal outcomes.
#   The verifier should treat either as success for this scenario.
#   (If verifier only accepts exact string matches, use a list of acceptable
#   reasons; this is flagged as an open implementation question — see scenario
#   report notes.)
#
# metadata_match / notes_contains: confirms at least one iteration fired —
#   the evaluator issued at least one "iterate: ..." feedback note before
#   the terminal close. Without this check, a trivial single-pass approve
#   wouldn't exercise the ping-pong mechanism at all.

mkdir -p "${PACK_ROOT}/fixtures"
cat > "${PACK_ROOT}/fixtures/${SCENARIO_ID}-expected.json" <<EOF
{
  "closed_in_order": [
    {
      "bead_id": "${BD_STEP_ITERATE}",
      "reason_one_of": ["approved", "max-iterations-reached"]
    }
  ],
  "notes_contains": [
    {
      "bead_id": "${BD_STEP_ITERATE}",
      "value": "iterate: forced-round-1"
    }
  ]
}
EOF

echo "[${SCENARIO_ID}] predicate written to fixtures/${SCENARIO_ID}-expected.json"

# ---------------------------------------------------------------------------
# 5. Spawn implementer + evaluator agents (via gc shim)
# ---------------------------------------------------------------------------
# Both agents loop continuously: claim → execute → route/close → drain-ack.
# The implementer will initially pick up step-iterate (routed to
# validation/implementer), produce a draft, and re-route to the evaluator.
# The evaluator will then pick it up, review, and either close or route back.
# Spawning both before the bead flips ensures no idle wait between handoffs.

echo "[${SCENARIO_ID}] spawning implementer agent..."
shim_spawn implementer 1

echo "[${SCENARIO_ID}] spawning evaluator agent..."
shim_spawn evaluator 1

# ---------------------------------------------------------------------------
# 6. Await terminal state via shim_await
# ---------------------------------------------------------------------------
# Wait for step-iterate to close (approved or max-iterations-reached).
# Timeout: 2400s (40 min). Generous ceiling to allow up to 3 full iterations,
# each involving a full Claude Code turn for both implementer and evaluator.
# Adjust once empirical timing is established.

echo "[${SCENARIO_ID}] awaiting step-iterate (${BD_STEP_ITERATE}) close..."

AWAIT_RC=0
shim_await "${BD_STEP_ITERATE}" 2400 || AWAIT_RC=$?

# ---------------------------------------------------------------------------
# 7. Outcome
# ---------------------------------------------------------------------------

if [[ "${AWAIT_RC}" -eq 0 ]]; then
    echo "[${SCENARIO_ID}] step-iterate closed — SUCCESS"
    exit 0
fi

# Timeout / failure path: dump diagnostics so the treehugger can triage.
echo "[${SCENARIO_ID}] FAILED (await exit ${AWAIT_RC})" >&2
echo "--- open beads in this run ---" >&2
bd list --status=open --json 2>/dev/null \
    | jq -r "[.[] | select(.id==\"${BD_ROOT}\" or .id==\"${BD_STEP_ITERATE}\")] | .[] | [.id, .status, .title] | @tsv" \
    2>&1 || true
echo "--- hooked beads in this run ---" >&2
bd list --status=hooked --json 2>/dev/null \
    | jq -r "[.[] | select(.id==\"${BD_ROOT}\" or .id==\"${BD_STEP_ITERATE}\")] | .[] | [.id, .status, .title] | @tsv" \
    2>&1 || true
echo "--- bd ready (implementer pool) ---" >&2
bd ready --metadata-field gc.routed_to=validation/implementer 2>&1 || true
echo "--- bd ready (evaluator pool) ---" >&2
bd ready --metadata-field gc.routed_to=validation/evaluator 2>&1 || true
echo "--- gc session list ---" >&2
gc session list --city "${PACK_ROOT}" 2>&1 || true
echo "--- step-iterate notes ---" >&2
bd show "${BD_STEP_ITERATE}" --json 2>/dev/null | jq '.notes' 2>&1 || true
exit 1
