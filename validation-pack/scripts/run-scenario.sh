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

# Run driver; don't let set -e abort us here — we want to capture the code.
DRIVER_RC=0
bash "${SCENARIO_SCRIPT}" || DRIVER_RC=$?

# Run verifier regardless — its output is useful for diagnosis even when the
# driver failed.
VERIFIER_RC=0
python3 "${PACK_ROOT}/scripts/verify_bead_state.py" --scenario "${SCENARIO_ID}" || VERIFIER_RC=$?

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

if [[ "${DRIVER_RC}" -ne 0 ]]; then
    echo "run-scenario: driver exited ${DRIVER_RC}; verifier exited ${VERIFIER_RC}" >&2
    exit "${DRIVER_RC}"
fi

exit "${VERIFIER_RC}"
