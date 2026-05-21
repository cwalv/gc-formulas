#!/usr/bin/env bash
set -euo pipefail

# One-time per-container setup. See validation-pack-design.md "OAuth handling":
# the host file is bind-mounted read-only at /mnt/host-claude/credentials.json,
# and we copy it into the agent's writable home so Claude Code can refresh
# tokens without writing back to the host.
#
# If the mount is missing, `install` will fail; that's an intentional hard
# fail (per design: the container can be recreated, but a scenario can't run
# without OAuth state).

mkdir -p "$HOME/.claude"
install -m 600 /mnt/host-claude/credentials.json "$HOME/.claude/.credentials.json"

# Start gc's machine-wide supervisor so that gc session new, gc events --watch,
# and gc hook all have a running controller to talk to.
#
# gc start registers the city with the supervisor, starts the supervisor in the
# background (forks gc supervisor run, polls the Unix control socket, and
# returns once the socket is alive), then triggers an immediate reconciliation.
# It is NOT a foreground/blocking call — it returns with exit 0 once the
# supervisor socket is ready, so no explicit background (&) or polling is needed.
#
# On EXIT, send SIGTERM to the supervisor so that docker compose run --rm
# completes cleanly without zombie processes. The socket-based readiness check
# inside gc start means the supervisor is alive by the time run-scenario.sh
# begins. If gc start exits non-zero (e.g., dolt missing, bad city.toml), the
# set -e above aborts the container here rather than silently running scenarios
# against a dead controller.
gc start --city /home/agent/validation-pack

# Suspend the `dog` agent — it's declared in city.toml only so the bundled
# dolt+maintenance packs' mol-dog-* orders dispatch cleanly. Letting it run
# concurrently with the scenario's implementer causes bd's JSONL persistence
# layer to lose writes (each bd invocation imports JSONL, modifies, re-exports;
# concurrent processes step on each other in last-writer-wins fashion). With
# dog suspended, only the scenario's implementer (+ gc's control-dispatcher,
# which is lighter) writes to bd, eliminating most of the contention.
gc agent suspend dog --city /home/agent/validation-pack 2>&1 | head -3 || true

# Clean shutdown: tell the supervisor to stop when the scenario exits.
trap 'gc supervisor stop --city /home/agent/validation-pack 2>/dev/null || true' EXIT

exec /home/agent/validation-pack/scripts/run-scenario.sh "$@"
