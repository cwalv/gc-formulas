#!/usr/bin/env bash
# scenarios/03-sectioning.sh
#
# Driver for scenario 03: parallelization-sectioning (Anthropic catalog pattern 3).
#
# Invoked by run-scenario.sh, which exports:
#   SCENARIO_ID — "03-sectioning"
#   PACK_ROOT   — "/home/agent/validation-pack"
#
# What this driver does:
#   1. Substrate prep — formula symlink, ~/.beads discovery symlink, git identity.
#   2. Pour the sectioning formula (pour=true materialises root + 3 slice beads +
#      1 join bead as persistent issues with proper blocker enforcement).
#   3. Route all 4 step beads to the implementer pool via direct metadata write
#      (NOT gc sling — avoids auto-convoy; stays orchestrator-agnostic per shim
#      architecture in validation-pack-design.md § Shim architecture).
#   4. Write the expected predicate fixture BEFORE spawning agents.
#      NOTE: the fixture uses a new predicate kind `closed_unordered` for the
#      3 parallel slices — see comment in the fixture section below.
#   5. Spawn three implementer sessions via shim_spawn (count=3). The substrate's
#      atomic `bd update --claim` prevents double-claim; three workers racing to
#      claim three beads is the sectioning pattern's collision-safety test.
#   6. Await step-join closed via shim_await (1500s ceiling). The join bead's deps
#      enforce that all three slices closed first — join closed means full scenario
#      success.
#   7. Exit 0 on success; on failure/timeout dump diagnostics and exit 1.
#
# Shim model: this driver sources shims/${SHIM:-gc}.sh to get shim_spawn,
# shim_prime, shim_await. Swapping SHIM=ntm (when shims/ntm.sh exists) re-runs
# the same scenario against a different orchestrator without touching this file.
#
# Step CLI: bash 03-sectioning.sh --step <name> runs up to that step and exits.
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

# Shared state set by scenario03_pour, consumed by later steps.
BD_STEP_SLICE_1=""
BD_STEP_SLICE_2=""
BD_STEP_SLICE_3=""
BD_STEP_JOIN=""
WISP_JSON=""

# ---------------------------------------------------------------------------
# Step functions
# ---------------------------------------------------------------------------

scenario03_pour() {
    # Substrate prep + pour formula + parse bead IDs.

    # Formula search path: bd looks in .beads/formulas/ — symlink our formula in.
    mkdir -p .beads/formulas
    if [[ ! -e .beads/formulas/sectioning.formula.toml ]]; then
        ln -s "${PACK_ROOT}/formulas/sectioning.formula.toml" \
              .beads/formulas/sectioning.formula.toml
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

    # bd mol wisp (not wisp) for the same reason as scenario 01: pour creates
    # persistent beads that `bd ready` treats with proper blocker semantics.
    # Ephemerals under wisp (even with --include-ephemeral) do NOT enforce
    # blocker deps — all beads appear ready simultaneously, defeating the
    # parallelization-sectioning pattern where step-join MUST be blocked until
    # all three slices close. Container is destroyed after the scenario so the
    # persistence tradeoff is irrelevant.
    #
    # Three slices with concrete, non-overlapping tasks:
    #   slice-1: haiku about blue
    #   slice-2: haiku about red
    #   slice-3: haiku about green
    #   join:    combine the three haikus into a numbered list
    # These tasks are deterministic and require no shared state between workers.

    TASK_TEMPLATE="Generate a one-line haiku about a primary color. Each slice covers a distinct color so workers can proceed independently with no shared state."

    echo "[${SCENARIO_ID}] pouring formula sectioning..."

    WISP_JSON="$(bd mol wisp sectioning \
        --var task_template="${TASK_TEMPLATE}" \
        --var slice_count=3 \
        --var assignee=implementer \
        --json)"

    echo "[${SCENARIO_ID}] pour output: ${WISP_JSON}"

    # Parse the 4 step bead IDs from the id_mapping.
    # id_mapping keys are formula-scoped: "sectioning.step-slice-1" etc.
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
print(d['id_mapping']['sectioning.${step}'])
"
    }
    BD_STEP_SLICE_1="$(_parse_step step-slice-1)"
    BD_STEP_SLICE_2="$(_parse_step step-slice-2)"
    BD_STEP_SLICE_3="$(_parse_step step-slice-3)"
    BD_STEP_JOIN="$(_parse_step step-join)"

    echo "[${SCENARIO_ID}] step-slice-1=${BD_STEP_SLICE_1} step-slice-2=${BD_STEP_SLICE_2} step-slice-3=${BD_STEP_SLICE_3} step-join=${BD_STEP_JOIN}"

    checkpoint pour
}

