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
if [[ "${DRIVER_RC}" -ne 0 ]]; then
    echo "run-scenario: driver exited ${DRIVER_RC}; verifier exited ${VERIFIER_RC}" >&2
    exit "${DRIVER_RC}"
fi

exit "${VERIFIER_RC}"
