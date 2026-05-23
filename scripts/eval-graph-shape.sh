#!/usr/bin/env bash
# eval-graph-shape.sh — Phase B graph-shape runner for plan-evals (bead fo-d5fh9).
#
# Shows the planner a case's design doc (spec.md) + the choreography-idioms
# library + the starting-state tree, and asks it to produce a bead graph: an
# idiom choice, a list of bead nodes (id/title/persona/scope_files/deps), and
# a short reasoning. The graph is then scored against evals/<case>/reference-
# graph.json for semantic equivalence (idiom, per-persona node counts, dep
# topology shape).
#
# Plan-only. No worker execution. No `claude -p` worker fan-out. Just one
# planner call + a Python scorer.
#
# Usage:
#   bash scripts/eval-graph-shape.sh <case-id> [--output-dir DIR] [--run-id ID]
#
# Env vars (probe knobs — not the default mode):
#   PLANNER_MODEL          — override planner model (default from eval-config.sh).
#   SPEC_FILE_OVERRIDE     — path to a design doc to use instead of evals/<case>/spec.md.
#                            Used to test "designless" variants where the layout hint is
#                            stripped from the architect's input (fo-d5fh9 follow-up).
#   EXTRA_INSTRUCTION      — string appended to the planner brief as an "Additional
#                            constraint" section. Used to probe whether sonnet's
#                            structural biases (over-coordination, batching) are
#                            correctable via explicit instruction.
#   IDIOMS_FILE_OVERRIDE   — path to a custom choreography idioms file to show the
#                            planner. Used to probe whether the library's
#                            hierarchical examples teach the model to over-structure.
#                            Default: docs/choreography-idioms.md.
#
# Outputs:
#   <output-dir>/results-<run-id>.json   — scored result JSON (driver-compatible)
#   <output-dir>/<run-id>/planner.out    — raw planner claude JSON
#   <output-dir>/<run-id>/planner.err    — planner stderr
#   <output-dir>/<run-id>/graph.json     — parsed planner graph
#   <output-dir>/<run-id>/score.json     — per-dimension score breakdown

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EVALS_DIR="${REPO_ROOT}/evals"
IDIOMS_FILE="${IDIOMS_FILE_OVERRIDE:-${REPO_ROOT}/docs/choreography-idioms.md}"

source "${SCRIPT_DIR}/eval-config.sh"

CASE_ID=""
OUTPUT_DIR="/tmp/eval-runs"
RUN_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --run-id)     RUN_ID="$2"; shift 2 ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) if [[ -z "$CASE_ID" ]]; then CASE_ID="$1"; shift; else echo "Unexpected positional: $1" >&2; exit 1; fi ;;
    esac
done

if [[ -z "$CASE_ID" ]]; then
    echo "Usage: bash scripts/eval-graph-shape.sh <case-id> [--output-dir DIR] [--run-id ID]" >&2
    exit 1
fi

if ! command -v claude &>/dev/null; then
    echo "ERROR: 'claude' not found on PATH." >&2; exit 1
fi

CASE_DIR="${EVALS_DIR}/${CASE_ID}"
SPEC_FILE="${SPEC_FILE_OVERRIDE:-${CASE_DIR}/spec.md}"
STARTING_STATE="${CASE_DIR}/starting-state"
REFERENCE_FILE="${CASE_DIR}/reference-graph.json"

for f in "$SPEC_FILE" "$IDIOMS_FILE" "$REFERENCE_FILE"; do
    if [[ ! -f "$f" ]]; then echo "ERROR: missing required file: $f" >&2; exit 1; fi
done
if [[ ! -d "$STARTING_STATE" ]]; then echo "ERROR: missing starting-state: $STARTING_STATE" >&2; exit 1; fi

if [[ -z "$RUN_ID" ]]; then
    RUN_ID="graph-shape-${CASE_ID}-$(date -u +%Y%m%d-%H%M%S)-$$"
fi
mkdir -p "${OUTPUT_DIR}/${RUN_ID}"
PLANNER_OUT="${OUTPUT_DIR}/${RUN_ID}/planner.out"
PLANNER_ERR="${OUTPUT_DIR}/${RUN_ID}/planner.err"
GRAPH_JSON="${OUTPUT_DIR}/${RUN_ID}/graph.json"
SCORE_JSON="${OUTPUT_DIR}/${RUN_ID}/score.json"

echo "=== eval-graph-shape: ${CASE_ID} (run_id=${RUN_ID}) ===" >&2