scenario03_route() {
    # Route all 4 step beads to the implementer pool + write fixture.

    # All 4 beads get assignee=validation/implementer. The join bead's blocker
    # deps mean it won't appear in `bd ready` until all three slices close — routing
    # it now is harmless and ensures the same worker persona picks it up once ready.

    echo "[${SCENARIO_ID}] routing beads to implementer..."

    for STEP_ID in "${BD_STEP_SLICE_1}" "${BD_STEP_SLICE_2}" "${BD_STEP_SLICE_3}" "${BD_STEP_JOIN}"; do
        bd update "${STEP_ID}" --assignee=validation/implementer
        echo "[${SCENARIO_ID}]   routed ${STEP_ID}"
    done

    # Write expected predicate fixture BEFORE spawning agents.
    # verify_bead_state.py reads this file after the scenario.
    #
    # PREDICATE KINDS IN USE:
    #   - closed_unordered: NEW predicate kind — NOT YET supported by
    #     verify_bead_state.py. Treehugger must add support for it. This predicate
    #     asserts that a set of beads are all closed with matching reasons, but
    #     makes no claim about the order they closed relative to each other.
    #     The three slice beads are the canonical use case: they can close in any
    #     mutual order; only the join-after-all-slices ordering is required.
    #
    #     Proposed schema:
    #       [{"bead_id": "...", "reason": "..."}]
    #     Asserts: for each entry, the named bead is closed with the named reason.
    #     Ordering within the list is unspecified (any permutation is valid).
    #
    #   - closed_in_order: supported today. Used here for the join bead alone,
    #     expressing that it closes AFTER all the unordered slices. For the
    #     verifier to honour this properly it must check that the join bead's
    #     closed_at timestamp is >= all slice beads' closed_at timestamps.
    #     Until closed_unordered is implemented, this entry at least confirms
    #     the join bead closed.
    #
    # Until the verifier supports closed_unordered, the scenario driver performs
    # the terminal-state check inline: it awaits step-join closing (step 6), which
    # by substrate dep semantics guarantees all three slices are already closed.

    mkdir -p "${PACK_ROOT}/fixtures"
    cat > "${PACK_ROOT}/fixtures/${SCENARIO_ID}-expected.json" <<EOF
{
  "_comment": "closed_unordered is a NEW predicate kind — not yet supported by verify_bead_state.py. Treehugger must extend verify_bead_state.py to evaluate this predicate kind. It asserts each named bead is closed with the named reason, with no ordering constraint among entries. The join bead's closed_in_order entry covers the aggregate success check (join closed last) until the unordered variant is implemented.",
  "closed_unordered": [
    {"bead_id": "${BD_STEP_SLICE_1}", "reason": "completed"},
    {"bead_id": "${BD_STEP_SLICE_2}", "reason": "completed"},
    {"bead_id": "${BD_STEP_SLICE_3}", "reason": "completed"}
  ],
  "closed_in_order": [
    {"bead_id": "${BD_STEP_JOIN}", "reason": "completed"}
  ]
}
EOF

    echo "[${SCENARIO_ID}] predicate written to fixtures/${SCENARIO_ID}-expected.json"

    checkpoint route
}

scenario03_spawn_workers() {
    # Spawn 3 parallel implementer agents (fan-out pattern).
    # shim_spawn implementer 3 — start 3 concurrent implementer sessions. Each
    # session runs the implementer persona loop: poll `bd ready` (filtered to
    # assignee=validation/implementer), claim via `bd update --claim`, work,
    # close. The substrate's atomic claim ensures that when three workers race for
    # three beads, each bead is claimed by exactly one worker — no collisions.
    # This is the sectioning pattern's core invariant under test.
    #
    # The join bead is also assigned to implementer but is blocked by deps — it will
    # not appear in any worker's `bd ready` results until all three slices close.
    # Once it unblocks, whichever idle worker picks it up first claims it and runs
    # the aggregation task.
    #
    # NOTE: shim_spawn requires tmux in the container image (plus dolt + lsof for
    # gc start). The baseline Dockerfile does not include these; the treehugger
    # must add them (open question fo-h8o87.1.8, noted in close notes). Until
    # that Dockerfile change lands, shim_spawn will exit non-zero with a clear
    # diagnostic.

    echo "[${SCENARIO_ID}] spawning 3 parallel implementer agents..."
    shim_spawn implementer 3

    checkpoint spawn
}

