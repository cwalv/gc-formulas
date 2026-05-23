#!/usr/bin/env bash
# eval-planner.sh — pattern-selection runner for plan-evals M2 (epic fo-6i6mt).
#
# Shows the planner a case (spec.md + starting-state tree summary) and a neutral
# pattern menu, parses the planner's JSON choice, then dispatches the chosen
# pattern's runner. The result JSON is the dispatched runner's JSON augmented
# with planner_* fields. The top-level "pattern" is rewritten to "planner";
# the actual pattern picked lives in planner_choice.
#
# This is the most direct test of position.md's "model-as-orchestrator" claim:
# does the LLM correctly route a case to the empirically-best pattern when
# given a neutral description of each option?
#
# Usage:
#   bash scripts/eval-planner.sh <case-id> [--output-dir DIR] [--run-id ID]
#
# Outputs:
#   <output-dir>/results-<run-id>.json             — merged planner + runner JSON
#   <output-dir>/<run-id>/planner.out              — raw planner claude JSON
#   <output-dir>/<run-id>/planner.parsed.json      — parsed planner fields
#   <output-dir>/results-<run-id>-dispatched.json  — dispatched runner's own JSON
#
# Pattern menu (kept in sync with the runners that actually exist):
#   - ralph        — single agent in a loop until tests pass
#   - fanout       — N parallel agents writing to a shared worktree, no coordination
#   - sectioning   — N parallel agents in isolated copies + deterministic file-scoped collation
#   - orchworkers  — N parallel agents, then an LLM merge reconciles cross-cutting concerns
#
# Result JSON schema (per fo-6i6mt.2 acceptance):
#   all dispatched-runner fields, plus:
#     planner_choice     — string ("ralph" | "fanout" | "orchworkers")
#     planner_reasoning  — string (the planner's 1-2 sentence justification)
#     planner_tokens_in  — int
#     planner_tokens_out — int
#     planner_model      — string (first key of modelUsage)
#   and the top-level "pattern" is rewritten to "planner".

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve repo root (script lives in scripts/ one level under root)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EVALS_DIR="${REPO_ROOT}/evals"

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
            echo "Unknown option: $1" >&2; exit 1 ;;
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
    echo "Usage: bash scripts/eval-planner.sh <case-id> [--output-dir DIR] [--run-id ID]" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
if ! command -v claude &>/dev/null; then
    echo "ERROR: 'claude' not found on PATH. Install Claude Code CLI before running evals." >&2
    exit 1
fi

CASE_DIR="${EVALS_DIR}/${CASE_ID}"
if [[ ! -d "$CASE_DIR" ]]; then
    echo "ERROR: Eval case not found: ${CASE_DIR}" >&2
    exit 1
fi

SPEC_FILE="${CASE_DIR}/spec.md"
if [[ ! -f "$SPEC_FILE" ]]; then
    echo "ERROR: spec.md missing from case: ${SPEC_FILE}" >&2
    exit 1
fi

STARTING_STATE="${CASE_DIR}/starting-state"
if [[ ! -d "$STARTING_STATE" ]]; then
    echo "ERROR: starting-state/ missing from case: ${STARTING_STATE}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Generate run-id if not provided
# ---------------------------------------------------------------------------
if [[ -z "$RUN_ID" ]]; then
    RUN_ID="planner-${CASE_ID}-$(date -u +%Y%m%d-%H%M%S)-$$"
fi

mkdir -p "${OUTPUT_DIR}/${RUN_ID}"
PLANNER_OUT="${OUTPUT_DIR}/${RUN_ID}/planner.out"
PLANNER_ERR="${OUTPUT_DIR}/${RUN_ID}/planner.err"
PLANNER_PARSED="${OUTPUT_DIR}/${RUN_ID}/planner.parsed.json"

echo "=== eval-planner: ${CASE_ID} (run_id=${RUN_ID}) ===" >&2

# ---------------------------------------------------------------------------
# Generate a starting-state tree summary (paths + line counts; not contents).
# Skips __pycache__ and other compiled artefacts so the planner sees the
# source layout, not byte-code droppings.
# ---------------------------------------------------------------------------
TREE_SUMMARY="$(python3 - "${STARTING_STATE}" <<'PYEOF'
import os, sys
root = sys.argv[1]
lines = []
for dirpath, dirnames, filenames in os.walk(root):
    # Skip caches and hidden dirs so the planner sees source layout, not noise.
    dirnames[:] = sorted(
        d for d in dirnames
        if d != "__pycache__" and not d.startswith(".")
    )
    for fname in sorted(filenames):
        if fname.endswith((".pyc", ".pyo")):
            continue
        full = os.path.join(dirpath, fname)
        rel = os.path.relpath(full, root)
        try:
            with open(full, "rb") as fh:
                line_count = sum(1 for _ in fh)
        except OSError:
            line_count = 0
        lines.append(f"  {rel} ({line_count} lines)")
