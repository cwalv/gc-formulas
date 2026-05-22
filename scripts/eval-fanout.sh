#!/usr/bin/env bash
# eval-fanout.sh — fan-out runner for plan-evals M1
#
# HOST-SIDE APPROXIMATION; NO VALIDATION-PACK.
# Rationale: wiring through the validation-pack docker/gc supervisor is expensive
# infrastructure overhead that distracts from the eval question (does parallelising
# per-entity work reduce wall-clock?). This script spawns one `claude -p` process
# per entity file in the background, waits for all to finish, then runs the scorer.
# That captures the structural argument for fan-out without the supervisor machinery.
#
# Usage:
#   bash scripts/eval-fanout.sh <case-id> [--output-dir DIR] [--run-id ID]
#
# Outputs:
#   <output-dir>/results-<run-id>.json  — per-run result JSON (schema from epic fo-ghqjh)
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
    RUN_ID="fanout-${CASE_ID}-$(date -u +%Y%m%d-%H%M%S)"
fi

# ---------------------------------------------------------------------------
# Set up worktree
# ---------------------------------------------------------------------------
mkdir -p "${OUTPUT_DIR}"
WORKTREE="${OUTPUT_DIR}/${RUN_ID}/worktree"
mkdir -p "${WORKTREE}"

echo "[fanout] Copying starting-state → ${WORKTREE}" >&2
cp -r "${STARTING_STATE}/." "${WORKTREE}/"

# ---------------------------------------------------------------------------
# Discover entity files (skip event_bus.py and __init__.py)
# ---------------------------------------------------------------------------
ENTITIES_DIR="${WORKTREE}/entities"
if [[ ! -d "$ENTITIES_DIR" ]]; then
    echo "entities/ not found in worktree: ${ENTITIES_DIR}" >&2
    exit 1
fi

ENTITY_FILES=()
while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    if [[ "$base" == "event_bus.py" || "$base" == "__init__.py" ]]; then
        continue
    fi
    ENTITY_FILES+=("$f")
done < <(find "${ENTITIES_DIR}" -maxdepth 1 -name "*.py" -print0 | sort -z)

