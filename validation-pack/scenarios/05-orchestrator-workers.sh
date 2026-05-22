#!/usr/bin/env bash
# scenarios/05-orchestrator-workers.sh
#
# Driver for scenario 05: orchestrator-workers (Anthropic catalog pattern 5).
#
# Invoked by run-scenario.sh, which exports:
#   SCENARIO_ID — "05-orchestrator-workers"
#   PACK_ROOT   — "/home/agent/validation-pack"
#
# What this driver does:
#   1. Substrate prep — formula symlink, ~/.beads discovery symlink, git identity.
#   2. Pour the orchestrator-workers formula to produce 4 step beads:
#      step-orchestrate, step-implement-1, step-implement-2, step-land.
#   3. Route each bead to its persona pool via direct metadata write:
#      - step-orchestrate → validation/foreman
#      - step-implement-1 → validation/implementer
#      - step-implement-2 → validation/implementer
#      - step-land        → validation/treehugger
#   4. Write the expected predicate fixture BEFORE spawning any agents.
#      Predicate shape:
#        - closed_in_order: [step-orchestrate(decomposed)]
#        - closed_unordered: [step-implement-1(completed), step-implement-2(completed)]
#        - closed_in_order (appended after): [step-land(landed)]
#      NOTE: the combined predicate requires verifier support for
#      `closed_unordered` — see flag in fixture comment.
#   5. Spawn agents: 1 foreman, 2 implementers (parallel), 1 treehugger.
#   6. Await step-land closed via shim_await (2000s ceiling — 3 sequential LLM
#      phases, each potentially multi-turn).
#   7. Exit 0 on success; on failure/timeout dump diagnostics and exit 1.
#
# Shim model: this driver sources shims/${SHIM:-gc}.sh to get shim_spawn,
# shim_prime, shim_await. Swapping SHIM=ntm re-runs against a different
# orchestrator without touching this file.
#
# Step CLI: bash 05-orchestrator-workers.sh --step <name> runs up to that step
# and exits. Valid steps: pour, route, spawn_workers, close

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Prerequisites
# ---------------------------------------------------------------------------

: "${PACK_ROOT:?PACK_ROOT must be set by run-scenario.sh}"
: "${SCENARIO_ID:?SCENARIO_ID must be set by run-scenario.sh}"

cd "${PACK_ROOT}"

# Source checkpoint helper (DEBUG_PAUSE_AT support).
# shellcheck source=scripts/checkpoint.sh
source "${PACK_ROOT}/scripts/checkpoint.sh"

# Source the orchestrator shim (defaults to gc).
SHIM="${SHIM:-gc}"
SHIM_FILE="${PACK_ROOT}/shims/${SHIM}.sh"
if [[ ! -f "${SHIM_FILE}" ]]; then
    echo "[${SCENARIO_ID}] ERROR: shim not found: ${SHIM_FILE}" >&2
    exit 1
fi
# shellcheck source=shims/gc.sh
source "${SHIM_FILE}"

# Shared state set by scenario05_pour, consumed by later steps.
BD_STEP_ORCHESTRATE=""
BD_STEP_IMPLEMENT_1=""
BD_STEP_IMPLEMENT_2=""
BD_STEP_LAND=""
WISP_JSON=""

