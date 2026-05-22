#!/usr/bin/env bash
# scenarios/01-prompt-chaining.sh
#
# Driver for scenario 01: prompt-chaining (Anthropic catalog pattern 1).
#
# Invoked by run-scenario.sh, which exports:
#   SCENARIO_ID — "01-prompt-chaining"
#   PACK_ROOT   — "/home/agent/validation-pack"
#
# What this driver does:
#   1. Substrate prep — formula symlink, ~/.beads discovery symlink, git identity.
#   2. Wisp the prompt-chaining formula (formula declares pour=true so wisp
#      materialises root + 3 step beads as ephemeral vapor-phase issues).
#   3. Route each step bead to the implementer pool via direct metadata write
#      (NOT gc sling — avoids auto-convoy; stays orchestrator-agnostic per shim
#      architecture in validation-pack-design.md § Shim architecture).
#   4. Write the expected predicate fixture BEFORE spawning the agent.
#   5. Spawn one implementer session via shim_spawn (gc session new implementer).
#   6. Await step-c closed via shim_await (gc events --watch; falls back to bd poll).
#   7. Exit 0 on success; on failure/timeout dump diagnostics and exit 1.
#
# Shim model: this driver sources shims/${SHIM:-gc}.sh to get shim_spawn,
# shim_prime, shim_await. Swapping SHIM=ntm (when shims/ntm.sh exists) re-runs
# the same scenario against a different orchestrator without touching this file.
#
# Step CLI: bash 01-prompt-chaining.sh --step <name> runs ONE step and exits.
# Valid steps: pour, route, spawn, close

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

# Shared state set by scenario01_pour, consumed by scenario01_route and later steps.
BD_STEP_A=""
BD_STEP_B=""
BD_STEP_C=""
WISP_JSON=""

# ---------------------------------------------------------------------------
# Step functions
# ---------------------------------------------------------------------------

scenario01_pour() {
    # Substrate prep + wisp formula + parse bead IDs.

    # Formula search path: bd looks in .beads/formulas/ — symlink our formula in.
    mkdir -p .beads/formulas
    if [[ ! -e .beads/formulas/prompt-chaining.formula.toml ]]; then
        ln -s "${PACK_ROOT}/formulas/prompt-chaining.formula.toml" \
              .beads/formulas/prompt-chaining.formula.toml
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

    # bd mol wisp (not wisp): pour creates persistent beads that bd ready treats
    # with proper blocker semantics (step-b and step-c stay blocked until step-a
    # closes). bd ready EXCLUDES ephemeral wisp-beads by default; the workaround
    # (--include-ephemeral) shows them but DOES NOT enforce blocker deps for
    # ephemerals — leading to all 3 steps showing as ready simultaneously and the
    # agent claiming them out of order. Container is destroyed after the scenario,
    # so the "persistence" tradeoff is irrelevant for our validation use.

    echo "[${SCENARIO_ID}] wisping formula prompt-chaining..."

    WISP_JSON="$(bd mol wisp prompt-chaining \
        --var task_a="Output exactly three comma-separated single-word descriptors of the color blue (lowercase, no extra words)." \
        --var task_b="Read step-a's notes. For each word in the list, write a single sentence describing that word's connotation. Output one sentence per line." \
        --var task_c="Read step-b's notes. Combine the sentences into a single coherent paragraph of 3-5 sentences." \
        --var assignee=implementer \
        --json)"

    echo "[${SCENARIO_ID}] wisp output: ${WISP_JSON}"

    # Parse the 3 step bead IDs from the id_mapping.
    # id_mapping keys are formula-scoped: "prompt-chaining.step-a" etc.
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
print(d['id_mapping']['prompt-chaining.${step}'])
"
    }
    BD_STEP_A="$(_parse_step step-a)"
    BD_STEP_B="$(_parse_step step-b)"
    BD_STEP_C="$(_parse_step step-c)"

    echo "[${SCENARIO_ID}] step-a=${BD_STEP_A} step-b=${BD_STEP_B} step-c=${BD_STEP_C}"

    checkpoint pour
}

scenario01_route() {
    # Route step beads to implementer pool + write fixture.

    # Use bd update --assignee rather than gc sling — sidesteps gc sling's
    # auto-convoy bead creation (only useful for parallel-fan-out scenarios).
    # The assignee slot doubles as a pool name: validation/<persona>.
    # The implementer persona's pool query reads --assignee=validation/implementer.
    # Personas are orchestrator-specific (they reference gc hook, gc runtime
    # drain-ack) — an ntm shim would have its own persona + namespace.

    echo "[${SCENARIO_ID}] routing beads to implementer..."

    for STEP_ID in "${BD_STEP_A}" "${BD_STEP_B}" "${BD_STEP_C}"; do
        bd update "${STEP_ID}" --assignee=validation/implementer
        echo "[${SCENARIO_ID}]   routed ${STEP_ID}"
    done

    # Write expected predicate fixture BEFORE spawning the agent.
    # verify_bead_state.py reads this file after the scenario to assert the
    # bead DAG matches the expected shape.

    mkdir -p "${PACK_ROOT}/fixtures"
    cat > "${PACK_ROOT}/fixtures/${SCENARIO_ID}-expected.json" <<EOF
{
  "closed_in_order": [
    {"bead_id": "${BD_STEP_A}", "reason": "completed"},
    {"bead_id": "${BD_STEP_B}", "reason": "completed"},
    {"bead_id": "${BD_STEP_C}", "reason": "completed"}
  ]
}
EOF

    echo "[${SCENARIO_ID}] predicate written to fixtures/${SCENARIO_ID}-expected.json"

    checkpoint route
}