print("\n".join(lines))
PYEOF
)"

# ---------------------------------------------------------------------------
# Read spec content once
# ---------------------------------------------------------------------------
SPEC_CONTENT="$(cat "${SPEC_FILE}")"

# ---------------------------------------------------------------------------
# Compose planner brief.
#
# Each pattern is described in one neutral sentence — no recommendations, no
# steering. The whole point is the planner decides; this script is plumbing.
# Output contract is strict JSON; we still parse robustly in case the model
# wraps the JSON in prose.
# ---------------------------------------------------------------------------
PLANNER_BRIEF="You are choosing an execution pattern for a coding task.

Here is the task spec:

---
${SPEC_CONTENT}
---

Here is the starting-state directory tree (paths + line counts):

${TREE_SUMMARY}

Here are your pattern options:

- ralph: single agent in a loop until tests pass.
- fanout: N parallel agents writing to a shared worktree, no coordination.
- sectioning: N parallel agents each in an isolated copy of the worktree; a deterministic file-scoped collator merges their work afterward (no LLM in the merge).
- orchworkers: N parallel agents each handling one file, then an LLM merge reconciles cross-cutting concerns.

Pick exactly one of {ralph, fanout, sectioning, orchworkers} and explain in 1-2 sentences.

Output ONLY a single JSON object on stdout, with no surrounding prose, no
markdown fences, no commentary. The object must have exactly two string
fields:

  {\"pattern\": \"ralph\" | \"fanout\" | \"sectioning\" | \"orchworkers\", \"reasoning\": \"...\"}"

echo "[planner] Invoking planner claude -p…" >&2

PLANNER_EXIT=0
claude -p "${PLANNER_BRIEF}" \
    --model "${PLANNER_MODEL}" \
    --dangerously-skip-permissions \
    --output-format json \
    > "${PLANNER_OUT}" \
    2> "${PLANNER_ERR}" || PLANNER_EXIT=$?

if [[ "$PLANNER_EXIT" -ne 0 ]]; then
    echo "[planner] Planner claude exited with code ${PLANNER_EXIT}" >&2
fi

# ---------------------------------------------------------------------------
# Parse planner output. The claude --output-format json wrapper puts the
# model's text under data["result"] (or data["text"] in some versions); we
# then extract the first balanced {...} block from that text.
#
# Writes a JSON object to ${PLANNER_PARSED} with fields:
#   planner_choice, planner_reasoning, planner_tokens_in,
#   planner_tokens_out, planner_model, parser_fallback
# Exits 0 even on parse failure; the shell branches on planner_choice.
# ---------------------------------------------------------------------------
python3 - "${PLANNER_OUT}" "${PLANNER_PARSED}" <<'PYEOF'
import json, sys

VALID_PATTERNS = {"ralph", "fanout", "sectioning", "orchworkers"}
PLANNER_OUT, PLANNER_PARSED = sys.argv[1], sys.argv[2]


def emit(choice, reasoning, tokens_in, tokens_out, model, fallback, cache_create=0, cache_read=0):
    payload = {
        "planner_choice":     choice or "",
        "planner_reasoning":  reasoning or "",
        "planner_tokens_in":  int(tokens_in or 0),
        "planner_tokens_out": int(tokens_out or 0),
        "planner_model":      model or "",
        "parser_fallback":    bool(fallback),
        "planner_cache_creation_input_tokens": int(cache_create or 0),
        "planner_cache_read_input_tokens":     int(cache_read or 0),
    }
    with open(PLANNER_PARSED, "w") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")


def find_balanced_json(text):
    """Return the first balanced {...} JSON object containing 'pattern', or None."""
    if not text:
        return None
    start_positions = [i for i, ch in enumerate(text) if ch == "{"]
    for start in start_positions:
        depth = 0
        in_str = False
        esc = False
        for j in range(start, len(text)):
            ch = text[j]
            if in_str:
                if esc:
                    esc = False
                elif ch == "\\":
                    esc = True
                elif ch == '"':
                    in_str = False
                continue
            if ch == '"':
                in_str = True
                continue
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    candidate = text[start:j+1]
                    try:
                        obj = json.loads(candidate)
                        if isinstance(obj, dict) and "pattern" in obj:
                            return obj
                    except Exception:
                        pass
                    break  # try next start position
    return None


try:
    raw = open(PLANNER_OUT).read().strip()
    wrapper = json.loads(raw)
except Exception:
    emit("", "", 0, 0, "", True)
    sys.exit(0)

usage = wrapper.get("usage") or {}
tokens_in    = usage.get("input_tokens", 0) or 0
tokens_out   = usage.get("output_tokens", 0) or 0
cache_create = usage.get("cache_creation_input_tokens", 0) or 0
cache_read   = usage.get("cache_read_input_tokens", 0) or 0

model_usage = wrapper.get("modelUsage") or {}
model = next(iter(model_usage), "") if model_usage else ""

# claude --output-format json puts the assistant's text under "result".
# Older shapes may use "text". Accept either; fall back to the whole wrapper
# text if neither is present.
text = wrapper.get("result") or wrapper.get("text") or ""
if not text:
    text = raw

fallback = False
obj = None

# Strict parse first (text might be the raw JSON object).
stripped = text.strip()
if stripped.startswith("{") and stripped.endswith("}"):
    try:
        candidate = json.loads(stripped)
        if isinstance(candidate, dict) and "pattern" in candidate:
            obj = candidate
    except Exception:
        pass

if obj is None:
    obj = find_balanced_json(text)
    if obj is not None:
        fallback = True

if obj is None:
    emit("", "", tokens_in, tokens_out, model, True, cache_create, cache_read)
    sys.exit(0)

choice = (obj.get("pattern") or "").strip()
reasoning = (obj.get("reasoning") or "").strip()

if choice not in VALID_PATTERNS:
    emit(choice, reasoning, tokens_in, tokens_out, model, True, cache_create, cache_read)
    sys.exit(0)

emit(choice, reasoning, tokens_in, tokens_out, model, fallback, cache_create, cache_read)
PYEOF

# Read fields we need for shell branching / log lines.
PLANNER_CHOICE="$(python3 -c "import json; print(json.load(open('${PLANNER_PARSED}'))['planner_choice'])")"
PLANNER_TOKENS_IN="$(python3 -c "import json; print(json.load(open('${PLANNER_PARSED}'))['planner_tokens_in'])")"
PLANNER_TOKENS_OUT="$(python3 -c "import json; print(json.load(open('${PLANNER_PARSED}'))['planner_tokens_out'])")"
PLANNER_MODEL="$(python3 -c "import json; print(json.load(open('${PLANNER_PARSED}'))['planner_model'])")"
PARSER_FALLBACK="$(python3 -c "import json; print(json.load(open('${PLANNER_PARSED}'))['parser_fallback'])")"

echo "[planner] choice=${PLANNER_CHOICE} tokens_in=${PLANNER_TOKENS_IN} tokens_out=${PLANNER_TOKENS_OUT} model=${PLANNER_MODEL} fallback=${PARSER_FALLBACK}" >&2

# Validate the planner picked a runnable pattern. If not, emit a results JSON
# recording the failure cleanly so the driver can tally it.
case "${PLANNER_CHOICE}" in
    ralph|fanout|orchworkers) ;;
    *)
        echo "[planner] ERROR: planner returned invalid or empty pattern: '${PLANNER_CHOICE}'" >&2
        RESULTS_FILE="${OUTPUT_DIR}/results-${RUN_ID}.json"
        mkdir -p "${OUTPUT_DIR}"
        python3 - "${PLANNER_PARSED}" "${RESULTS_FILE}" "${RUN_ID}" "${CASE_ID}" <<'PYEOF'