# ---------------------------------------------------------------------------
# Diagnostics helper (called on failure paths below)
# ---------------------------------------------------------------------------
_dump_diagnostics() {
    local ALL_IDS=("${BD_STEP_ORCHESTRATE}" "${BD_STEP_IMPLEMENT_1}" "${BD_STEP_IMPLEMENT_2}" "${BD_STEP_LAND}")
    local ID_FILTER
    ID_FILTER="$(printf '.id=="%s" or ' "${ALL_IDS[@]}")false"

    echo "--- bead states ---" >&2
    for ID in "${ALL_IDS[@]}"; do
        bd show "${ID}" --json 2>/dev/null \
            | python3 -c "
import json, sys
text = sys.stdin.read()
idx = text.index('{')
d = json.loads(text[idx:])
print(d.get('id','?'), d.get('status','?'), d.get('close_reason',''), d.get('title','')[:60])
" 2>&1 || true
    done

    echo "--- open beads in this run ---" >&2
    bd list --status=open --json 2>/dev/null \
        | python3 -c "
import json, sys
text = sys.stdin.read()
idx = text.index('[')
items = json.loads(text[idx:])
ids = {'${BD_STEP_ORCHESTRATE}','${BD_STEP_IMPLEMENT_1}','${BD_STEP_IMPLEMENT_2}','${BD_STEP_LAND}'}
for d in items:
    if d.get('id') in ids:
        print(d.get('id'), d.get('status'), d.get('title','')[:60])
" 2>&1 || true

    echo "--- hooked beads in this run ---" >&2
    bd list --status=hooked --json 2>/dev/null \
        | python3 -c "
import json, sys
text = sys.stdin.read()
idx = text.index('[')
items = json.loads(text[idx:])
ids = {'${BD_STEP_ORCHESTRATE}','${BD_STEP_IMPLEMENT_1}','${BD_STEP_IMPLEMENT_2}','${BD_STEP_LAND}'}
for d in items:
    if d.get('id') in ids:
        print(d.get('id'), d.get('status'), d.get('title','')[:60])
" 2>&1 || true

    echo "--- bd ready (foreman pool) ---" >&2
    bd ready --include-ephemeral --assignee=validation/foreman --json --limit 1 2>&1 || true

    echo "--- bd ready (implementer pool) ---" >&2
    bd ready --include-ephemeral --assignee=validation/implementer --json --limit 1 2>&1 || true

    echo "--- bd ready (treehugger pool) ---" >&2
    bd ready --include-ephemeral --assignee=validation/treehugger --json --limit 1 2>&1 || true

    echo "--- gc session list ---" >&2
    gc session list --city "${PACK_ROOT}" 2>&1 || true
}

# ---------------------------------------------------------------------------
# Step functions
# ---------------------------------------------------------------------------

scenario05_pour() {
    # Substrate prep + pour formula + parse bead IDs.

    # Formula search path: bd looks in .beads/formulas/ — symlink our formula in.
    mkdir -p .beads/formulas
    if [[ ! -e .beads/formulas/orchestrator-workers.formula.toml ]]; then
        ln -s "${PACK_ROOT}/formulas/orchestrator-workers.formula.toml" \
              .beads/formulas/orchestrator-workers.formula.toml
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

    # `bd mol wisp` (not wisp): pour creates persistent beads with proper blocker
    # semantics. step-implement-1 and step-implement-2 are blocked until step-
    # orchestrate closes; step-land is blocked until both implement beads close.
    # Container is destroyed after the scenario so persistence cost is irrelevant.
    #
    # Concrete task: two independent trivia questions that decompose cleanly into
    # non-overlapping SUBTASK-1 and SUBTASK-2. The foreman knows both questions
    # but must write them as separate subtask lines for the implementers to pick up.

    TASK_DESC="Generate a short factual answer for two trivia questions: (1) What is the capital of France? (2) What is the chemical symbol for gold?"

    echo "[${SCENARIO_ID}] pouring formula orchestrator-workers..."

    WISP_JSON="$(bd mol wisp orchestrator-workers \
        --var task_description="${TASK_DESC}" \
        --var assignee=foreman \
        --json)"

    echo "[${SCENARIO_ID}] pour output: ${WISP_JSON}"

    # Parse the 4 step bead IDs from the id_mapping.
    # id_mapping keys are formula-scoped: "orchestrator-workers.step-orchestrate" etc.
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
print(d['id_mapping']['orchestrator-workers.${step}'])
"
    }

    BD_STEP_ORCHESTRATE="$(_parse_step step-orchestrate)"
    BD_STEP_IMPLEMENT_1="$(_parse_step step-implement-1)"
    BD_STEP_IMPLEMENT_2="$(_parse_step step-implement-2)"
    BD_STEP_LAND="$(_parse_step step-land)"

    echo "[${SCENARIO_ID}] step-orchestrate=${BD_STEP_ORCHESTRATE}"
    echo "[${SCENARIO_ID}] step-implement-1=${BD_STEP_IMPLEMENT_1}"
    echo "[${SCENARIO_ID}] step-implement-2=${BD_STEP_IMPLEMENT_2}"
    echo "[${SCENARIO_ID}] step-land=${BD_STEP_LAND}"

    checkpoint pour
}

