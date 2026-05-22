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
#      Includes a comments_contain assertion.
#   5. Spawn one implementer session via shim_spawn.
#   6. Await step-loop closed via shim_await.
#   7. Exit 0 on success; on failure/timeout dump diagnostics and exit 1.
#
# Pattern shape: ONE bead, many internal tool invocations, agent decides
# the plan. Validates that the substrate doesn't try to over-structure
# dynamic agentic work — the bead is a unit of work + state container;
# the agent owns the planning and records its output as a comment.
#
# Step CLI: bash 07-agent-loop.sh --step <name> runs up to that step and exits.
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

# Shared state set by scenario07_pour, consumed by later steps.
BD_STEP_LOOP=""
BD_ROOT=""
WISP_JSON=""

# ---------------------------------------------------------------------------
# Step functions
# ---------------------------------------------------------------------------

scenario07_pour() {
    # Substrate prep + pour formula + parse bead IDs.

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
    # Parse bead IDs from pour output (raw_decode pattern)
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

    checkpoint pour
}

scenario07_route() {
    # Route step-loop to implementer pool + write fixture.

    # Use bd update --assignee rather than gc sling — sidesteps gc sling's
    # auto-convoy bead creation (not needed for single-bead scenarios).
    # The assignee slot doubles as a pool name: validation/<persona>.
    # The implementer persona's pool query reads --assignee=validation/implementer.

    echo "[${SCENARIO_ID}] routing step-loop to implementer..."

    bd update "${BD_STEP_LOOP}" --assignee=validation/implementer
    echo "[${SCENARIO_ID}]   routed ${BD_STEP_LOOP}"

    # Write expected predicate fixture BEFORE spawning the agent.
    # Predicate kinds used:
    #   closed_in_order   — step-loop must close with reason=completed
    #   comments_contain  — step-loop comments must contain "bash"

    mkdir -p "${PACK_ROOT}/fixtures"
    cat > "${PACK_ROOT}/fixtures/${SCENARIO_ID}-expected.json" <<EOF
{
  "closed_in_order": [
    {"bead_id": "${BD_STEP_LOOP}", "reason": "completed"}
  ],
  "comments_contain": [
    {"bead_id": "${BD_STEP_LOOP}", "value": "bash"}
  ]
}
EOF

    echo "[${SCENARIO_ID}] predicate written to fixtures/${SCENARIO_ID}-expected.json"

    checkpoint route
}

scenario07_spawn() {
    # Spawn the implementer agent (via gc shim).

    echo "[${SCENARIO_ID}] spawning implementer agent..."
    shim_spawn implementer 1

    checkpoint spawn
}

scenario07_fake_worker() {
    # Deterministic stand-in for a passing implementer agent — no LLM required.
    # Performs the exact bd operations a real agent would: claim, comment, close.
    # Used when SCENARIO_MODE=fake to validate rig-side changes (shim/persona/
    # Dockerfile) without paying for an LLM run. If this path fails, the bug is
    # rig-side, not LLM-side.

    echo "[${SCENARIO_ID}] fake-worker: claiming ${BD_STEP_LOOP}..."
    bd update "${BD_STEP_LOOP}" --claim

    echo "[${SCENARIO_ID}] fake-worker: adding comment to ${BD_STEP_LOOP}..."
    bd comment "${BD_STEP_LOOP}" "ran: bash -c 'cat /etc/hostname' → vp-07-agent-loop"

    echo "[${SCENARIO_ID}] fake-worker: closing ${BD_STEP_LOOP}..."
    bd close "${BD_STEP_LOOP}" --reason completed

    echo "[${SCENARIO_ID}] fake-worker: done"
}

scenario07_close() {
    # Await step-loop close; dump diagnostics on failure.
    # Wait for step-loop to close. A single bead = the scenario is done when it
    # reaches terminal state.
    #
    # Timeout: 1500s (25 min). One bead, multi-step task; generous ceiling because
    # each bash invocation + note append involves a full Claude Code turn.

    echo "[${SCENARIO_ID}] awaiting step-loop (${BD_STEP_LOOP}) close..."

    AWAIT_RC=0
    shim_await "${BD_STEP_LOOP}" 1500 || AWAIT_RC=$?

    checkpoint close

    if [[ "${AWAIT_RC}" -eq 0 ]]; then
        echo "[${SCENARIO_ID}] step-loop closed — SUCCESS"
        return 0
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
    bd ready --include-ephemeral --assignee=validation/implementer --json --limit 1 2>&1 || true
    echo "--- gc session list ---" >&2
    gc session list --city "${PACK_ROOT}" 2>&1 || true
    return 1
}

main() {
    if [[ "${SCENARIO_MODE:-real}" == fake ]]; then
        scenario07_pour
        scenario07_route
        scenario07_fake_worker      # replaces spawn + await
        checkpoint verify
    else
        scenario07_pour && scenario07_route && scenario07_spawn && scenario07_close
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
        pour)  scenario07_pour ;;
        route) scenario07_pour && scenario07_route ;;
        spawn) scenario07_pour && scenario07_route && scenario07_spawn ;;
        close) scenario07_pour && scenario07_route && scenario07_spawn && scenario07_close ;;
        fake_worker) scenario07_pour && scenario07_route && scenario07_fake_worker ;;
        *)
            echo "[${SCENARIO_ID}] ERROR: unknown step '${_STEP}'" >&2
            echo "Valid steps: ${_VALID_STEPS}" >&2
            exit 1
            ;;
    esac
else
    main
fi
