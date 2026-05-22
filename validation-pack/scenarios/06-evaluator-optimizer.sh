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
#
# Step CLI: bash 06-evaluator-optimizer.sh --step <name> runs up to that step
# and exits. Valid steps: pour, route, spawn, close

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

# Shared state set by scenario06_pour, consumed by later steps.
BD_ROOT=""
BD_STEP_ITERATE=""
WISP_JSON=""

# ---------------------------------------------------------------------------
# Step functions
# ---------------------------------------------------------------------------

scenario06_pour() {
    # Substrate prep + pour formula + parse bead IDs.

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

    # bd mol wisp (not wisp): pour creates persistent beads with proper blocker
    # semantics. The container is destroyed after the scenario, so persistence
    # is irrelevant, but pour avoids the bd ready ephemeral-exclusion issue
    # documented in scenario 01.

    echo "[${SCENARIO_ID}] pouring formula evaluator-optimizer..."

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

    checkpoint pour
}

scenario06_route() {
    # Route step-iterate to implementer pool + write fixture.

    # Direct assignee write — avoids gc sling auto-convoy creation (only useful
    # for parallel fan-out scenarios). The assignee slot doubles as a pool name:
    # validation/<persona>.

    echo "[${SCENARIO_ID}] routing step-iterate to implementer..."
    bd update "${BD_STEP_ITERATE}" --assignee=validation/implementer
    echo "[${SCENARIO_ID}]   routed ${BD_STEP_ITERATE} → validation/implementer"

    # Write expected predicate fixture BEFORE spawning agents.
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
    # comments_contain: confirms at least one iteration fired — the evaluator
    #   emits a `bd comment "iterate: forced-round-1: ..."` on its first review.
    #   We assert on comments (append-only) rather than notes (single-field,
    #   overwritten by the implementer's next draft); the marker would
    #   otherwise vanish from notes after round-2 implementer write-through.

    mkdir -p "${PACK_ROOT}/fixtures"
    cat > "${PACK_ROOT}/fixtures/${SCENARIO_ID}-expected.json" <<EOF
{
  "closed_in_order": [
    {
      "bead_id": "${BD_STEP_ITERATE}",
      "reason_one_of": ["approved", "max-iterations-reached"]
    }
  ],
  "comments_contain": [
    {
      "bead_id": "${BD_STEP_ITERATE}",
      "value": "iterate: forced-round-1"
    }
  ]
}
EOF

    echo "[${SCENARIO_ID}] predicate written to fixtures/${SCENARIO_ID}-expected.json"

    checkpoint route
}

scenario06_spawn() {
    # Spawn implementer + evaluator agents (via gc shim).
    # Both agents loop continuously: claim → execute → route/close → drain-ack.
    # The implementer will initially pick up step-iterate (routed to
    # validation/implementer), produce a draft, and re-route to the evaluator.
    # The evaluator will then pick it up, review, and either close or route back.
    # Spawning both before the bead flips ensures no idle wait between handoffs.

    echo "[${SCENARIO_ID}] spawning implementer agent..."
    shim_spawn implementer 1

    echo "[${SCENARIO_ID}] spawning evaluator agent..."
    shim_spawn evaluator 1

    checkpoint spawn
}

scenario06_fake_worker() {
    # Deterministic stand-in — no LLM required.
    # Fixture asserts:
    #   closed_in_order:  step-iterate with reason_one_of=[approved, max-iterations-reached]
    #   comments_contain: step-iterate must have a comment containing "iterate: forced-round-1"
    # Fake the ping-pong: implementer draft-1 → evaluator forced-round-1 iterate comment
    # → implementer draft-2 → evaluator approves → close with reason=approved.

    echo "[${SCENARIO_ID}] fake-worker: implementer claiming ${BD_STEP_ITERATE}..."
    bd update "${BD_STEP_ITERATE}" --claim

    echo "[${SCENARIO_ID}] fake-worker: implementer posting draft-1..."
    bd comment "${BD_STEP_ITERATE}" "draft-1: Teal depths call softly / Shimmering hues of stillness / Ocean meets the sky"

    echo "[${SCENARIO_ID}] fake-worker: evaluator posting forced-round-1 iterate marker..."
    bd comment "${BD_STEP_ITERATE}" "iterate: forced-round-1: syllable count in line 2 needs review — revise and resubmit"

    echo "[${SCENARIO_ID}] fake-worker: implementer posting draft-2 (revised)..."
    bd comment "${BD_STEP_ITERATE}" "draft-2: Teal depths call softly / Cool hues shimmer in stillness / Sky meets the ocean"

    echo "[${SCENARIO_ID}] fake-worker: evaluator approving and closing ${BD_STEP_ITERATE}..."
    bd comment "${BD_STEP_ITERATE}" "approved: haiku satisfies 5-7-5 syllable constraint"
    bd close "${BD_STEP_ITERATE}" --reason approved

    echo "[${SCENARIO_ID}] fake-worker: done"
}

scenario06_close() {
    # Await terminal state via shim_await.
    # Wait for step-iterate to close (approved or max-iterations-reached).
    # Timeout: 2400s (40 min). Generous ceiling to allow up to 3 full iterations,
    # each involving a full Claude Code turn for both implementer and evaluator.
    # Adjust once empirical timing is established.

    echo "[${SCENARIO_ID}] awaiting step-iterate (${BD_STEP_ITERATE}) close..."

    AWAIT_RC=0
    shim_await "${BD_STEP_ITERATE}" 2400 || AWAIT_RC=$?

    checkpoint close

    if [[ "${AWAIT_RC}" -eq 0 ]]; then
        echo "[${SCENARIO_ID}] step-iterate closed — SUCCESS"
        return 0
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
    bd ready --include-ephemeral --assignee=validation/implementer --json --limit 1 2>&1 || true
    echo "--- bd ready (evaluator pool) ---" >&2
    bd ready --include-ephemeral --assignee=validation/evaluator --json --limit 1 2>&1 || true
    echo "--- gc session list ---" >&2
    gc session list --city "${PACK_ROOT}" 2>&1 || true
    echo "--- step-iterate notes ---" >&2
    bd show "${BD_STEP_ITERATE}" --json 2>/dev/null | jq '.notes' 2>&1 || true
    return 1
}

main() {
    if [[ "${SCENARIO_MODE:-real}" == fake ]]; then
        scenario06_pour
        scenario06_route
        scenario06_fake_worker      # replaces spawn + await
        checkpoint verify
    else
        scenario06_pour && scenario06_route && scenario06_spawn && scenario06_close
    fi
}

# ---------------------------------------------------------------------------
# --step dispatcher
# ---------------------------------------------------------------------------

_VALID_STEPS="pour route spawn close fake_worker"

if [[ $# -ge 1 && "$1" == "--step" ]]; then
    if [[ $# -lt 2 ]]; then
        echo "[${SCENARIO_ID}] ERROR: --step requires a step name" >&2
        echo "Valid steps: ${_VALID_STEPS}" >&2
        exit 1
    fi
    _STEP="$2"
    case "${_STEP}" in
        pour)        scenario06_pour ;;
        route)       scenario06_pour && scenario06_route ;;
        spawn)       scenario06_pour && scenario06_route && scenario06_spawn ;;
        close)       scenario06_pour && scenario06_route && scenario06_spawn && scenario06_close ;;
        fake_worker) scenario06_pour && scenario06_route && scenario06_fake_worker ;;
        *)
            echo "[${SCENARIO_ID}] ERROR: unknown step '${_STEP}'" >&2
            echo "Valid steps: ${_VALID_STEPS}" >&2
            exit 1
            ;;
    esac
else
    main
fi
