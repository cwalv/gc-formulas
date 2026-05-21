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

exec /home/agent/validation-pack/scripts/run-scenario.sh "$@"
