#!/usr/bin/env bash
# eval-orchworkers.sh — orchestrator-workers runner for plan-evals M1
#
# ORCHESTRATOR-WORKERS PATTERN (vs. naive fanout):
#
#   Naive fanout (eval-fanout.sh) spawns N parallel claude -p workers, each
#   modifying its own file in isolation.  They cannot see each other's edits,
#   so cross-cutting concerns (shared ABCs, base-class contracts, registries,
#   enums) diverge silently.  Smoke testing on validator-suite showed 0/11
#   visible-test pass rate because workers broke base.py contracts and the
#   shared Reason enum in incompatible ways.
#
#   This script adds a MERGE STEP after the workers finish: a single "treehugger"
#   reconciliation claude -p call reads the full worktree + spec and fixes whatever
#   cross-cutting inconsistencies the parallel workers introduced.  It runs pytest
#   inside the worktree to see what's failing and iterates until it's done its
#   best reconciliation pass.  This mirrors what the validation-pack's scenario 05
#   does via the treehugger persona.
#
#   Merge tokens are tracked separately (merge_tokens_in / merge_tokens_out) AND
#   rolled into the top-level tokens_in / tokens_out totals so the totals represent
#   ALL LLM calls in the run.
#
# Usage:
#   bash scripts/eval-orchworkers.sh <case-id> [--output-dir DIR] [--run-id ID]
#
# Outputs:
#   <output-dir>/results-<run-id>.json  — per-run result JSON
#
# JSON schema: same as eval-fanout.sh plus:
#   "merge_tokens_in":  N   (included in tokens_in total)
#   "merge_tokens_out": N   (included in tokens_out total)
#
# Requirements: bash, claude (Claude Code CLI), python3, cp, date

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
CASE_ID=""
OUTPUT_DIR="/tmp/eval-runs"
RUN_ID=""

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVALS_DIR="${REPO_ROOT}/evals"

# Shared model constants (WORKER_MODEL, PLANNER_MODEL).
source "$(dirname "${BASH_SOURCE[0]}")/eval-config.sh"

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
    RUN_ID="orchworkers-${CASE_ID}-$(date -u +%Y%m%d-%H%M%S)"
fi

# ---------------------------------------------------------------------------
# Set up worktree
# ---------------------------------------------------------------------------
mkdir -p "${OUTPUT_DIR}"
WORKTREE="${OUTPUT_DIR}/${RUN_ID}/worktree"
mkdir -p "${WORKTREE}"

echo "[orchworkers] Copying starting-state → ${WORKTREE}" >&2
cp -r "${STARTING_STATE}/." "${WORKTREE}/"

# ---------------------------------------------------------------------------
# Discover files to fan out over.
#
# Cases declare their fan-out target via <case>/fanout.json:
#   {"dir": "validators", "exclude": ["base.py", "__init__.py"]}
#
# For backward compatibility, if fanout.json is absent we default to the
# cancel-method-shaped layout (dir=entities, exclude=event_bus.py + __init__.py).
# ---------------------------------------------------------------------------
FANOUT_CONFIG="${CASE_DIR}/fanout.json"
if [[ -f "$FANOUT_CONFIG" ]]; then
    FANOUT_DIR_NAME="$(python3 -c "import json; print(json.load(open('${FANOUT_CONFIG}'))['dir'])")"
    FANOUT_EXCLUDE_LIST="$(python3 -c "import json; print(' '.join(json.load(open('${FANOUT_CONFIG}'))['exclude']))")"
else
    FANOUT_DIR_NAME="entities"
    FANOUT_EXCLUDE_LIST="event_bus.py __init__.py"
fi

ENTITIES_DIR="${WORKTREE}/${FANOUT_DIR_NAME}"
if [[ ! -d "$ENTITIES_DIR" ]]; then
    echo "fan-out target dir not found in worktree: ${ENTITIES_DIR}" >&2
    exit 1
fi

ENTITY_FILES=()
while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    skip=false
    for excl in $FANOUT_EXCLUDE_LIST; do
        if [[ "$base" == "$excl" ]]; then
            skip=true
            break
        fi
    done
    [[ "$skip" == true ]] && continue
    ENTITY_FILES+=("$f")
