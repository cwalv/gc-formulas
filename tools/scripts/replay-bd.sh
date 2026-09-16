#!/usr/bin/env bash
# replay-bd.sh — replay a bd-trace.jsonl against a fresh .beads/ substrate.
#
# Usage: replay-bd.sh <trace.jsonl> [target-dir]
#
#   trace.jsonl — path to the JSONL file written by bd-record-shim.sh
#   target-dir  — directory in which to create a fresh .beads/ (defaults to a
#                 new temp dir so the original is never polluted)
#
# After replay, dumps end-state via `bd list --json` to
#   <target-dir>/replay-end-state.json
# and prints the path so the caller can diff against expected state.
#
# Requires: bd (real bd, not the shim), python3, jq (optional, for pretty
# output).  bd must be in PATH or set BD_BIN.

set -euo pipefail

BD_BIN="${BD_BIN:-/usr/local/bin/bd-real}"
# Fall back to plain `bd` if bd-real is absent (e.g. running outside the image).
if [[ ! -x "${BD_BIN}" ]]; then
    BD_BIN="bd"
fi

usage() {
    echo "Usage: replay-bd.sh <trace.jsonl> [target-dir]" >&2
    exit 2
}

if [[ $# -lt 1 ]]; then
    usage
fi

TRACE_FILE="$1"
TARGET_DIR="${2:-}"

if [[ ! -f "${TRACE_FILE}" ]]; then
    echo "replay-bd: trace file not found: ${TRACE_FILE}" >&2
    exit 2
fi

# Create a fresh target directory if none was supplied.
if [[ -z "${TARGET_DIR}" ]]; then
    TARGET_DIR="$(mktemp -d)"
    echo "replay-bd: created fresh target dir: ${TARGET_DIR}" >&2
else
    mkdir -p "${TARGET_DIR}"
fi

# Sanity: refuse to replay into a directory that already has .beads/ to avoid
# silently polluting existing state.
if [[ -d "${TARGET_DIR}/.beads" ]]; then
    echo "replay-bd: ${TARGET_DIR}/.beads already exists — won't replay into a live substrate." >&2
    echo "           Pass an empty directory or omit target-dir to use a fresh temp dir." >&2
    exit 2
fi

echo "replay-bd: initialising fresh substrate in ${TARGET_DIR}" >&2
pushd "${TARGET_DIR}" >/dev/null

# Initialise with the same flags the validation-pack uses at build time.
# --non-interactive prevents prompts in non-TTY contexts.
"${BD_BIN}" init --prefix=vp --non-interactive >/dev/null 2>&1 || \
    "${BD_BIN}" init --non-interactive >/dev/null 2>&1

# Match the build-time config so replay behaviour mirrors the live rig.
"${BD_BIN}" config set dolt.auto-commit on  2>/dev/null || true
"${BD_BIN}" config set dolt.auto-start  on  2>/dev/null || true
"${BD_BIN}" config set export.auto     false 2>/dev/null || true

echo "replay-bd: replaying $(wc -l < "${TRACE_FILE}") invocations from ${TRACE_FILE}" >&2

_line_num=0
_ok=0
_fail=0

while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    _line_num=$(( _line_num + 1 ))

    # Extract the args array via python3.
    mapfile -t _args < <(python3 -c "
import sys, json
rec = json.loads(sys.argv[1])
for a in rec.get('args', []):
    print(a)
" "${line}")

    if [[ ${#_args[@]} -eq 0 ]]; then
        echo "replay-bd: line ${_line_num}: no args — skipping" >&2
        continue
    fi

    # Skip `bd init` lines — we already initialised above.
    if [[ "${_args[0]}" == "init" ]]; then
        echo "replay-bd: line ${_line_num}: skipping 'bd init' (already initialised)" >&2
        continue
    fi

    echo "replay-bd: [${_line_num}] bd ${_args[*]}" >&2
    if "${BD_BIN}" "${_args[@]}"; then
        _ok=$(( _ok + 1 ))
    else
        _rc=$?
        echo "replay-bd: [${_line_num}] FAILED (rc=${_rc}): bd ${_args[*]}" >&2
        _fail=$(( _fail + 1 ))
    fi

done < "${TRACE_FILE}"

# Dump end-state for diffing.
END_STATE_FILE="${TARGET_DIR}/replay-end-state.json"
"${BD_BIN}" list --json > "${END_STATE_FILE}" 2>/dev/null || \
    "${BD_BIN}" list       > "${END_STATE_FILE}" 2>/dev/null || true

popd >/dev/null

echo "replay-bd: done — ${_ok} ok, ${_fail} failed" >&2
echo "replay-bd: end-state written to ${END_STATE_FILE}" >&2
echo "${END_STATE_FILE}"
