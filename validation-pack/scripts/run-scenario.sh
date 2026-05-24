#!/usr/bin/env bash
set -euo pipefail

# run-scenario.sh — per-scenario harness.
#
# Usage: run-scenario.sh <scenario-id>
#   e.g. run-scenario.sh 01-prompt-chaining
#
# Control flow:
#   1. Validate that scenarios/<id>.sh exists.
#   2. Export SCENARIO_ID and PACK_ROOT for the driver to consume.
#   3. Run the driver; capture its exit code without aborting immediately.
#   4. Run the verifier; capture its exit code.
#   5. If driver failed, surface that code (don't paper over a broken driver
#      with a passing verifier). Otherwise surface the verifier's code.

PACK_ROOT="/home/agent/validation-pack"

if [[ $# -ne 1 ]]; then
    echo "Usage: run-scenario.sh <scenario-id>" >&2
    exit 2
fi

SCENARIO_ID="$1"
SCENARIO_SCRIPT="${PACK_ROOT}/scenarios/${SCENARIO_ID}.sh"

if [[ ! -f "${SCENARIO_SCRIPT}" ]]; then
    echo "Error: scenario script not found: ${SCENARIO_SCRIPT}" >&2
    exit 2
fi

export SCENARIO_ID
export PACK_ROOT

# Source checkpoint helper so the 'verify' checkpoint is available here.
# shellcheck source=scripts/checkpoint.sh
source "${PACK_ROOT}/scripts/checkpoint.sh"

# Run driver; don't let set -e abort us here — we want to capture the code.
DRIVER_RC=0
bash "${SCENARIO_SCRIPT}" || DRIVER_RC=$?

# Run verifier regardless — its output is useful for diagnosis even when the
# driver failed.
#
# Exception: eval-case mode (EVAL_CASE_ID set) has no fixture predicate; the
# pytest-pass-rate predicate runs host-side after container exit (see
# docs/per-orchestrator-runners.md §1). Skip the verifier AND the bead-state
# dump — the worktree is the artifact, not the bead DAG.
VERIFIER_RC=0
if [[ -n "${EVAL_CASE_ID:-}" ]]; then
    echo "===== run-scenario: eval-case mode (EVAL_CASE_ID=${EVAL_CASE_ID}); skipping verifier and bead-state dump =====" >&2
    DEBUG_DUMP_BEADS=0
else
    python3 "${PACK_ROOT}/scripts/verify_bead_state.py" --scenario "${SCENARIO_ID}" || VERIFIER_RC=$?
fi

# Checkpoint: after verifier, before artifact capture (and exit).
checkpoint verify

# Unconditionally copy ~/.claude/projects/ to the host-visible debug directory
# so token aggregation can run on the host after container exit (fo-4nglm).
# The container is destroyed with --rm; anything not persisted here is lost.
if [[ -d "${HOME}/.claude/projects" ]]; then
    _claude_dst="/home/agent/debug-artifacts/claude-projects"
    mkdir -p "${_claude_dst}"
    cp -r "${HOME}/.claude/projects/." "${_claude_dst}/" 2>/dev/null || true
    echo "===== run-scenario: claude/projects copied to ${_claude_dst} =====" >&2
fi

# A failed driver is the root cause; don't mask it.
# Dump full state of every bead the verifier touched (per the fixture).
# Lands in container stdout so `docker logs` retains it after the run ends —
# without this, the in-dolt state is lost the moment the container exits
# (the JSONL on disk may be stale relative to dolt). Cheap to keep; turn
# off with DEBUG_DUMP_BEADS=0 if it gets noisy.
if [[ "${DEBUG_DUMP_BEADS:-1}" == "1" ]]; then
    echo "===== run-scenario: bead state dump =====" >&2
    fixture="${PACK_ROOT}/fixtures/${SCENARIO_ID}-expected.json"
    if [[ -f "${fixture}" ]]; then
        python3 -c "
import json, subprocess, sys
fx = json.load(open('${fixture}'))
seen = set()
for kind, entries in fx.items():
    if not isinstance(entries, list):
        continue
    for e in entries:
        bid = e.get('bead_id')
        if not bid or bid in seen:
            continue
        seen.add(bid)
        r = subprocess.run(['bd','show',bid,'--json'], capture_output=True, text=True)
        if r.returncode != 0:
            print(f'--- {bid}: bd show failed ---', file=sys.stderr); continue
        try:
            d = json.loads(r.stdout)[0]
        except Exception as exc:
            print(f'--- {bid}: parse error: {exc} ---', file=sys.stderr); continue
        print(f'--- {bid} ---', file=sys.stderr)
        for k in ('status','close_reason','assignee','metadata','notes'):
            v = d.get(k)
            if v in (None, '', {}, []): continue
            print(f'  {k}: {v}', file=sys.stderr)
"
    fi
    echo "===== end bead state dump =====" >&2
fi

# On any failure, capture full diagnostic state to the host-visible debug
# directory before the container exits. The container is destroyed with --rm,
# so anything not persisted here is lost. Failed-test debugging needs at
# minimum: agent session log (jsonl), tmux pane scrollback (if any), bd
# JSONL + dolt export, the predicate fixture, and the container logs. The
# host mounts /home/agent/debug-artifacts via compose; on success we skip
# the capture (test passed; no need for forensics).
if [[ "${DRIVER_RC}" -ne 0 || "${VERIFIER_RC}" -ne 0 ]]; then
    artifacts_dir="/home/agent/debug-artifacts/${SCENARIO_ID}-$(date -u +%Y%m%dT%H%M%SZ)"
    echo "===== run-scenario: FAILURE — capturing debug artifacts to ${artifacts_dir} =====" >&2
    mkdir -p "${artifacts_dir}"

    # tmux pane scrollback for every active session. 10000-line scrollback;
    # captures the full agent dialogue under either gc or ntm shim.
    if command -v tmux >/dev/null 2>&1; then
        mkdir -p "${artifacts_dir}/tmux"
        tmux list-sessions -F '#{session_name}' 2>/dev/null | while read -r s; do
            tmux capture-pane -t "${s}" -p -S -10000 > "${artifacts_dir}/tmux/${s}.txt" 2>/dev/null || true
        done
    fi

    # bd substrate state — both the JSONL on disk and a fresh export.
    if [[ -d "${PACK_ROOT}/.beads" ]]; then
        mkdir -p "${artifacts_dir}/beads"
        cp "${PACK_ROOT}/.beads/issues.jsonl" "${artifacts_dir}/beads/issues.jsonl" 2>/dev/null || true
        bd export 2>/dev/null > "${artifacts_dir}/beads/bd-export.jsonl" || true
    fi

    # bd invocation trace (populated when DEBUG_BD_RECORD=1 was set for the run).
    _bd_trace="${DEBUG_BD_TRACE:-/home/agent/debug-artifacts/bd-trace.jsonl}"
    if [[ -f "${_bd_trace}" ]]; then
        cp "${_bd_trace}" "${artifacts_dir}/bd-trace.jsonl" 2>/dev/null || true
    fi

    # The fixture predicate the verifier was asserting against.
    cp "${PACK_ROOT}/fixtures/${SCENARIO_ID}-expected.json" "${artifacts_dir}/" 2>/dev/null || true

    # Exit codes + the bead-dump rendered earlier (re-render to a file).
    {
        echo "scenario: ${SCENARIO_ID}"
        echo "driver_rc: ${DRIVER_RC}"
        echo "verifier_rc: ${VERIFIER_RC}"
        echo "captured_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "${artifacts_dir}/summary.txt"

    chmod -R a+rX "${artifacts_dir}" 2>/dev/null || true
    echo "===== artifact capture complete =====" >&2
fi

if [[ "${DRIVER_RC}" -ne 0 ]]; then
    echo "run-scenario: driver exited ${DRIVER_RC}; verifier exited ${VERIFIER_RC}" >&2
    exit "${DRIVER_RC}"
fi

exit "${VERIFIER_RC}"