scenario05_route() {
    # Route beads to persona pools + write fixture.

    # Use bd update --assignee rather than gc sling — sidesteps gc sling's
    # auto-convoy bead creation (only useful for parallel-fan-out scenarios).
    # The assignee slot doubles as a pool name: validation/<persona>.
    # Each persona's pool query reads --assignee=validation/<their-name>.
    # step-implement-1 and step-implement-2 both route to the same implementer pool;
    # two implementer sessions will race to claim whichever becomes ready first.

    echo "[${SCENARIO_ID}] routing beads to persona pools..."

    bd update "${BD_STEP_ORCHESTRATE}" --assignee=validation/foreman
    echo "[${SCENARIO_ID}]   routed ${BD_STEP_ORCHESTRATE} → validation/foreman"

    bd update "${BD_STEP_IMPLEMENT_1}" --assignee=validation/implementer
    echo "[${SCENARIO_ID}]   routed ${BD_STEP_IMPLEMENT_1} → validation/implementer"

    bd update "${BD_STEP_IMPLEMENT_2}" --assignee=validation/implementer
    echo "[${SCENARIO_ID}]   routed ${BD_STEP_IMPLEMENT_2} → validation/implementer"

    bd update "${BD_STEP_LAND}" --assignee=validation/treehugger
    echo "[${SCENARIO_ID}]   routed ${BD_STEP_LAND} → validation/treehugger"

    # Write expected predicate fixture BEFORE spawning agents.
    # verify_bead_state.py reads this file after the scenario to assert the
    # bead DAG matches the expected shape.
    #
    # PREDICATE KINDS IN USE:
    #   - closed_in_order: supported by verify_bead_state.py today.
    #   - closed_unordered: NEW predicate kind — NOT YET supported by
    #     verify_bead_state.py. The two implement beads are unblocked simultaneously
    #     once step-orchestrate closes and may close in any order. `closed_unordered`
    #     asserts that all listed beads are closed with the expected reason but
    #     makes no ordering claim relative to each other (only that all precede
    #     step-land). Treehugger must add support for `closed_unordered` before the
    #     verifier can assert this predicate kind. Until then, the driver's
    #     shim_await on step-land (close step below) covers the liveness assertion.
    #
    # closed_unordered schema (proposed):
    #   [{"bead_id": "...", "reason": "..."}]
    #   Asserts that all listed beads are closed with the named reason. No ordering
    #   constraint among the entries; all must precede any bead that deps on them
    #   (enforced by substrate, not verifier).
    #
    # Combined predicate intent:
    #   1. step-orchestrate closes decomposed (must be first — substrate dep).
    #   2. step-implement-1 AND step-implement-2 close completed (either order).
    #   3. step-land closes landed (must be last — substrate dep on both implements).

    mkdir -p "${PACK_ROOT}/fixtures"
    cat > "${PACK_ROOT}/fixtures/${SCENARIO_ID}-expected.json" <<EOF
{
  "_comment": "closed_unordered is a NEW predicate kind — not yet supported by verify_bead_state.py. The scenario driver's shim_await on step-land covers liveness. Treehugger must extend verify_bead_state.py to evaluate closed_unordered before relying on the verifier alone. closed_in_order entries must still be honoured by the verifier in the order listed.",
  "closed_in_order": [
    {"bead_id": "${BD_STEP_ORCHESTRATE}", "reason": "decomposed"},
    {"bead_id": "${BD_STEP_LAND}",        "reason": "landed"}
  ],
  "closed_unordered": [
    {"bead_id": "${BD_STEP_IMPLEMENT_1}", "reason": "completed"},
    {"bead_id": "${BD_STEP_IMPLEMENT_2}", "reason": "completed"}
  ]
}
EOF

    echo "[${SCENARIO_ID}] predicate written to fixtures/${SCENARIO_ID}-expected.json"

    checkpoint route
}

