#!/usr/bin/env bash
# eval-tpc.sh — Two-Phase Commit runner for plan-evals
#
# TWO-PHASE COMMIT PATTERN:
#
#   Phase 1 (contract-author): a claude -p instance reads spec.md and writes
#   tests/test_contract.py (≥5 test functions) plus a minimal stub in
#   validator/__init__.py. It does NOT implement the validator.
#
#   Phase 2 (implementer): a separate claude -p instance (fresh context) reads
#   spec.md + tests/test_contract.py and implements validator/__init__.py so
#   the contract tests pass. It MAY NOT modify any test file.
#
#   Between phases: tests/ is snapshotted via sha256sum. After Phase 2, the
#   snapshot is re-checked. Any modification → run failure with
#   _meta.implementer_modified_tests = <count>.
#
# Usage:
#   bash scripts/eval-tpc.sh <case-id> [--output-dir DIR] [--run-id ID]
#
# Outputs:
#   <output-dir>/results-<run-id>.json  — per-run result JSON
#
# JSON schema (per design fragment docs/two-phase-commit-eval.md):
#   pattern, phase1_wall_clock_secs, phase1_tokens_in/out/cache_*,
#   phase1_test_count, phase2_wall_clock_secs, phase2_tokens_in/out/cache_*,
#   wall_clock_secs (combined), tokens_in/out/cache_* (combined),
#   visible_pass/total, hidden_pass/total, existing_pass/total,
#   exit_code, _meta

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
CASE_ID=""
OUTPUT_DIR="/tmp/eval-runs"
RUN_ID=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EVALS_DIR="${REPO_ROOT}/evals"

# Shared model constants (WORKER_MODEL, PLANNER_MODEL).
source "${SCRIPT_DIR}/eval-config.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --run-id)
            RUN_ID="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [[ -z "$CASE_ID" ]]; then
                CASE_ID="$1"
            else
                echo "Unexpected positional argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$CASE_ID" ]]; then
    echo "Usage: $0 <case-id> [--output-dir DIR] [--run-id ID]" >&2
    exit 1
fi

CASE_DIR="${EVALS_DIR}/${CASE_ID}"
if [[ ! -d "$CASE_DIR" ]]; then
    echo "Case directory not found: ${CASE_DIR}" >&2
    exit 1
fi

SPEC_FILE="${CASE_DIR}/spec.md"
if [[ ! -f "$SPEC_FILE" ]]; then
    echo "spec.md not found in: ${CASE_DIR}" >&2
    exit 1
fi

STARTING_STATE="${CASE_DIR}/starting-state"
if [[ ! -d "$STARTING_STATE" ]]; then
    echo "starting-state not found in: ${CASE_DIR}" >&2
    exit 1
fi

# Generate run-id from timestamp if not provided
if [[ -z "$RUN_ID" ]]; then
    RUN_ID="tpc-${CASE_ID}-$(date -u +%Y%m%d-%H%M%S)"
fi

# ---------------------------------------------------------------------------
# Set up worktree
# ---------------------------------------------------------------------------
mkdir -p "${OUTPUT_DIR}"
WORKTREE="${OUTPUT_DIR}/${RUN_ID}/worktree"
AGENT_TMP="${OUTPUT_DIR}/${RUN_ID}/agents"
mkdir -p "${WORKTREE}"
mkdir -p "${AGENT_TMP}"

echo "[tpc] Case: ${CASE_ID}  run_id: ${RUN_ID}" >&2
echo "[tpc] Copying starting-state → ${WORKTREE}" >&2
cp -r "${STARTING_STATE}/." "${WORKTREE}/"

# Ensure tests/ exists in worktree (starting-state may have an empty dir)
mkdir -p "${WORKTREE}/tests"

# ---------------------------------------------------------------------------
# Read spec content once
# ---------------------------------------------------------------------------
SPEC_CONTENT="$(cat "${SPEC_FILE}")"

# ---------------------------------------------------------------------------
# Combined wall-clock start
# ---------------------------------------------------------------------------
WALL_TOTAL_START="$(date +%s%3N)"

# ---------------------------------------------------------------------------
# Phase 1 — Contract author
# ---------------------------------------------------------------------------
echo "[tpc] Phase 1: contract-author starting…" >&2

PHASE1_BRIEF="You are the contract-author in a Two-Phase Commit TDD workflow.

Working directory: ${WORKTREE}

