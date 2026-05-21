#!/usr/bin/env bash
# shims/ntm.sh — ntm orchestrator shim implementing the three primitives:
#   shim_spawn <persona> <count>
#   shim_prime <persona>
#   shim_await <bead-id> <timeout-secs>
#
# Sourced by scenario drivers (or by run-scenario.sh when it gains shim
# sourcing support). Assumes PACK_ROOT is set by the time these are called.
#
# ntm model overview:
#   ntm manages tmux sessions; each pane is an AI agent. Sessions are created
#   with `ntm spawn`, prompts are pushed via `ntm send`. ntm has no concept
#   equivalent to gc's controller/session-pool — work routing is accomplished
#   by sending explicit prompts to panes. The routing key (gc.routed_to) is
#   shared across shims — namespace is just a string. Scenario drivers write
#   gc.routed_to=validation/<persona> and both gc and ntm personas query that
#   same key (see shim_spawn).
#
# Routing mapping:
#   gc shim:  gc session new → pool subscribes via gc hook / gc.routed_to
#   ntm shim: ntm spawn session --persona=<persona> → ntm send explicit bead prompt
#   The ntm persona carries the system prompt but not the pool-queue loop;
#   the scenario driver (via shim_spawn) sends the looping task explicitly.
#
# Session naming:
#   ntm sessions are named "vp-${SCENARIO_ID}". ntm uses the session name as
#   the Agent Mail project key, so it must be slug-safe (hyphens OK).
#
# Daemon requirement:
#   `ntm serve` is NOT required for spawn/send/activity operations — those talk
#   directly to tmux. ntm serve provides an SSE event stream and REST API that
#   could be used for richer await mechanics; the shim_await implementation here
#   uses bd poll (same fallback as gc.sh) because it requires no daemon.
#   TREEHUGGER NOTE: if a richer ntm-native await is wanted later (SSE from
#   ntm serve /events), the entrypoint must start `ntm serve &` before the
#   scenario runs. Not done here.
#
# Container prerequisites:
#   - tmux (already in ntm's own Dockerfile; must be in the validation-pack image)
#   - ntm binary in PATH
#   - NTM_CONFIG pointing at a config.toml (see below)
#   The baseline validation-pack Dockerfile does NOT include tmux or ntm.
#   TREEHUGGER NOTE: the Dockerfile needs:
#     1. tmux package
#     2. ntm binary — either:
#        a. Build from source: requires Go toolchain + the ntm repo available.
#           `go build -o /usr/local/bin/ntm ./cmd/ntm` from the ntm source tree.
#           ntm source is at github/cwalv/ntm (foundations weave).
#           The ntm Dockerfile (golang:1.25-alpine builder) is the reference.
#        b. Bind-mount the ntm binary from the host if the host has it already.
#     3. NTM_CONFIG env var pointing at a writable config (ntm requires a
#        projects_base directory it can write to; /home/agent/ntm-work is
#        used here — create it in the Dockerfile or entrypoint).
#
# Persona config:
#   ntm loads personas from:
#     1. Built-in (compiled in)
#     2. User: ~/.config/ntm/personas.toml  (or $NTM_CONFIG dir's personas.toml)
#     3. Project: .ntm/personas.toml relative to the working directory
#   The shim's shim_prime uses the project personas.toml at
#   ${PACK_ROOT}/.ntm/personas.toml (created by ntm.toml prep step, or
#   expected to be pre-baked). shim_spawn also uses --persona to let ntm
#   inject the system prompt when it starts the pane.
#
# ntm.toml vs personas.toml:
#   ntm does NOT have a concept analogous to gc's city.toml / agent-template
#   declarations. The ntm project config lives in .ntm/personas.toml (project
#   level) or ~/.config/ntm/personas.toml (user level). This shim expects
#   ${PACK_ROOT}/.ntm/personas.toml to exist with vp-implementer (and friends)
#   declared. See validation-pack/.ntm/personas.toml for the declarations.

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# NTM session name for this scenario run.
_ntm_session_name() {
    echo "vp-${SCENARIO_ID:-scenario}"
}

