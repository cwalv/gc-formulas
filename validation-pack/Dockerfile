FROM ubuntu:24.04

# Base toolchain. Keep layers minimal; treehugger may consolidate.
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        lsof \
        python3 \
        nodejs \
        npm \
        tmux \
    && rm -rf /var/lib/apt/lists/*

# Non-root user matching host uid 1000 (see docker-compose.yml `user:` directive).
# Ubuntu 24.04 ships with a built-in 'ubuntu' user at uid 1000 -- delete it so
# 'agent' is the only uid 1000 entry. Otherwise /etc/passwd lookups for uid
# 1000 resolve to 'ubuntu' first ($HOME=/home/ubuntu) while the COPY below
# places the pack under /home/agent/, creating a split-brain.
RUN userdel -r ubuntu && useradd -m -u 1000 -s /bin/bash agent

# Claude Code CLI installs cleanly without auth; OAuth credentials arrive via
# bind-mount at run time (see entrypoint.sh).
RUN npm install -g @anthropic-ai/claude-code

# bd CLI — gastownhall/beads v1.0.3 (prebuilt linux/amd64 release tarball)
# SHA256: 1ef5dca818d7e81574df9e9f9fc2a16ab711da09b0fa7b822ae162d9a81c8912
# Release page: https://github.com/gastownhall/beads/releases/tag/v1.0.3
# Pinned to v1.0.3 (not v1.0.4) because v1.0.4 has known issues with the
# JSONL-import-on-every-invocation persistence model that cause lost-update
# races between concurrent bd processes (claude implementer + gc supervisor
# subshells). Observed at v1.0.4: writes land briefly, then revert when a
# concurrent process re-imports JSONL. User flagged "known issues with this
# version" — switching to v1.0.3 to validate the substrate.
RUN curl -fsSL \
    "https://github.com/gastownhall/beads/releases/download/v1.0.3/beads_1.0.3_linux_amd64.tar.gz" \
    -o /tmp/beads.tar.gz \
    && echo "1ef5dca818d7e81574df9e9f9fc2a16ab711da09b0fa7b822ae162d9a81c8912  /tmp/beads.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/beads.tar.gz -C /usr/local/bin bd \
    && chmod +x /usr/local/bin/bd \
    && rm /tmp/beads.tar.gz

# gc CLI — gastownhall/gascity v1.1.0 (prebuilt linux/amd64 release tarball)
# SHA256: b6983ff515d3b7785c00ab1b53948fdae2cc6f6ee88bfc0b60a7c3bca72ab78b
# Release page: https://github.com/gastownhall/gascity/releases/tag/v1.1.0
# Host is at 1.1.1 (2 commits past tag on the cwalv fork); v1.1.0 is the
# nearest pinnable public release and is functionally equivalent for Phase 0.
RUN curl -fsSL \
    "https://github.com/gastownhall/gascity/releases/download/v1.1.0/gascity_1.1.0_linux_amd64.tar.gz" \
    -o /tmp/gascity.tar.gz \
    && echo "b6983ff515d3b7785c00ab1b53948fdae2cc6f6ee88bfc0b60a7c3bca72ab78b  /tmp/gascity.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/gascity.tar.gz -C /usr/local/bin gc \
    && chmod +x /usr/local/bin/gc \
    && rm /tmp/gascity.tar.gz

# dolt binary — dolthub/dolt v2.0.5 (prebuilt linux/amd64 release tarball)
# SHA256: 70eb16b8dd5ec3c8ecde711c3977631c4a98ccf7c2f26f5860e79a0787c202ca
# Release page: https://github.com/dolthub/dolt/releases/tag/v2.0.5
# gc start (the supervisor) probes dolt binary presence and lsof for port
# checks; both must be in PATH before the supervisor can manage a city.
RUN curl -fsSL \
    "https://github.com/dolthub/dolt/releases/download/v2.0.5/dolt-linux-amd64.tar.gz" \
    -o /tmp/dolt.tar.gz \
    && echo "70eb16b8dd5ec3c8ecde711c3977631c4a98ccf7c2f26f5860e79a0787c202ca  /tmp/dolt.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/dolt.tar.gz -C /tmp \
    && mv /tmp/dolt-linux-amd64/bin/dolt /usr/local/bin/dolt \
    && chmod +x /usr/local/bin/dolt \
    && rm -rf /tmp/dolt.tar.gz /tmp/dolt-linux-amd64

# ntm binary — pre-built from foundations-weave source via
# validation-pack/assets/build-ntm.sh (GOWORK=off CGO_ENABLED=0 go build).
# Pre-built rather than inline so the docker build context stays small
# (just gc-formulas/) and we avoid the Go toolchain + ntm dependency
# graph (chromedp, bubbletea, etc.) on every rebuild.
COPY validation-pack/assets/ntm /usr/local/bin/ntm
RUN chmod +x /usr/local/bin/ntm

WORKDIR /home/agent

# Build context is the pack root (../), so the validation-pack/ prefix resolves.
COPY --chown=agent:agent validation-pack/ /home/agent/validation-pack/

USER agent

# Disable bd's automatic JSONL export on every CLI invocation. The default
# (auto-export = on) writes .beads/issues.jsonl after each bd write, which
# causes lost-update races when multiple bd processes (claude + gc
# control-dispatcher + supervisor's order machinery) interleave their
# Disable bd's auto-export-on-write — JSONL is only refreshed via explicit
# `bd export`. In-dolt state persists across bd invocations regardless
# (confirmed empirically), so the JSONL doesn't need to be live. Keeps
# concurrent bd writes (e.g. driver + agent) from racing on the JSONL file.
ENV BEADS_EXPORT_AUTO=false

# Identity for dolt and git. gc's supervisor spawns an external dolt sql-server
# for the city, and dolt refuses to start without a configured identity. Global
# git config also acts as bd's audit-row identity. Set both at build time so
# every container starts with a working identity.
RUN git config --global user.name  "agent" \
    && git config --global user.email "agent@validation-pack.local" \
    && dolt config --global --add user.name  "agent" \
    && dolt config --global --add user.email "agent@validation-pack.local"

# bd substrate — Option A (build-time init, preferred over entrypoint init):
# Initialise the embedded-Dolt substrate once at image build time. Running as
# the agent user ensures .beads/ is owned by uid 1000 and the embedded engine
# can write its WAL/lock files without privilege escalation at runtime. Using
# --non-interactive prevents bd from prompting in the non-TTY build environment.
# The prefix "vp" (validation-pack) is the shared namespace for all scenarios.
# gc does NOT need dolt_host/dolt_port for embedded-mode bd — city.toml's rig
# block no longer carries those settings (removed during this bead).
RUN cd /home/agent/validation-pack && bd init --prefix=vp --non-interactive \
    && bd config set dolt.auto-commit on \
    && bd config set dolt.auto-start on

# Pre-seed Claude Code's user-level config so the first-run wizard doesn't
# block the spawned agent on theme/UI choices. Without this, claude in a
# fresh tmux pane sits at "Choose your theme" forever, gc session-start
# hits its 60s timeout, and the implementer never executes. ~/.claude.json
# (at $HOME root, not under .claude/) is the file Claude Code reads to
# determine onboarding state. Setting `theme` + `numStartups` > 0 skips
# the wizard entirely.
# Build the .claude.json with onboarding-complete flags + pre-trust for every
# session path the ntm shim will create at runtime. The ntm shim uses
# `projects_base/vp-<scenario-id>` as the session directory; Claude shows
# a "Trust this folder?" dialog the first time it runs in any new directory.
# In a non-TTY container that dialog reads no stdin and aborts — same class
# of bug as the bypass-permissions warning above. Trust the seven scenario
# directories upfront. (Trust is path-specific; there's no global "trust
# everything" flag, and Claude only skips the dialog under `-p` / piped stdout,
# which we can't use for an interactive agent loop.)
# ntm shim uses per-persona sessions: vp-<scenario-id>-<persona>. Pre-trust
# every (scenario, persona) cell plus the bare per-scenario path for any
# backward-compat callers. (Trust is path-keyed; no global "trust everything".)
RUN python3 -c "import json; sc=['01-prompt-chaining','02-routing','03-sectioning','04-voting','05-orchestrator-workers','06-evaluator-optimizer','07-agent-loop']; ps=['foreman','implementer','evaluator','treehugger']; e={'hasTrustDialogAccepted':True,'allowedTools':[],'mcpContextUris':[],'mcpServers':{},'enabledMcpjsonServers':[],'disabledMcpjsonServers':[],'projectOnboardingSeenCount':1}; p={f'/home/agent/ntm-work/vp-{s}-{x}':e for s in sc for x in ps}; p.update({f'/home/agent/ntm-work/vp-{s}':e for s in sc}); d={'numStartups':1,'theme':'dark','hasCompletedOnboarding':True,'hasSeenTasksHint':True,'autoUpdates':False,'bypassPermissionsModeAccepted':True,'projects':p}; open('/home/agent/.claude.json','w').write(json.dumps(d))"

# Register gc's required custom issue types in bd's types.custom config so
# gc sling / gc session / gc converge accept beads of those types. Without
# this, gc fails with "invalid issue type: <name>" (convoy, session, etc.)
# when it tries to auto-create container beads. The list of required types
# is hard-coded in gascity's internal/doctor/checks_custom_types.go:23-27.
# gc doctor --fix reads the missing-types list and writes it via bd config
# set types.custom.
#
# `|| true`: gc doctor runs other checks too (dolt runtime state, gh CLI,
# external dolt binary). Those are unavailable at build time and emit
# non-zero exit. The custom-types check runs and applies its fix
# idempotently before the other checks fail; the registration we care
# about lands regardless. Tolerating the non-zero exit lets the build
# proceed.
RUN gc doctor --fix --city /home/agent/validation-pack || true

# Strip parts of bundled packs that bring in personas (mayor, dog, witness,
# polecat, refinery, deacon, boot) the city.toml doesn't declare. Those packs
# include `[[named_session]] mode = "always"` entries for those personas; the
# supervisor tries to start them, fails repeatedly, and crowds the implementer
# out of the start queue. Keep bd + dolt packs (bd depends on dolt; bd ships
# the bd CLI integration the substrate needs), but strip their `orders/`
# subdirs that target the missing dog persona. Drop gastown + maintenance
# entirely since they're purely persona-add layers we don't need.
RUN rm -rf /home/agent/validation-pack/.gc/system/packs/gastown \
    /home/agent/validation-pack/.gc/system/packs/maintenance \
    && rm -rf /home/agent/validation-pack/.gc/system/packs/dolt/orders \
    /home/agent/validation-pack/.gc/system/packs/dolt/formulas \
    /home/agent/validation-pack/.gc/system/packs/dolt/agents

# Default entrypoint is the gc-shim path. Compose overrides this to
# scripts/entrypoint-ntm.sh for SHIM=ntm runs (see docker-compose.ntm.yml).
ENTRYPOINT ["/home/agent/validation-pack/scripts/entrypoint-gc.sh"]
CMD []