TREE_SUMMARY="$(python3 - "${STARTING_STATE}" <<'PYEOF'
import os, sys
root = sys.argv[1]
lines = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = sorted(d for d in dirnames if d != "__pycache__" and not d.startswith("."))
    for fname in sorted(filenames):
        if fname.endswith((".pyc", ".pyo")): continue
        full = os.path.join(dirpath, fname)
        rel = os.path.relpath(full, root)
        try:
            with open(full, "rb") as fh: line_count = sum(1 for _ in fh)
        except OSError: line_count = 0
        lines.append(f"  {rel} ({line_count} lines)")
print("\n".join(lines))
PYEOF
)"

SPEC_CONTENT="$(cat "${SPEC_FILE}")"
IDIOMS_CONTENT="$(cat "${IDIOMS_FILE}")"

PLANNER_BRIEF="You are the architect choosing a bead-graph shape for a coding task.

Below is (1) a library of choreography idioms — the shapes you may choose from,
(2) the design doc for the task, (3) the starting-state directory tree (paths +
line counts).

Pick exactly one idiom from the library, then produce the concrete bead graph
that realizes it for this task. Each bead is a unit of work for one worker.

# Idiom library

${IDIOMS_CONTENT}

# Design doc (task spec)

${SPEC_CONTENT}

# Starting-state tree

${TREE_SUMMARY}

# Output

Output ONLY a single JSON object on stdout. No prose, no markdown fences.

Schema:
{
  \"idiom\": one of {\"fanout\", \"synthesis-pipeline\", \"critique-loop\", \"two-phase-commit\", \"gatekeeper\"},
  \"beads\": [
    {
      \"id\": \"b1\",                       // unique string id
      \"title\": \"...\",                   // short imperative title
      \"persona\": \"worker\" | \"merger\" | \"critic\" | \"reviewer\" | \"contract-author\" | \"implementer\",
      \"scope_files\": [\"path/to/file\"],  // files this bead is allowed to write
      \"deps\": [\"b-of-other\"]            // ids of beads this one depends on
    }
  ],
  \"reasoning\": \"1-2 sentence justification\"
}

Constraints:
- Persona names: use \"worker\" for parallel implementers in fanout / synthesis-pipeline; \"merger\" for the synthesis bead; \"critic\" / \"reviewer\" for evaluator-style beads; \"contract-author\" + \"implementer\" for two-phase-commit.
- Bead ids may be anything unique; deps reference ids.
- Don't invent files that aren't in the starting-state tree as scope.
${EXTRA_INSTRUCTION:+

# Additional constraint

${EXTRA_INSTRUCTION}
}"

echo "[graph-shape] Invoking planner claude -p…" >&2

PLANNER_EXIT=0
claude -p "${PLANNER_BRIEF}" \
    --model "${PLANNER_MODEL}" \
    --dangerously-skip-permissions \
    --output-format json \
    > "${PLANNER_OUT}" \
    2> "${PLANNER_ERR}" || PLANNER_EXIT=$?

if [[ "$PLANNER_EXIT" -ne 0 ]]; then
    echo "[graph-shape] planner claude exited ${PLANNER_EXIT}" >&2
fi

# Parse planner output → graph.json, then score against reference-graph.json.
python3 - "${PLANNER_OUT}" "${REFERENCE_FILE}" "${GRAPH_JSON}" "${SCORE_JSON}" <<'PYEOF'
import json, sys, collections

planner_out_path, reference_path, graph_path, score_path = sys.argv[1:5]


def find_balanced_json(text):
    if not text: return None
    for i, ch in enumerate(text):
        if ch != "{": continue
        depth, in_str, esc = 0, False, False
        for j in range(i, len(text)):
            c = text[j]
            if in_str:
                if esc: esc = False
                elif c == "\\": esc = True
                elif c == '"': in_str = False
                continue
            if c == '"': in_str = True; continue
            if c == "{": depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    try:
                        obj = json.loads(text[i:j+1])
                        if isinstance(obj, dict) and "idiom" in obj and "beads" in obj:
                            return obj
                    except Exception: pass
                    break
    return None


