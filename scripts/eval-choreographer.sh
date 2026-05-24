#!/usr/bin/env bash
# eval-choreographer.sh — choreographer eval runner (plan-evals Phase C reactive).
#
# Tests the choreographer tier: given a partial initial bead graph and a stream
# of pre-decided worker close signals, does the choreographer respond correctly?
#
# Architecture (mode b — host-driven loop):
#   1. Stage starting-state into a fresh worktree.
#   2. Materialise initial-graph.json into bd using auto-assigned IDs.
#      Write a logical-name→bd-id map to ${RUN_DIR}/id-map.json.
#   3. Spawn deterministic workers (background subshells):
#      - Each worker polls bd ready for its (real) bead ID to become ready.
#      - Claims, applies file edits if reason=completed, then closes with
#        the pre-decided signal from worker-signals.json.
#   4. Host-driven choreographer loop:
#      - Poll bd list for newly-closed beads (filtered to THIS run's IDs).
#      - For each new close event, invoke claude -p with the event brief.
#      - Parse MUTATION: tag from response; apply via bd commands.
#      - Check exit condition; loop.
#   5. Score: eval-scorer.py (pass-rate) + eval-mutation-scorer.py (rubric).
#   6. Emit one result JSON.
#
# Usage:
#   bash scripts/eval-choreographer.sh <case-id> \
#       [--output-dir DIR] [--run-id ID] [--worker-model M] [--choreo-model M]
#
# Default choreographer model: claude-sonnet-4-6 (per design fragment OQ2).
# Workers are deterministic (no LLM) in this bead.
#
# Design source: docs/choreographer-eval.md (commit 501ba17)

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
CASE_ID=""
OUTPUT_DIR="/tmp/eval-runs"
RUN_ID=""
WORKER_MODEL_OVERRIDE=""
CHOREO_MODEL="claude-sonnet-4-6"
POLL_INTERVAL=3       # seconds between bd polls
LOOP_TIMEOUT=300      # seconds before declaring stuck
MAX_CHOREO_EVENTS=30  # safety cap on choreographer invocations

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVALS_DIR="${REPO_ROOT}/evals"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)    OUTPUT_DIR="$2";              shift 2 ;;
        --run-id)        RUN_ID="$2";                  shift 2 ;;
        --worker-model)  WORKER_MODEL_OVERRIDE="$2";   shift 2 ;;
        --choreo-model)  CHOREO_MODEL="$2";             shift 2 ;;
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
    echo "Usage: $0 <case-id> [--output-dir DIR] [--run-id ID] [--choreo-model M] [--worker-model M]" >&2
    exit 1
fi

CASE_DIR="${EVALS_DIR}/${CASE_ID}"
if [[ ! -d "$CASE_DIR" ]]; then
    echo "Case directory not found: ${CASE_DIR}" >&2
    exit 1
fi

for req_file in initial-graph.json worker-signals.json reference-mutations.json; do
    if [[ ! -f "${CASE_DIR}/${req_file}" ]]; then
        echo "Required file not found: ${CASE_DIR}/${req_file}" >&2
        exit 1
    fi
done

if [[ -z "$RUN_ID" ]]; then
    RUN_ID="choreo-${CASE_ID}-$(date -u +%Y%m%d-%H%M%S)"
fi

# ---------------------------------------------------------------------------
# Set up directories
# ---------------------------------------------------------------------------
mkdir -p "${OUTPUT_DIR}"
RUN_DIR="${OUTPUT_DIR}/${RUN_ID}"
WORKTREE="${RUN_DIR}/worktree"
AGENT_TMP="${RUN_DIR}/agents"
CHOREO_TMP="${RUN_DIR}/choreo"
mkdir -p "${WORKTREE}" "${AGENT_TMP}" "${CHOREO_TMP}"

MUTATIONS_LOG="${CHOREO_TMP}/mutations.jsonl"
ID_MAP="${RUN_DIR}/id-map.json"   # logical-name → real bd-id
: > "${MUTATIONS_LOG}"
echo '{}' > "${ID_MAP}"

echo "[choreo] case=${CASE_ID} run-id=${RUN_ID}" >&2
echo "[choreo] choreo-model=${CHOREO_MODEL}" >&2
echo "[choreo] worktree=${WORKTREE}" >&2

# ---------------------------------------------------------------------------
# Verify bd is available
# ---------------------------------------------------------------------------
if ! command -v bd &>/dev/null; then
    echo "[choreo] ERROR: bd not found on PATH" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Stage starting-state
# ---------------------------------------------------------------------------
STARTING_STATE="${CASE_DIR}/starting-state"
if [[ -d "$STARTING_STATE" ]]; then
    echo "[choreo] Staging starting-state → ${WORKTREE}" >&2
    cp -r "${STARTING_STATE}/." "${WORKTREE}/"
