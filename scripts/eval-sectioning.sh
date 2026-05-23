#!/usr/bin/env bash
# eval-sectioning.sh — sectioning runner for plan-evals C.1
#
# SECTIONING PATTERN (vs. naive fanout, vs. orchestrator-workers):
#
#   Naive fanout (eval-fanout.sh) spawns N parallel claude -p workers, all
#   writing into a shared worktree.  They cannot see each other's edits and
#   they CAN trample each other's shared modules — the only thing preventing
#   corruption is "workers happen to touch disjoint files".  On shared-state
#   tasks (validator-suite) this collapses (M2 showed 0/11).
#
#   Sectioning (this script) is the correct implementation of Anthropic's
#   "sectioning" pattern: per-worker ISOLATED worktrees + DETERMINISTIC
#   file-scoped collation.  Each worker gets its own fresh copy of
#   starting-state; the collator copies each worker's assigned file back
#   into a single final worktree.  Crucially:
#
#     - Workers cannot corrupt files they do not see (isolation).
#     - The collator is a file copy, NOT an LLM call (determinism).
#
#   This is distinct from orchestrator-workers (eval-orchworkers.sh), which
#   adds an LLM merge step on top of the isolated worker outputs.  Sectioning
#   is "isolation, no merge"; orch-workers is "isolation, with merge".  The
#   structural difference is exactly the LLM reconciliation: sectioning
#   produces correct individual files but cannot reconcile cross-file
#   invariants that workers diverge on (e.g. extending a shared enum with
#   incompatible variants).
#
#   Per-worker disk footprint = N copies of starting-state.  For our cases
#   (~10 files, few KB each) this is fine.  Will need a different approach
#   if starting-states ever grow large.
#
# Usage:
#   bash scripts/eval-sectioning.sh <case-id> [--output-dir DIR] [--run-id ID]
#
# Outputs:
#   <output-dir>/results-<run-id>.json  — per-run result JSON
#
#   On-disk layout under <output-dir>/<run-id>/:
#     workers/<entity-basename-no-ext>/   — per-worker fresh copy of starting-state
#     worktree/                            — final collated worktree (scored against)
#     agents/<entity-basename>.{out,err}  — per-worker claude -p output
#
# JSON schema: same as eval-fanout.sh; pattern field is "sectioning".  Adds
# a `workers` array (per-worker tokens) to align with the C.1 / A direction
# of moving from aggregated tokens to per-worker tokens.
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
    RUN_ID="sectioning-${CASE_ID}-$(date -u +%Y%m%d-%H%M%S)"
fi

# ---------------------------------------------------------------------------
# Discover files to fan out over.
#
# Cases declare their fan-out target via <case>/fanout.json:
#   {"dir": "validators", "exclude": ["base.py", "__init__.py"]}
#
# For backward compatibility, if fanout.json is absent we default to the
# cancel-method-shaped layout (dir=entities, exclude=event_bus.py + __init__.py).
# We probe the starting-state for this (not the per-worker copies, which
# don't exist yet at this point).
# ---------------------------------------------------------------------------
FANOUT_CONFIG="${CASE_DIR}/fanout.json"
if [[ -f "$FANOUT_CONFIG" ]]; then
    FANOUT_DIR_NAME="$(python3 -c "import json; print(json.load(open('${FANOUT_CONFIG}'))['dir'])")"
    FANOUT_EXCLUDE_LIST="$(python3 -c "import json; print(' '.join(json.load(open('${FANOUT_CONFIG}'))['exclude']))")"
else
    FANOUT_DIR_NAME="entities"
    FANOUT_EXCLUDE_LIST="event_bus.py __init__.py"
fi

PROBE_DIR="${STARTING_STATE}/${FANOUT_DIR_NAME}"
if [[ ! -d "$PROBE_DIR" ]]; then
    echo "fan-out target dir not found in starting-state: ${PROBE_DIR}" >&2
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
done < <(find "${PROBE_DIR}" -maxdepth 1 -name "*.py" -print0 | sort -z)