def parse_planner(path):
    """Returns (graph_dict_or_None, tokens_in, tokens_out, model, fallback_used)."""
    try:
        raw = open(path).read().strip()
        wrapper = json.loads(raw)
    except Exception:
        return None, 0, 0, "", True
    usage = wrapper.get("usage") or {}
    tin, tout = usage.get("input_tokens", 0) or 0, usage.get("output_tokens", 0) or 0
    cache_create = usage.get("cache_creation_input_tokens", 0) or 0
    cache_read   = usage.get("cache_read_input_tokens", 0) or 0
    model_usage = wrapper.get("modelUsage") or {}
    model = next(iter(model_usage), "") if model_usage else ""
    text = wrapper.get("result") or wrapper.get("text") or raw
    fallback = False
    obj = None
    stripped = text.strip()
    if stripped.startswith("{") and stripped.endswith("}"):
        try:
            cand = json.loads(stripped)
            if isinstance(cand, dict) and "idiom" in cand and "beads" in cand:
                obj = cand
        except Exception: pass
    if obj is None:
        obj = find_balanced_json(text)
        if obj is not None: fallback = True
    return obj, int(tin), int(tout), model, fallback, int(cache_create), int(cache_read)


def topology(beads):
    """(roots, sinks, max_depth, max_fan_in)."""
    ids = {b["id"] for b in beads}
    deps_of = {b["id"]: [d for d in b.get("deps", []) if d in ids] for b in beads}
    children = collections.defaultdict(list)
    for b in beads:
        for d in deps_of[b["id"]]:
            children[d].append(b["id"])
    roots = [bid for bid, ds in deps_of.items() if not ds]
    sinks = [bid for bid in ids if not children[bid]]
    # depth via memoized DFS (DAG assumption).
    depth_cache = {}
    def depth(bid, stack=()):
        if bid in depth_cache: return depth_cache[bid]
        if bid in stack: return 0  # cycle guard
        ds = deps_of.get(bid, [])
        d = 1 + max((depth(x, stack + (bid,)) for x in ds), default=0)
        depth_cache[bid] = d
        return d
    max_depth = max((depth(bid) for bid in ids), default=0)
    max_fan_in = max((len(deps_of[bid]) for bid in ids), default=0)
    return len(roots), len(sinks), max_depth, max_fan_in


def _match_single(graph, ref_idiom, ref_personas, ref_shape, persona_aliases):
    got_idiom = (graph.get("idiom") or "").strip()
    idiom_match = got_idiom == ref_idiom

    beads = graph.get("beads") or []
    def canon(p): return persona_aliases.get(p, p)
    counter = collections.Counter(canon((b.get("persona") or "worker").strip()) for b in beads)
    persona_match = all(counter.get(p, 0) == n for p, n in ref_personas.items())

    roots, sinks, depth, fan_in = topology(beads)
    shape_actual = {"roots": roots, "sinks": sinks, "max_depth": depth, "fan_in_to_sink": fan_in}
    shape_match = all(shape_actual.get(k) == v for k, v in ref_shape.items())

    return {
        "idiom_match":   idiom_match,
        "persona_match": persona_match,
        "shape_match":   shape_match,
        "all_three":     idiom_match and persona_match and shape_match,
        "got_idiom":     got_idiom,
        "got_personas":  dict(counter),
        "got_shape":     shape_actual,
    }


def score(graph, reference):
    """Score against primary reference + any alternates.

    Returns:
      overall_pass: True iff primary reference matches (strict).
      structurally_sound: True iff primary OR any alternate matches.
      matched_alternate: name of matched alternate (or "primary" / None).
    """
    persona_aliases = reference.get("persona_aliases", {})
    primary = _match_single(
        graph,
        reference["idiom"],
        reference.get("personas", {}),
        reference.get("shape", {}),
        persona_aliases,
    )

    matched_alt = "primary" if primary["all_three"] else None
    alt_details = []
    for alt in reference.get("idiom_alternates", []) or []:
        # Each alt has its own persona_aliases override (optional).
        alt_aliases = {**persona_aliases, **(alt.get("persona_aliases") or {})}
        m = _match_single(
            graph,
            alt["idiom"],
            alt.get("personas", {}),
            alt.get("shape", {}),
            alt_aliases,
        )
        alt_details.append({"name": alt.get("name", alt["idiom"]), **m})
        if matched_alt is None and m["all_three"]:
            matched_alt = alt.get("name", alt["idiom"])

    structurally_sound = matched_alt is not None

    return {
        # Strict-reference fields (back-compat).
        "idiom_match":     primary["idiom_match"],
        "persona_match":   primary["persona_match"],
        "shape_match":     primary["shape_match"],
        "overall_pass":    primary["all_three"],
        "got_idiom":       primary["got_idiom"],
        "got_personas":    primary["got_personas"],
        "got_shape":       primary["got_shape"],
        "ref_idiom":       reference["idiom"],
        "ref_personas":    reference.get("personas", {}),
        "ref_shape":       reference.get("shape", {}),
        # New: structural-soundness fields.
        "structurally_sound": structurally_sound,
        "matched_alternate":  matched_alt,
        "alternate_details":  alt_details,
    }