else
    echo "[choreo] WARNING: no starting-state in case dir; worktree will be empty" >&2
fi

# ---------------------------------------------------------------------------
# Materialise initial-graph.json into bd
# bd creates beads with auto-assigned IDs; we store the logical→real map.
# ---------------------------------------------------------------------------
echo "[choreo] Materialising initial-graph.json..." >&2

INIT_GRAPH="${CASE_DIR}/initial-graph.json"

# Use a label tag to identify this run's beads
RUN_LABEL="choreo-eval-${RUN_ID}"

# Create beads and capture real IDs
python3 - "${INIT_GRAPH}" "${ID_MAP}" "${RUN_LABEL}" << 'PYEOF'
import json, subprocess, sys, re

graph_file, id_map_file, run_label = sys.argv[1], sys.argv[2], sys.argv[3]
graph = json.load(open(graph_file))
beads = graph.get("beads", [])

# logical-name → real bd id
id_map = {}

for bead in beads:
    logical_id = bead["id"]
    title      = bead["title"]
    btype      = bead.get("type", "task")
    assignee   = bead.get("assignee", "")

    cmd = ["bd", "create", "--title", title, "--label", run_label]
    if assignee:
        cmd += ["--assignee", assignee]
    if btype == "epic":
        cmd += ["--type", "epic"]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR: bd create for '{logical_id}' failed: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)

    # Parse the newly-created bead ID from stdout
    out = result.stdout.strip()
    # bd create outputs something like "Created issue fo-abc123" or just the ID
    m = re.search(r'\b([a-z]+-[a-z0-9]+(?:\.[0-9]+)?)\b', out)
    if m:
        real_id = m.group(1)
    else:
        # Fallback: call bd list with the label to find what we just created
        list_result = subprocess.run(
            ["bd", "list", "--label", run_label, "--json"],
            capture_output=True, text=True
        )
        candidates = json.loads(list_result.stdout) if list_result.stdout.strip() else []
        existing = set(id_map.values())
        new_ones = [b["id"] for b in candidates if b["id"] not in existing]
        if len(new_ones) == 1:
            real_id = new_ones[0]
        else:
            print(f"ERROR: cannot determine real ID for '{logical_id}'; bd output: {out!r}", file=sys.stderr)
            sys.exit(1)

    id_map[logical_id] = real_id
    print(f"Created {logical_id!r} → {real_id}")

# Write the id map
json.dump(id_map, open(id_map_file, "w"), indent=2)

