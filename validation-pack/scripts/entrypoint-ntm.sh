#!/usr/bin/env bash
set -euo pipefail

# entrypoint-ntm.sh — container entrypoint for SHIM=ntm runs.
#
# ntm has no supervisor: there's nothing analogous to `gc start`. The shim
# talks to tmux directly. So this entrypoint is just the OAuth credential
# copy + a minimal ntm config writeout, then exec the scenario harness.
#
# (See entrypoint-gc.sh for the gc-shim variant that boots gc's supervisor.)

mkdir -p "$HOME/.claude"
install -m 600 /mnt/host-claude/credentials.json "$HOME/.claude/.credentials.json"

# ntm needs a config file that points at a writable projects_base. Create
# a minimal one if it isn't already in place. The shim's _ntm_ensure_config
# does this lazily too, but doing it here makes the first spawn faster and
# the runtime state explicit.
ntm_work="$HOME/ntm-work"
mkdir -p "$ntm_work"

config_dir="$HOME/.config/ntm"
mkdir -p "$config_dir"
config_file="$config_dir/config.toml"
if [[ ! -f "$config_file" ]]; then
    cat > "$config_file" <<EOF
# ntm config — validation-pack container, ntm shim
projects_base = "$ntm_work"
EOF
fi

export NTM_CONFIG="$config_file"

# Copy the project-level personas.toml into ntm's user-level config dir.
#
# `ntm spawn` resolves its working directory from `projects_base/<session-name>`
# (see resolveSpawnProjectDir in ntm's spawn.go), NOT from the shell's cwd.
# Our project personas live at PACK_ROOT/.ntm/personas.toml which `ntm spawn`
# does NOT see — it would only look at projects_base/<session>/.ntm/personas.toml.
#
# The user-level path (~/.config/ntm/personas.toml) IS always consulted. Copy
# our project file there so spawn can resolve the vp-* personas regardless of
# session name. This is per the .ntm/personas.toml comment header (load order:
# built-in → user → project; we promote project to user for this container).
project_personas="/home/agent/validation-pack/.ntm/personas.toml"
user_personas="$config_dir/personas.toml"
if [[ -f "$project_personas" ]]; then
    cp "$project_personas" "$user_personas"
fi

# No supervisor, no dog suspension, no EXIT trap — there's nothing daemonised
# in the ntm shim to clean up. Scenarios are responsible for their own tmux
# sessions (the shim kills stale sessions on idempotent re-spawn).

exec /home/agent/validation-pack/scripts/run-scenario.sh "$@"
