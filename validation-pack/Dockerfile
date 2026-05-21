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
RUN useradd -m -u 1000 -s /bin/bash agent

# Claude Code CLI installs cleanly without auth; OAuth credentials arrive via
# bind-mount at run time (see entrypoint.sh).
RUN npm install -g @anthropic-ai/claude-code

# TODO: install bd CLI
RUN echo "TODO: install bd CLI" >&2
# bd lives at github.com/gastownhall/beads. Install path is not yet pinned --
# treehugger will iterate (decide between `go install`, prebuilt release tarball,
# or vendored binary) once the agent-orchestration substrate stabilises.

# TODO: install gc CLI
RUN echo "TODO: install gc CLI" >&2
# gc lives in the foundations project (alongside this design doc). Install path
# is not yet pinned -- the gc binary/wrapper is currently consumed via the
# foundations weave on the host and there is no published release artifact.
# Treehugger will iterate (decide between in-image build from a pinned commit,
# release tarball, or a thin shim that delegates to a mounted toolchain).

WORKDIR /home/agent

# Build context is the pack root (../), so the validation-pack/ prefix resolves.
COPY --chown=agent:agent validation-pack/ /home/agent/validation-pack/

USER agent

ENTRYPOINT ["/home/agent/validation-pack/scripts/entrypoint.sh"]
CMD []