# Add dependency edges using real IDs
for bead in beads:
    logical_id = bead["id"]
    real_id    = id_map.get(logical_id, "")
    if not real_id:
        continue
    for dep_logical in bead.get("needs", []):
        if "*" in dep_logical:
            print(f"Skipping wildcard dep: {logical_id} needs {dep_logical}")
            continue
        dep_real = id_map.get(dep_logical, "")
        if not dep_real:
            print(f"WARNING: dep {dep_logical} not in id_map, skipping edge", file=sys.stderr)
            continue
        print(f"bd dep add {real_id} {dep_real} ({logical_id} needs {dep_logical})")
        result = subprocess.run(
            ["bd", "dep", "add", real_id, dep_real],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            print(f"WARNING: dep add failed: {result.stderr.strip()}", file=sys.stderr)

print("Graph materialised.")
PYEOF

echo "[choreo] id-map: $(cat "${ID_MAP}")" >&2

# ---------------------------------------------------------------------------
# Load id-map for use by workers and the choreo loop
# ---------------------------------------------------------------------------
# Helpers to look up IDs
_logical_to_real() {
    local logical="$1"
    python3 -c "import json; m=json.load(open('${ID_MAP}')); print(m.get('${logical}', ''))" 2>/dev/null || echo ""
}

_real_to_logical() {
    local real="$1"
    python3 -c "
import json
m = json.load(open('${ID_MAP}'))
rev = {v:k for k,v in m.items()}
print(rev.get('${real}', '${real}'))
" 2>/dev/null || echo "${real}"
}

# Get the set of all real IDs for this run (comma-separated for Python)
RUN_BEAD_IDS=$(python3 -c "
import json
m = json.load(open('${ID_MAP}'))
print(','.join(m.values()))
" 2>/dev/null || echo "")

echo "[choreo] Run bead IDs: ${RUN_BEAD_IDS}" >&2

# ---------------------------------------------------------------------------
# Spawn deterministic workers
# ---------------------------------------------------------------------------
echo "[choreo] Spawning deterministic workers..." >&2

declare -a WORKER_PIDS=()
WORKER_SIGNALS="${CASE_DIR}/worker-signals.json"

# Emit TSV: logical_id TAB real_id TAB reason TAB comment_escaped
while IFS=$'\t' read -r logical_bead_id real_bead_id reason comment_escaped; do
    [[ -z "${logical_bead_id}" || -z "${real_bead_id}" ]] && continue
    real_comment="${comment_escaped//\\n/$'\n'}"
    out_file="${AGENT_TMP}/worker-${logical_bead_id}.out"

    (
        echo "[worker:${logical_bead_id}] starting (real_id=${real_bead_id} reason=${reason})"

        waited=0
        while true; do
            ready_json=$(bd ready --json --limit 200 2>/dev/null || echo "[]")
            if echo "${ready_json}" | python3 -c "
import json,sys
beads=json.loads(sys.stdin.read())
ids=[b.get('id','') for b in beads]
sys.exit(0 if '${real_bead_id}' in ids else 1)
" 2>/dev/null; then
                echo "[worker:${logical_bead_id}] bead ready — claiming"
                break
            fi
            if [[ $waited -ge 180 ]]; then
                echo "[worker:${logical_bead_id}] TIMEOUT waiting for ready state"
                exit 0
            fi
            sleep "${POLL_INTERVAL}"
            waited=$((waited + POLL_INTERVAL))
        done

        bd update "${real_bead_id}" --claim 2>/dev/null || true

        # Apply file edits based on the logical bead ID
        case "${logical_bead_id}" in
            design-codes)
                if [[ "${reason}" == "completed" ]]; then
                    python3 -c "
import os
codes_path = '${WORKTREE}/errors/codes.py'
if os.path.exists(codes_path):
    content = open(codes_path).read()
    if 'NOT_FOUND' not in content:
        open(codes_path, 'w').write('''from enum import IntEnum

class ErrorCode(IntEnum):
    UNKNOWN        = 0
    NOT_FOUND      = 1
    UNAUTHORIZED   = 2
    CONFLICT       = 3
    RATE_LIMIT     = 4
    TIMEOUT        = 5
    VALIDATION     = 6
''')
        print('[worker:design-codes] wrote codes.py')
" 2>/dev/null || true
                fi
                ;;
            impl-conflict)
                if [[ "${reason}" == "completed" ]]; then
                    python3 -c "
open('${WORKTREE}/errors/conflict.py', 'w').write('''from dataclasses import dataclass
from .base import BaseError
from .codes import ErrorCode
from .registry import register


@dataclass
class ConflictError(BaseError):
    @property
    def code(self) -> ErrorCode:
        return ErrorCode.CONFLICT


register(ErrorCode.CONFLICT, ConflictError)

__all__ = [\"ConflictError\"]
''')
print('[worker:impl-conflict] wrote conflict.py')
" 2>/dev/null || true
                fi
                ;;
            impl-timeout)
                if [[ "${reason}" == "completed" ]]; then
                    python3 -c "
open('${WORKTREE}/errors/timeout.py', 'w').write('''from dataclasses import dataclass
from .base import BaseError
from .codes import ErrorCode
from .registry import register


@dataclass
class TimeoutError(BaseError):
    @property
    def code(self) -> ErrorCode:
        return ErrorCode.TIMEOUT


register(ErrorCode.TIMEOUT, TimeoutError)

__all__ = [\"TimeoutError\"]
''')
print('[worker:impl-timeout] wrote timeout.py')
" 2>/dev/null || true
                fi
                ;;
            impl-unauthorized)
                if [[ "${reason}" == "completed" ]]; then
                    python3 -c "
open('${WORKTREE}/errors/unauthorized.py', 'w').write('''from dataclasses import dataclass
from .base import BaseError
from .codes import ErrorCode
from .registry import register


@dataclass
class UnauthorizedError(BaseError):
    @property
    def code(self) -> ErrorCode:
        return ErrorCode.UNAUTHORIZED


register(ErrorCode.UNAUTHORIZED, UnauthorizedError)

__all__ = [\"UnauthorizedError\"]
''')
print('[worker:impl-unauthorized] wrote unauthorized.py')
" 2>/dev/null || true
                fi
                ;;
            impl-not-found)
                # Worker still implements the class even when signaling revealed-additional-work
                python3 -c "
open('${WORKTREE}/errors/not_found.py', 'w').write('''from dataclasses import dataclass
from .base import BaseError
from .codes import ErrorCode
from .registry import register


@dataclass
class NotFoundError(BaseError):
    @property
    def code(self) -> ErrorCode:
        return ErrorCode.NOT_FOUND


register(ErrorCode.NOT_FOUND, NotFoundError)

__all__ = [\"NotFoundError\"]
''')
print('[worker:impl-not-found] wrote not_found.py')
" 2>/dev/null || true
                ;;
        esac

        if [[ -n "${real_comment}" ]]; then
            bd comment "${real_bead_id}" "${real_comment}" 2>/dev/null || true
        fi

        bd close "${real_bead_id}" --reason="${reason}" 2>/dev/null || \
        bd update "${real_bead_id}" --status=closed 2>/dev/null || true

        echo "[worker:${logical_bead_id}] closed (${real_bead_id}) reason=${reason}"
    ) >> "${out_file}" 2>&1 &

    WORKER_PIDS+=($!)
    echo "[choreo] Spawned worker for ${logical_bead_id} → ${real_bead_id} (pid=$!, reason=${reason})" >&2

