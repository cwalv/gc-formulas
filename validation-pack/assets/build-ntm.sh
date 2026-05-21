#!/usr/bin/env bash
# build-ntm.sh — build the ntm binary from the foundations weave's ntm source
# and place it at validation-pack/assets/ntm so the Dockerfile can COPY it in.
#
# Why pre-built (vs. inline Go build): keeps the docker build context bounded
# to gc-formulas/, avoids pulling the Go toolchain + ntm's dependency graph
# on every image rebuild.
#
# Run from anywhere — the script resolves paths relative to its own location.
#
# Prerequisites:
#   - Go (1.26.x) in PATH
#   - foundations weave with github/cwalv/ntm/ present
#
# GOWORK=off skips the weave-root go.work file (which mixes go.mod versions
# across sibling repos and confuses the toolchain selector). The ntm module
# stands alone and builds cleanly with its own go.mod.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# validation-pack/assets/ → validation-pack/ → gc-formulas/ → github/cwalv/ → <weave-root>/
WEAVE_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
NTM_SRC="${WEAVE_ROOT}/github/cwalv/ntm"
OUT="${SCRIPT_DIR}/ntm"

if [[ ! -f "${NTM_SRC}/go.mod" ]]; then
    echo "ERROR: ntm source not found at ${NTM_SRC}" >&2
    echo "Make sure the foundations weave has github/cwalv/ntm checked out." >&2
    exit 1
fi

cd "${NTM_SRC}"
echo "Building ntm from ${NTM_SRC}"
GOWORK=off CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -trimpath \
    -ldflags="-s -w" \
    -o "${OUT}" \
    ./cmd/ntm

echo "Built: $(file "${OUT}" | head -1)"
echo "Size:  $(du -sh "${OUT}" | cut -f1)"
