#!/usr/bin/env bash
# shims/gc.sh — gc orchestrator shim implementing the three primitives:
#   shim_spawn <persona> <count>
#   shim_prime <persona>
#   shim_await <bead-id> <timeout-secs>
#
# Sourced by scenario drivers (or by run-scenario.sh when it gains shim
# sourcing support). Assumes PACK_ROOT is set by the time these are called.
#
# Prerequisites in the container image:
#   - tmux (for gc session new / gc start)
#   - dolt  (for gc start's embedded Dolt controller mode)
#   - lsof  (for gc start's port checks)
# These are NOT in the baseline Dockerfile; the treehugger must add them.
# Until then, shim_spawn will fail with a clear diagnostic.

# ---------------------------------------------------------------------------
# shim_prime <persona>
#   Emit the persona's system prompt to stdout.
#   gc prime reads prompt_template from city.toml and renders it.
# ---------------------------------------------------------------------------
shim_prime() {
    local persona="${1:?shim_prime: persona required}"
    gc prime "${persona}" --city "${PACK_ROOT}"
}

# ---------------------------------------------------------------------------
# shim_spawn <persona> <count>
#   Start <count> interactive Claude sessions under the named agent template.
#   Each session runs the implementer lifecycle loop autonomously:
#     gc hook → bd update --claim → bd show → execute → bd close → repeat
#     → gc runtime drain-ack when empty.
#   Sessions are created with --no-attach (detached); they run in the
#   background managed by the gc controller.
#
# CONTRACT:
#   - Requires gc controller running (gc start must have been called first,
#     or the container entrypoint starts it).
#   - Requires tmux, dolt, lsof in the container image.
#   - Returns 0 if all sessions were created; non-zero otherwise.
# ---------------------------------------------------------------------------
shim_spawn() {
    local persona="${1:?shim_spawn: persona required}"
    local count="${2:-1}"

    # Sanity-check that tmux is present before calling gc session new.
    if ! command -v tmux &>/dev/null; then
        echo "[shim_spawn] FATAL: tmux not found in PATH." >&2
        echo "[shim_spawn] gc session new requires tmux. Add 'tmux' to the" >&2
        echo "[shim_spawn] Dockerfile (and dolt + lsof for gc start)." >&2
        return 1
    fi

    local i
    for (( i=1; i<=count; i++ )); do
        local alias="${persona}-$(printf '%02d' "${i}")"
        echo "[shim_spawn] creating session: template=${persona} alias=${alias}"
        gc session new "${persona}" \
            --no-attach \
            --alias "${alias}" \
            --title-hint "${SCENARIO_ID:-scenario} ${persona} worker ${i}" \
            --city "${PACK_ROOT}"
    done
}

# ---------------------------------------------------------------------------
# shim_await <bead-id> <timeout-secs>
#   Block until the named bead emits a bead.closed event, or until the
#   timeout elapses.
#
#   Primary mechanism: gc events --watch (uses the gc API event stream).
#   Fallback: bounded poll via bd list --status=closed --json | jq.
#   The fallback activates only when gc events --watch fails immediately
#   (e.g. the controller API is unreachable), not on legitimate timeouts.
#
# CONTRACT:
#   - Returns 0 if the bead closed within the timeout.
#   - Returns 1 on timeout or permanent API failure (with diagnostics to stderr).
# ---------------------------------------------------------------------------
shim_await() {
    local bead_id="${1:?shim_await: bead-id required}"
    local timeout_secs="${2:-1500}"

    echo "[shim_await] waiting for bead ${bead_id} to close (timeout ${timeout_secs}s)..."

    # We poll bd directly instead of using `gc events --watch --payload-match`:
    # gc events' --payload-match flag does not descend into nested fields, and
    # the bead.closed DTO carries the bead ID at payload.bead.id (not
    # payload.id). Without a working filter, --watch returns on the first
    # event of the requested type rather than on the target bead, which made
    # the scenario flaky. Polling `bd show --json` is bounded, cheap, and
    # explicit. (Polling cadence matches gascity's own watcher cadence.)
    _shim_await_poll "${bead_id}" "${timeout_secs}"
}

# Poll fallback for shim_await — used when the gc controller is not running.
# Not the preferred path; present so the scenario is testable even without
# a live gc supervisor (e.g. during incremental bring-up).
_shim_await_poll() {
    local bead_id="${1}"
    local timeout_secs="${2}"
    local poll_interval=5
    local start_ts
    start_ts="$(date +%s)"

    while true; do
        # `bd show <id> --json` returns a one-element array. Read status off
        # element [0]. Bounded query, no full-table scan.
        local status
        status="$(bd show "${bead_id}" --json 2>/dev/null \
            | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)[0]
    print(d.get("status",""))
except Exception:
    print("")' 2>/dev/null || echo "")"

        if [[ "${status}" == "closed" ]]; then
            echo "[shim_await] bead ${bead_id} closed (poll)"
            return 0
        fi

        local elapsed=$(( $(date +%s) - start_ts ))
        if [[ "${elapsed}" -ge "${timeout_secs}" ]]; then
            echo "[shim_await] TIMEOUT after ${elapsed}s: bead ${bead_id} still status=${status:-<unknown>}" >&2
            return 1
        fi

        sleep "${poll_interval}"
    done
}