done < <(python3 - "${WORKER_SIGNALS}" "${ID_MAP}" << 'PYEOF'
import json, sys

signals_file = sys.argv[1]
id_map_file  = sys.argv[2]

signals = json.load(open(signals_file))
id_map  = json.load(open(id_map_file))

for logical_id, sig in sorted(signals.items()):
    if logical_id.startswith("_"):
        continue
    real_id = id_map.get(logical_id, "")
    if not real_id:
        print(f"WARNING: {logical_id} not in id_map, skipping worker", file=sys.stderr)
        continue
    reason = sig.get("reason", "completed")
    comment = sig.get("comment") or ""
    comment_esc = comment.replace("\t", " ").replace("\n", "\\n")
    print(f"{logical_id}\t{real_id}\t{reason}\t{comment_esc}")
PYEOF
)

echo "[choreo] ${#WORKER_PIDS[@]} workers spawned." >&2

# ---------------------------------------------------------------------------
# Helper scripts in CHOREO_TMP
# ---------------------------------------------------------------------------
HELPER_DIR="${CHOREO_TMP}/helpers"
mkdir -p "${HELPER_DIR}"

# list_closed.py — list closed beads from THIS run, skip seen IDs
# Args: seen_ids_csv run_ids_csv id_map_path run_label
cat > "${HELPER_DIR}/list_closed.py" << 'PYEOF'
#!/usr/bin/env python3
"""List newly-closed beads from this run as TSV (logical_id, real_id, reason, comment_esc)."""
import subprocess, json, sys

seen_ids  = set(x for x in sys.argv[1].split(",") if x)
run_ids   = set(x for x in sys.argv[2].split(",") if x)
id_map_f  = sys.argv[3]
run_label = sys.argv[4] if len(sys.argv) > 4 else ""

id_map   = json.load(open(id_map_f))
rev_map  = {v: k for k, v in id_map.items()}

# Use label filter if available, otherwise fall back to unlimited list
cmd = ["bd", "list", "--status", "closed", "--json", "--limit", "0"]
if run_label:
    cmd += ["--label", run_label]

result = subprocess.run(cmd, capture_output=True, text=True)
if result.returncode != 0 or not result.stdout.strip():
    sys.exit(0)

try:
    beads = json.loads(result.stdout)
except Exception:
    sys.exit(0)

for bead in beads:
    real_id = bead.get("id", "")
    if not real_id:
        continue
    if real_id not in run_ids:
        continue  # not from this run
    if real_id in seen_ids:
        continue  # already processed

    logical_id = rev_map.get(real_id, real_id)
    reason = bead.get("close_reason") or bead.get("reason") or "completed"

    # Notes field may be empty; fetch comments separately (workers use bd comment)
    notes = bead.get("notes") or ""
    if not notes:
        comments_result = subprocess.run(
            ["bd", "comments", real_id, "--json"],
            capture_output=True, text=True
        )
        if comments_result.returncode == 0 and comments_result.stdout.strip():
            try:
                comments_data = json.loads(comments_result.stdout)
                # comments is a list; join body fields
                bodies = []
                for c in (comments_data if isinstance(comments_data, list) else []):
                    body = c.get("text") or c.get("body") or c.get("content") or ""
                    if body:
                        bodies.append(body)
                notes = "\n".join(bodies)
            except Exception:
                pass

    comment_esc = notes.replace("\t", " ").replace("\n", "\\n")
    print(f"{logical_id}\t{real_id}\t{reason}\t{comment_esc}")
PYEOF

# count_open.py — count open+in_progress beads from this run
cat > "${HELPER_DIR}/count_open.py" << 'PYEOF'
#!/usr/bin/env python3
import subprocess, json, sys

run_ids = set(x for x in sys.argv[1].split(",") if x)

total = 0
for status in ("open", "in_progress"):
    result = subprocess.run(
        ["bd", "list", "--status", status, "--json"],
        capture_output=True, text=True
    )
    if result.returncode == 0 and result.stdout.strip():
        try:
            beads = json.loads(result.stdout)
            total += sum(1 for b in beads if b.get("id","") in run_ids)
        except Exception:
            pass

print(total)
PYEOF

# parse_mutation.py — parse MUTATION: block from choreographer response
cat > "${HELPER_DIR}/parse_mutation.py" << 'PYEOF'
#!/usr/bin/env python3
import re, json, sys

response_file = sys.argv[1]
response = open(response_file).read()