graph, tin, tout, model, fallback, cache_create, cache_read = parse_planner(planner_out_path)

with open(reference_path) as fh:
    reference = json.load(fh)

if graph is None:
    sc = {
        "idiom_match": False, "persona_match": False, "shape_match": False,
        "overall_pass": False, "parse_failed": True,
        "structurally_sound": False, "matched_alternate": None,
    }
    graph_out = {"_parse_failed": True}
else:
    sc = score(graph, reference)
    graph_out = graph

with open(graph_path, "w") as fh: json.dump(graph_out, fh, indent=2); fh.write("\n")
with open(score_path, "w") as fh: json.dump(sc, fh, indent=2); fh.write("\n")

# Stash tokens/model in a sidecar so the bash side can read it without re-parsing planner.out.
sidecar = {
    "planner_tokens_in":  tin,
    "planner_tokens_out": tout,
    "planner_model":      model,
    "parser_fallback":    fallback,
    "planner_cache_creation_input_tokens": cache_create,
    "planner_cache_read_input_tokens":     cache_read,
}
with open(score_path + ".meta", "w") as fh: json.dump(sidecar, fh, indent=2); fh.write("\n")

print(f"[graph-shape] idiom_match={sc.get('idiom_match')} persona_match={sc.get('persona_match')} shape_match={sc.get('shape_match')} overall={sc.get('overall_pass')}")
PYEOF

# Emit driver-compatible results JSON. The "visible_pass/total" axis is repurposed:
# pass = 1 if overall_pass, total = 3 (idiom + persona + shape sub-scores summed).
RESULTS_FILE="${OUTPUT_DIR}/results-${RUN_ID}.json"

python3 - "${SCORE_JSON}" "${GRAPH_JSON}" "${RESULTS_FILE}" "${RUN_ID}" "${CASE_ID}" "${PLANNER_EXIT}" <<'PYEOF'
import json, sys
score_path, graph_path, results_path, run_id, case_id, planner_exit = sys.argv[1:7]
sc = json.load(open(score_path))
meta = json.load(open(score_path + ".meta"))
graph = json.load(open(graph_path))

sub_pass = sum(1 for k in ("idiom_match","persona_match","shape_match") if sc.get(k))

result = {
    "run_id":          run_id,
    "case_id":         case_id,
    "pattern":         "graph-shape",
    "wall_clock_secs": 0.0,  # driver fills its own wall measurement; we don't double-count
    "tokens_in":       int(meta["planner_tokens_in"]),
    "tokens_out":      int(meta["planner_tokens_out"]),
    "cache_creation_input_tokens": int(meta.get("planner_cache_creation_input_tokens", 0)),
    "cache_read_input_tokens":     int(meta.get("planner_cache_read_input_tokens", 0)),
    "visible_pass":    sub_pass,
    "visible_total":   3,
    "hidden_pass":     1 if sc.get("overall_pass") else 0,
    "hidden_total":    1,
    "existing_pass":   0,
    "existing_total":  0,
    "exit_code":       0 if sc.get("overall_pass") else 1,
    "planner_model":   meta["planner_model"],
    "graph_idiom":     sc.get("got_idiom", ""),
    "ref_idiom":       sc.get("ref_idiom", ""),
    "idiom_match":     bool(sc.get("idiom_match")),
    "persona_match":   bool(sc.get("persona_match")),
    "shape_match":     bool(sc.get("shape_match")),
    "structurally_sound": bool(sc.get("structurally_sound")),
    "matched_alternate":  sc.get("matched_alternate"),
    "_meta": {
        "planner_exit":           int(planner_exit),
        "parser_fallback":        bool(meta.get("parser_fallback")),
        "parse_failed":           bool(sc.get("parse_failed", False)),
        "got_personas":           sc.get("got_personas", {}),
        "ref_personas":           sc.get("ref_personas", {}),
        "got_shape":              sc.get("got_shape", {}),
        "ref_shape":              sc.get("ref_shape", {}),
    },
}
with open(results_path, "w") as fh: json.dump(result, fh, indent=2); fh.write("\n")
print(json.dumps(result, indent=2))
PYEOF

echo "[graph-shape] Results: ${RESULTS_FILE}" >&2
exit 0