Your task:
1. Read the spec below carefully.
2. Write a comprehensive test file at tests/test_contract.py that asserts the
   contract described in the spec. Include at least 5 test functions. Cover
   the main behaviours AND the edge cases you can derive from the spec
   (type errors, boundary values, reserved ranges, etc.).
3. Write a minimal stub at validator/__init__.py — just enough so the test file
   can be imported (the class with a validate method that returns None or raises
   NotImplementedError). Do NOT implement the actual logic.

You MUST produce tests/test_contract.py and validator/__init__.py.
Do NOT implement the validator — Phase 2 will do that.

---
SPEC:
---
${SPEC_CONTENT}
---

When done, output a brief summary of the test functions you wrote."

PHASE1_OUT="${AGENT_TMP}/phase1.out"
PHASE1_ERR="${AGENT_TMP}/phase1.err"
PHASE1_START="$(date +%s%3N)"
PHASE1_EXIT=0

claude -p "${PHASE1_BRIEF}" \
    --model "${WORKER_MODEL}" \
    --dangerously-skip-permissions \
    --output-format json \
    > "${PHASE1_OUT}" \
    2> "${PHASE1_ERR}" || PHASE1_EXIT=$?

PHASE1_END="$(date +%s%3N)"
PHASE1_WALL_MS=$(( PHASE1_END - PHASE1_START ))
PHASE1_WALL_SECS="$(python3 -c "print(round(${PHASE1_WALL_MS}/1000.0, 1))")"

echo "[tpc] Phase 1 done. exit=${PHASE1_EXIT} wall=${PHASE1_WALL_SECS}s" >&2

# ---------------------------------------------------------------------------
# Extract Phase 1 tokens
# ---------------------------------------------------------------------------
PHASE1_TOKENS_IN=0
PHASE1_TOKENS_OUT=0
PHASE1_CACHE_CREATE=0
PHASE1_CACHE_READ=0
OBSERVED_MODEL=""

if [[ -f "${PHASE1_OUT}" ]]; then
    P1_USAGE="$(python3 "${SCRIPT_DIR}/eval-extract-usage.py" "${PHASE1_OUT}" 2>/dev/null || echo '{}')"
    PHASE1_TOKENS_IN="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('input_tokens', 0))" "$P1_USAGE")"
    PHASE1_TOKENS_OUT="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('output_tokens', 0))" "$P1_USAGE")"
    PHASE1_CACHE_CREATE="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('cache_creation_input_tokens', 0))" "$P1_USAGE")"
    PHASE1_CACHE_READ="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('cache_read_input_tokens', 0))" "$P1_USAGE")"
    OBSERVED_MODEL="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('model', ''))" "$P1_USAGE")" || true
fi

echo "[tpc] Phase 1 tokens: in=${PHASE1_TOKENS_IN} out=${PHASE1_TOKENS_OUT}" >&2

# ---------------------------------------------------------------------------
# Phase 1 exit criterion: tests/test_contract.py must exist with ≥5 test_* fns
# ---------------------------------------------------------------------------
CONTRACT_FILE="${WORKTREE}/tests/test_contract.py"
MIN_TEST_COUNT=5

PHASE1_TEST_COUNT=0
PHASE1_OK=true

if [[ ! -f "${CONTRACT_FILE}" ]]; then
    echo "[tpc] Phase 1 FAILED: tests/test_contract.py does not exist" >&2
    PHASE1_OK=false
else
    PHASE1_TEST_COUNT="$(python3 - "${CONTRACT_FILE}" <<'PYEOF'
import ast, sys
path = sys.argv[1]
try:
    tree = ast.parse(open(path).read())
    count = sum(
        1 for node in ast.walk(tree)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        and node.name.startswith("test_")
    )
    print(count)
except Exception:
    print(0)
PYEOF
)"
    if [[ "$PHASE1_TEST_COUNT" -lt "$MIN_TEST_COUNT" ]]; then
        echo "[tpc] Phase 1 FAILED: test_contract.py has only ${PHASE1_TEST_COUNT} test function(s) (need ≥${MIN_TEST_COUNT})" >&2
        PHASE1_OK=false
    else
        echo "[tpc] Phase 1 OK: test_contract.py has ${PHASE1_TEST_COUNT} test function(s)" >&2
    fi
fi

