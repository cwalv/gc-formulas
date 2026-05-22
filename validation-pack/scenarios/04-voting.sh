#!/usr/bin/env bash
# scenarios/04-voting.sh
#
# Driver for scenario 04: parallelization-voting (Anthropic catalog pattern 4).
#
# Invoked by run-scenario.sh, which exports:
#   SCENARIO_ID — "04-voting"
#   PACK_ROOT   — "/home/agent/validation-pack"
#
# What this driver does:
#   1. Substrate prep — formula symlink, ~/.beads discovery symlink, git identity.
#   2. Pour the voting formula (pour=true materialises root + 3 voter beads +
#      1 tally bead as persistent issues with proper blocker enforcement).
#   3. Route all 4 step beads to the implementer pool via direct metadata write
#      (NOT gc sling — avoids auto-convoy; stays orchestrator-agnostic per shim
#      architecture in validation-pack-design.md § Shim architecture).
#   4. Write the expected predicate fixture BEFORE spawning agents.
#      NOTE: the fixture uses `closed_unordered` for the 3 voter beads (same
#      predicate kind introduced by scenario 03) and a new `metadata_match`
#      predicate kind for asserting the tally bead's notes contain "4".
#   5. Spawn three implementer sessions via shim_spawn (count=3). All three
#      voters get the SAME prompt and answer independently — this is voting, not
#      sectioning (no output coordination between workers).
#   6. Await step-tally closed via shim_await (1500s ceiling). The tally bead's
#      deps enforce that all three voters closed first — tally closed means full
#      scenario success.
#   7. Exit 0 on success; on failure/timeout dump diagnostics and exit 1.
#
# Shim model: this driver sources shims/${SHIM:-gc}.sh to get shim_spawn,
# shim_prime, shim_await. Swapping SHIM=ntm (when shims/ntm.sh exists) re-runs
# the same scenario against a different orchestrator without touching this file.
#
# Step CLI: bash 04-voting.sh --step <name> runs up to that step and exits.
# Valid steps: pour, route, spawn_workers, close

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

# Shared state set by scenario04_pour, consumed by later steps.
BD_STEP_VOTER_1=""
BD_STEP_VOTER_2=""
BD_STEP_VOTER_3=""
BD_STEP_TALLY=""
WISP_JSON=""

# ---------------------------------------------------------------------------
# Step functions
# ---------------------------------------------------------------------------

scenario04_pour() {
    # Substrate prep + pour formula + parse bead IDs.

    # Formula search path: bd looks in .beads/formulas/ — symlink our formula in.
    mkdir -p .beads/formulas
    if [[ ! -e .beads/formulas/voting.formula.toml ]]; then
        ln -s "${PACK_ROOT}/formulas/voting.formula.toml" \
              .beads/formulas/voting.formula.toml
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

    # bd mol wisp (not wisp) for the same reason as scenarios 01 and 03: pour
    # creates persistent beads that `bd ready` treats with proper blocker semantics.
    # Ephemerals under wisp (even with --include-ephemeral) do NOT enforce blocker
    # deps — all beads appear ready simultaneously, defeating the voting pattern
    # where step-tally MUST be blocked until all three voters close.
    # Container is destroyed after the scenario so the persistence tradeoff is
    # irrelevant.
    #
    # Voter prompt is deliberately low-entropy arithmetic: "What is 2+2?" produces
    # the answer "4" from all three voters independently. The tally bead will
    # record unanimous majority "4". This makes the fixture assertion deterministic.

    VOTER_PROMPT="What is 2+2? Output only the digit, no other text."

    echo "[${SCENARIO_ID}] pouring formula voting..."

    WISP_JSON="$(bd mol wisp voting \
        --var voter_prompt="${VOTER_PROMPT}" \
        --var voter_count=3 \
        --var assignee=implementer \
        --json)"

    echo "[${SCENARIO_ID}] pour output: ${WISP_JSON}"

    # Parse the 4 step bead IDs from the id_mapping.
    # id_mapping keys are formula-scoped: "voting.step-voter-1" etc.
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
print(d['id_mapping']['voting.${step}'])
"
    }
    BD_STEP_VOTER_1="$(_parse_step step-voter-1)"
    BD_STEP_VOTER_2="$(_parse_step step-voter-2)"
    BD_STEP_VOTER_3="$(_parse_step step-voter-3)"
    BD_STEP_TALLY="$(_parse_step step-tally)"

    echo "[${SCENARIO_ID}] step-voter-1=${BD_STEP_VOTER_1} step-voter-2=${BD_STEP_VOTER_2} step-voter-3=${BD_STEP_VOTER_3} step-tally=${BD_STEP_TALLY}"

    checkpoint pour
}

