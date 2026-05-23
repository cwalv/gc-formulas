#!/usr/bin/env bash
# scenarios/08-eval-case.sh
#
# Generic external-case driver for plan-evals C.2 (per-orchestrator runners).
#
# Unlike scenarios 00-07 which hardcode a hermetic task and assert against a
# bead-DAG predicate via verify_bead_state.py, this driver:
#   1. Reads EVAL_* env vars to identify the case + pattern + fan-out scope.
#   2. Copies <eval-case>/starting-state/ into the bind-mounted worktree.
#   3. Pours the eval-mode formula with spec_content + worktree_path +
#      fanout_files vars.
#   4. Routes the orchestrator + N implementer beads + treehugger; pre-closes
#      the (max-N - N) unused implementer beads with reason=skipped so
#      step-land's dep graph still resolves.
#   5. Spawns shim agents (foreman, implementer pool, treehugger).
#   6. Awaits step-land close.
#
# The worktree is bind-mounted host↔container so on container exit the host's
# eval-{gc,ntm}.sh wrapper sees the workers' edits and runs scripts/eval-scorer.py
# against them.
#
# No fixture predicate is written. run-scenario.sh detects EVAL_CASE_ID and
# skips verify_bead_state.py (the bead-DAG predicate doesn't apply; the
# pytest-pass-rate predicate runs host-side after container exit).
#
# Env contract:
#   EVAL_CASE_ID         required. Mounted at /home/agent/eval-case/.
#   EVAL_PATTERN         optional. One of: orchestrator-workers. Default: orchestrator-workers.
#                        (sectioning, agent-loop are follow-up beads.)
#   EVAL_FANOUT_DIR      required. From <case>/fanout.json#dir.
#   EVAL_FANOUT_EXCLUDE  optional. Space-separated, from <case>/fanout.json#exclude.
#   EVAL_TIMEOUT_SECS    optional. Default 2000s.

set -euo pipefail

: "${PACK_ROOT:?PACK_ROOT must be set by run-scenario.sh}"
: "${SCENARIO_ID:?SCENARIO_ID must be set by run-scenario.sh}"
: "${EVAL_CASE_ID:?EVAL_CASE_ID must be set for eval-case mode}"
: "${EVAL_FANOUT_DIR:?EVAL_FANOUT_DIR must be set (from <case>/fanout.json#dir)}"

EVAL_PATTERN="${EVAL_PATTERN:-orchestrator-workers}"
EVAL_FANOUT_EXCLUDE="${EVAL_FANOUT_EXCLUDE:-}"
EVAL_TIMEOUT_SECS="${EVAL_TIMEOUT_SECS:-2000}"

# Bind mounts set by docker-compose.yml under EVAL_CASE_ID:
CASE_DIR="/home/agent/eval-case"
WORKTREE="/home/agent/eval-worktree"

if [[ ! -d "${CASE_DIR}" ]]; then
    echo "[${SCENARIO_ID}] ERROR: case dir not bind-mounted: ${CASE_DIR}" >&2
    exit 2
fi
if [[ ! -d "${WORKTREE}" ]]; then
    echo "[${SCENARIO_ID}] ERROR: worktree not bind-mounted: ${WORKTREE}" >&2
    exit 2
fi
if [[ ! -d "${CASE_DIR}/starting-state" ]]; then
    echo "[${SCENARIO_ID}] ERROR: ${CASE_DIR}/starting-state missing" >&2
    exit 2
fi
if [[ ! -f "${CASE_DIR}/spec.md" ]]; then
    echo "[${SCENARIO_ID}] ERROR: ${CASE_DIR}/spec.md missing" >&2
    exit 2
fi

cd "${PACK_ROOT}"

# Source shim (SHIM=gc by default; entrypoint-ntm.sh exports SHIM=ntm).
SHIM="${SHIM:-gc}"
SHIM_FILE="${PACK_ROOT}/shims/${SHIM}.sh"
if [[ ! -f "${SHIM_FILE}" ]]; then
    echo "[${SCENARIO_ID}] ERROR: shim not found: ${SHIM_FILE}" >&2
    exit 1
fi
# shellcheck source=shims/gc.sh
source "${SHIM_FILE}"

# Source checkpoint helper for DEBUG_PAUSE_AT support.
# shellcheck source=scripts/checkpoint.sh
source "${PACK_ROOT}/scripts/checkpoint.sh"