# ---------------------------------------------------------------------------
# If Phase 1 failed, emit a failure result and exit (option a from open Q3)
# ---------------------------------------------------------------------------
if [[ "$PHASE1_OK" == "false" ]]; then
    RESULTS_FILE="${OUTPUT_DIR}/results-${RUN_ID}.json"
    python3 - <<PYEOF
import json

result = {
    "run_id": "${RUN_ID}",
    "case_id": "${CASE_ID}",
    "pattern": "tpc",
    "phase1_wall_clock_secs": ${PHASE1_WALL_SECS},
    "phase1_tokens_in": ${PHASE1_TOKENS_IN},
    "phase1_tokens_out": ${PHASE1_TOKENS_OUT},
    "phase1_cache_creation_input_tokens": ${PHASE1_CACHE_CREATE},
    "phase1_cache_read_input_tokens": ${PHASE1_CACHE_READ},
    "phase1_test_count": ${PHASE1_TEST_COUNT},
    "phase2_wall_clock_secs": 0,
    "phase2_tokens_in": 0,
    "phase2_tokens_out": 0,
    "phase2_cache_creation_input_tokens": 0,
    "phase2_cache_read_input_tokens": 0,
    "wall_clock_secs": ${PHASE1_WALL_SECS},
    "tokens_in": ${PHASE1_TOKENS_IN},
    "tokens_out": ${PHASE1_TOKENS_OUT},
    "cache_creation_input_tokens": ${PHASE1_CACHE_CREATE},
    "cache_read_input_tokens": ${PHASE1_CACHE_READ},
    "visible_pass": 0,
    "visible_total": 0,
    "hidden_pass": 0,
    "hidden_total": 0,
    "existing_pass": 0,
    "existing_total": 0,
    "exit_code": 1,
    "_meta": {
        "phase1_failed": True,
        "tests_locked_after_phase1": False,
        "implementer_modified_tests": False,
        "worktree": "${WORKTREE}",
    }
}
with open("${RESULTS_FILE}", "w") as fh:
    json.dump(result, fh, indent=2)
    fh.write("\n")
print(json.dumps(result, indent=2))
PYEOF
    echo "[tpc] Results written to: ${RESULTS_FILE}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Snapshot tests/ after Phase 1 (file-lock enforcement)
# ---------------------------------------------------------------------------
SNAPSHOT_FILE="${AGENT_TMP}/tests_snapshot.txt"
(cd "${WORKTREE}" && find tests -type f -not -path '*/__pycache__/*' -not -name '*.pyc' -exec sha256sum {} +) | sort > "${SNAPSHOT_FILE}" 2>/dev/null || true
echo "[tpc] tests/ snapshot taken ($(wc -l < "${SNAPSHOT_FILE}") file(s))" >&2

# ---------------------------------------------------------------------------
# Phase 2 — Implementer
# ---------------------------------------------------------------------------
echo "[tpc] Phase 2: implementer starting…" >&2

# Read the contract tests Phase 1 produced so we can include them in context
CONTRACT_CONTENT="$(cat "${CONTRACT_FILE}" 2>/dev/null || echo '# (not found)')"

PHASE2_BRIEF="You are the implementer in a Two-Phase Commit TDD workflow.

Working directory: ${WORKTREE}

Your task:
1. Read spec.md and tests/test_contract.py (shown below).
2. Implement validator/__init__.py so that all contract tests pass.
3. You MAY NOT modify any file in tests/ or any test file. The test files
   are locked — any modification is a protocol violation.

Stay strictly in scope: only modify validator/__init__.py.

---
SPEC:
---
${SPEC_CONTENT}
---

CONTRACT TESTS (tests/test_contract.py):
---
${CONTRACT_CONTENT}
---

When done, run the tests to verify they pass, then output a brief summary."

PHASE2_OUT="${AGENT_TMP}/phase2.out"
PHASE2_ERR="${AGENT_TMP}/phase2.err"
PHASE2_START="$(date +%s%3N)"
PHASE2_EXIT=0

claude -p "${PHASE2_BRIEF}" \
    --model "${WORKER_MODEL}" \
    --dangerously-skip-permissions \
    --output-format json \
    > "${PHASE2_OUT}" \
    2> "${PHASE2_ERR}" || PHASE2_EXIT=$?

PHASE2_END="$(date +%s%3N)"
PHASE2_WALL_MS=$(( PHASE2_END - PHASE2_START ))
PHASE2_WALL_SECS="$(python3 -c "print(round(${PHASE2_WALL_MS}/1000.0, 1))")"

