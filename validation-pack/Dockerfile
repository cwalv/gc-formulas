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

# bd CLI — gastownhall/beads v1.0.4 (prebuilt linux/amd64 release tarball)
# SHA256: 643e602e27f666c8726abff0f22001e2b5883988fa960204bde20a3129d448a5
# Release page: https://github.com/gastownhall/beads/releases/tag/v1.0.4
# bd defaults to embedded Dolt — no external dolt sql-server required.
# The host bd-wrapper.sh port-guard is intentionally omitted here — it only
# applies to the host's multi-city environment, not the single-city container.
RUN curl -fsSL \
    "https://github.com/gastownhall/beads/releases/download/v1.0.4/beads_1.0.4_linux_amd64.tar.gz" \
    -o /tmp/beads.tar.gz \
    && echo "643e602e27f666c8726abff0f22001e2b5883988fa960204bde20a3129d448a5  /tmp/beads.tar.gz" | sha256sum -c - \
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

WORKDIR /home/agent

# Build context is the pack root (../), so the validation-pack/ prefix resolves.
COPY --chown=agent:agent validation-pack/ /home/agent/validation-pack/

USER agent

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
RUN printf '{"numStartups":1,"theme":"dark","hasCompletedOnboarding":true,"hasSeenTasksHint":true,"autoUpdates":false}\n' \
    > /home/agent/.claude.json

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

ENTRYPOINT ["/home/agent/validation-pack/scripts/entrypoint.sh"]
CMD []