# -----------------------------------------------------------------------------
# 1. Stage starting-state into the host-shared worktree.
# -----------------------------------------------------------------------------
echo "[${SCENARIO_ID}] staging ${CASE_DIR}/starting-state/ → ${WORKTREE}/"
cp -r "${CASE_DIR}/starting-state/." "${WORKTREE}/"

# -----------------------------------------------------------------------------
# 2. Discover fan-out files (same logic as eval-orchworkers.sh).
# -----------------------------------------------------------------------------
FANOUT_PATH="${WORKTREE}/${EVAL_FANOUT_DIR}"
if [[ ! -d "${FANOUT_PATH}" ]]; then
    echo "[${SCENARIO_ID}] ERROR: fan-out dir not found in worktree: ${FANOUT_PATH}" >&2
    exit 2
fi

FANOUT_FILES=()
while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    skip=false
    for excl in $EVAL_FANOUT_EXCLUDE; do
        if [[ "$base" == "$excl" ]]; then skip=true; break; fi
    done
    [[ "$skip" == true ]] && continue
    FANOUT_FILES+=("${EVAL_FANOUT_DIR}/${base}")
done < <(find "${FANOUT_PATH}" -maxdepth 1 -name '*.py' -print0 | sort -z)

N_FILES="${#FANOUT_FILES[@]}"
if [[ "${N_FILES}" -eq 0 ]]; then
    echo "[${SCENARIO_ID}] ERROR: no fan-out files matched in ${FANOUT_PATH}" >&2
    exit 2
fi
if [[ "${N_FILES}" -gt 10 ]]; then
    echo "[${SCENARIO_ID}] ERROR: case has ${N_FILES} files; eval-orchestrator-workers caps at 10" >&2
    exit 2
fi

echo "[${SCENARIO_ID}] fan-out: ${N_FILES} file(s): ${FANOUT_FILES[*]}"

# Newline-join for the formula var.
FANOUT_FILES_TEXT=""
for f in "${FANOUT_FILES[@]}"; do
    FANOUT_FILES_TEXT+="${f}"$'\n'
done

# -----------------------------------------------------------------------------
# 3. Substrate prep (mirrors scenarios/05-orchestrator-workers.sh).
# -----------------------------------------------------------------------------
mkdir -p .beads/formulas
for formula_basename in eval-orchestrator-workers; do
    if [[ ! -e ".beads/formulas/${formula_basename}.formula.toml" ]]; then
        ln -s "${PACK_ROOT}/formulas/${formula_basename}.formula.toml" \
              ".beads/formulas/${formula_basename}.formula.toml"
    fi
done

if [[ ! -e "${HOME}/.beads" ]]; then
    ln -sf "${PACK_ROOT}/.beads" "${HOME}/.beads"
fi

git config --local user.name  "agent" 2>/dev/null || true
git config --local user.email "agent@validation-pack.local" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 4. Pour the eval formula.
# -----------------------------------------------------------------------------
SPEC_CONTENT="$(cat "${CASE_DIR}/spec.md")"

echo "[${SCENARIO_ID}] pouring formula ${EVAL_PATTERN}..."

case "${EVAL_PATTERN}" in
    orchestrator-workers)
        FORMULA_NAME="eval-orchestrator-workers"
        ;;
    *)
        echo "[${SCENARIO_ID}] ERROR: unsupported EVAL_PATTERN: ${EVAL_PATTERN}" >&2
        echo "[${SCENARIO_ID}] supported: orchestrator-workers" >&2
        exit 2
        ;;
esac

WISP_JSON="$(bd mol wisp "${FORMULA_NAME}" \
    --var spec_content="${SPEC_CONTENT}" \
    --var worktree_path="${WORKTREE}" \
    --var fanout_dir="${EVAL_FANOUT_DIR}" \
    --var fanout_files="${FANOUT_FILES_TEXT}" \
    --json)"

echo "[${SCENARIO_ID}] pour ok"

_parse_step() {
    local step="$1"
    printf '%s' "${WISP_JSON}" | python3 -c "
import json, sys
text = sys.stdin.read()
idx = text.index('{')
d = json.loads(text[idx:])
print(d['id_mapping']['${FORMULA_NAME}.${step}'])
"
}

BD_ORCHESTRATE="$(_parse_step step-orchestrate)"
BD_LAND="$(_parse_step step-land)"

