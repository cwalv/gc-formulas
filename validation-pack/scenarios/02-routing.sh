#!/usr/bin/env bash
# scenarios/02-routing.sh
#
# Driver for scenario 02: routing (Anthropic catalog pattern 2).
#
# Invoked by run-scenario.sh, which exports:
#   SCENARIO_ID — "02-routing"
#   PACK_ROOT   — "/home/agent/validation-pack"
#
# What this driver does:
#   1. Substrate prep — formula symlink, ~/.beads discovery symlink, git identity.
#   2. Wisp the routing formula with a concrete routing_input that is
#      unambiguously implementer-work for first-pass validation.
#   3. Route step-classify to the foreman pool via direct metadata write.
#      step-execute is intentionally left unrouted at this point — the foreman
#      writes its routing decision onto step-execute as part of the scenario.
#   4. Write the expected predicate fixture BEFORE spawning the agent.
#      NOTE: the fixture uses a new predicate kind `metadata_match` — see
#      comment in the fixture section below.
#   5. Spawn one foreman session via shim_spawn.
#   6. Await step-classify closed via shim_await (600s ceiling — foreman only
#      needs one LLM call to classify and route).
#   7. Inspect step-execute's gc.routed_to metadata and assert it matches
#      the expected target. (Done here rather than by verify_bead_state.py
#      because metadata_match support is not yet in the verifier.)
#   8. Exit 0 on success; on failure/timeout dump diagnostics and exit 1.
#
# Shim model: sources shims/${SHIM:-gc}.sh for shim_spawn / shim_prime /
# shim_await. Swapping SHIM=ntm re-runs against a different orchestrator.

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
if [[ ! -e .beads/formulas/routing.formula.toml ]]; then
    ln -s "${PACK_ROOT}/formulas/routing.formula.toml" \
          .beads/formulas/routing.formula.toml
fi

# bd discovery from /home/agent: bd walks up from cwd to find .beads/.
# The verifier runs from /home/agent, not PACK_ROOT. Symlink so both
# cwd contexts resolve the same substrate.
if [[ ! -e "${HOME}/.beads" ]]; then
    ln -sf "${PACK_ROOT}/.beads" "${HOME}/.beads"
fi

# bd embedded Dolt needs a git user.name for audit commits.
git config --local user.name  "agent" 2>/dev/null || true
git config --local user.email "agent@validation-pack.local" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Wisp the formula (bd mol wisp + pour=true → full DAG, ephemeral phase)
# ---------------------------------------------------------------------------

# Routing input: deliberately unambiguous implementer-work for the first-pass
# test case. "Add a new GraphQL endpoint for user search" is a code change;
# any competent classifier routes this to implementer. Edge cases (ambiguous
# scope, treehugger-work, review-only requests) are follow-on tests.
#
# expected_target=implementer tells the fixture what gc.routed_to we expect
# the foreman to write on step-execute. The foreman never sees this value —
# it's the verifier's reference only.
ROUTING_INPUT="Add a new GraphQL endpoint for user search that filters by name and email"
EXPECTED_TARGET="implementer"

echo "[${SCENARIO_ID}] wisping formula routing..."

WISP_JSON="$(bd mol wisp routing \
    --var routing_input="${ROUTING_INPUT}" \
    --var expected_target="${EXPECTED_TARGET}" \
    --var assignee=foreman \
    --json)"

echo "[${SCENARIO_ID}] wisp output: ${WISP_JSON}"

# Parse the 2 step bead IDs from the id_mapping.
# id_mapping keys are formula-scoped: "routing.step-classify" etc.
# Robust parse: bd may emit auto-import lines on stdout before the JSON
# (observed: "auto-importing N bytes...", "auto-imported N issues..."). Use
# raw_decode to locate and parse the JSON object regardless of preceding text.
_parse_step() {
    local step="$1"
    printf '%s' "${WISP_JSON}" | python3 -c "
import json, sys
text = sys.stdin.read()
idx = text.index('{')
d = json.loads(text[idx:])
print(d['id_mapping']['routing.${step}'])
"
}
STEP_CLASSIFY="$(_parse_step step-classify)"
STEP_EXECUTE="$(_parse_step step-execute)"

