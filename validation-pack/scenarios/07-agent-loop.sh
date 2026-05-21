#!/usr/bin/env bash
# scenarios/07-agent-loop.sh
#
# Driver for scenario 07: agent-loop (Anthropic catalog pattern 7).
#
# Invoked by run-scenario.sh, which exports:
#   SCENARIO_ID — "07-agent-loop"
#   PACK_ROOT   — "/home/agent/validation-pack"
#
# What this driver does:
#   1. Substrate prep — formula symlink, ~/.beads discovery symlink, git identity.
#   2. Pour the agent-loop formula (single bead: step-loop).
#   3. Route step-loop to the implementer pool via direct metadata write.
#   4. Write the expected predicate fixture BEFORE spawning the agent.
#      Includes a notes_contains assertion (new predicate kind — see
#      verify_bead_state.py flag below).
#   5. Spawn one implementer session via shim_spawn.
#   6. Await step-loop closed via shim_await.
#   7. Exit 0 on success; on failure/timeout dump diagnostics and exit 1.
#
# Pattern shape: ONE bead, many internal tool invocations, agent decides
# the plan. Validates that the substrate doesn't try to over-structure
# dynamic agentic work — the bead is a unit of work + state container;
# the agent owns the planning and records its trace in notes.
#
# notes_contains predicate (NEW):
#   verify_bead_state.py does not yet implement notes_contains. The fixture
#   written by this driver includes:
#     "metadata_match": [{"bead_id": "<step-loop-id>", "key": "notes_contains",
#                         "value": "bash"}]
#   Treehugger must add notes_contains support to verify_bead_state.py before
#   this predicate is enforced. The closed_in_order check (reason=completed)
#   fires immediately with the existing verifier.

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
if [[ ! -e .beads/formulas/agent-loop.formula.toml ]]; then
    ln -s "${PACK_ROOT}/formulas/agent-loop.formula.toml" \
          .beads/formulas/agent-loop.formula.toml
fi

# bd discovery from /home/agent (the container WORKDIR): bd walks up from cwd
# to find .beads/. The verifier runs from /home/agent, not PACK_ROOT. Symlink
# /home/agent/.beads → PACK_ROOT/.beads so both cwd contexts resolve the same
# substrate.
if [[ ! -e "${HOME}/.beads" ]]; then
    ln -sf "${PACK_ROOT}/.beads" "${HOME}/.beads"
fi

# bd embedded Dolt needs a git user.name for audit commits. Scope to local
# config (this repo) so host global config is unaffected.
git config --local user.name  "agent" 2>/dev/null || true
git config --local user.email "agent@validation-pack.local" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Pour the formula (bd mol wisp → persistent beads, blocker semantics)
# ---------------------------------------------------------------------------
# bd mol wisp (not wisp): pour creates persistent beads so bd ready enforces
# proper blocker semantics. Container is destroyed after the scenario, so the
# "persistence" tradeoff is irrelevant for validation use.
# The agent-loop formula has a single step (step-loop); no dep chain to manage.

echo "[${SCENARIO_ID}] pouring formula agent-loop..."

WISP_JSON="$(bd mol wisp agent-loop \
    --var multi_step_task="Compute the SHA256 hash of /etc/hostname, then count the number of lines in /etc/passwd, then output both results as a comma-separated pair (sha256,linecount). Use separate bash invocations for each operation. Record each bash command and its first output line as a note after each step." \
    --var assignee=implementer \
    --json)"

echo "[${SCENARIO_ID}] pour output: ${WISP_JSON}"

# ---------------------------------------------------------------------------
# 3. Parse bead IDs from pour output (raw_decode pattern)
# ---------------------------------------------------------------------------
# bd may emit auto-import lines on stdout before the JSON object.
# raw_decode: locate the first '{' and parse from there — robust against
# leading noise ("auto-importing N bytes...", "auto-imported N issues...").

_parse_bead() {
    local key="$1"
    printf '%s' "${WISP_JSON}" | python3 -c "
import json, sys
text = sys.stdin.read()
idx = text.index('{')
d = json.loads(text[idx:])
print(d['id_mapping']['agent-loop.${key}'])
"
}

