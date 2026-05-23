#!/usr/bin/env bash
# eval-ralph.sh — single-Claude-agent baseline runner for plan-evals M1
#
# Usage:
#   bash scripts/eval-ralph.sh <case-id> [--output-dir DIR] [--run-id ID]
#
# Writes: <output-dir>/results-<run-id>.json
#
# Token capture: claude --output-format json emits a top-level "usage" object
# with input_tokens and output_tokens fields. We parse those. The JSON output
# also includes cache_creation_input_tokens and cache_read_input_tokens; we
# report tokens_in as input_tokens (prompt tokens sent to the model this turn,
# excluding cache hits). If JSON parsing fails, tokens_in/tokens_out are 0.
#
# Worker model: claude --output-format json emits a top-level "modelUsage"
# object whose keys are model identifiers (e.g. "claude-opus-4-7[1m]"). We
# extract the first key from iter-1 output as worker_model. If absent or
# unparseable, the field is omitted from results rather than faked.
#
# Scorer: expects scripts/eval-scorer.py to exist. If absent, exits with a
# clear error after still writing a results JSON with scorer fields zeroed.
#
# Interface per epic fo-ghqjh (locked):
#   result JSON fields: run_id, case_id, pattern, wall_clock_secs,
#                       tokens_in, tokens_out, visible_pass, visible_total,
#                       existing_pass, existing_total, exit_code
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve repo root (script lives in scripts/ one level under root)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Shared model constants (WORKER_MODEL, PLANNER_MODEL).
source "${SCRIPT_DIR}/eval-config.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CASE_ID=""
OUTPUT_DIR="/tmp/eval-runs"
RUN_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="$2"; shift 2 ;;
    --run-id)
      RUN_ID="$2"; shift 2 ;;
    -*)
      echo "Unknown flag: $1" >&2; exit 1 ;;
    *)
      if [[ -z "$CASE_ID" ]]; then
        CASE_ID="$1"; shift
      else
        echo "Unexpected positional argument: $1" >&2; exit 1
      fi
      ;;
  esac
done

if [[ -z "$CASE_ID" ]]; then
  echo "Usage: bash scripts/eval-ralph.sh <case-id> [--output-dir DIR] [--run-id ID]" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
if ! command -v claude &>/dev/null; then
  echo "ERROR: 'claude' not found on PATH. Install Claude Code CLI before running evals." >&2
  exit 1
fi

CASE_PATH="${REPO_ROOT}/evals/${CASE_ID}"
if [[ ! -d "$CASE_PATH" ]]; then
  echo "ERROR: Eval case not found: ${CASE_PATH}" >&2
  exit 1
fi

if [[ ! -f "${CASE_PATH}/spec.md" ]]; then
  echo "ERROR: spec.md missing from case: ${CASE_PATH}/spec.md" >&2
  exit 1
fi

if [[ ! -d "${CASE_PATH}/starting-state" ]]; then
  echo "ERROR: starting-state/ missing from case: ${CASE_PATH}/starting-state" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Generate run-id if not provided
# ---------------------------------------------------------------------------
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -z "$RUN_ID" ]]; then
  RUN_ID="ralph-${CASE_ID}-${TIMESTAMP}-$$"
fi

# ---------------------------------------------------------------------------
# Create worktree directory
# ---------------------------------------------------------------------------
WORKTREE="${OUTPUT_DIR}/${RUN_ID}/worktree"
mkdir -p "$WORKTREE"

echo "=== eval-ralph: ${CASE_ID} (run_id=${RUN_ID}) ===" >&2
echo "  worktree: ${WORKTREE}" >&2

# ---------------------------------------------------------------------------
# Copy starting-state into worktree
# ---------------------------------------------------------------------------
echo "  Copying starting-state..." >&2
cp -r "${CASE_PATH}/starting-state/." "${WORKTREE}/"

# ---------------------------------------------------------------------------
# Read spec
# ---------------------------------------------------------------------------
SPEC_CONTENT="$(cat "${CASE_PATH}/spec.md")"