if [[ ${#ENTITY_FILES[@]} -eq 0 ]]; then
    echo "No fan-out target files found in: ${PROBE_DIR}" >&2
    exit 1
fi

echo "[sectioning] Fan-out target: ${FANOUT_DIR_NAME}/ — found ${#ENTITY_FILES[@]} file(s): ${ENTITY_FILES[*]}" >&2

# ---------------------------------------------------------------------------
# Read spec content once
# ---------------------------------------------------------------------------
SPEC_CONTENT="$(cat "${SPEC_FILE}")"

# ---------------------------------------------------------------------------
# Set up per-run output dirs
# ---------------------------------------------------------------------------
mkdir -p "${OUTPUT_DIR}"
RUN_DIR="${OUTPUT_DIR}/${RUN_ID}"
WORKERS_DIR="${RUN_DIR}/workers"
WORKTREE="${RUN_DIR}/worktree"
AGENT_TMP="${RUN_DIR}/agents"
mkdir -p "${WORKERS_DIR}" "${AGENT_TMP}"

# ---------------------------------------------------------------------------
# Start wall-clock timer (covers per-worker setup, worker LLM calls, collation)
# ---------------------------------------------------------------------------
WALL_START="$(date +%s%3N)"   # milliseconds

# ---------------------------------------------------------------------------
# Per-worker isolation: each worker gets a FRESH copy of starting-state at
# ${WORKERS_DIR}/${ENTITY_BASENAME%.py}/ .  Use cp -r so each worker's tree
# is independent; the worker cannot see or corrupt other workers' copies.
# ---------------------------------------------------------------------------
declare -a PIDS=()
declare -A PID_TO_BASENAME
declare -A PID_TO_OUT
declare -A PID_TO_WORKER_TREE

for ENTITY_FILE in "${ENTITY_FILES[@]}"; do
    ENTITY_BASENAME="$(basename "${ENTITY_FILE}")"
    ENTITY_REL="${FANOUT_DIR_NAME}/${ENTITY_BASENAME}"
    WORKER_KEY="${ENTITY_BASENAME%.py}"
    WORKER_TREE="${WORKERS_DIR}/${WORKER_KEY}"

    # Fresh per-worker worktree (cp -r, never modify starting-state in place)
    mkdir -p "${WORKER_TREE}"
    cp -r "${STARTING_STATE}/." "${WORKER_TREE}/"

    AGENT_OUT="${AGENT_TMP}/${WORKER_KEY}.out"
    AGENT_ERR="${AGENT_TMP}/${WORKER_KEY}.err"

    BRIEF="Working in the directory: ${WORKER_TREE}

Your task is to implement the required behaviour for ONLY the file: ${ENTITY_REL}

You may only modify ${ENTITY_REL} inside your worktree. Do not touch any other
file. Do not modify any tests.

Read spec.md (or the spec content below) for what to do.

Here is the full task spec for context (but your scope is limited to ${ENTITY_REL}):

---
${SPEC_CONTENT}
---

When done, your work is complete. Output a summary of what you changed."

    echo "[sectioning] Spawning worker for ${ENTITY_BASENAME} in ${WORKER_TREE}" >&2
    claude -p "${BRIEF}" \
        --model "${WORKER_MODEL}" \
        --dangerously-skip-permissions \
        --output-format json \
        > "${AGENT_OUT}" \
        2> "${AGENT_ERR}" &

    PID=$!
    PIDS+=("$PID")
    PID_TO_BASENAME[$PID]="${ENTITY_BASENAME}"
    PID_TO_OUT[$PID]="${AGENT_OUT}"
    PID_TO_WORKER_TREE[$PID]="${WORKER_TREE}"
done

# ---------------------------------------------------------------------------
# Wait for all background workers, collect exit codes + per-worker tokens
# ---------------------------------------------------------------------------
echo "[sectioning] Waiting for ${#PIDS[@]} worker(s)…" >&2

TOTAL_TOKENS_IN=0
TOTAL_TOKENS_OUT=0
TOKENS_PARTIAL=0   # flag: 1 if any agent didn't surface tokens
OVERALL_EXIT=0
OBSERVED_MODEL=""

# Per-worker entries for the `workers` JSON array.  We accumulate
# already-JSON-encoded strings so the final emit step doesn't have to
# re-quote anything.
declare -a WORKER_JSON_ENTRIES=()

for PID in "${PIDS[@]}"; do
    ENTITY_BASENAME="${PID_TO_BASENAME[$PID]}"
    AGENT_OUT="${PID_TO_OUT[$PID]}"

    if wait "$PID"; then
        AGENT_EXIT=0
    else
        AGENT_EXIT=$?
        OVERALL_EXIT=$AGENT_EXIT
        echo "[sectioning] Worker for ${ENTITY_BASENAME} exited with code ${AGENT_EXIT}" >&2
    fi

    AGENT_IN_RAW=""
    AGENT_OUT_RAW=""

    # Try to parse token counts and worker_model from JSON output
    if [[ -f "${AGENT_OUT}" ]] && command -v python3 &>/dev/null; then
        AGENT_IN_RAW="$(python3 -c "
import sys, json
try:
    data = json.load(open('${AGENT_OUT}'))
    usage = data.get('usage', {})
    print(usage.get('input_tokens', usage.get('prompt_tokens', '')))
except Exception:
    print('')
" 2>/dev/null)"
        AGENT_OUT_RAW="$(python3 -c "
import sys, json
try:
    data = json.load(open('${AGENT_OUT}'))
    usage = data.get('usage', {})
    print(usage.get('output_tokens', usage.get('completion_tokens', '')))
except Exception:
    print('')
" 2>/dev/null)"

        if [[ -n "$AGENT_IN_RAW" && "$AGENT_IN_RAW" =~ ^[0-9]+$ ]]; then
            TOTAL_TOKENS_IN=$((TOTAL_TOKENS_IN + AGENT_IN_RAW))
        else
            TOKENS_PARTIAL=1
        fi
        if [[ -n "$AGENT_OUT_RAW" && "$AGENT_OUT_RAW" =~ ^[0-9]+$ ]]; then
            TOTAL_TOKENS_OUT=$((TOTAL_TOKENS_OUT + AGENT_OUT_RAW))
        else
            TOKENS_PARTIAL=1
        fi

        # Capture worker_model from the first agent output that has modelUsage.
        # All workers use the same default model, so one is sufficient.
        if [[ -z "$OBSERVED_MODEL" ]]; then
            OBSERVED_MODEL="$(python3 -c "
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

    # Build per-worker JSON entry.  null for unparseable tokens so the
    # token_coverage = "partial" flag stays meaningful.
    WORKER_ENTRY="$(python3 -c "
import json, sys
def norm(x):
    s = (x or '').strip()
    return int(s) if s.isdigit() else None
entry = {
    'file': '${FANOUT_DIR_NAME}/${ENTITY_BASENAME}',
    'tokens_in': norm('${AGENT_IN_RAW}'),
    'tokens_out': norm('${AGENT_OUT_RAW}'),
    'exit_code': ${AGENT_EXIT},
}
print(json.dumps(entry))
" 2>/dev/null)" || WORKER_ENTRY="{\"file\":\"${FANOUT_DIR_NAME}/${ENTITY_BASENAME}\",\"tokens_in\":null,\"tokens_out\":null,\"exit_code\":${AGENT_EXIT}}"
    WORKER_JSON_ENTRIES+=("${WORKER_ENTRY}")
done

echo "[sectioning] All workers done. Starting deterministic file-scoped collation…" >&2

# ---------------------------------------------------------------------------
# DETERMINISTIC FILE-SCOPED COLLATION
#
# 1. Copy starting-state to ${WORKTREE} as the base.
# 2. For each worker, copy ONLY their assigned file
#    (${FANOUT_DIR_NAME}/${ENTITY_BASENAME}) from their worker tree into the
#    final worktree.
#
# No LLM here.  No merge step.  This is intentional — sectioning's correctness
# story is "workers can't corrupt files they don't see, and given the same
# worker outputs the final worktree is reproducible".
# ---------------------------------------------------------------------------
mkdir -p "${WORKTREE}"
cp -r "${STARTING_STATE}/." "${WORKTREE}/"

for PID in "${PIDS[@]}"; do
    ENTITY_BASENAME="${PID_TO_BASENAME[$PID]}"
    WORKER_TREE="${PID_TO_WORKER_TREE[$PID]}"
    SRC="${WORKER_TREE}/${FANOUT_DIR_NAME}/${ENTITY_BASENAME}"
    DST="${WORKTREE}/${FANOUT_DIR_NAME}/${ENTITY_BASENAME}"
    if [[ -f "$SRC" ]]; then
        cp "$SRC" "$DST"
    else
        echo "[sectioning] WARN: worker output missing for ${ENTITY_BASENAME}: ${SRC}" >&2
    fi
done

# ---------------------------------------------------------------------------
# Wall-clock elapsed (seconds, one decimal)
# ---------------------------------------------------------------------------
WALL_END="$(date +%s%3N)"
WALL_MS=$(( WALL_END - WALL_START ))
WALL_SECS="$(python3 -c "print(round(${WALL_MS}/1000.0, 1))")"

echo "[sectioning] Run complete. Wall-clock: ${WALL_SECS}s" >&2

# ---------------------------------------------------------------------------
# Run scorer (if available; graceful fallback if not)
# ---------------------------------------------------------------------------
SCORER="${REPO_ROOT}/scripts/eval-scorer.py"
SCORER_OUT='{}'

if [[ -f "$SCORER" ]]; then
    echo "[sectioning] Running scorer…" >&2
    SCORER_JSON="$(python3 "${SCORER}" \
        --case-path "${CASE_DIR}" \
        --worktree "${WORKTREE}" 2>/dev/null)" || true
    if [[ -n "$SCORER_JSON" ]]; then
        SCORER_OUT="$SCORER_JSON"
    fi
else
    echo "[sectioning] Scorer not found (${SCORER}); using zero-fill fallback." >&2
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

# Join workers JSON entries.  IFS dance keeps a clean comma separator.
WORKERS_JOINED=""
if [[ ${#WORKER_JSON_ENTRIES[@]} -gt 0 ]]; then
    WORKERS_JOINED="$(printf '%s,' "${WORKER_JSON_ENTRIES[@]}")"
    WORKERS_JOINED="[${WORKERS_JOINED%,}]"
else
    WORKERS_JOINED="[]"
fi

python3 - <<PYEOF
import json, sys

tokens_partial = ${TOKENS_PARTIAL} == 1
tokens_note = "partial (some agents did not surface token counts)" if tokens_partial else "complete"

workers = json.loads('''${WORKERS_JOINED}''')

result = {
    "run_id": "${RUN_ID}",
    "case_id": "${CASE_ID}",
    "pattern": "sectioning",
    "wall_clock_secs": ${WALL_SECS},
    "tokens_in": ${TOTAL_TOKENS_IN},
    "tokens_out": ${TOTAL_TOKENS_OUT},
    "visible_pass": ${VISIBLE_PASS},
    "visible_total": ${VISIBLE_TOTAL},
    "hidden_pass": ${HIDDEN_PASS},
    "hidden_total": ${HIDDEN_TOTAL},
    "existing_pass": ${EXISTING_PASS},
    "existing_total": ${EXISTING_TOTAL},
    "exit_code": ${OVERALL_EXIT},
    "workers": workers,
    "_meta": {
        "token_coverage": tokens_note,
        "approach": "host-side approximation; no validation-pack",
        "worker_count": ${#ENTITY_FILES[@]},
        "isolation": "per-worker fresh cp -r of starting-state",
        "collation": "deterministic file-scoped copy (no LLM, no merge)",
        "worktree": "${WORKTREE}"
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

echo "[sectioning] Results written to: ${RESULTS_FILE}" >&2
exit "${OVERALL_EXIT}"