# Root bead ID (the molecule root).
_parse_root() {
    printf '%s' "${WISP_JSON}" | python3 -c "
import json, sys
text = sys.stdin.read()
idx = text.index('{')
d = json.loads(text[idx:])
# root_id is the molecule root; some bd versions use 'root_id', others 'id'
print(d.get('root_id') or d.get('id', ''))
"
}

BD_STEP_LOOP="$(_parse_bead step-loop)"
BD_ROOT="$(_parse_root)"

echo "[${SCENARIO_ID}] root=${BD_ROOT} step-loop=${BD_STEP_LOOP}"

# ---------------------------------------------------------------------------
# 4. Route step-loop to the implementer pool (direct metadata write)
# ---------------------------------------------------------------------------
# Use bd update --set-metadata rather than gc sling — sidesteps gc sling's
# auto-convoy bead creation (not needed for single-bead scenarios).
# Namespace matches the gc shim's convention: gc.routed_to=validation/<persona>.
# The implementer persona's pool query reads gc.routed_to=validation/implementer.

echo "[${SCENARIO_ID}] routing step-loop to implementer..."

bd update "${BD_STEP_LOOP}" --set-metadata gc.routed_to=validation/implementer
echo "[${SCENARIO_ID}]   routed ${BD_STEP_LOOP}"

# ---------------------------------------------------------------------------
# 5. Write expected predicate fixture BEFORE spawning the agent
# ---------------------------------------------------------------------------
# Predicate kinds used:
#   closed_in_order   — step-loop must close with reason=completed
#   metadata_match    — step-loop notes must contain "bash"
#                       (notes_contains is a NEW predicate kind; verify_bead_state.py
#                        does not yet implement it — treehugger must add support)

mkdir -p "${PACK_ROOT}/fixtures"
cat > "${PACK_ROOT}/fixtures/${SCENARIO_ID}-expected.json" <<EOF
{
  "closed_in_order": [
    {"bead_id": "${BD_STEP_LOOP}", "reason": "completed"}
  ],
  "notes_contains": [
    {"bead_id": "${BD_STEP_LOOP}", "value": "bash"}
  ]
}
EOF

echo "[${SCENARIO_ID}] predicate written to fixtures/${SCENARIO_ID}-expected.json"

# ---------------------------------------------------------------------------
# 6. Spawn the implementer agent (via gc shim)
# ---------------------------------------------------------------------------

echo "[${SCENARIO_ID}] spawning implementer agent..."
shim_spawn implementer 1

# ---------------------------------------------------------------------------
# 7. Await terminal state via shim_await
# ---------------------------------------------------------------------------
# Wait for step-loop to close. A single bead = the scenario is done when it
# reaches terminal state.
#
# Timeout: 1500s (25 min). One bead, multi-step task; generous ceiling because
# each bash invocation + note append involves a full Claude Code turn.

echo "[${SCENARIO_ID}] awaiting step-loop (${BD_STEP_LOOP}) close..."

AWAIT_RC=0
shim_await "${BD_STEP_LOOP}" 1500 || AWAIT_RC=$?

# ---------------------------------------------------------------------------
# 8. Outcome
# ---------------------------------------------------------------------------

if [[ "${AWAIT_RC}" -eq 0 ]]; then
    echo "[${SCENARIO_ID}] step-loop closed — SUCCESS"
    exit 0
fi

# Timeout / failure path: dump diagnostics so the treehugger can triage.
echo "[${SCENARIO_ID}] FAILED (await exit ${AWAIT_RC})" >&2
echo "--- open beads in this run ---" >&2
bd list --status=open --json 2>/dev/null \
    | jq -r "[.[] | select(.id==\"${BD_STEP_LOOP}\" or .id==\"${BD_ROOT}\")] | .[] | [.id, .status, .title] | @tsv" \
    2>&1 || true
echo "--- hooked beads in this run ---" >&2
bd list --status=hooked --json 2>/dev/null \
    | jq -r "[.[] | select(.id==\"${BD_STEP_LOOP}\" or .id==\"${BD_ROOT}\")] | .[] | [.id, .status, .title] | @tsv" \
    2>&1 || true
echo "--- bd ready (implementer pool) ---" >&2
bd ready --metadata-field gc.routed_to=validation/implementer 2>&1 || true
echo "--- gc session list ---" >&2
gc session list --city "${PACK_ROOT}" 2>&1 || true
exit 1