import json, sys
parsed_path, results_path, run_id, case_id = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
parsed = json.load(open(parsed_path))
result = {
    "run_id":            run_id,
    "case_id":           case_id,
    "pattern":           "planner",
    "wall_clock_secs":   0.0,
    "tokens_in":         int(parsed["planner_tokens_in"]),
    "tokens_out":        int(parsed["planner_tokens_out"]),
    "cache_creation_input_tokens": int(parsed.get("planner_cache_creation_input_tokens", 0)),
    "cache_read_input_tokens":     int(parsed.get("planner_cache_read_input_tokens", 0)),
    "visible_pass":      0,
    "visible_total":     0,
    "hidden_pass":       0,
    "hidden_total":      0,
    "existing_pass":     0,
    "existing_total":    0,
    "exit_code":         1,
    "planner_choice":    parsed["planner_choice"],
    "planner_reasoning": parsed["planner_reasoning"],
    "planner_tokens_in": int(parsed["planner_tokens_in"]),
    "planner_tokens_out": int(parsed["planner_tokens_out"]),
    "planner_cache_creation_input_tokens": int(parsed.get("planner_cache_creation_input_tokens", 0)),
    "planner_cache_read_input_tokens":     int(parsed.get("planner_cache_read_input_tokens", 0)),
    "planner_model":     parsed["planner_model"],
    "_meta": {
        "error":                    "planner did not return a valid pattern",
        "planner_parser_fallback":  bool(parsed.get("parser_fallback")),
    },
}
with open(results_path, "w") as fh:
    json.dump(result, fh, indent=2)
    fh.write("\n")
