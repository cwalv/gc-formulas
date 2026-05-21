FROM ubuntu:24.04

# Base toolchain. Keep layers minimal; treehugger may consolidate.
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        python3 \
        nodejs \
        npm \
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

WORKDIR /home/agent

# Build context is the pack root (../), so the validation-pack/ prefix resolves.
COPY --chown=agent:agent validation-pack/ /home/agent/validation-pack/

USER agent

# bd substrate — Option A (build-time init, preferred over entrypoint init):
# Initialise the embedded-Dolt substrate once at image build time. Running as
# the agent user ensures .beads/ is owned by uid 1000 and the embedded engine
# can write its WAL/lock files without privilege escalation at runtime. Using
# --non-interactive prevents bd from prompting in the non-TTY build environment.
# The prefix "vp" (validation-pack) is the shared namespace for all scenarios.
# gc does NOT need dolt_host/dolt_port for embedded-mode bd — city.toml's rig
# block no longer carries those settings (removed during this bead).
RUN cd /home/agent/validation-pack && bd init --prefix=vp --non-interactive

ENTRYPOINT ["/home/agent/validation-pack/scripts/entrypoint.sh"]
CMD []