scenario05_spawn_workers() {
    # Spawn all three persona agents (foreman + implementers + treehugger).
    # Three personas are needed for this scenario:
    #   - foreman (1 session):    handles step-orchestrate (decomposition).
    #   - implementer (2 sessions): handle step-implement-1 and step-implement-2
    #                               in parallel once the foreman closes step-orchestrate.
    #                               Two sessions so both implement beads can be claimed
    #                               concurrently rather than sequentially.
    #   - treehugger (1 session): handles step-land after both implements close.
    #
    # NOTE: shim_spawn requires tmux in the container image (plus dolt + lsof for
    # gc start). See shims/gc.sh for the full prerequisite list. The baseline
    # Dockerfile does not include these; the treehugger must add them.

    echo "[${SCENARIO_ID}] spawning foreman (1 session)..."
    shim_spawn foreman 1

    echo "[${SCENARIO_ID}] spawning implementer (2 sessions)..."
    shim_spawn implementer 2

    echo "[${SCENARIO_ID}] spawning treehugger (1 session)..."
    shim_spawn treehugger 1

    checkpoint spawn
}

scenario05_close() {
    # Await step-land close (the terminal success predicate).
    # Await step-land closing. The substrate's dep enforcement guarantees:
    #   step-orchestrate closes → step-implement-1 and step-implement-2 unblocked
    #   → both close → step-land unblocked → treehugger claims and closes it.
    # step-land closed with reason=landed is the authoritative success signal.
    #
    # Timeout: 2000s (~33 min). Generous ceiling because this scenario has three
    # sequential LLM phases (foreman, implementers, treehugger), each potentially
    # multi-turn. Adjust down once empirical timing data is available.

    echo "[${SCENARIO_ID}] awaiting step-land (${BD_STEP_LAND}) close..."

    AWAIT_RC=0
    shim_await "${BD_STEP_LAND}" 2000 || AWAIT_RC=$?

    checkpoint close

    if [[ "${AWAIT_RC}" -eq 0 ]]; then
        echo "[${SCENARIO_ID}] step-land closed — SUCCESS"
        return 0
    fi

    # Timeout / failure path: dump diagnostics so the treehugger can triage.
    echo "[${SCENARIO_ID}] FAILED (await exit ${AWAIT_RC})" >&2
    _dump_diagnostics
    return 1
}

main() {
    scenario05_pour && scenario05_route && scenario05_spawn_workers && scenario05_close
}

# ---------------------------------------------------------------------------
# --step dispatcher
# ---------------------------------------------------------------------------

_VALID_STEPS="pour route spawn_workers close"

if [[ $# -ge 1 && "$1" == "--step" ]]; then
    if [[ $# -lt 2 ]]; then
        echo "[${SCENARIO_ID}] ERROR: --step requires a step name" >&2
        echo "Valid steps: ${_VALID_STEPS}" >&2
        exit 1
    fi
    _STEP="$2"
    case "${_STEP}" in
        pour)          scenario05_pour ;;
        route)         scenario05_pour && scenario05_route ;;
        spawn_workers) scenario05_pour && scenario05_route && scenario05_spawn_workers ;;
        close)         scenario05_pour && scenario05_route && scenario05_spawn_workers && scenario05_close ;;
        *)
            echo "[${SCENARIO_ID}] ERROR: unknown step '${_STEP}'" >&2
            echo "Valid steps: ${_VALID_STEPS}" >&2
            exit 1
            ;;
    esac
else
    main
fi
