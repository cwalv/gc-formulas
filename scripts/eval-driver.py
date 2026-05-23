#!/usr/bin/env python3
"""
eval-driver.py — runs an eval runner N times and aggregates per-run results.

Usage:
    python3 scripts/eval-driver.py --case <case-id> \
        --pattern {ralph,fanout,sectioning,orchworkers,planner,graph-shape} --n 10 [--output-dir DIR]

The driver invokes:
    bash scripts/eval-<pattern>.sh <case-id> --output-dir <dir> --run-id <run-id>

Each runner is expected to write <dir>/results-<run-id>.json matching the locked
per-run schema from epic fo-ghqjh.  If the runner exits non-zero the run is
recorded as failed (exit_code != 0) but the driver continues.

For --pattern planner (epic fo-6i6mt.2), the aggregate additionally reports
the per-pattern selection distribution under "planner_choices", e.g.:
    {"orchworkers": 8, "fanout": 2, "ralph": 0}

Aggregate JSON is written to:
    <output-dir>/aggregate-<pattern>-<case>-<timestamp>.json
and also emitted on stdout.
"""

import argparse
import collections
import json
import pathlib
import statistics
import subprocess
import sys
import time


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser(description="Run an eval pattern N times and aggregate results.")
    p.add_argument("--case", required=True, help="Eval case ID (e.g. cancel-method)")
    p.add_argument(
        "--pattern",
        required=True,
        help="Runner pattern name (ralph, fanout, sectioning, orchworkers, planner, graph-shape)",
    )
    p.add_argument("--n", type=int, required=True, help="Number of runs")
    p.add_argument(
        "--output-dir",
        default="/tmp/eval-runs",
        help="Directory for per-run result files and the aggregate (default: /tmp/eval-runs)",
    )
    return p.parse_args()


def run_id_for(pattern: str, case_id: str, index: int) -> str:
    ts = time.strftime("%Y%m%d-%H%M%S")
    return f"{pattern}-{case_id}-{ts}-{index:02d}"


def invoke_runner(
    pattern: str,
    case_id: str,
    run_id: str,
    output_dir: pathlib.Path,
    script_dir: pathlib.Path,
) -> tuple[int, float]:
    """
    Call bash scripts/eval-<pattern>.sh <case-id> --output-dir <dir> --run-id <run-id>.
    Returns (exit_code, wall_clock_secs).
    """
    runner = script_dir / f"eval-{pattern}.sh"
    cmd = [
        "bash",
        str(runner),
        case_id,
        "--output-dir",
        str(output_dir),
        "--run-id",
        run_id,
    ]
    t0 = time.monotonic()
    try:
        result = subprocess.run(cmd, capture_output=False)
        rc = result.returncode
    except Exception as exc:
        # Runner not found or couldn't start — treat as hard failure (rc=127)
        print(f"  [runner error] {exc}", file=sys.stderr)
        rc = 127
    elapsed = time.monotonic() - t0
    return rc, elapsed


def load_result(output_dir: pathlib.Path, run_id: str, rc: int, elapsed: float) -> dict:
    """
    Try to load <output-dir>/results-<run-id>.json.
    If absent or malformed, synthesise a failure record so the driver never crashes.
    """
    path = output_dir / f"results-{run_id}.json"
    if path.exists():
        try:
            with path.open() as fh:
                data = json.load(fh)
            # Back-fill exit_code/wall_clock if the runner omitted them (defensive)
            data.setdefault("exit_code", rc)
            data.setdefault("wall_clock_secs", elapsed)
            return data
        except json.JSONDecodeError as exc:
            print(f"  [warn] could not parse {path}: {exc}", file=sys.stderr)

    # Synthesise a failure record
    return {
        "run_id": run_id,
        "case_id": "",
        "pattern": "",
        "wall_clock_secs": elapsed,
        "tokens_in": 0,
        "tokens_out": 0,
        "visible_pass": 0,
        "visible_total": 0,
        "hidden_pass": 0,
        "hidden_total": 0,
        "existing_pass": 0,
        "existing_total": 0,
        "exit_code": rc if rc != 0 else 1,  # ensure it counts as failed
    }