echo "[tpc] Phase 2 done. exit=${PHASE2_EXIT} wall=${PHASE2_WALL_SECS}s" >&2

# ---------------------------------------------------------------------------
# Extract Phase 2 tokens
# ---------------------------------------------------------------------------
PHASE2_TOKENS_IN=0
PHASE2_TOKENS_OUT=0
PHASE2_CACHE_CREATE=0
PHASE2_CACHE_READ=0

if [[ -f "${PHASE2_OUT}" ]]; then
    P2_USAGE="$(python3 "${SCRIPT_DIR}/eval-extract-usage.py" "${PHASE2_OUT}" 2>/dev/null || echo '{}')"
    PHASE2_TOKENS_IN="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('input_tokens', 0))" "$P2_USAGE")"
    PHASE2_TOKENS_OUT="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('output_tokens', 0))" "$P2_USAGE")"
    PHASE2_CACHE_CREATE="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('cache_creation_input_tokens', 0))" "$P2_USAGE")"
    PHASE2_CACHE_READ="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('cache_read_input_tokens', 0))" "$P2_USAGE")"
    if [[ -z "$OBSERVED_MODEL" ]]; then
        OBSERVED_MODEL="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('model', ''))" "$P2_USAGE")" || true
    fi
fi

echo "[tpc] Phase 2 tokens: in=${PHASE2_TOKENS_IN} out=${PHASE2_TOKENS_OUT}" >&2

# ---------------------------------------------------------------------------
# File-lock enforcement: diff tests/ snapshot
# ---------------------------------------------------------------------------
SNAPSHOT_AFTER="${AGENT_TMP}/tests_snapshot_after.txt"
(cd "${WORKTREE}" && find tests -type f -not -path '*/__pycache__/*' -not -name '*.pyc' -exec sha256sum {} +) | sort > "${SNAPSHOT_AFTER}" 2>/dev/null || true

IMPLEMENTER_MODIFIED_TESTS=0
TESTS_LOCKED=1   # 1 = locked (no changes), 0 = violated

if ! diff -q "${SNAPSHOT_FILE}" "${SNAPSHOT_AFTER}" > /dev/null 2>&1; then
    DIFF_LINES="$(diff "${SNAPSHOT_FILE}" "${SNAPSHOT_AFTER}" 2>/dev/null || true)"
    IMPLEMENTER_MODIFIED_TESTS="$(printf '%s\n' "${DIFF_LINES}" | grep -c '^[<>]' || echo 0)"
    echo "[tpc] LOCK VIOLATION: implementer modified ${IMPLEMENTER_MODIFIED_TESTS} test file record(s)" >&2
    TESTS_LOCKED=0
    PHASE2_EXIT=1  # treat lock violation as run failure
fi

# ---------------------------------------------------------------------------
# Combined wall-clock
# ---------------------------------------------------------------------------
WALL_TOTAL_END="$(date +%s%3N)"
WALL_TOTAL_MS=$(( WALL_TOTAL_END - WALL_TOTAL_START ))
WALL_TOTAL_SECS="$(python3 -c "print(round(${WALL_TOTAL_MS}/1000.0, 1))")"

echo "[tpc] Total wall-clock: ${WALL_TOTAL_SECS}s" >&2

# Combined token totals
TOTAL_TOKENS_IN=$(( PHASE1_TOKENS_IN + PHASE2_TOKENS_IN ))
TOTAL_TOKENS_OUT=$(( PHASE1_TOKENS_OUT + PHASE2_TOKENS_OUT ))
TOTAL_CACHE_CREATE=$(( PHASE1_CACHE_CREATE + PHASE2_CACHE_CREATE ))
TOTAL_CACHE_READ=$(( PHASE1_CACHE_READ + PHASE2_CACHE_READ ))

# ---------------------------------------------------------------------------
# Run scorer
# ---------------------------------------------------------------------------
SCORER="${REPO_ROOT}/scripts/eval-scorer.py"
SCORER_OUT='{}'

if [[ -f "$SCORER" ]]; then
    echo "[tpc] Running scorer…" >&2
    SCORER_JSON="$(python3 "${SCORER}" \
        --case-path "${CASE_DIR}" \
        --worktree "${WORKTREE}" 2>/dev/null)" || true
    if [[ -n "$SCORER_JSON" ]]; then
        SCORER_OUT="$SCORER_JSON"
    fi
else
    echo "[tpc] Scorer not found (${SCORER}); score fields zeroed." >&2
fi