scenario04_route() {
    # Route all 4 step beads to the implementer pool + write fixture.

    # All 4 beads get assignee=validation/implementer. The tally bead's blocker
    # deps mean it won't appear in `bd ready` until all three voters close — routing
    # it now is harmless and ensures the same worker persona picks it up once ready.

    echo "[${SCENARIO_ID}] routing beads to implementer..."

    for STEP_ID in "${BD_STEP_VOTER_1}" "${BD_STEP_VOTER_2}" "${BD_STEP_VOTER_3}" "${BD_STEP_TALLY}"; do
        bd update "${STEP_ID}" --assignee=validation/implementer
        echo "[${SCENARIO_ID}]   routed ${STEP_ID}"
    done

    # Write expected predicate fixture BEFORE spawning agents.
    # verify_bead_state.py reads this file after the scenario.
    #
    # PREDICATE KINDS IN USE:
    #   - closed_unordered: asserts each named bead is closed with the named reason;
    #     no ordering constraint among entries. The three voter beads close in any
    #     mutual order.
    #   - closed_in_order: used for the tally bead alone, asserting it closes AFTER
    #     all voters with reason `tallied`.
    #   - comments_contain: asserts the tally bead has at least one comment
    #     containing "4", confirming the majority answer was recorded via bd comment.

    mkdir -p "${PACK_ROOT}/fixtures"
    cat > "${PACK_ROOT}/fixtures/${SCENARIO_ID}-expected.json" <<EOF
{
  "_comment": "closed_unordered asserts each voter bead is closed with reason=completed (no ordering constraint). closed_in_order asserts the tally bead closed with reason=tallied after all voters. comments_contain asserts the tally bead has a comment containing the majority answer.",
  "closed_unordered": [
    {"bead_id": "${BD_STEP_VOTER_1}", "reason": "completed"},
    {"bead_id": "${BD_STEP_VOTER_2}", "reason": "completed"},
    {"bead_id": "${BD_STEP_VOTER_3}", "reason": "completed"}
  ],
  "closed_in_order": [
    {"bead_id": "${BD_STEP_TALLY}", "reason": "tallied"}
  ],
  "comments_contain": [
    {"bead_id": "${BD_STEP_TALLY}", "value": "4"}
  ]
}
EOF

    echo "[${SCENARIO_ID}] predicate written to fixtures/${SCENARIO_ID}-expected.json"

    checkpoint route
}

scenario04_spawn_workers() {
    # Spawn 3 parallel implementer agents (voting fan-out pattern).
    # shim_spawn implementer 3 — start 3 concurrent implementer sessions. Each
    # voter bead carries the SAME prompt; each worker claims one voter bead and
    # answers independently. Unlike sectioning (where each slice has distinct
    # work), all three workers here are doing the same task on different bead
    # instances. This is the self-consistency / majority-vote pattern: N
    # independent samples from the same prompt, aggregated by the tally bead.
    #
    # The substrate's atomic claim ensures each voter bead is claimed by exactly
    # one worker — no double-claim. The tally bead is blocked by deps; it will not
    # appear in any worker's `bd ready` until all three voters close.
    #
    # NOTE: shim_spawn requires tmux in the container image (plus dolt + lsof for
    # gc start). The baseline Dockerfile does not include these; the treehugger
    # must add them (open question fo-h8o87.1.8, noted in close notes). Until
    # that Dockerfile change lands, shim_spawn will exit non-zero with a clear
    # diagnostic.

    echo "[${SCENARIO_ID}] spawning 3 parallel implementer agents (voter beads)..."
    shim_spawn implementer 3

    checkpoint spawn
}

scenario04_fake_workers() {
    # Deterministic stand-in — no LLM required.
    # Fixture asserts:
    #   closed_unordered: voter-1, voter-2, voter-3 with reason=completed
    #   closed_in_order:  step-tally with reason=tallied
    #   comments_contain: step-tally must have a comment containing "4"
    # Close voters first (any order); tally has blocker deps so close it last.
    # Each voter posts their answer as a comment before closing.

    echo "[${SCENARIO_ID}] fake-workers: voter-1 (${BD_STEP_VOTER_1})..."
    bd update "${BD_STEP_VOTER_1}" --status=in_progress
    bd comment "${BD_STEP_VOTER_1}" "4"
    bd close "${BD_STEP_VOTER_1}" --reason completed

    echo "[${SCENARIO_ID}] fake-workers: voter-2 (${BD_STEP_VOTER_2})..."
    bd update "${BD_STEP_VOTER_2}" --status=in_progress
    bd comment "${BD_STEP_VOTER_2}" "4"
    bd close "${BD_STEP_VOTER_2}" --reason completed

    echo "[${SCENARIO_ID}] fake-workers: voter-3 (${BD_STEP_VOTER_3})..."
    bd update "${BD_STEP_VOTER_3}" --status=in_progress
    bd comment "${BD_STEP_VOTER_3}" "4"
    bd close "${BD_STEP_VOTER_3}" --reason completed

    echo "[${SCENARIO_ID}] fake-workers: tally (${BD_STEP_TALLY})..."
    bd update "${BD_STEP_TALLY}" --status=in_progress
    bd comment "${BD_STEP_TALLY}" "Tally: majority answer is 4 (unanimous 3/3)"
    bd close "${BD_STEP_TALLY}" --reason tallied

    echo "[${SCENARIO_ID}] fake-workers: done"
}

