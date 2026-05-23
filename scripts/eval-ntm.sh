#!/usr/bin/env bash
# eval-ntm.sh — plan-evals C.2 substrate runner under the ntm shim.
#
# Runs a plan-evals case through the validation-pack container, where workers
# execute INSIDE the container under a real ntm tmux shim + bd substrate (not
# bash-parallelized claude -p calls on the host). The host bind-mounts the case
# read-only and a writable worktree; on container exit the host runs
# scripts/eval-scorer.py against the worktree.
#
# See docs/per-orchestrator-runners.md for the full design.
#
# Usage:
#   bash scripts/eval-ntm.sh <case-id> [--output-dir DIR] [--run-id ID] \
#                                     [--pattern PATTERN] [--worker-model MODEL]
#
# Outputs:
#   <output-dir>/results-<run-id>.json — per-run result JSON (same schema as
#                                        eval-orchworkers.sh + 'substrate' field).
#
# Token coverage: the substrate doesn't surface aggregated token counts in the
# first cut (per-session JSONL aggregation is a follow-up bead). Result emits
# tokens_in=tokens_out=cache_*=0 with _meta.token_coverage = "unavailable (substrate)".

set -euo pipefail

CASE_ID=""
OUTPUT_DIR=""
RUN_ID=""
PATTERN="orchestrator-workers"
WORKER_MODEL_OVERRIDE=""

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVALS_DIR="${REPO_ROOT}/evals"
PACK_DIR="${REPO_ROOT}/validation-pack"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)    OUTPUT_DIR="$2";              shift 2 ;;
        --run-id)        RUN_ID="$2";                  shift 2 ;;
        --pattern)       PATTERN="$2";                 shift 2 ;;
        --worker-model)  WORKER_MODEL_OVERRIDE="$2";   shift 2 ;;
        -*)              echo "Unknown option: $1" >&2; exit 1 ;;
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
    echo "Usage: $0 <case-id> [--output-dir DIR] [--run-id ID] [--pattern P] [--worker-model M]" >&2
    exit 1
fi

CASE_DIR="${EVALS_DIR}/${CASE_ID}"
if [[ ! -d "$CASE_DIR" ]]; then
    echo "Case directory not found: ${CASE_DIR}" >&2
    exit 1
fi

FANOUT_CONFIG="${CASE_DIR}/fanout.json"
if [[ ! -f "$FANOUT_CONFIG" ]]; then
    echo "${CASE_ID}/fanout.json required for eval-ntm.sh (must declare 'dir')" >&2
    exit 1
fi
FANOUT_DIR="$(jq -r .dir "${FANOUT_CONFIG}")"
FANOUT_EXC="$(jq -r '(.exclude // []) | join(" ")' "${FANOUT_CONFIG}")"

if [[ -z "$RUN_ID" ]]; then
    RUN_ID="ntm-${PATTERN}-${CASE_ID}-$(date -u +%Y%m%d-%H%M%S)"
fi

if [[ -z "$OUTPUT_DIR" ]]; then OUTPUT_DIR="${REPO_ROOT}/eval-runs"; fi
mkdir -p "${OUTPUT_DIR}"
WORKTREE="${OUTPUT_DIR}/${RUN_ID}/worktree"
mkdir -p "${WORKTREE}"
# starting-state is staged INSIDE the container (08-eval-case.sh) so the host
# worktree starts empty; the container populates it via the bind mount.

# Optional per-run city.toml override for --worker-model.
COMPOSE_FILES=(-f "${PACK_DIR}/docker-compose.ntm.yml" -f "${PACK_DIR}/docker-compose.eval.yml")
EXTRA_MOUNTS=()

if [[ -n "$WORKER_MODEL_OVERRIDE" ]]; then
    CITY_OVERRIDE="${OUTPUT_DIR}/${RUN_ID}/city.override.toml"
    python3 - "$PACK_DIR/city.toml" "$WORKER_MODEL_OVERRIDE" "$CITY_OVERRIDE" <<'PYEOF'
import re, sys
src, model, dst = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read()
text = re.sub(r'(\[agent\.option_defaults\][^\[]*?model\s*=\s*)"[^"]*"', r'\1"' + model + '"', text, count=1)
open(dst, 'w').write(text)
PYEOF
    EXTRA_MOUNTS+=(-v "${CITY_OVERRIDE}:/home/agent/validation-pack/city.toml:ro")
    echo "[eval-ntm] worker-model override: ${WORKER_MODEL_OVERRIDE}" >&2