# ---------------------------------------------------------------------------
# Ralph loop: attempt → check goal → retry if needed (up to MAX_ITERS)
#
# "Real ralph" is a goal-check loop, not a single turn. For tasks claude
# can solve in one turn (like cancel-method), this terminates after iter=1
# with the same wall-clock as one-shot. For harder tasks, ralph keeps trying
# with feedback from previous iterations until visible tests pass or the
# iteration cap is hit. Wall-clock + tokens are cumulative across iterations.
# ---------------------------------------------------------------------------
MAX_ITERS="${RALPH_MAX_ITERS:-5}"
SCORER="${REPO_ROOT}/scripts/eval-scorer.py"
CLAUDE_EXIT_CODE=0
TOKENS_IN=0
TOKENS_OUT=0
VISIBLE_PASS=0
VISIBLE_TOTAL=0
HIDDEN_PASS=0
HIDDEN_TOTAL=0
EXISTING_PASS=0
EXISTING_TOTAL=0
ITERATIONS=0
OBSERVED_MODEL=""

LOOP_START_SECS="$(date +%s%N)"

for (( iter=1; iter <= MAX_ITERS; iter++ )); do
  ITERATIONS="$iter"
  CLAUDE_OUTPUT_FILE="${OUTPUT_DIR}/${RUN_ID}/claude-output-iter${iter}.json"

  # Build iteration prompt: spec on iter 1; spec + failure feedback on retries.
  if [[ $iter -eq 1 ]]; then
    ITER_PROMPT="${SPEC_CONTENT}"
  else
    ITER_PROMPT="Your previous attempt did not pass all visible tests. The scorer reported visible_pass=${VISIBLE_PASS}/${VISIBLE_TOTAL}. Examine the test failures (run pytest visible-tests/ from the worktree if helpful) and fix the remaining issues. Stay strictly in scope per the original spec below.

---

${SPEC_CONTENT}"
  fi

  echo "  Invoking Claude Code agent (iter ${iter}/${MAX_ITERS})..." >&2

  ITER_EXIT_CODE=0
  (
    cd "${WORKTREE}"
    claude \
      -p "${ITER_PROMPT}" \
      --model "${WORKER_MODEL}" \
      --dangerously-skip-permissions \
      --output-format json \
      2>&1
  ) > "${CLAUDE_OUTPUT_FILE}" || ITER_EXIT_CODE=$?

  # Track the LAST iteration's claude exit code as the run's exit code.
  # If any iteration succeeds (scorer passes) we use that; if the loop
  # exhausts, the final iteration's code is most representative.
  CLAUDE_EXIT_CODE="$ITER_EXIT_CODE"
  echo "    Claude iter ${iter} exited with code: ${ITER_EXIT_CODE}" >&2

  # Accumulate tokens from this iteration; capture worker_model from iter 1.
  if command -v python3 &>/dev/null && [[ -f "${CLAUDE_OUTPUT_FILE}" ]]; then
    read -r ITER_TOKENS_IN ITER_TOKENS_OUT < <(
      python3 - "${CLAUDE_OUTPUT_FILE}" <<'PYEOF'
import sys, json
try:
    with open(sys.argv[1]) as f:
        raw = f.read().strip()
    data = json.loads(raw)
    usage = data.get("usage", {})
    tokens_in = usage.get("input_tokens", 0) or 0
    tokens_out = usage.get("output_tokens", 0) or 0
    print(tokens_in, tokens_out)
except Exception:
    print(0, 0)
PYEOF
    ) || true
    TOKENS_IN=$(( TOKENS_IN + ITER_TOKENS_IN ))
    TOKENS_OUT=$(( TOKENS_OUT + ITER_TOKENS_OUT ))

    # Extract worker_model from the first iteration's modelUsage keys.
    # modelUsage is a dict keyed by model ID; we take the first key.
    if [[ $iter -eq 1 && -z "$OBSERVED_MODEL" ]]; then
      OBSERVED_MODEL="$(python3 - "${CLAUDE_OUTPUT_FILE}" <<'PYEOF'
import sys, json
try:
    with open(sys.argv[1]) as f:
        raw = f.read().strip()
    data = json.loads(raw)
    model_usage = data.get("modelUsage", {})
    if model_usage:
        print(next(iter(model_usage)))
    else:
        print("")
except Exception:
    print("")