def aggregate(case_id: str, pattern: str, results: list[dict]) -> dict:
    n = len(results)

    wall_clocks = [r["wall_clock_secs"] for r in results]
    tokens_in   = [r["tokens_in"] for r in results]
    tokens_out  = [r["tokens_out"] for r in results]

    # visible_pass_rate: [median_pass, median_total]
    vis_pass    = sorted(r["visible_pass"] for r in results)
    vis_total   = sorted(r["visible_total"] for r in results)
    median_vp   = statistics.median(vis_pass)
    median_vt   = statistics.median(vis_total)

    # hidden_pass_rate: [median_pass, median_total]
    hid_pass    = sorted(r.get("hidden_pass", 0) for r in results)
    hid_total   = sorted(r.get("hidden_total", 0) for r in results)
    median_hp   = statistics.median(hid_pass)
    median_ht   = statistics.median(hid_total)

    # all_passed_count: runs where visible_pass == visible_total AND exit_code == 0
    all_passed = sum(
        1
        for r in results
        if r["exit_code"] == 0 and r["visible_pass"] == r["visible_total"]
    )

    agg = {
        "case_id": case_id,
        "pattern": pattern,
        "n_runs": n,
        "median_wall_clock_secs": statistics.median(wall_clocks),
        "mean_tokens_in": statistics.mean(tokens_in) if tokens_in else 0.0,
        "mean_tokens_out": statistics.mean(tokens_out) if tokens_out else 0.0,
        "visible_pass_rate": [median_vp, median_vt],
        "hidden_pass_rate": [median_hp, median_ht],
        "all_passed_count": all_passed,
    }

    # For the planner pattern, also report the distribution of pattern choices
    # so it's obvious from the aggregate alone "planner chose orchworkers 8/10
    # times for validator-suite" (acceptance criterion 4, epic fo-6i6mt.2).
    if pattern == "graph-shape":
        # Per-dimension breakdown so the aggregate shows e.g. "idiom 9/10,
        # persona 7/10, shape 6/10, overall 5/10" — distinguishes which axis
        # the planner gets wrong.
        agg["graph_shape_breakdown"] = {
            "idiom_match":   sum(1 for r in results if r.get("idiom_match")),
            "persona_match": sum(1 for r in results if r.get("persona_match")),
            "shape_match":   sum(1 for r in results if r.get("shape_match")),
            "overall":       sum(1 for r in results if r.get("exit_code") == 0),
            "structurally_sound": sum(1 for r in results if r.get("structurally_sound")),
        }
        # Distribution of which reference (primary or named alternate) matched.
        alt_counter: collections.Counter[str] = collections.Counter()
        for r in results:
            m = r.get("matched_alternate")
            alt_counter[m if m else "__no_match__"] += 1
        agg["matched_alternates"] = dict(sorted(alt_counter.items(), key=lambda kv: (-kv[1], kv[0])))

    if pattern == "planner":
        counter: collections.Counter[str] = collections.Counter()
        for r in results:
            choice = r.get("planner_choice") or ""
            if choice:
                counter[choice] += 1
            else:
                counter["__missing__"] += 1
        # Sort by count desc, then name asc for stable output.
        agg["planner_choices"] = dict(
            sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))
        )

    return agg


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    args = parse_args()
    output_dir = pathlib.Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # Resolve script dir relative to this file so the driver works from any cwd
    script_dir = pathlib.Path(__file__).parent.resolve()

    results: list[dict] = []
    n = args.n

    for i in range(1, n + 1):
        run_id = run_id_for(args.pattern, args.case, i)
        rc, elapsed = invoke_runner(args.pattern, args.case, run_id, output_dir, script_dir)
        print(f"[{i}/{n}] {run_id} rc={rc} wall={elapsed:.1f}s", file=sys.stderr)
        result = load_result(output_dir, run_id, rc, elapsed)
        results.append(result)

    agg = aggregate(args.case, args.pattern, results)

    ts = time.strftime("%Y%m%d-%H%M%S")
    agg_path = output_dir / f"aggregate-{args.pattern}-{args.case}-{ts}.json"
    with agg_path.open("w") as fh:
        json.dump(agg, fh, indent=2)
    print(f"[driver] aggregate saved to {agg_path}", file=sys.stderr)

    print(json.dumps(agg, indent=2))


if __name__ == "__main__":
    main()