scenario03_fake_workers() {
    # Deterministic stand-in — no LLM required.
    # Fixture asserts:
    #   closed_unordered: slice-1, slice-2, slice-3 with reason=completed
    #   closed_in_order:  step-join with reason=completed
    # Close slices first (any order); join has blocker deps so close it last.

    echo "[${SCENARIO_ID}] fake-workers: closing slice-1 (${BD_STEP_SLICE_1})..."
    bd update "${BD_STEP_SLICE_1}" --status=in_progress
    bd close "${BD_STEP_SLICE_1}" --reason completed

    echo "[${SCENARIO_ID}] fake-workers: closing slice-2 (${BD_STEP_SLICE_2})..."
    bd update "${BD_STEP_SLICE_2}" --status=in_progress
    bd close "${BD_STEP_SLICE_2}" --reason completed

    echo "[${SCENARIO_ID}] fake-workers: closing slice-3 (${BD_STEP_SLICE_3})..."
    bd update "${BD_STEP_SLICE_3}" --status=in_progress
    bd close "${BD_STEP_SLICE_3}" --reason completed

    echo "[${SCENARIO_ID}] fake-workers: closing join (${BD_STEP_JOIN})..."
    bd update "${BD_STEP_JOIN}" --status=in_progress
    bd close "${BD_STEP_JOIN}" --reason completed

    echo "[${SCENARIO_ID}] fake-workers: done"
}

scenario03_close() {
    # Await step-join close (gates on all 3 slices via substrate deps).
    # Wait for step-join to close. The substrate's dep enforcement guarantees that
    # all three slices close before step-join becomes ready — so step-join closed
    # means the entire sectioning + join sequence completed successfully.
    #
    # Timeout: 1500s (25 min). Three beads involve three full Claude Code turns
    # (one per worker) plus the join turn. Generous ceiling; adjust after timing
    # observations accumulate.

    echo "[${SCENARIO_ID}] awaiting step-join (${BD_STEP_JOIN}) close..."

    AWAIT_RC=0
    shim_await "${BD_STEP_JOIN}" 1500 || AWAIT_RC=$?

    checkpoint close

    if [[ "${AWAIT_RC}" -eq 0 ]]; then
        echo "[${SCENARIO_ID}] step-join closed — SUCCESS"
        echo "[${SCENARIO_ID}] all 3 slices + join completed; sectioning scenario PASS"
        return 0
    fi

    # Timeout / failure path: dump diagnostics so the treehugger can triage.
    echo "[${SCENARIO_ID}] FAILED (await exit ${AWAIT_RC})" >&2
    echo "--- slice bead states ---" >&2
    bd list --status=open --json 2>/dev/null \
        | jq -r "[.[] | select(.id==\"${BD_STEP_SLICE_1}\" or .id==\"${BD_STEP_SLICE_2}\" or .id==\"${BD_STEP_SLICE_3}\" or .id==\"${BD_STEP_JOIN}\")] | .[] | [.id, .status, .title] | @tsv" \
        2>&1 || true
    echo "--- hooked beads in this run ---" >&2
    bd list --status=hooked --json 2>/dev/null \
        | jq -r "[.[] | select(.id==\"${BD_STEP_SLICE_1}\" or .id==\"${BD_STEP_SLICE_2}\" or .id==\"${BD_STEP_SLICE_3}\" or .id==\"${BD_STEP_JOIN}\")] | .[] | [.id, .status, .title] | @tsv" \
        2>&1 || true
    echo "--- closed beads in this run ---" >&2
    bd list --status=closed --json 2>/dev/null \
        | jq -r "[.[] | select(.id==\"${BD_STEP_SLICE_1}\" or .id==\"${BD_STEP_SLICE_2}\" or .id==\"${BD_STEP_SLICE_3}\" or .id==\"${BD_STEP_JOIN}\")] | .[] | [.id, .status, .close_reason, .title] | @tsv" \
        2>&1 || true
    echo "--- bd ready (implementer pool) ---" >&2
    bd ready --include-ephemeral --assignee=validation/implementer --json --limit 1 2>&1 || true
    echo "--- gc session list ---" >&2
    gc session list --city "${PACK_ROOT}" 2>&1 || true
    return 1
}

main() {
    if [[ "${SCENARIO_MODE:-real}" == fake ]]; then
        scenario03_pour
        scenario03_route
        scenario03_fake_workers     # replaces spawn + await
        checkpoint verify
    else
        scenario03_pour && scenario03_route && scenario03_spawn_workers && scenario03_close
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
        pour)          scenario03_pour ;;
        route)         scenario03_pour && scenario03_route ;;
        spawn_workers) scenario03_pour && scenario03_route && scenario03_spawn_workers ;;
        close)         scenario03_pour && scenario03_route && scenario03_spawn_workers && scenario03_close ;;
        fake_workers)  scenario03_pour && scenario03_route && scenario03_fake_workers ;;
        *)
            echo "[${SCENARIO_ID}] ERROR: unknown step '${_STEP}'" >&2
            echo "Valid steps: ${_VALID_STEPS}" >&2
            exit 1
            ;;
    esac
else
    main
fi