VISIBLE_PASS="$(python3 -c "import json; d=json.loads('''${SCORER_OUT}'''); print(d.get('visible_pass', 0))" 2>/dev/null || echo 0)"
VISIBLE_TOTAL="$(python3 -c "import json; d=json.loads('''${SCORER_OUT}'''); print(d.get('visible_total', 0))" 2>/dev/null || echo 0)"
HIDDEN_PASS="$(python3 -c "import json; d=json.loads('''${SCORER_OUT}'''); print(d.get('hidden_pass', 0))" 2>/dev/null || echo 0)"
HIDDEN_TOTAL="$(python3 -c "import json; d=json.loads('''${SCORER_OUT}'''); print(d.get('hidden_total', 0))" 2>/dev/null || echo 0)"
EXISTING_PASS="$(python3 -c "import json; d=json.loads('''${SCORER_OUT}'''); print(d.get('existing_pass', 0))" 2>/dev/null || echo 0)"
EXISTING_TOTAL="$(python3 -c "import json; d=json.loads('''${SCORER_OUT}'''); print(d.get('existing_total', 0))" 2>/dev/null || echo 0)"

echo "[tpc] Score: visible ${VISIBLE_PASS}/${VISIBLE_TOTAL} hidden ${HIDDEN_PASS}/${HIDDEN_TOTAL} existing ${EXISTING_PASS}/${EXISTING_TOTAL}" >&2

# Overall exit: 0 only if Phase 2 passed AND lock not violated
OVERALL_EXIT=0
if [[ "$PHASE2_EXIT" -ne 0 ]]; then
    OVERALL_EXIT="$PHASE2_EXIT"
fi

# ---------------------------------------------------------------------------
# Emit results JSON
# ---------------------------------------------------------------------------
RESULTS_FILE="${OUTPUT_DIR}/results-${RUN_ID}.json"

python3 - <<PYEOF
import json

result = {
    "run_id": "${RUN_ID}",
    "case_id": "${CASE_ID}",
    "pattern": "tpc",
    # Phase 1 fields
    "phase1_wall_clock_secs": ${PHASE1_WALL_SECS},
    "phase1_tokens_in": ${PHASE1_TOKENS_IN},
    "phase1_tokens_out": ${PHASE1_TOKENS_OUT},
    "phase1_cache_creation_input_tokens": ${PHASE1_CACHE_CREATE},
    "phase1_cache_read_input_tokens": ${PHASE1_CACHE_READ},
    "phase1_test_count": ${PHASE1_TEST_COUNT},
    # Phase 2 fields
    "phase2_wall_clock_secs": ${PHASE2_WALL_SECS},
    "phase2_tokens_in": ${PHASE2_TOKENS_IN},
    "phase2_tokens_out": ${PHASE2_TOKENS_OUT},
    "phase2_cache_creation_input_tokens": ${PHASE2_CACHE_CREATE},
    "phase2_cache_read_input_tokens": ${PHASE2_CACHE_READ},
    # Combined totals
    "wall_clock_secs": ${WALL_TOTAL_SECS},
    "tokens_in": ${TOTAL_TOKENS_IN},
    "tokens_out": ${TOTAL_TOKENS_OUT},
    "cache_creation_input_tokens": ${TOTAL_CACHE_CREATE},
    "cache_read_input_tokens": ${TOTAL_CACHE_READ},
    # Scoring
    "visible_pass": ${VISIBLE_PASS},
    "visible_total": ${VISIBLE_TOTAL},
    "hidden_pass": ${HIDDEN_PASS},
    "hidden_total": ${HIDDEN_TOTAL},
    "existing_pass": ${EXISTING_PASS},
    "existing_total": ${EXISTING_TOTAL},
    "exit_code": ${OVERALL_EXIT},
    "_meta": {
        "tests_locked_after_phase1": bool(${TESTS_LOCKED}),
        "implementer_modified_tests": ${IMPLEMENTER_MODIFIED_TESTS},
        "worktree": "${WORKTREE}",
    }
}

worker_model = "${OBSERVED_MODEL}".strip()
if worker_model:
    result["worker_model"] = worker_model

with open("${RESULTS_FILE}", "w") as fh:
    json.dump(result, fh, indent=2)
    fh.write("\n")

print(json.dumps(result, indent=2))
PYEOF

echo "[tpc] Results written to: ${RESULTS_FILE}" >&2
exit "${OVERALL_EXIT}"