fi

PROJECT_NAME="vp-eval-$(echo "${RUN_ID}" | tr -c '[:alnum:]_-' '_' | cut -c1-50)"

echo "[eval-ntm] case=${CASE_ID} pattern=${PATTERN} run-id=${RUN_ID}" >&2
echo "[eval-ntm] worktree=${WORKTREE}" >&2
echo "[eval-ntm] fanout dir=${FANOUT_DIR} exclude='${FANOUT_EXC}'" >&2

WALL_START=$(date +%s%3N)

CONTAINER_EXIT=0
EVAL_CASE_DIR="${CASE_DIR}" \
EVAL_WORKTREE_DIR="${WORKTREE}" \
EVAL_CASE_ID="${CASE_ID}" \
EVAL_PATTERN="${PATTERN}" \
EVAL_FANOUT_DIR="${FANOUT_DIR}" \
EVAL_FANOUT_EXCLUDE="${FANOUT_EXC}" \
docker compose "${COMPOSE_FILES[@]}" -p "${PROJECT_NAME}" \
    run --rm "${EXTRA_MOUNTS[@]}" validation 08-eval-case || CONTAINER_EXIT=$?

WALL_END=$(date +%s%3N)
WALL_SECS="$(python3 -c "print(round((${WALL_END}-${WALL_START})/1000.0, 1))")"

echo "[eval-ntm] container exited rc=${CONTAINER_EXIT} wall=${WALL_SECS}s" >&2

# Host-side scoring against the worktree.
SCORER="${REPO_ROOT}/scripts/eval-scorer.py"
SCORER_OUT='{}'
if [[ -f "$SCORER" ]]; then
    SCORER_JSON="$(python3 "${SCORER}" --case-path "${CASE_DIR}" --worktree "${WORKTREE}" 2>/dev/null)" || true
    if [[ -n "$SCORER_JSON" ]]; then
        SCORER_OUT="$SCORER_JSON"
    fi
fi

VISIBLE_PASS="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('visible_pass',0))" "$SCORER_OUT" 2>/dev/null || echo 0)"
VISIBLE_TOTAL="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('visible_total',0))" "$SCORER_OUT" 2>/dev/null || echo 0)"
HIDDEN_PASS="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('hidden_pass',0))" "$SCORER_OUT" 2>/dev/null || echo 0)"
HIDDEN_TOTAL="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('hidden_total',0))" "$SCORER_OUT" 2>/dev/null || echo 0)"
EXISTING_PASS="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('existing_pass',0))" "$SCORER_OUT" 2>/dev/null || echo 0)"
EXISTING_TOTAL="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('existing_total',0))" "$SCORER_OUT" 2>/dev/null || echo 0)"

RESULTS_FILE="${OUTPUT_DIR}/results-${RUN_ID}.json"

WORKER_MODEL_REPORTED="${WORKER_MODEL_OVERRIDE:-haiku}"

python3 - <<PYEOF
import json
result = {
    "run_id": "${RUN_ID}",
    "case_id": "${CASE_ID}",
    "pattern": "${PATTERN}",
    "substrate": "ntm",
    "formula": "eval-orchestrator-workers",
    "worker_model": "${WORKER_MODEL_REPORTED}",
    "wall_clock_secs": ${WALL_SECS},
    "tokens_in": 0,
    "tokens_out": 0,
    "cache_creation_input_tokens": 0,
    "cache_read_input_tokens": 0,
    "visible_pass": ${VISIBLE_PASS},
    "visible_total": ${VISIBLE_TOTAL},
    "hidden_pass": ${HIDDEN_PASS},
    "hidden_total": ${HIDDEN_TOTAL},
    "existing_pass": ${EXISTING_PASS},
    "existing_total": ${EXISTING_TOTAL},
    "exit_code": ${CONTAINER_EXIT},
    "_meta": {
        "token_coverage": "unavailable (substrate)",
        "approach": "validation-pack scenario via ntm shim",
        "container_image": "validation-pack:latest",
        "compose_project": "${PROJECT_NAME}",
        "worktree": "${WORKTREE}",
    },
}
with open("${RESULTS_FILE}", "w") as fh:
    json.dump(result, fh, indent=2)
    fh.write("\n")
print(json.dumps(result, indent=2))
PYEOF

echo "[eval-ntm] results: ${RESULTS_FILE}" >&2
exit "${CONTAINER_EXIT}"