declare -a BD_IMPLEMENTS=()
for i in $(seq 1 10); do
    BD_IMPLEMENTS+=("$(_parse_step "step-implement-${i}")")
done

echo "[${SCENARIO_ID}] step-orchestrate=${BD_ORCHESTRATE}"
echo "[${SCENARIO_ID}] step-implement-1..10=${BD_IMPLEMENTS[*]}"
echo "[${SCENARIO_ID}] step-land=${BD_LAND}"

checkpoint pour

# -----------------------------------------------------------------------------
# 5. Route active beads. Pre-close unused implements as 'skipped' so step-land
#    becomes ready once the active N implementers finish.
# -----------------------------------------------------------------------------
echo "[${SCENARIO_ID}] routing step-orchestrate → validation/foreman"
bd update "${BD_ORCHESTRATE}" --assignee=validation/foreman

for i in $(seq 1 "${N_FILES}"); do
    idx=$((i - 1))
    BEAD="${BD_IMPLEMENTS[$idx]}"
    echo "[${SCENARIO_ID}] routing ${BEAD} (step-implement-${i}) → validation/implementer"
    bd update "${BEAD}" --assignee=validation/implementer
done

# Pre-close unused implements. step-land needs all 10; closing them as skipped
# satisfies the dep graph without spawning per-skip implementer turns.
#
# --force is required: each implement-N bead has needs=[step-orchestrate], and
# step-orchestrate is still open at this point (the foreman hasn't run yet).
# bd's default close-policy refuses "cannot close X: blocked by open issues
# [step-orchestrate]". --force bypasses that check; the close still satisfies
# step-land's dep on step-implement-N.
if [[ "${N_FILES}" -lt 10 ]]; then
    for i in $(seq $((N_FILES + 1)) 10); do
        idx=$((i - 1))
        BEAD="${BD_IMPLEMENTS[$idx]}"
        echo "[${SCENARIO_ID}] pre-closing unused ${BEAD} (step-implement-${i}) reason=skipped"
        bd close "${BEAD}" --reason=skipped --force
    done
fi

echo "[${SCENARIO_ID}] routing step-land → validation/treehugger"
bd update "${BD_LAND}" --assignee=validation/treehugger

checkpoint route

# -----------------------------------------------------------------------------
# 6. Spawn shim agents.
# -----------------------------------------------------------------------------
# Pool sizes: 1 foreman, min(N, 5) implementers (city.toml caps implementer at 5),
# 1 treehugger. Multiple implementer sessions claim multiple beads concurrently.
IMPL_SPAWN=$(( N_FILES < 5 ? N_FILES : 5 ))

echo "[${SCENARIO_ID}] spawning foreman (1)..."
shim_spawn foreman 1

echo "[${SCENARIO_ID}] spawning implementer (${IMPL_SPAWN})..."
shim_spawn implementer "${IMPL_SPAWN}"

echo "[${SCENARIO_ID}] spawning treehugger (1)..."
shim_spawn treehugger 1

checkpoint spawn

# -----------------------------------------------------------------------------
# 7. Await step-land close.
# -----------------------------------------------------------------------------
echo "[${SCENARIO_ID}] awaiting step-land (${BD_LAND}) close (timeout ${EVAL_TIMEOUT_SECS}s)..."

AWAIT_RC=0
shim_await "${BD_LAND}" "${EVAL_TIMEOUT_SECS}" || AWAIT_RC=$?

checkpoint close

if [[ "${AWAIT_RC}" -eq 0 ]]; then
    echo "[${SCENARIO_ID}] step-land closed — SUCCESS"
    exit 0
fi

echo "[${SCENARIO_ID}] FAILED (await exit ${AWAIT_RC})" >&2
echo "--- bd ready (foreman pool) ---" >&2
bd ready --include-ephemeral --assignee=validation/foreman --json --limit 1 2>&1 || true
echo "--- bd ready (implementer pool) ---" >&2
bd ready --include-ephemeral --assignee=validation/implementer --json --limit 1 2>&1 || true
echo "--- bd ready (treehugger pool) ---" >&2
bd ready --include-ephemeral --assignee=validation/treehugger --json --limit 1 2>&1 || true
echo "--- gc session list ---" >&2
gc session list --city "${PACK_ROOT}" 2>&1 || true
exit 1