echo "[${SCENARIO_ID}] step-classify=${STEP_CLASSIFY} step-execute=${STEP_EXECUTE}"

# ---------------------------------------------------------------------------
# 3. Route step-classify to the foreman pool
# ---------------------------------------------------------------------------
# Direct metadata write (not gc sling) — sidesteps auto-convoy per shim
# architecture (validation-pack-design.md § Shim architecture).
# step-execute is deliberately left WITHOUT gc.routed_to at this point:
# the foreman's classify task writes it. That write IS the routing assertion.

echo "[${SCENARIO_ID}] routing step-classify to foreman..."
bd update "${STEP_CLASSIFY}" --set-metadata gc.routed_to=validation/foreman
echo "[${SCENARIO_ID}]   routed ${STEP_CLASSIFY} to validation/foreman"
echo "[${SCENARIO_ID}]   step-execute (${STEP_EXECUTE}) left unrouted — foreman will write routing"

# ---------------------------------------------------------------------------
# 4. Write expected predicate fixture BEFORE spawning the agent
# ---------------------------------------------------------------------------
# verify_bead_state.py reads this file after the scenario.
#
# PREDICATE KINDS IN USE:
#   - closed_in_order: supported by verify_bead_state.py today.
#   - metadata_match: NEW predicate kind — NOT YET supported by
#     verify_bead_state.py. Treehugger must add support for it before the
#     verifier can assert the routing metadata. The inline metadata check at
#     the end of this driver (step 7) covers the assertion for now; the
#     fixture documents the intended predicate shape for the verifier.
#
# metadata_match schema (proposed):
#   [{"bead_id": "...", "key": "...", "value": "..."}]
#   Asserts that the named bead has the named metadata key set to exactly
#   the named value at scenario end.

mkdir -p "${PACK_ROOT}/fixtures"
cat > "${PACK_ROOT}/fixtures/${SCENARIO_ID}-expected.json" <<EOF
{
  "_comment": "metadata_match is a NEW predicate kind — not yet supported by verify_bead_state.py. The scenario driver (step 7) performs this assertion inline. Treehugger must extend verify_bead_state.py to evaluate this predicate kind before relying on the verifier alone.",
  "closed_in_order": [
    {"bead_id": "${STEP_CLASSIFY}", "reason": "classified"}
  ],
  "metadata_match": [
    {"bead_id": "${STEP_EXECUTE}", "key": "gc.routed_to", "value": "validation/${EXPECTED_TARGET}"}
  ]
}
EOF

echo "[${SCENARIO_ID}] predicate written to fixtures/${SCENARIO_ID}-expected.json"

# ---------------------------------------------------------------------------
# 5. Spawn the foreman agent (via gc shim)
# ---------------------------------------------------------------------------
# shim_spawn creates one gc session from the 'foreman' agent template
# (defined in city.toml). The foreman persona (personas/foreman.md) describes
# the foreman as a wisp-maker and observer; for this scenario it acts as the
# classifier. The foreman needs one LLM call to: claim step-classify, read
# the routing_input, decide the persona, write gc.routed_to onto step-execute,
# and close step-classify with reason=classified.
#
# NOTE: shim_spawn requires tmux in the container image (plus dolt + lsof for
# gc start). See shims/gc.sh for the full prerequisite list. The baseline
# Dockerfile does not include these; the treehugger must add them.

echo "[${SCENARIO_ID}] spawning foreman agent..."
shim_spawn foreman 1

# ---------------------------------------------------------------------------
# 6. Await step-classify closed
# ---------------------------------------------------------------------------
# Success criterion for routing is metadata-based, not step-execute-closed.
# We await step-classify closing (which the foreman does after writing the
# routing metadata) and then inspect step-execute's metadata.
#
# Timeout: 600s (10 min). This scenario requires only one foreman LLM call —
# classify + write metadata + close. Much shorter than the 3-bead prompt-
# chaining ceiling.