scenario01_spawn() {
    # Spawn the implementer agent (via gc shim).
    # shim_spawn creates one gc session from the 'implementer' agent template
    # (defined in city.toml). The session runs interactively under claude (Claude
    # Code subscription, not API-billed --print mode). The persona prompt
    # (personas/implementer.md, loaded via gc prime / prompt_template) instructs
    # the agent to loop: gc hook → bd update --claim → bd show → execute →
    # bd comment → bd close → repeat → gc runtime drain-ack on empty.
    #
    # NOTE: shim_spawn requires tmux in the container image (plus dolt + lsof for
    # gc start). The baseline Dockerfile does not include these; the treehugger
    # must add them (open question fo-h8o87.1.8, noted in close notes). Until
    # that Dockerfile change lands, shim_spawn will exit non-zero with a clear
    # diagnostic.

    echo "[${SCENARIO_ID}] spawning implementer agent..."
    shim_spawn implementer 1

    checkpoint spawn
}

scenario01_fake_worker() {
    # Deterministic stand-in for a passing implementer agent — no LLM required.
    # Closes step-a, step-b, step-c in dependency order with reason=completed.
    # The fixture asserts closed_in_order [step-a, step-b, step-c] with reason=completed.

    echo "[${SCENARIO_ID}] fake-worker: claiming ${BD_STEP_A}..."
    bd update "${BD_STEP_A}" --claim
    echo "[${SCENARIO_ID}] fake-worker: closing ${BD_STEP_A}..."
    bd close "${BD_STEP_A}" --reason completed

    echo "[${SCENARIO_ID}] fake-worker: claiming ${BD_STEP_B}..."
    bd update "${BD_STEP_B}" --claim
    echo "[${SCENARIO_ID}] fake-worker: closing ${BD_STEP_B}..."
    bd close "${BD_STEP_B}" --reason completed

    echo "[${SCENARIO_ID}] fake-worker: claiming ${BD_STEP_C}..."
    bd update "${BD_STEP_C}" --claim
    echo "[${SCENARIO_ID}] fake-worker: closing ${BD_STEP_C}..."
    bd close "${BD_STEP_C}" --reason completed

    echo "[${SCENARIO_ID}] fake-worker: done"
}

scenario01_close() {
    # Await step-c (final step) close; dump diagnostics on failure.
    # Wait for step-c (the final step) to close. The substrate's dep enforcement
    # guarantees A and B close before C becomes ready — so step-c closed means
    # the full chain completed.
    #
    # Timeout: 1500s (25 min). Generous ceiling because each bead involves a
    # full Claude Code turn. Adjust if scenario tuning reveals a tighter bound.

    echo "[${SCENARIO_ID}] awaiting step-c (${BD_STEP_C}) close..."

    AWAIT_RC=0
    shim_await "${BD_STEP_C}" 1500 || AWAIT_RC=$?

    checkpoint close

    if [[ "${AWAIT_RC}" -eq 0 ]]; then
        echo "[${SCENARIO_ID}] step-c closed — SUCCESS"
        return 0
    fi

    # Timeout / failure path: dump diagnostics so the treehugger can triage.
    echo "[${SCENARIO_ID}] FAILED (await exit ${AWAIT_RC})" >&2
    echo "--- open beads in this run ---" >&2
    bd list --status=open --json 2>/dev/null \
        | jq -r "[.[] | select(.id==\"${BD_STEP_A}\" or .id==\"${BD_STEP_B}\" or .id==\"${BD_STEP_C}\")] | .[] | [.id, .status, .title] | @tsv" \
        2>&1 || true
    echo "--- hooked beads in this run ---" >&2
    bd list --status=hooked --json 2>/dev/null \
        | jq -r "[.[] | select(.id==\"${BD_STEP_A}\" or .id==\"${BD_STEP_B}\" or .id==\"${BD_STEP_C}\")] | .[] | [.id, .status, .title] | @tsv" \
        2>&1 || true
    echo "--- bd ready (implementer pool) ---" >&2
    bd ready --include-ephemeral --assignee=validation/implementer --json --limit 1 2>&1 || true
    echo "--- gc session list ---" >&2
    gc session list --city "${PACK_ROOT}" 2>&1 || true
    return 1
}

main() {
    if [[ "${SCENARIO_MODE:-real}" == fake ]]; then
        scenario01_pour
        scenario01_route
        scenario01_fake_worker      # replaces spawn + await
        checkpoint verify
    else
        scenario01_pour && scenario01_route && scenario01_spawn && scenario01_close
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
        pour)        scenario01_pour ;;
        route)       scenario01_pour && scenario01_route ;;
        spawn)       scenario01_pour && scenario01_route && scenario01_spawn ;;
        close)       scenario01_pour && scenario01_route && scenario01_spawn && scenario01_close ;;
        fake_worker) scenario01_pour && scenario01_route && scenario01_fake_worker ;;
        *)
            echo "[${SCENARIO_ID}] ERROR: unknown step '${_STEP}'" >&2
            echo "Valid steps: ${_VALID_STEPS}" >&2
            exit 1
            ;;
    esac
else
    main
fi
