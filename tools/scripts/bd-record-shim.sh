#!/usr/bin/env bash
# bd-record-shim.sh — recording shim for bd invocations.
#
# Installed as /usr/local/bin/bd (real bd moved to /usr/local/bin/bd-real).
# When DEBUG_BD_RECORD=1, appends one JSONL line per invocation to
# ${DEBUG_BD_TRACE:-/home/agent/debug-artifacts/bd-trace.jsonl}.
# When DEBUG_BD_RECORD is unset or 0 this is a cheap pass-through:
# exec the real bd directly (no subshell, no overhead beyond the env check).
#
# JSONL line schema:
#   {"ts": "...", "args": [...], "rc": N, "stdout_excerpt": "..."}
#   ts:             ISO-8601 timestamp (seconds precision, UTC)
#   args:           JSON array of all positional arguments
#   rc:             integer exit code of bd-real
#   stdout_excerpt: first ~500 bytes of bd stdout (stderr passes through unchanged)

BD_REAL="/usr/local/bin/bd-real"

# Fast path: recording disabled — exec directly (zero recording overhead).
if [[ "${DEBUG_BD_RECORD:-0}" != "1" ]]; then
    exec "${BD_REAL}" "$@"
fi

# --- Recording path ---

TRACE_FILE="${DEBUG_BD_TRACE:-/home/agent/debug-artifacts/bd-trace.jsonl}"
mkdir -p "$(dirname "${TRACE_FILE}")"

# Capture stdout to a temp file while passing stderr through to the caller.
_tmp_out="$(mktemp)"

# Run bd-real once; capture rc without letting the shell abort on failure.
"${BD_REAL}" "$@" >"${_tmp_out}" 2>&1
_rc=$?

# Emit captured output (stdout+stderr combined) to the caller.
cat "${_tmp_out}"

# Snapshot the first ~500 bytes for the trace record, then clean up.
_excerpt="$(dd if="${_tmp_out}" bs=1 count=500 2>/dev/null)"
rm -f "${_tmp_out}"

_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Use python3 for correct JSON encoding of arbitrary argument strings.
# Arguments are passed as positional params to avoid shell quoting issues.
python3 -c "
import sys, json
record = {
    'ts':             sys.argv[1],
    'args':           list(sys.argv[4:]),
    'rc':             int(sys.argv[3]),
    'stdout_excerpt': sys.argv[2],
}
print(json.dumps(record, ensure_ascii=False))
" "${_ts}" "${_excerpt}" "${_rc}" "$@" >> "${TRACE_FILE}"

exit "${_rc}"