PYEOF
      )" || true
    fi
  fi

  # Score this iteration.
  SCORER_OK=true
  if [[ ! -f "${SCORER}" ]]; then
    echo "    WARNING: Scorer not yet present at ${SCORER}. Score fields will be 0." >&2
    SCORER_OK=false
  fi

  if [[ "$SCORER_OK" == "true" ]]; then
    SCORER_OUTPUT="$(python3 "${SCORER}" \
      --case-path "${CASE_PATH}" \
      --worktree "${WORKTREE}" \
      2>&1)" || {
      echo "    WARNING: Scorer exited non-zero. Score fields will be 0." >&2
      SCORER_OK=false
    }
  fi

  if [[ "$SCORER_OK" == "true" ]] && command -v python3 &>/dev/null; then
    read -r VISIBLE_PASS VISIBLE_TOTAL HIDDEN_PASS HIDDEN_TOTAL EXISTING_PASS EXISTING_TOTAL < <(
      python3 - "${SCORER_OUTPUT}" <<'PYEOF'
import sys, json
try:
    data = json.loads(sys.argv[1])
    print(
        data.get("visible_pass", 0),
        data.get("visible_total", 0),
        data.get("hidden_pass", 0),
        data.get("hidden_total", 0),
        data.get("existing_pass", 0),
        data.get("existing_total", 0),
    )
except Exception:
    print(0, 0, 0, 0, 0, 0)
PYEOF
    ) || true
  fi

  echo "    Scorer iter ${iter}: visible ${VISIBLE_PASS}/${VISIBLE_TOTAL}, hidden ${HIDDEN_PASS}/${HIDDEN_TOTAL}, existing ${EXISTING_PASS}/${EXISTING_TOTAL}" >&2

  # Goal-check: if all visible tests pass AND existing tests still pass, done.
  if [[ "${VISIBLE_PASS}" -eq "${VISIBLE_TOTAL}" ]] \
      && [[ "${VISIBLE_TOTAL}" -gt 0 ]] \
      && [[ "${EXISTING_PASS}" -eq "${EXISTING_TOTAL}" ]]; then
    echo "  Goal reached at iteration ${iter}." >&2
    break
  fi

  if [[ $iter -lt $MAX_ITERS ]]; then
    echo "  Not yet at goal (visible ${VISIBLE_PASS}/${VISIBLE_TOTAL}); iterating..." >&2
  else
    echo "  Reached MAX_ITERS=${MAX_ITERS} without passing all visible tests." >&2
  fi
done

LOOP_END_SECS="$(date +%s%N)"
ELAPSED_NS=$(( LOOP_END_SECS - LOOP_START_SECS ))
WALL_CLOCK_SECS="$(awk "BEGIN { printf \"%.1f\", ${ELAPSED_NS} / 1000000000 }")"

echo "  Total: ${ITERATIONS} iteration(s), tokens in: ${TOKENS_IN}, out: ${TOKENS_OUT}, wall: ${WALL_CLOCK_SECS}s" >&2
echo "  Final scorer: visible ${VISIBLE_PASS}/${VISIBLE_TOTAL}, hidden ${HIDDEN_PASS}/${HIDDEN_TOTAL}, existing ${EXISTING_PASS}/${EXISTING_TOTAL}" >&2

# ---------------------------------------------------------------------------
# Write results JSON
# ---------------------------------------------------------------------------
RESULTS_FILE="${OUTPUT_DIR}/results-${RUN_ID}.json"
mkdir -p "${OUTPUT_DIR}"

python3 - <<PYEOF
import json, sys

result = {
    "run_id":           "${RUN_ID}",
    "case_id":          "${CASE_ID}",
    "pattern":          "ralph",
    "wall_clock_secs":  float("${WALL_CLOCK_SECS}"),
    "tokens_in":        int("${TOKENS_IN}"),
    "tokens_out":       int("${TOKENS_OUT}"),
    "visible_pass":     int("${VISIBLE_PASS}"),
    "visible_total":    int("${VISIBLE_TOTAL}"),
    "hidden_pass":      int("${HIDDEN_PASS}"),
    "hidden_total":     int("${HIDDEN_TOTAL}"),
    "existing_pass":    int("${EXISTING_PASS}"),
    "existing_total":   int("${EXISTING_TOTAL}"),
    "exit_code":        int("${CLAUDE_EXIT_CODE}"),
    "iterations":       int("${ITERATIONS}"),
    "max_iterations":   int("${MAX_ITERS}"),
}

worker_model = "${OBSERVED_MODEL}".strip()
if worker_model:
    result["worker_model"] = worker_model

with open("${RESULTS_FILE}", "w") as f:
    json.dump(result, f, indent=2)
    f.write("\n")

print(json.dumps(result, indent=2))
PYEOF

echo "" >&2
echo "  Results written to: ${RESULTS_FILE}" >&2