action_m = re.search(r"MUTATION:\s*(\w+)", response, re.IGNORECASE)
if not action_m:
    print(json.dumps({"action": "noop", "_parse_note": "no MUTATION tag found"}))
    sys.exit(0)

action = action_m.group(1).lower()
result = {"action": action}

for pat, key in [
    (r"TITLE:\s*(.+)",       "title"),
    (r"ASSIGNEE:\s*(.+)",    "assignee"),
    (r"DESC:\s*(.+)",        "desc"),
    (r"BEAD_ID:\s*(\S+)",    "bead_id"),
    (r"NOTE:\s*(.+)",        "note"),
    (r"TO:\s*(.+)",          "to"),
]:
    m = re.search(pat, response)
    if m:
        result[key] = m.group(1).strip()

print(json.dumps(result))
PYEOF

# graph_snapshot.py — compact snapshot of this run's beads
cat > "${HELPER_DIR}/graph_snapshot.py" << 'PYEOF'
#!/usr/bin/env python3
import subprocess, json, sys

run_ids = set(x for x in sys.argv[1].split(",") if x)
rev_map_j = sys.argv[2]
rev_map = json.loads(rev_map_j)

result = subprocess.run(["bd", "list", "--all", "--json"], capture_output=True, text=True)
if result.returncode != 0 or not result.stdout.strip():
    print("[]")
    sys.exit(0)

try:
    beads = json.loads(result.stdout)
except Exception:
    print("[]")
    sys.exit(0)

summary = []
for b in beads:
    if b.get("id","") in run_ids:
        summary.append({
            "id": b.get("id","?"),
            "logical_id": rev_map.get(b.get("id",""), b.get("id","")),
            "title": b.get("title",""),
            "status": b.get("status",""),
            "assignee": b.get("assignee",""),
        })

print(json.dumps(summary, indent=2))
PYEOF