done < <(find "${ENTITIES_DIR}" -maxdepth 1 -name "*.py" -print0 | sort -z)

if [[ ${#ENTITY_FILES[@]} -eq 0 ]]; then
    echo "No fan-out target files found in: ${ENTITIES_DIR}" >&2
    exit 1
fi

echo "[orchworkers] Fan-out target: ${FANOUT_DIR_NAME}/ — found ${#ENTITY_FILES[@]} file(s): ${ENTITY_FILES[*]}" >&2

# Build the file list for the merge brief (relative paths from worktree)
WORKER_FILE_LIST=""
for ENTITY_FILE in "${ENTITY_FILES[@]}"; do
    ENTITY_BASENAME="$(basename "${ENTITY_FILE}")"
    WORKER_FILE_LIST="${WORKER_FILE_LIST}  - ${FANOUT_DIR_NAME}/${ENTITY_BASENAME}"$'\n'
done

# ---------------------------------------------------------------------------
# Read spec content once
# ---------------------------------------------------------------------------
SPEC_CONTENT="$(cat "${SPEC_FILE}")"

# ---------------------------------------------------------------------------
# Temp dir for per-agent output
# ---------------------------------------------------------------------------
AGENT_TMP="${OUTPUT_DIR}/${RUN_ID}/agents"
mkdir -p "${AGENT_TMP}"

# ---------------------------------------------------------------------------
# Start wall-clock timer
# ---------------------------------------------------------------------------
WALL_START="$(date +%s%3N)"   # milliseconds

# ---------------------------------------------------------------------------
# Spawn one claude -p per entity file in the background
# ---------------------------------------------------------------------------
declare -a PIDS=()
declare -A PID_TO_FILE
declare -A PID_TO_OUT

for ENTITY_FILE in "${ENTITY_FILES[@]}"; do
    ENTITY_BASENAME="$(basename "${ENTITY_FILE}")"
    ENTITY_REL="${FANOUT_DIR_NAME}/${ENTITY_BASENAME}"
    AGENT_OUT="${AGENT_TMP}/${ENTITY_BASENAME%.py}.out"
    AGENT_ERR="${AGENT_TMP}/${ENTITY_BASENAME%.py}.err"

    BRIEF="Working in the directory: ${WORKTREE}

Your task is to modify ONLY the file: ${ENTITY_REL}

Do not touch any other file. Do not modify tests. Read the spec below for what to do.

Here is the full task spec for context (but your scope is limited to ${ENTITY_REL}):

---
${SPEC_CONTENT}
---

When done, your work is complete. Output a summary of what you changed."

    echo "[orchworkers] Spawning worker for ${ENTITY_BASENAME}" >&2
    claude -p "${BRIEF}" \
        --model "${WORKER_MODEL}" \
        --dangerously-skip-permissions \
        --output-format json \
        > "${AGENT_OUT}" \
        2> "${AGENT_ERR}" &

    PID=$!
    PIDS+=("$PID")
    PID_TO_FILE[$PID]="${ENTITY_BASENAME}"
    PID_TO_OUT[$PID]="${AGENT_OUT}"
done

# ---------------------------------------------------------------------------
# Wait for all background worker processes, collect exit codes + tokens
# ---------------------------------------------------------------------------
echo "[orchworkers] Waiting for ${#PIDS[@]} worker(s)…" >&2

TOTAL_TOKENS_IN=0
TOTAL_TOKENS_OUT=0
TOKENS_PARTIAL=0   # flag: 1 if any agent didn't surface tokens
OVERALL_EXIT=0
WORKER_MODEL=""

# Per-worker token records written as JSONL; assembled into the result JSON's
# `workers` array. Each line: {"file": "...", "tokens_in": N, "tokens_out": N}.
# Merge-step tokens stay in their own merge_tokens_in/merge_tokens_out fields.
WORKERS_JSONL="${AGENT_TMP}/workers.jsonl"
: > "${WORKERS_JSONL}"

for PID in "${PIDS[@]}"; do
    ENTITY_BASENAME="${PID_TO_FILE[$PID]}"
    AGENT_OUT="${PID_TO_OUT[$PID]}"

    if wait "$PID"; then
        AGENT_EXIT=0
    else
        AGENT_EXIT=$?
        OVERALL_EXIT=$AGENT_EXIT
        echo "[orchworkers] Worker for ${ENTITY_BASENAME} exited with code ${AGENT_EXIT}" >&2
    fi

    # Per-worker tokens default to 0 when parsing fails; emit one entry per
    # spawned worker so the workers array is parallel to ENTITY_FILES.
    AGENT_IN_N=0
    AGENT_OUT_N=0

    # Try to parse token counts and worker_model from JSON output
    if [[ -f "${AGENT_OUT}" ]] && command -v python3 &>/dev/null; then
        AGENT_IN="$(python3 -c "
import sys, json
try:
    data = json.load(open('${AGENT_OUT}'))
    usage = data.get('usage', {})
    print(usage.get('input_tokens', usage.get('prompt_tokens', '')))
except Exception:
    print('')
" 2>/dev/null)"
        AGENT_OUT_TOK="$(python3 -c "
import sys, json
try:
    data = json.load(open('${AGENT_OUT}'))
    usage = data.get('usage', {})
    print(usage.get('output_tokens', usage.get('completion_tokens', '')))
except Exception:
    print('')
" 2>/dev/null)"

        if [[ -n "$AGENT_IN" && "$AGENT_IN" =~ ^[0-9]+$ ]]; then
            AGENT_IN_N="$AGENT_IN"
            TOTAL_TOKENS_IN=$((TOTAL_TOKENS_IN + AGENT_IN))
        else
            TOKENS_PARTIAL=1
        fi
        if [[ -n "$AGENT_OUT_TOK" && "$AGENT_OUT_TOK" =~ ^[0-9]+$ ]]; then
            AGENT_OUT_N="$AGENT_OUT_TOK"
            TOTAL_TOKENS_OUT=$((TOTAL_TOKENS_OUT + AGENT_OUT_TOK))
        else
            TOKENS_PARTIAL=1
        fi

        # Capture worker_model from the first agent output that has modelUsage.
        if [[ -z "$WORKER_MODEL" ]]; then
            WORKER_MODEL="$(python3 -c "
import sys, json
try:
    data = json.load(open('${AGENT_OUT}'))
    model_usage = data.get('modelUsage', {})
    if model_usage:
        print(next(iter(model_usage)))
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null)" || true
        fi
    else
        TOKENS_PARTIAL=1
    fi

    # Append per-worker record (json-safe via python).
    python3 -c "
import json
print(json.dumps({
    'file': '${ENTITY_BASENAME}',
    'tokens_in': ${AGENT_IN_N},
    'tokens_out': ${AGENT_OUT_N},
}))
" >> "${WORKERS_JSONL}"
done

echo "[orchworkers] All workers done. Starting merge step…" >&2

# ---------------------------------------------------------------------------
# MERGE STEP — one reconciliation call that reads the full worktree + spec
# and fixes cross-cutting inconsistencies the parallel workers may have
# introduced (broken imports, ABC/interface violations, enum drift, etc.).
# ---------------------------------------------------------------------------

# Discover visible/existing test paths for the pytest invocation in the brief.
# We pass whatever test dirs/files exist under the worktree and case dir.
PYTEST_TARGETS=""
if [[ -d "${CASE_DIR}/visible-tests" ]]; then
    PYTEST_TARGETS="${PYTEST_TARGETS} ${CASE_DIR}/visible-tests"
fi
if [[ -d "${WORKTREE}/tests" ]]; then
    PYTEST_TARGETS="${PYTEST_TARGETS} ${WORKTREE}/tests"
fi
PYTEST_TARGETS="${PYTEST_TARGETS# }"  # strip leading space

MERGE_BRIEF="You are the final reconciliation step in an orchestrator-workers workflow.

${#ENTITY_FILES[@]} parallel workers each modified one of the following files independently:
${WORKER_FILE_LIST}
They could not see each other's changes. Your job: read the spec, examine
the current state of the worktree at ${WORKTREE}, and resolve any cross-cutting
inconsistencies the workers may have introduced. Specifically:

- Imports broken because workers modified shared modules incompatibly
- Shared ABC / interface contract violations (e.g. base class changes)
- Inconsistent style or naming across the per-file outputs
- Cross-cutting concerns (registries, enums, type aliases) needing reconciliation
- Any regression in files the workers were NOT supposed to touch

Stay strictly in scope: do not add new features or rewrite the workers' work;
just RECONCILE.

Run:
  cd ${WORKTREE} && PYTHONPATH=${WORKTREE} pytest ${PYTEST_TARGETS}
to see what is failing, and fix until either all tests pass or you have made
your best reconciliation pass.

---
FULL SPEC:
---
${SPEC_CONTENT}
---"

MERGE_OUT="${AGENT_TMP}/merge.out"
MERGE_ERR="${AGENT_TMP}/merge.err"

MERGE_EXIT=0
claude -p "${MERGE_BRIEF}" \
    --model "${PLANNER_MODEL}" \
    --dangerously-skip-permissions \
    --output-format json \
    > "${MERGE_OUT}" \
    2> "${MERGE_ERR}" || MERGE_EXIT=$?

if [[ "$MERGE_EXIT" -ne 0 ]]; then
    echo "[orchworkers] Merge step exited with code ${MERGE_EXIT}" >&2
    OVERALL_EXIT=$MERGE_EXIT
fi

# Parse merge step token counts
MERGE_TOKENS_IN=0
MERGE_TOKENS_OUT=0

if [[ -f "${MERGE_OUT}" ]] && command -v python3 &>/dev/null; then
    MERGE_IN_RAW="$(python3 -c "
import sys, json
try:
    data = json.load(open('${MERGE_OUT}'))
    usage = data.get('usage', {})
    print(usage.get('input_tokens', usage.get('prompt_tokens', '')))
except Exception:
    print('')
" 2>/dev/null)"
    MERGE_OUT_RAW="$(python3 -c "
import sys, json
try:
    data = json.load(open('${MERGE_OUT}'))
    usage = data.get('usage', {})
    print(usage.get('output_tokens', usage.get('completion_tokens', '')))
except Exception:
    print('')
" 2>/dev/null)"

    if [[ -n "$MERGE_IN_RAW" && "$MERGE_IN_RAW" =~ ^[0-9]+$ ]]; then
        MERGE_TOKENS_IN="$MERGE_IN_RAW"
    else
        TOKENS_PARTIAL=1
    fi
    if [[ -n "$MERGE_OUT_RAW" && "$MERGE_OUT_RAW" =~ ^[0-9]+$ ]]; then
        MERGE_TOKENS_OUT="$MERGE_OUT_RAW"
    else
        TOKENS_PARTIAL=1
    fi

    # Also try to capture model from merge output if we didn't get it from workers
    if [[ -z "$WORKER_MODEL" ]]; then
        WORKER_MODEL="$(python3 -c "
import sys, json
try:
    data = json.load(open('${MERGE_OUT}'))
    model_usage = data.get('modelUsage', {})
    if model_usage:
        print(next(iter(model_usage)))
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null)" || true
    fi
else
    TOKENS_PARTIAL=1
fi

# Roll merge tokens into totals (merge overhead is part of the run cost)
TOTAL_TOKENS_IN=$((TOTAL_TOKENS_IN + MERGE_TOKENS_IN))
TOTAL_TOKENS_OUT=$((TOTAL_TOKENS_OUT + MERGE_TOKENS_OUT))

echo "[orchworkers] Merge step done. merge_tokens_in=${MERGE_TOKENS_IN} merge_tokens_out=${MERGE_TOKENS_OUT}" >&2

# ---------------------------------------------------------------------------
# Wall-clock elapsed (seconds, one decimal)
# ---------------------------------------------------------------------------
WALL_END="$(date +%s%3N)"
WALL_MS=$(( WALL_END - WALL_START ))
WALL_SECS="$(python3 -c "print(round(${WALL_MS}/1000.0, 1))")"

echo "[orchworkers] Run complete. Wall-clock: ${WALL_SECS}s" >&2

# ---------------------------------------------------------------------------
# Run scorer (if available; graceful fallback if not)
# ---------------------------------------------------------------------------
SCORER="${REPO_ROOT}/scripts/eval-scorer.py"
SCORER_OUT='{}'

if [[ -f "$SCORER" ]]; then
    echo "[orchworkers] Running scorer…" >&2
    SCORER_JSON="$(python3 "${SCORER}" \
        --case-path "${CASE_DIR}" \
        --worktree "${WORKTREE}" 2>/dev/null)" || true
    if [[ -n "$SCORER_JSON" ]]; then
        SCORER_OUT="$SCORER_JSON"
    fi
else
    echo "[orchworkers] Scorer not found (${SCORER}); using zero-fill fallback." >&2
fi

VISIBLE_PASS="$(python3 -c "import json; d=json.loads('''${SCORER_OUT}'''); print(d.get('visible_pass', 0))" 2>/dev/null || echo 0)"
VISIBLE_TOTAL="$(python3 -c "import json; d=json.loads('''${SCORER_OUT}'''); print(d.get('visible_total', 0))" 2>/dev/null || echo 0)"
HIDDEN_PASS="$(python3 -c "import json; d=json.loads('''${SCORER_OUT}'''); print(d.get('hidden_pass', 0))" 2>/dev/null || echo 0)"
HIDDEN_TOTAL="$(python3 -c "import json; d=json.loads('''${SCORER_OUT}'''); print(d.get('hidden_total', 0))" 2>/dev/null || echo 0)"
EXISTING_PASS="$(python3 -c "import json; d=json.loads('''${SCORER_OUT}'''); print(d.get('existing_pass', 0))" 2>/dev/null || echo 0)"
EXISTING_TOTAL="$(python3 -c "import json; d=json.loads('''${SCORER_OUT}'''); print(d.get('existing_total', 0))" 2>/dev/null || echo 0)"

# ---------------------------------------------------------------------------
# Emit results JSON
# ---------------------------------------------------------------------------
RESULTS_FILE="${OUTPUT_DIR}/results-${RUN_ID}.json"

python3 - <<PYEOF
import json, sys

tokens_partial = ${TOKENS_PARTIAL} == 1
tokens_note = "partial (some agents did not surface token counts)" if tokens_partial else "complete"

# Read per-worker JSONL (one record per per-file worker; the merge step's
# tokens are reported separately as merge_tokens_in / merge_tokens_out).
workers = []
try:
    with open("${WORKERS_JSONL}") as fh:
        for line in fh:
            line = line.strip()
            if line:
                workers.append(json.loads(line))
except FileNotFoundError:
    pass

result = {
    "run_id": "${RUN_ID}",
    "case_id": "${CASE_ID}",
    "pattern": "orchworkers",
    "wall_clock_secs": ${WALL_SECS},
    "tokens_in": ${TOTAL_TOKENS_IN},
    "tokens_out": ${TOTAL_TOKENS_OUT},
    "merge_tokens_in": ${MERGE_TOKENS_IN},
    "merge_tokens_out": ${MERGE_TOKENS_OUT},
    "workers": workers,
    "visible_pass": ${VISIBLE_PASS},
    "visible_total": ${VISIBLE_TOTAL},
    "hidden_pass": ${HIDDEN_PASS},
    "hidden_total": ${HIDDEN_TOTAL},
    "existing_pass": ${EXISTING_PASS},
    "existing_total": ${EXISTING_TOTAL},
    "exit_code": ${OVERALL_EXIT},
    "_meta": {
        "token_coverage": tokens_note,
        "approach": "host-side approximation; no validation-pack",
        "worker_count": ${#ENTITY_FILES[@]},
        "merge_step": "1 reconciliation call after workers",
        "worktree": "${WORKTREE}"
    }
}

worker_model = "${WORKER_MODEL}".strip()
if worker_model:
    result["worker_model"] = worker_model

with open("${RESULTS_FILE}", "w") as fh:
    json.dump(result, fh, indent=2)
    fh.write("\n")

print(json.dumps(result, indent=2))
PYEOF

echo "[orchworkers] Results written to: ${RESULTS_FILE}" >&2
exit "${OVERALL_EXIT}"