print(json.dumps(result, indent=2))
PYEOF
        echo "[planner] Results written to: ${RESULTS_FILE}" >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Dispatch the chosen runner.
#
# We pass --output-dir <same> so the dispatched runner writes its results JSON
# next to ours, and --run-id <run-id>-dispatched so artefacts don't collide.
# ---------------------------------------------------------------------------
DISPATCHED_RUN_ID="${RUN_ID}-dispatched"
DISPATCHED_RUNNER="${SCRIPT_DIR}/eval-${PLANNER_CHOICE}.sh"

if [[ ! -f "${DISPATCHED_RUNNER}" ]]; then
    echo "[planner] ERROR: dispatched runner not found: ${DISPATCHED_RUNNER}" >&2
    exit 1
fi

echo "[planner] Dispatching: bash ${DISPATCHED_RUNNER} ${CASE_ID} --output-dir ${OUTPUT_DIR} --run-id ${DISPATCHED_RUN_ID}" >&2

DISPATCH_EXIT=0
bash "${DISPATCHED_RUNNER}" \
    "${CASE_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --run-id "${DISPATCHED_RUN_ID}" \
    || DISPATCH_EXIT=$?

DISPATCHED_RESULTS="${OUTPUT_DIR}/results-${DISPATCHED_RUN_ID}.json"

if [[ ! -f "${DISPATCHED_RESULTS}" ]]; then
    echo "[planner] ERROR: dispatched runner produced no results JSON at ${DISPATCHED_RESULTS}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Merge: take the dispatched runner's JSON, overwrite top-level pattern to
# "planner", rewrite run_id to ours, then add planner_* fields and parser-
# fallback flag under _meta.
# ---------------------------------------------------------------------------
RESULTS_FILE="${OUTPUT_DIR}/results-${RUN_ID}.json"

python3 - "${DISPATCHED_RESULTS}" "${PLANNER_PARSED}" "${RESULTS_FILE}" "${RUN_ID}" "${DISPATCHED_RUN_ID}" <<'PYEOF'
import json, sys
dispatched_path, parsed_path, results_path, run_id, dispatched_run_id = sys.argv[1:6]

with open(dispatched_path) as fh:
    result = json.load(fh)

parsed = json.load(open(parsed_path))

# Rewrite identity fields so the merged result represents the planner run.
result["run_id"]  = run_id
result["pattern"] = "planner"

# Add planner_* fields.
result["planner_choice"]     = parsed["planner_choice"]
result["planner_reasoning"]  = parsed["planner_reasoning"]
result["planner_tokens_in"]  = int(parsed["planner_tokens_in"])
result["planner_tokens_out"] = int(parsed["planner_tokens_out"])
result["planner_cache_creation_input_tokens"] = int(parsed.get("planner_cache_creation_input_tokens", 0))
result["planner_cache_read_input_tokens"]     = int(parsed.get("planner_cache_read_input_tokens", 0))
result["planner_model"]      = parsed["planner_model"]
# Roll planner cache into the run-level totals so the aggregate counts both
# planner + dispatched-runner contract length.
result["cache_creation_input_tokens"] = int(result.get("cache_creation_input_tokens", 0)) + int(parsed.get("planner_cache_creation_input_tokens", 0))
result["cache_read_input_tokens"]     = int(result.get("cache_read_input_tokens", 0))     + int(parsed.get("planner_cache_read_input_tokens", 0))

# Annotate _meta with planner-specific provenance.
meta = result.get("_meta") or {}
if not isinstance(meta, dict):
    meta = {}
meta["planner_parser_fallback"] = bool(parsed.get("parser_fallback"))
meta["dispatched_run_id"]       = dispatched_run_id
result["_meta"] = meta

with open(results_path, "w") as fh:
    json.dump(result, fh, indent=2)
    fh.write("\n")

print(json.dumps(result, indent=2))
PYEOF

echo "[planner] Results written to: ${RESULTS_FILE}" >&2
exit "${DISPATCH_EXIT}"