scenario04_close() {
    # Await step-tally close (gates on all 3 voters via substrate deps).
    # Wait for step-tally to close. The substrate's dep enforcement guarantees that
    # all three voter beads close before step-tally becomes ready — so step-tally
    # closed means the entire voting + tally sequence completed successfully.
    #
    # Timeout: 1500s (25 min). Three voter turns plus one tally turn; generous
    # ceiling consistent with scenarios 01 and 03.

    echo "[${SCENARIO_ID}] awaiting step-tally (${BD_STEP_TALLY}) close..."

    AWAIT_RC=0
    shim_await "${BD_STEP_TALLY}" 1500 || AWAIT_RC=$?

    checkpoint close

    if [[ "${AWAIT_RC}" -eq 0 ]]; then
        echo "[${SCENARIO_ID}] step-tally closed — SUCCESS"
        echo "[${SCENARIO_ID}] all 3 voters + tally completed; voting scenario PASS"
        return 0
    fi

    # Timeout / failure path: dump diagnostics so the treehugger can triage.
    echo "[${SCENARIO_ID}] FAILED (await exit ${AWAIT_RC})" >&2
    echo "--- voter bead states ---" >&2
    bd list --status=open --json 2>/dev/null \
        | jq -r "[.[] | select(.id==\"${BD_STEP_VOTER_1}\" or .id==\"${BD_STEP_VOTER_2}\" or .id==\"${BD_STEP_VOTER_3}\" or .id==\"${BD_STEP_TALLY}\")] | .[] | [.id, .status, .title] | @tsv" \
        2>&1 || true
    echo "--- hooked beads in this run ---" >&2
    bd list --status=hooked --json 2>/dev/null \
        | jq -r "[.[] | select(.id==\"${BD_STEP_VOTER_1}\" or .id==\"${BD_STEP_VOTER_2}\" or .id==\"${BD_STEP_VOTER_3}\" or .id==\"${BD_STEP_TALLY}\")] | .[] | [.id, .status, .title] | @tsv" \
        2>&1 || true
    echo "--- closed beads in this run ---" >&2
    bd list --status=closed --json 2>/dev/null \
        | jq -r "[.[] | select(.id==\"${BD_STEP_VOTER_1}\" or .id==\"${BD_STEP_VOTER_2}\" or .id==\"${BD_STEP_VOTER_3}\" or .id==\"${BD_STEP_TALLY}\")] | .[] | [.id, .status, .close_reason, .title] | @tsv" \
        2>&1 || true
    echo "--- bd ready (implementer pool) ---" >&2
    bd ready --include-ephemeral --assignee=validation/implementer --json --limit 1 2>&1 || true
    echo "--- gc session list ---" >&2
    gc session list --city "${PACK_ROOT}" 2>&1 || true
    return 1
}

main() {
    if [[ "${SCENARIO_MODE:-real}" == fake ]]; then
        scenario04_pour
        scenario04_route
        scenario04_fake_workers     # replaces spawn + await
        checkpoint verify
    else
        scenario04_pour && scenario04_route && scenario04_spawn_workers && scenario04_close
    fi
}

# ---------------------------------------------------------------------------
# --step dispatcher
# ---------------------------------------------------------------------------

_VALID_STEPS="pour route spawn_workers close fake_workers"

if [[ $# -ge 1 && "$1" == "--step" ]]; then
    if [[ $# -lt 2 ]]; then
        echo "[${SCENARIO_ID}] ERROR: --step requires a step name" >&2
        echo "Valid steps: ${_VALID_STEPS}" >&2
        exit 1
    fi
    _STEP="$2"
    case "${_STEP}" in
        pour)          scenario04_pour ;;
        route)         scenario04_pour && scenario04_route ;;
        spawn_workers) scenario04_pour && scenario04_route && scenario04_spawn_workers ;;
        close)         scenario04_pour && scenario04_route && scenario04_spawn_workers && scenario04_close ;;
        fake_workers)  scenario04_pour && scenario04_route && scenario04_fake_workers ;;
        *)
            echo "[${SCENARIO_ID}] ERROR: unknown step '${_STEP}'" >&2
            echo "Valid steps: ${_VALID_STEPS}" >&2
            exit 1
            ;;
    esac
else
    main
fi
