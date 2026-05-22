#!/usr/bin/env bash
set -euo pipefail

# entrypoint-gc-instrumented.sh — same as entrypoint-gc.sh but captures
# supervisor log to /home/agent/debug-artifacts/supervisor-<TAG>.log
# before container exit. Does NOT use exec so the EXIT trap fires.
#
# Usage: bind-mount this over scripts/entrypoint-gc-instrumented.sh and
# specify --entrypoint pointing here. Mount an artifacts dir from the host
# at /home/agent/debug-artifacts (must be writable by container UID).

echo "[INSTRUMENTED-ENTRYPOINT] starting (TAG=${SUPERVISOR_TAG:-notset})" >&2

mkdir -p "$HOME/.claude"
install -m 600 /mnt/host-claude/credentials.json "$HOME/.claude/.credentials.json"

TAG="${SUPERVISOR_TAG:-$(hostname | cut -c1-8)}"
SUPLOG="$HOME/.gc/supervisor.log"
DEST="/home/agent/debug-artifacts/supervisor-${TAG}.log"

gc start --city /home/agent/validation-pack

gc agent suspend dog --city /home/agent/validation-pack 2>&1 | head -3 || true

# EXIT trap fires because we do NOT use exec here.
# Also print supervisor log tail to stdout so it appears in docker run output.
trap '
  echo "[INSTRUMENTED-ENTRYPOINT] EXIT trap firing" >&2
  if [[ -f "$SUPLOG" ]]; then
    echo "[INSTRUMENTED-ENTRYPOINT] supervisor log size: $(wc -l < "$SUPLOG") lines" >&2
    # Copy to artifacts dir (must be writable by container)
    cp "$SUPLOG" "$DEST" 2>/dev/null && echo "[INSTRUMENTED-ENTRYPOINT] copied -> $DEST" >&2 || \
        echo "[INSTRUMENTED-ENTRYPOINT] WARN: copy failed (check dir perms)" >&2
    # Also dump full log to stdout so docker logs captures it
    echo "==== SUPERVISOR_LOG_BEGIN tag=${TAG} ====" >&2
    cat "$SUPLOG" >&2
    echo "==== SUPERVISOR_LOG_END tag=${TAG} ====" >&2
  else
    echo "[INSTRUMENTED-ENTRYPOINT] supervisor log not found at $SUPLOG" >&2
  fi
  gc supervisor stop --city /home/agent/validation-pack 2>/dev/null || true
' EXIT

# Run scenario without exec so this shell sticks around for the EXIT trap
bash /home/agent/validation-pack/scripts/run-scenario.sh "$@"