# ---------------------------------------------------------------------------
# Build rev_map JSON (real→logical) for snapshot helper
# ---------------------------------------------------------------------------
REV_MAP_JSON=$(python3 -c "
import json
m = json.load(open('${ID_MAP}'))
rev = {v:k for k,v in m.items()}
print(json.dumps(rev))
" 2>/dev/null || echo '{}')

# ---------------------------------------------------------------------------
# Choreographer loop (host-driven, mode b)
# ---------------------------------------------------------------------------
echo "[choreo] Starting choreographer loop..." >&2

WALL_START="$(date +%s%3N)"

CHOREO_PERSONA="$(cat "${REPO_ROOT}/validation-pack/personas/choreographer.md" 2>/dev/null || echo "You are the choreographer. Observe bead close signals and respond with a single MUTATION: tag.")"

CHOREO_EVENT_COUNT=0
OVERALL_EXIT=0
SEEN_REAL_IDS=""   # comma-separated real bead IDs already processed

LOOP_START="$(date +%s)"

while true; do
    NOW="$(date +%s)"
    if [[ $((NOW - LOOP_START)) -ge $LOOP_TIMEOUT ]]; then
        echo "[choreo] Loop timeout (${LOOP_TIMEOUT}s reached)" >&2
        break
    fi

    if [[ $CHOREO_EVENT_COUNT -ge $MAX_CHOREO_EVENTS ]]; then
        echo "[choreo] Max event cap reached (${MAX_CHOREO_EVENTS})" >&2
        break
    fi

    # Check exit condition
    OPEN_COUNT=$(python3 "${HELPER_DIR}/count_open.py" "${RUN_BEAD_IDS}" 2>/dev/null || echo "1")
    if [[ "$OPEN_COUNT" -eq 0 ]]; then
        echo "[choreo] Exit condition met: no open beads in this run." >&2
        break
    fi

    # Poll for newly-closed beads in this run
    NEW_EVENTS=$(python3 "${HELPER_DIR}/list_closed.py" \
        "${SEEN_REAL_IDS}" "${RUN_BEAD_IDS}" "${ID_MAP}" "${RUN_LABEL}" 2>/dev/null || true)

    if [[ -z "$NEW_EVENTS" ]]; then
        sleep "${POLL_INTERVAL}"
        continue
    fi

    while IFS=$'\t' read -r logical_bead_id real_bead_id event_reason event_comment_esc; do
        [[ -z "$logical_bead_id" ]] && continue

        SEEN_REAL_IDS="${SEEN_REAL_IDS},${real_bead_id}"
        CHOREO_EVENT_COUNT=$((CHOREO_EVENT_COUNT + 1))

        event_comment="${event_comment_esc//\\n/$'\n'}"

        echo "[choreo] Event ${CHOREO_EVENT_COUNT}: ${logical_bead_id} (${real_bead_id}) closed reason=${event_reason}" >&2

        # Get current graph snapshot
        GRAPH_SNAPSHOT=$(python3 "${HELPER_DIR}/graph_snapshot.py" \
            "${RUN_BEAD_IDS}" "${REV_MAP_JSON}" 2>/dev/null || echo "[]")

        # Build the per-event brief
        CHOREO_BRIEF="${CHOREO_PERSONA}

---

## Event: bead closed

**Logical bead name**: ${logical_bead_id}
**Real bead ID**: ${real_bead_id}
**Close reason**: ${event_reason}
**Worker comment**:
\`\`\`
${event_comment}
\`\`\`

## Current graph snapshot (this eval run only)

\`\`\`json
${GRAPH_SNAPSHOT}
\`\`\`

## Your task

Based on the close reason and worker comment above, emit exactly ONE MUTATION: block.
Use the logical bead name (not the real ID) in BEAD_ID fields where possible.
Refer to the decision rubric in your persona."

        CHOREO_OUT="${CHOREO_TMP}/choreo-event-${CHOREO_EVENT_COUNT}.out"
        CHOREO_ERR="${CHOREO_TMP}/choreo-event-${CHOREO_EVENT_COUNT}.err"

        CHOREO_EXIT=0
        claude -p "${CHOREO_BRIEF}" \
            --model "${CHOREO_MODEL}" \
            --dangerously-skip-permissions \
            --output-format text \
            > "${CHOREO_OUT}" 2> "${CHOREO_ERR}" || CHOREO_EXIT=$?

        if [[ $CHOREO_EXIT -ne 0 ]]; then
            echo "[choreo] claude -p exited ${CHOREO_EXIT} for ${logical_bead_id}" >&2
        fi

        # Parse mutation
        MUTATION_JSON=$(python3 "${HELPER_DIR}/parse_mutation.py" "${CHOREO_OUT}" 2>/dev/null \
            || echo '{"action":"noop"}')

        TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

        # Enrich with context
        FULL_MUTATION=$(python3 -c "
import json, sys
m = json.loads(sys.argv[1])
m['on_close_bead']         = '${logical_bead_id}'
m['on_close_real_id']      = '${real_bead_id}'
m['timestamp']             = '${TIMESTAMP}'
m['event_num']             = ${CHOREO_EVENT_COUNT}
print(json.dumps(m))
" "${MUTATION_JSON}" 2>/dev/null || echo "{\"action\":\"noop\",\"on_close_bead\":\"${logical_bead_id}\"}")

        echo "${FULL_MUTATION}" >> "${MUTATIONS_LOG}"

        ACTION=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('action','noop'))" \
            "${FULL_MUTATION}" 2>/dev/null || echo "noop")

        echo "[choreo] Mutation: ${ACTION} (on_close=${logical_bead_id})" >&2

        # Apply the mutation
        case "$ACTION" in
            noop)
                ;;
            spawn)
                SPAWN_TITLE=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('title','Spawned bead'))" "${FULL_MUTATION}" 2>/dev/null || echo "Spawned bead")
                SPAWN_ASSIGNEE=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('assignee','validation/implementer'))" "${FULL_MUTATION}" 2>/dev/null || echo "validation/implementer")
                SPAWN_DESC=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('desc',''))" "${FULL_MUTATION}" 2>/dev/null || echo "")

                echo "[choreo] spawn: '${SPAWN_TITLE}' → ${SPAWN_ASSIGNEE}" >&2
                SPAWN_OUT=$(bd create --title "${SPAWN_TITLE}" \
                    --assignee "${SPAWN_ASSIGNEE}" \
                    --label "${RUN_LABEL:-choreo-eval}" 2>/dev/null || echo "")
                echo "[choreo] spawn bd output: ${SPAWN_OUT}" >&2

                # Track the newly spawned ID in RUN_BEAD_IDS and close it (no real worker)
                SPAWNED_REAL=$(echo "${SPAWN_OUT}" | grep -oE '[a-z]+-[a-z0-9]+' | head -1 || echo "")
                if [[ -n "$SPAWNED_REAL" ]]; then
                    RUN_BEAD_IDS="${RUN_BEAD_IDS},${SPAWNED_REAL}"
                    # Update id_map to track this spawned bead
                    python3 -c "
import json
m = json.load(open('${ID_MAP}'))
m['spawned-${CHOREO_EVENT_COUNT}'] = '${SPAWNED_REAL}'
json.dump(m, open('${ID_MAP}', 'w'), indent=2)
" 2>/dev/null || true
                    # Close the spawned bead (deterministic eval — no real worker for spawned beads)
                    bd close "${SPAWNED_REAL}" --reason="completed" 2>/dev/null || true
                fi
                ;;
            human)
                HUMAN_BEAD=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('bead_id','${logical_bead_id}'))" "${FULL_MUTATION}" 2>/dev/null || echo "${logical_bead_id}")
                HUMAN_NOTE=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('note','needs human review'))" "${FULL_MUTATION}" 2>/dev/null || echo "needs human review")

                # Resolve logical→real if needed
                HUMAN_REAL=$(python3 -c "
import json
m = json.load(open('${ID_MAP}'))
bid = '${HUMAN_BEAD}'
print(m.get(bid, bid))
" 2>/dev/null || echo "${HUMAN_BEAD}")

                echo "[choreo] human: flag ${HUMAN_BEAD} (${HUMAN_REAL}) for review" >&2
                bd update "${HUMAN_REAL}" --notes "HUMAN-REVIEW: ${HUMAN_NOTE}" 2>/dev/null || true
                ;;
            reassign)
                REASSIGN_BEAD=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('bead_id','${logical_bead_id}'))" "${FULL_MUTATION}" 2>/dev/null || echo "${logical_bead_id}")
                REASSIGN_TO=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('to','validation/implementer'))" "${FULL_MUTATION}" 2>/dev/null || echo "validation/implementer")

                # Normalize pool
                if [[ "$REASSIGN_TO" != *"/"* ]]; then
                    REASSIGN_TO="validation/${REASSIGN_TO}"
                fi

                REASSIGN_REAL=$(python3 -c "
import json
m = json.load(open('${ID_MAP}'))
bid = '${REASSIGN_BEAD}'
print(m.get(bid, bid))
" 2>/dev/null || echo "${REASSIGN_BEAD}")

                echo "[choreo] reassign: ${REASSIGN_BEAD} → ${REASSIGN_TO}" >&2
                bd update "${REASSIGN_REAL}" --assignee "${REASSIGN_TO}" 2>/dev/null || true
                ;;
            reopen)
                REOPEN_BEAD=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('bead_id','${logical_bead_id}'))" "${FULL_MUTATION}" 2>/dev/null || echo "${logical_bead_id}")
                REOPEN_NOTE=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('note','retry'))" "${FULL_MUTATION}" 2>/dev/null || echo "retry")

                REOPEN_REAL=$(python3 -c "
import json
m = json.load(open('${ID_MAP}'))
bid = '${REOPEN_BEAD}'
print(m.get(bid, bid))
" 2>/dev/null || echo "${REOPEN_BEAD}")

                echo "[choreo] reopen: ${REOPEN_BEAD} (${REOPEN_REAL})" >&2
                bd update "${REOPEN_REAL}" --status=open --notes "${REOPEN_NOTE}" 2>/dev/null || true
                ;;
            *)
                echo "[choreo] WARNING: unknown mutation action '${ACTION}'" >&2
                ;;
        esac

    done <<< "$NEW_EVENTS"

done

echo "[choreo] Choreographer loop done. Events processed: ${CHOREO_EVENT_COUNT}" >&2

# ---------------------------------------------------------------------------
# Wait for workers
# ---------------------------------------------------------------------------
echo "[choreo] Waiting for workers..." >&2
for pid in "${WORKER_PIDS[@]:-}"; do
    wait "$pid" 2>/dev/null || true
done
echo "[choreo] Workers done." >&2

for out_file in "${AGENT_TMP}"/worker-*.out; do
    [[ -f "$out_file" ]] || continue
    bead_name=$(basename "${out_file%.out}")
    while IFS= read -r line; do echo "[choreo] worker| ${line}" >&2; done < "${out_file}"
done

# ---------------------------------------------------------------------------
# Terminal state check
# Worker beads = all run beads minus epic and land (which are infra, not workers)
# ---------------------------------------------------------------------------
WORKER_BEAD_IDS=$(python3 - "${ID_MAP}" << 'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
# Exclude epic and land beads from terminal state check
exclude = {"epic", "land"}
print(",".join(v for k, v in m.items() if k not in exclude))
PYEOF
)

TERMINAL_STATE_OK="true"
OPEN_BEADS_FINAL=$(python3 "${HELPER_DIR}/count_open.py" "${WORKER_BEAD_IDS}" 2>/dev/null || echo "0")

if [[ "$OPEN_BEADS_FINAL" -gt 0 ]]; then
    echo "[choreo] WARNING: ${OPEN_BEADS_FINAL} open worker beads at loop exit" >&2
    TERMINAL_STATE_OK="false"
fi

# ---------------------------------------------------------------------------
# Wall-clock elapsed
# ---------------------------------------------------------------------------
WALL_END="$(date +%s%3N)"
WALL_SECS="$(python3 -c "print(round((${WALL_END}-${WALL_START})/1000.0, 1))")"

# ---------------------------------------------------------------------------
# Pass-rate scoring
# ---------------------------------------------------------------------------
SCORER="${REPO_ROOT}/scripts/eval-scorer.py"
SCORER_OUT='{}'
if [[ -f "$SCORER" ]]; then
    SCORER_JSON="$(python3 "${SCORER}" --case-path "${CASE_DIR}" --worktree "${WORKTREE}" 2>/dev/null)" || true
    if [[ -n "$SCORER_JSON" ]]; then
        SCORER_OUT="$SCORER_JSON"
    fi
fi

VISIBLE_PASS="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('visible_pass',0))" "${SCORER_OUT}" 2>/dev/null || echo 0)"
VISIBLE_TOTAL="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('visible_total',0))" "${SCORER_OUT}" 2>/dev/null || echo 0)"
HIDDEN_PASS="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('hidden_pass',0))" "${SCORER_OUT}" 2>/dev/null || echo 0)"
HIDDEN_TOTAL="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('hidden_total',0))" "${SCORER_OUT}" 2>/dev/null || echo 0)"

# ---------------------------------------------------------------------------
# Mutation rubric scoring
# ---------------------------------------------------------------------------
MUT_SCORER="${REPO_ROOT}/scripts/eval-mutation-scorer.py"
MUT_SCORER_OUT='{}'
TERMINAL_FLAG="--terminal-state-ok"
[[ "$TERMINAL_STATE_OK" != "true" ]] && TERMINAL_FLAG="--no-terminal-state-ok"

if [[ -f "$MUT_SCORER" && -f "$MUTATIONS_LOG" ]]; then
    MUT_SCORER_JSON="$(python3 "${MUT_SCORER}" \
        --reference "${CASE_DIR}/reference-mutations.json" \
        --mutations "${MUTATIONS_LOG}" \
        "${TERMINAL_FLAG}" 2>/dev/null)" || true
    if [[ -n "$MUT_SCORER_JSON" ]]; then
        MUT_SCORER_OUT="$MUT_SCORER_JSON"
    fi
fi

MUTATION_RECALL="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('mutation_recall',0.0))" "${MUT_SCORER_OUT}" 2>/dev/null || echo 0.0)"
MUTATION_PRECISION="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('mutation_precision',0.0))" "${MUT_SCORER_OUT}" 2>/dev/null || echo 0.0)"
FORBIDDEN_VIOLATIONS="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('forbidden_violations',0))" "${MUT_SCORER_OUT}" 2>/dev/null || echo 0)"

# ---------------------------------------------------------------------------
# Emit result JSON
# ---------------------------------------------------------------------------
RESULTS_FILE="${OUTPUT_DIR}/results-${RUN_ID}.json"

python3 - "${MUTATIONS_LOG}" "${RESULTS_FILE}" << PYEOF
import json, sys

mutations_log_path = sys.argv[1]
results_file_path  = sys.argv[2]

mutations = []
try:
    with open(mutations_log_path) as fh:
        for line in fh:
            line = line.strip()
            if line:
                mutations.append(json.loads(line))
except FileNotFoundError:
    pass

mut_scorer = {}
try:
    mut_scorer = json.loads("""${MUT_SCORER_OUT}""")
except Exception:
    pass

result = {
    "run_id":                    "${RUN_ID}",
    "case_id":                   "${CASE_ID}",
    "pattern":                   "choreographer",
    "choreo_model":              "${CHOREO_MODEL}",
    "wall_clock_secs":           ${WALL_SECS},
    "tokens_in":                 0,
    "tokens_out":                0,
    "cache_creation_input_tokens": 0,
    "cache_read_input_tokens":   0,
    "choreo_events":             ${CHOREO_EVENT_COUNT},
    "mutation_recall":           ${MUTATION_RECALL},
    "mutation_precision":        ${MUTATION_PRECISION},
    "forbidden_violations":      ${FORBIDDEN_VIOLATIONS},
    "terminal_state_ok":         ("${TERMINAL_STATE_OK}" == "true"),
    "visible_pass":              ${VISIBLE_PASS},
    "visible_total":             ${VISIBLE_TOTAL},
    "hidden_pass":               ${HIDDEN_PASS},
    "hidden_total":              ${HIDDEN_TOTAL},
    "exit_code":                 ${OVERALL_EXIT},
    "mutation_log":              mutations,
    "mutation_rubric":           mut_scorer,
    "_meta": {
        "token_coverage":  "unavailable (substrate)",
        "approach":        "host-driven choreographer loop, deterministic workers",
        "design_fragment": "docs/choreographer-eval.md commit 501ba17",
        "worktree":        "${WORKTREE}",
        "id_map":          "${ID_MAP}",
        "mutations_log":   "${MUTATIONS_LOG}",
    },
}

with open(results_file_path, "w") as fh:
    json.dump(result, fh, indent=2)
    fh.write("\n")

print(json.dumps(result, indent=2))
PYEOF

echo "[choreo] Results written: ${RESULTS_FILE}" >&2
exit "${OVERALL_EXIT}"