if [[ ${#ENTITY_FILES[@]} -eq 0 ]]; then
    echo "No entity files found in: ${ENTITIES_DIR}" >&2
    exit 1
fi

echo "[fanout] Found ${#ENTITY_FILES[@]} entity file(s): ${ENTITY_FILES[*]}" >&2

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
    ENTITY_REL="entities/${ENTITY_BASENAME}"
    AGENT_OUT="${AGENT_TMP}/${ENTITY_BASENAME%.py}.out"
    AGENT_ERR="${AGENT_TMP}/${ENTITY_BASENAME%.py}.err"

    BRIEF="Working in the directory: ${WORKTREE}

Your task is to add a cancel() method to ONLY the file: ${ENTITY_REL}

Do not touch any other file. Do not modify tests. Do not modify event_bus.py.

Here is the full task spec for context (but your scope is limited to ${ENTITY_REL}):

---
${SPEC_CONTENT}
---

When done, your work is complete. Output a summary of what you changed."

    echo "[fanout] Spawning agent for ${ENTITY_BASENAME}" >&2
    claude -p "${BRIEF}" \
        --output-format json \
        --no-preamble \
        > "${AGENT_OUT}" \
        2> "${AGENT_ERR}" &

    PID=$!
    PIDS+=("$PID")
    PID_TO_FILE[$PID]="${ENTITY_BASENAME}"
    PID_TO_OUT[$PID]="${AGENT_OUT}"
done

# ---------------------------------------------------------------------------
# Wait for all background processes, collect exit codes
# ---------------------------------------------------------------------------
echo "[fanout] Waiting for ${#PIDS[@]} agent(s)…" >&2

TOTAL_TOKENS_IN=0
TOTAL_TOKENS_OUT=0
TOKENS_PARTIAL=0   # flag: 1 if any agent didn't surface tokens
OVERALL_EXIT=0

for PID in "${PIDS[@]}"; do
    ENTITY_BASENAME="${PID_TO_FILE[$PID]}"
    AGENT_OUT="${PID_TO_OUT[$PID]}"

    if wait "$PID"; then
        AGENT_EXIT=0
    else
        AGENT_EXIT=$?
        OVERALL_EXIT=$AGENT_EXIT
        echo "[fanout] Agent for ${ENTITY_BASENAME} exited with code ${AGENT_EXIT}" >&2
    fi

    # Try to parse token counts from JSON output
    if [[ -f "${AGENT_OUT}" ]] && command -v python3 &>/dev/null; then
        AGENT_IN="$(python3 -c "
import sys, json
try:
    data = json.load(open('${AGENT_OUT}'))
    # claude --output-format json puts usage under 'usage' or 'cost_usd' siblings
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
            TOTAL_TOKENS_IN=$((TOTAL_TOKENS_IN + AGENT_IN))
        else
            TOKENS_PARTIAL=1
        fi
        if [[ -n "$AGENT_OUT_TOK" && "$AGENT_OUT_TOK" =~ ^[0-9]+$ ]]; then
            TOTAL_TOKENS_OUT=$((TOTAL_TOKENS_OUT + AGENT_OUT_TOK))
        else
            TOKENS_PARTIAL=1
        fi
    else
        TOKENS_PARTIAL=1
    fi
done

# ---------------------------------------------------------------------------
# Wall-clock elapsed (seconds, one decimal)
# ---------------------------------------------------------------------------
WALL_END="$(date +%s%3N)"
WALL_MS=$(( WALL_END - WALL_START ))
WALL_SECS="$(python3 -c "print(round(${WALL_MS}/1000.0, 1))")"

echo "[fanout] All agents done. Wall-clock: ${WALL_SECS}s" >&2

# ---------------------------------------------------------------------------
# Run scorer (if available; graceful fallback if not)
# ---------------------------------------------------------------------------
SCORER="${REPO_ROOT}/scripts/eval-scorer.py"
SCORER_OUT='{}'

if [[ -f "$SCORER" ]]; then
    echo "[fanout] Running scorer…" >&2
    SCORER_JSON="$(python3 "${SCORER}" \
        --case-path "${CASE_DIR}" \
        --worktree "${WORKTREE}" 2>/dev/null)" || true
    if [[ -n "$SCORER_JSON" ]]; then
        SCORER_OUT="$SCORER_JSON"
    fi
else
    echo "[fanout] Scorer not found (${SCORER}); using zero-fill fallback." >&2
fi

VISIBLE_PASS="$(python3 -c "import json; d=json.loads('''${SCORER_OUT}'''); print(d.get('visible_pass', 0))" 2>/dev/null || echo 0)"
VISIBLE_TOTAL="$(python3 -c "import json; d=json.loads('''${SCORER_OUT}'''); print(d.get('visible_total', 0))" 2>/dev/null || echo 0)"
EXISTING_PASS="$(python3 -c "import json; d=json.loads('''${SCORER_OUT}'''); print(d.get('existing_pass', 0))" 2>/dev/null || echo 0)"
EXISTING_TOTAL="$(python3 -c "import json; d=json.loads('''${SCORER_OUT}'''); print(d.get('existing_total', 0))" 2>/dev/null || echo 0)"

# ---------------------------------------------------------------------------
# Emit results JSON
# ---------------------------------------------------------------------------
RESULTS_FILE="${OUTPUT_DIR}/results-${RUN_ID}.json"

python3 - <<PYEOF
import json, sys

# Token coverage note
tokens_partial = ${TOKENS_PARTIAL} == 1
tokens_note = "partial (some agents did not surface token counts)" if tokens_partial else "complete"

result = {
    "run_id": "${RUN_ID}",
    "case_id": "${CASE_ID}",
    "pattern": "fanout",
    "wall_clock_secs": ${WALL_SECS},
    "tokens_in": ${TOTAL_TOKENS_IN},
    "tokens_out": ${TOTAL_TOKENS_OUT},
    "visible_pass": ${VISIBLE_PASS},
    "visible_total": ${VISIBLE_TOTAL},
    "existing_pass": ${EXISTING_PASS},
    "existing_total": ${EXISTING_TOTAL},
    "exit_code": ${OVERALL_EXIT},
    "_meta": {
        "token_coverage": tokens_note,
        "approach": "host-side approximation; no validation-pack",
        "agent_count": ${#ENTITY_FILES[@]},
        "worktree": "${WORKTREE}"
    }
}

with open("${RESULTS_FILE}", "w") as fh:
    json.dump(result, fh, indent=2)
    fh.write("\n")

print(json.dumps(result, indent=2))
PYEOF

echo "[fanout] Results written to: ${RESULTS_FILE}" >&2
exit "${OVERALL_EXIT}"