# NTM_CONFIG: point ntm at a writable config in the container. ntm needs a
# projects_base it can mkdir. Default to /home/agent/ntm-work.
_ntm_ensure_config() {
    local ntm_work="${HOME}/ntm-work"
    mkdir -p "${ntm_work}"

    # If NTM_CONFIG is already set (e.g. injected by entrypoint), leave it.
    if [[ -n "${NTM_CONFIG:-}" ]]; then
        return 0
    fi

    local config_dir="${HOME}/.config/ntm"
    mkdir -p "${config_dir}"
    local config_file="${config_dir}/config.toml"

    # Write a minimal config if none exists yet.
    if [[ ! -f "${config_file}" ]]; then
        cat > "${config_file}" <<EOF
# ntm config for validation-pack container
projects_base = "${ntm_work}"
EOF
    fi

    export NTM_CONFIG="${config_file}"
}

# ---------------------------------------------------------------------------
# shim_prime <persona>
#   Emit the persona's system prompt to stdout.
#
#   Primary: ntm personas show <name> --json | extract SystemPrompt field.
#   The persona must be visible to ntm — either built-in, in the user config,
#   or in the project .ntm/personas.toml. For validation-pack personas (e.g.
#   vp-implementer), the project personas.toml must be present.
#
#   Fallback: if ntm can't find the persona by name, cat the .md file directly
#   from personas/<persona>.md (stripping the vp- prefix if present).
# ---------------------------------------------------------------------------
shim_prime() {
    local persona="${1:?shim_prime: persona required}"

    _ntm_ensure_config

    # Try ntm personas show first.
    local prompt
    if prompt="$(ntm personas show "${persona}" --json 2>/dev/null \
                    | python3 -c 'import json,sys; print(json.load(sys.stdin)["SystemPrompt"])' \
                    2>/dev/null)"; then
        printf '%s\n' "${prompt}"
        return 0
    fi

    # Fallback: read from the .md file. Strip leading "vp-" prefix if present
    # so "vp-implementer" maps to personas/implementer.md (base personas) or
    # personas/ntm-implementer.md (ntm variant, preferred if present).
    local base="${persona#vp-}"
    local md_ntm="${PACK_ROOT}/personas/ntm-${base}.md"
    local md_base="${PACK_ROOT}/personas/${base}.md"

    if [[ -f "${md_ntm}" ]]; then
        cat "${md_ntm}"
    elif [[ -f "${md_base}" ]]; then
        cat "${md_base}"
    else
        echo "[shim_prime] ERROR: no system prompt found for persona '${persona}'" >&2
        echo "[shim_prime]   ntm personas show failed and no .md file at ${md_ntm} or ${md_base}" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# shim_spawn <persona> <count>
#   Start <count> ntm agent panes running the named persona, then send the
#   bead-loop task prompt to each.
#
#   ntm does not have a pool/subscription model like gc's session hook. Instead
#   the driver sends an explicit task prompt that instructs the agent to loop
#   over bd ready → claim → execute → close → repeat → exit when queue empty.
#
#   Session name: vp-${SCENARIO_ID}. Re-using an existing session will fail
#   unless --safety is dropped; this shim kills any stale session first.
#
#   Pane layout:
#     --no-user: skip the human pane (headless automation context).
#     --persona=<persona>:<count>: spawn <count> Claude panes with the named
#       persona's system prompt injected automatically by ntm.
#
# CONTRACT:
#   - Requires tmux and ntm in PATH.
#   - Requires NTM_CONFIG to point at a valid config (projects_base must exist).
#   - The persona must be resolvable by ntm (see .ntm/personas.toml).
#   - Returns 0 if the session and prompt were delivered; non-zero otherwise.
# ---------------------------------------------------------------------------
shim_spawn() {
    local persona="${1:?shim_spawn: persona required}"
    local count="${2:-1}"
    local session
    session="$(_ntm_session_name)"

    # Sanity-check prerequisites.
    if ! command -v tmux &>/dev/null; then
        echo "[shim_spawn] FATAL: tmux not found in PATH." >&2
        echo "[shim_spawn] Add tmux to the Dockerfile." >&2
        return 1
    fi
    if ! command -v ntm &>/dev/null; then
        echo "[shim_spawn] FATAL: ntm not found in PATH." >&2
        echo "[shim_spawn] Install ntm binary in the container image." >&2
        return 1
    fi

    _ntm_ensure_config

    # Kill any stale session with this name (idempotent re-runs).
    if tmux has-session -t "${session}" 2>/dev/null; then
        echo "[shim_spawn] killing stale session: ${session}"
        tmux kill-session -t "${session}" 2>/dev/null || true
    fi

    # Pre-create the session's project directory under projects_base. `ntm
    # spawn` resolves session_name → projects_base/session_name and, if the
    # directory does not exist, prompts interactively ("Create it? [y/N]").
    # In a non-TTY container that prompt reads no stdin and aborts the spawn.
    # Creating the directory ourselves bypasses the prompt entirely.
    local projects_base
    projects_base="$(python3 -c "
import sys, re, os
try:
    cfg = open(os.environ['NTM_CONFIG']).read()
    m = re.search(r'projects_base\s*=\s*[\"\\']([^\"\\']+)', cfg)
    print(m.group(1) if m else '')
except Exception:
    print('')
" 2>/dev/null)"
    if [[ -n "${projects_base}" ]]; then
        mkdir -p "${projects_base}/${session}"
    fi

    # ntm ships built-in personas (implementer, architect, etc.) whose system
    # prompts don't match this validation-pack's lifecycle. Our project-level
    # .ntm/personas.toml declares vp-* names to avoid shadowing — so when
    # scenarios call shim_spawn implementer/foreman/etc., we map to the vp-*
    # variants here. The mapping is one line of shell, the alternative is
    # changing every scenario driver to call shim_spawn with the vp- prefix,
    # which would be ugly cross-shim contract leakage.
    local ntm_persona="vp-${persona}"

    echo "[shim_spawn] creating ntm session: ${session} persona=${ntm_persona} count=${count}"

    # Minimal kick-off prompt. The persona system prompt (loaded by ntm via
    # the --persona flag, from .ntm/personas.toml's system_prompt field)
    # already contains the full work-loop. The user message here just tells
    # the agent to begin. Persona-specific routing (validation/foreman vs
    # validation/implementer etc.) is baked into the persona prompt itself,
    # so this kick-off doesn't need to template by role.
    local loop_prompt
    loop_prompt="Begin. Follow the work-loop in your system prompt: poll your pool, claim ready beads, execute each one per its description, and exit cleanly when the pool is empty."

    ntm spawn "${session}" \
        --persona="${ntm_persona}:${count}" \
        --no-user \
        --config "${NTM_CONFIG}"

    local spawn_rc=$?
    if [[ "${spawn_rc}" -ne 0 ]]; then
        echo "[shim_spawn] ERROR: ntm spawn exited ${spawn_rc}" >&2
        return "${spawn_rc}"
    fi

    # Wait for Claude's welcome screen to finish rendering before delivering
    # the kickoff prompt. ntm activity's state machine reports state changes
    # during init that don't reliably reach "WAITING" at the moment Claude
    # is ready for input, so we check the pane content directly for Claude's
    # input-ready marker: the "bypass permissions on" footer text only appears
    # once Claude has rendered its main UI and is at the input box.
    #
    # Upstream bug: ntm spawn's `--prompt` flag uses a 200ms sleep before
    # delivery, which races Claude's 5-15s welcome render and drops the
    # prompt. Filed as Dicklesworthstone/ntm#158. Workaround here is a
    # pane-content poll; remove once that issue is fixed and ntm's --prompt
    # waits properly.
    #
    # Timeout 120s: Claude welcome typically renders in 5-15s; extra headroom
    # for slow first-run startups (config writes, OAuth refresh, etc.).
    local waited=0
    local max_wait=120
    local ready_marker="bypass permissions on"
    while (( waited < max_wait )); do
        local pane_content
        pane_content="$(tmux capture-pane -t "${session}" -p 2>/dev/null || echo '')"
        if printf '%s' "${pane_content}" | grep -qF "${ready_marker}"; then
            echo "[shim_spawn] agent ready (marker '${ready_marker}' detected) after ${waited}s; delivering prompt"
            # Give Claude one more beat to settle into the input box even
            # after the footer renders (avoids racing the last few keystrokes
            # of init).
            sleep 2
            break
        fi
        sleep 2
        waited=$(( waited + 2 ))
    done

    if (( waited >= max_wait )); then
        echo "[shim_spawn] WARNING: ready marker not seen after ${max_wait}s; sending prompt anyway" >&2
    fi

    ntm send "${session}" \
        --all \
        --force-non-interactive \
        --config "${NTM_CONFIG}" \
        "${loop_prompt}"

    local send_rc=$?
    if [[ "${send_rc}" -ne 0 ]]; then
        echo "[shim_spawn] ERROR: ntm send exited ${send_rc}" >&2
        return "${send_rc}"
    fi

    echo "[shim_spawn] session ${session} running with ${count} agent pane(s) — prompt delivered"
    return 0
}

# ---------------------------------------------------------------------------
# shim_await <bead-id> <timeout-secs>
#   Block until the named bead reaches closed status, or until timeout.
#
#   ntm has no native bead-lifecycle event stream analogous to gc events
#   --watch. The ntm serve API (/events SSE stream) surfaces agent activity
#   state changes (WAITING/GENERATING/THINKING) but not bd bead lifecycle
#   transitions. Therefore shim_await uses bd poll exclusively.
#
#   Additionally: before the poll loop, check agent health via ntm activity
#   --json. If all agents have been WAITING for >60s and the bead is still
#   open, the agent likely exited or stalled — emit a diagnostic and
#   continue polling (don't abort; the agent might resume).
#
# CONTRACT:
#   - Returns 0 if the bead closed within the timeout.
#   - Returns 1 on timeout (with diagnostics to stderr).
#   - Returns 2 if ntm session died unexpectedly and bead still open (with
#     diagnostics to stderr, non-fatal — let caller decide).
# ---------------------------------------------------------------------------
shim_await() {
    local bead_id="${1:?shim_await: bead-id required}"
    local timeout_secs="${2:-1500}"
    local poll_interval=10
    local stall_check_interval=60    # seconds between agent-health checks
    local last_stall_check=0
    local start_ts
    start_ts="$(date +%s)"
    local session
    session="$(_ntm_session_name)"

    echo "[shim_await] waiting for bead ${bead_id} to close (timeout ${timeout_secs}s)..."

    while true; do
        # Primary check: is the bead closed?
        local status
        status="$(bd list --status=closed --json 2>/dev/null \
            | jq -r "[.[] | select(.id==\"${bead_id}\")] | length" \
            2>/dev/null || echo 0)"

        if [[ "${status}" -ge 1 ]]; then
            echo "[shim_await] bead ${bead_id} closed (poll)"
            return 0
        fi

        local now elapsed
        now="$(date +%s)"
        elapsed=$(( now - start_ts ))

        if [[ "${elapsed}" -ge "${timeout_secs}" ]]; then
            echo "[shim_await] TIMEOUT after ${elapsed}s: bead ${bead_id} still not closed" >&2
            return 1
        fi

        # Periodic agent health check using ntm activity --json.
        # Detects stalled/dead sessions early so diagnostics appear in logs.
        if (( now - last_stall_check >= stall_check_interval )); then
            last_stall_check="${now}"
            _ntm_check_agent_health "${session}" "${bead_id}" || true
        fi

        sleep "${poll_interval}"
    done
}

# Internal: check ntm agent activity; emit a warning if all agents are WAITING
# or the session is gone (likely signals the agent loop finished or crashed).
_ntm_check_agent_health() {
    local session="${1}"
    local bead_id="${2}"

    if ! tmux has-session -t "${session}" 2>/dev/null; then
        echo "[shim_await] WARNING: ntm session '${session}' is gone; bead ${bead_id} still open" >&2
        echo "[shim_await] The agent may have exited prematurely — check bd show ${bead_id}" >&2
        return 1
    fi

    if ! command -v ntm &>/dev/null; then
        return 0
    fi

    local activity_json
    activity_json="$(ntm activity "${session}" --json 2>/dev/null || echo '')"
    if [[ -z "${activity_json}" ]]; then
        return 0
    fi

    # Count agents not in WAITING state (GENERATING or THINKING = still active).
    local active_count
    active_count="$(printf '%s' "${activity_json}" \
        | jq '[.agents[] | select(.state != "WAITING")] | length' 2>/dev/null \
        || echo 1)"  # default 1 = assume active if jq fails

    if [[ "${active_count}" -eq 0 ]]; then
        echo "[shim_await] NOTE: all agents in session '${session}' are WAITING; bead ${bead_id} still open" >&2
        echo "[shim_await] Agent may be idle/done or awaiting input — continuing to poll" >&2
    fi

    return 0
}

# Poll fallback alias for parity with gc.sh naming conventions.
# shim_await already is poll-based; this is kept for documentation symmetry.
_shim_await_poll() {
    shim_await "$@"
}