echo "[${SCENARIO_ID}] awaiting step-classify (${STEP_CLASSIFY}) close..."

AWAIT_RC=0
shim_await "${STEP_CLASSIFY}" 600 || AWAIT_RC=$?

if [[ "${AWAIT_RC}" -ne 0 ]]; then
    echo "[${SCENARIO_ID}] FAILED: step-classify did not close within timeout" >&2
    _dump_diagnostics
    exit 1
fi

echo "[${SCENARIO_ID}] step-classify closed"

# ---------------------------------------------------------------------------
# 7. Inline metadata assertion (covers metadata_match until verifier supports it)
# ---------------------------------------------------------------------------
# Inspect step-execute's gc.routed_to metadata and assert it matches the
# expected target. This bridges the gap until verify_bead_state.py gains
# metadata_match support.

echo "[${SCENARIO_ID}] asserting step-execute routing metadata..."

ACTUAL_ROUTED_TO="$(bd show "${STEP_EXECUTE}" --json \
    | python3 -c "
import json, sys
text = sys.stdin.read()
idx = text.index('{')
d = json.loads(text[idx:])
# Metadata may be at d['metadata'] or d['gc.routed_to'] depending on bd version.
# Try both common shapes.
meta = d.get('metadata') or {}
val = meta.get('gc.routed_to') or d.get('gc.routed_to') or ''
print(val)
" 2>/dev/null || true)"

EXPECTED_ROUTED_TO="validation/${EXPECTED_TARGET}"

if [[ "${ACTUAL_ROUTED_TO}" == "${EXPECTED_ROUTED_TO}" ]]; then
    echo "[${SCENARIO_ID}] PASS: step-execute gc.routed_to=${ACTUAL_ROUTED_TO}"
else
    echo "[${SCENARIO_ID}] FAIL: step-execute routing mismatch" >&2
    echo "  expected: ${EXPECTED_ROUTED_TO}" >&2
    echo "  actual:   ${ACTUAL_ROUTED_TO:-<not set>}" >&2
    _dump_diagnostics
    exit 1
fi

# ---------------------------------------------------------------------------
# 8. Outcome
# ---------------------------------------------------------------------------

echo "[${SCENARIO_ID}] routing scenario SUCCESS"
exit 0

# ---------------------------------------------------------------------------
# Diagnostics helper (called on failure paths above)
# ---------------------------------------------------------------------------
_dump_diagnostics() {
    echo "--- classify bead state ---" >&2
    bd show "${STEP_CLASSIFY}" --json 2>/dev/null \
        | jq '{id, status, close_reason, metadata}' 2>&1 || true
    echo "--- execute bead state ---" >&2
    bd show "${STEP_EXECUTE}" --json 2>/dev/null \
        | jq '{id, status, close_reason, metadata}' 2>&1 || true
    echo "--- open beads in this run ---" >&2
    bd list --status=open --json 2>/dev/null \
        | jq -r "[.[] | select(.id==\"${STEP_CLASSIFY}\" or .id==\"${STEP_EXECUTE}\")] | .[] | [.id, .status, .title] | @tsv" \
        2>&1 || true
    echo "--- hooked beads in this run ---" >&2
    bd list --status=hooked --json 2>/dev/null \
        | jq -r "[.[] | select(.id==\"${STEP_CLASSIFY}\" or .id==\"${STEP_EXECUTE}\")] | .[] | [.id, .status, .title] | @tsv" \
        2>&1 || true
    echo "--- bd ready (foreman pool) ---" >&2
    bd ready --metadata-field gc.routed_to=validation/foreman 2>&1 || true
    echo "--- gc session list ---" >&2
    gc session list --city "${PACK_ROOT}" 2>&1 || true
}
