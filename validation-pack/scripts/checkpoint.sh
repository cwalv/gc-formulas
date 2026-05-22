#!/usr/bin/env bash
# scripts/checkpoint.sh — DEBUG_PAUSE_AT checkpoint mechanism.
#
# Usage (in a scenario driver):
#   source "${PACK_ROOT}/scripts/checkpoint.sh"
#   ...
#   checkpoint pour    # pauses here if "pour" is in DEBUG_PAUSE_AT
#   checkpoint route
#   checkpoint spawn
#   checkpoint close
#   checkpoint verify  # also wired into run-scenario.sh
#
# Operator workflow:
#   1. Set DEBUG_PAUSE_AT=pour,spawn (comma-separated) before running the container.
#   2. When the scenario hits a named checkpoint it sleeps for 2 hours and prints
#      inspection/unblock instructions.
#   3. Inspect: docker exec <container> /home/agent/validation-pack/scripts/inspect.sh
#   4. Unblock: docker exec <container> pkill -f "sleep 7200"
#
# The function is idempotent and safe to call even when DEBUG_PAUSE_AT is unset.

# ---------------------------------------------------------------------------
# checkpoint <name>
#   Pauses if <name> appears in the comma-separated DEBUG_PAUSE_AT env var.
# ---------------------------------------------------------------------------
checkpoint() {
    local name="${1:?checkpoint: name required}"

    # If DEBUG_PAUSE_AT is unset or empty, do nothing.
    local pause_list="${DEBUG_PAUSE_AT:-}"
    if [[ -z "${pause_list}" ]]; then
        return 0
    fi

    # Check whether <name> is in the comma-separated list.
    # Use a simple loop so we don't require external tools.
    local hit=0
    local IFS=','
    for entry in ${pause_list}; do
        # Trim whitespace.
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        if [[ "${entry}" == "${name}" ]]; then
            hit=1
            break
        fi
    done
    unset IFS

    if [[ "${hit}" -eq 0 ]]; then
        return 0
    fi

    # Resolve a container identifier for the hint message.
    # Try $HOSTNAME (set in containers) then fall back to a generic label.
    local container="${HOSTNAME:-<container>}"

    echo ""
    echo "[${SCENARIO_ID:-scenario}] PAUSED at checkpoint=${name}; inspect via 'docker exec ${container} /home/agent/validation-pack/scripts/inspect.sh'; unblock with 'docker exec ${container} pkill -f \"sleep 7200\"'"
    echo ""

    # Sleep 7200s (2h). The operator unblocks with pkill -f "sleep 7200".
    sleep 7200

    echo "[${SCENARIO_ID:-scenario}] checkpoint=${name} unblocked; continuing."
}
