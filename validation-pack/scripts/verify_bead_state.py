#!/usr/bin/env python3
"""verify_bead_state.py — assert the final bead DAG matches an expected predicate.

Usage (normal mode):
    python3 verify_bead_state.py --scenario <id>

    Loads the predicate from  fixtures/<id>-expected.json,
    queries live bd state via subprocess, and compares.

Usage (self-test mode):
    python3 verify_bead_state.py --self-test

    Does NOT touch live bd. Instead reads synthetic state from
    fixtures/self-test-state.json and predicate from
    fixtures/self-test-expected.json, then runs the same assertion
    logic. Used to sanity-check the harness decoupled from a real scenario.

Predicate schema (fixtures/<scenario>-expected.json):
{
    "closed_in_order": [
        {"bead_id": "...", "reason": "..."},
        ...
    ],
    "open": [
        {"bead_id": "..."},
        ...
    ],
    "hooked": [
        {"bead_id": "..."},
        ...
    ]
}

- closed_in_order: beads that must be closed with a matching reason, in the
  specified order (by close timestamp ascending). Extra closed beads beyond
  those listed are tolerated unless they appear out of order relative to the
  listed ones.
- open: beads that must currently be in open state.
- hooked: beads that must currently be in hooked (claimed) state.

Synthetic state schema (fixtures/self-test-state.json):
{
    "closed": [
        {"bead_id": "...", "reason": "...", "closed_at": "<ISO8601>"},
        ...
    ],
    "open": [{"bead_id": "..."}, ...],
    "hooked": [{"bead_id": "..."}, ...]
}
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Locate pack root
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
PACK_ROOT = SCRIPT_DIR.parent  # scripts/ is one level inside the pack


# ---------------------------------------------------------------------------
# bd queries
# ---------------------------------------------------------------------------

def _run_bd(*args: str) -> list[dict]:
    """Run a bd command and return parsed JSON output."""
    cmd = ["bd", *args, "--json"]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR: bd command failed: {' '.join(cmd)}", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        sys.exit(1)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        print(f"ERROR: bd output is not valid JSON: {exc}", file=sys.stderr)
        print(result.stdout[:500], file=sys.stderr)
        sys.exit(1)


def query_live_state() -> dict:
    """Return a state dict shaped like the synthetic-state schema."""
    closed_raw = _run_bd("list", "--status=closed")
    open_raw   = _run_bd("list", "--status=open")
    hooked_raw = _run_bd("list", "--status=hooked")

    def _extract_closed(item: dict) -> dict:
        return {
            "bead_id": item.get("id") or item.get("bead_id", ""),
            "reason":  item.get("close_reason") or item.get("reason", ""),
            "closed_at": item.get("closed_at", ""),
        }

    def _extract_id(item: dict) -> dict:
        return {"bead_id": item.get("id") or item.get("bead_id", "")}

    return {
        "closed": sorted(
            [_extract_closed(i) for i in closed_raw],
            key=lambda x: x["closed_at"],
        ),
        "open":   [_extract_id(i) for i in open_raw],
        "hooked": [_extract_id(i) for i in hooked_raw],
    }


def load_synthetic_state() -> dict:
    path = PACK_ROOT / "fixtures" / "self-test-state.json"
    with path.open() as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# Predicate engine
# ---------------------------------------------------------------------------

def assert_state(state: dict, predicate: dict) -> bool:
    """Walk the predicate spec and check against state.

    Returns True if all assertions pass; prints PASS/FAIL lines and returns
    False on first failure.
    """
    all_passed = True

    # --- closed_in_order ---
    if "closed_in_order" in predicate:
        expected_closed = predicate["closed_in_order"]
        # Build an ordered list of (bead_id -> index in expected) from state
        actual_closed = state.get("closed", [])
        actual_by_id = {item["bead_id"]: item for item in actual_closed}

        # Verify each expected bead is closed with the right reason
        for exp in expected_closed:
            bead_id = exp["bead_id"]
            exp_reason = exp["reason"]
            if bead_id not in actual_by_id:
                print(f"FAIL: bead {bead_id!r} expected closed but not found in closed list",
                      file=sys.stderr)
                all_passed = False
                continue
            actual_reason = actual_by_id[bead_id].get("reason", "")
            if actual_reason != exp_reason:
                print(
                    f"FAIL: bead {bead_id!r} close reason mismatch: "
                    f"expected={exp_reason!r} actual={actual_reason!r}",
                    file=sys.stderr,
                )
                all_passed = False
                continue
            print(f"PASS: bead {bead_id!r} closed with reason={exp_reason!r}")

        # Verify ordering: the expected beads must appear in the same relative
        # order within the actual closed list (by closed_at position).
        expected_ids = [e["bead_id"] for e in expected_closed]
        # Filter actual to only the expected bead_ids, preserving order
        actual_order = [
            item["bead_id"]
            for item in actual_closed
            if item["bead_id"] in set(expected_ids)
        ]
        if actual_order != expected_ids:
            print(
                f"FAIL: closed order mismatch: "
                f"expected={expected_ids} actual={actual_order}",
                file=sys.stderr,
            )
            all_passed = False
        else:
            print(f"PASS: closed_in_order sequence matches")

    # --- open ---
    if "open" in predicate:
        actual_open_ids = {item["bead_id"] for item in state.get("open", [])}
        for exp in predicate["open"]:
            bead_id = exp["bead_id"]
            if bead_id not in actual_open_ids:
                print(f"FAIL: bead {bead_id!r} expected open but not found", file=sys.stderr)
                all_passed = False
            else:
                print(f"PASS: bead {bead_id!r} is open")

    # --- hooked ---
    if "hooked" in predicate:
        actual_hooked_ids = {item["bead_id"] for item in state.get("hooked", [])}
        for exp in predicate["hooked"]:
            bead_id = exp["bead_id"]
            if bead_id not in actual_hooked_ids:
                print(f"FAIL: bead {bead_id!r} expected hooked but not found", file=sys.stderr)
                all_passed = False
            else:
                print(f"PASS: bead {bead_id!r} is hooked")

    return all_passed


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Assert bead DAG state against an expected predicate."
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--scenario",
        metavar="ID",
        help="Scenario id; loads fixtures/<ID>-expected.json and queries live bd.",
    )
    mode.add_argument(
        "--self-test",
        action="store_true",
        help="Load synthetic state and predicate from fixtures/self-test-*.json; no live bd.",
    )
    args = parser.parse_args()

    if args.self_test:
        state_path     = PACK_ROOT / "fixtures" / "self-test-state.json"
        predicate_path = PACK_ROOT / "fixtures" / "self-test-expected.json"
        print(f"[self-test] loading state from {state_path}")
        print(f"[self-test] loading predicate from {predicate_path}")
        with state_path.open() as f:
            state = json.load(f)
        with predicate_path.open() as f:
            predicate = json.load(f)
    else:
        scenario_id = args.scenario
        predicate_path = PACK_ROOT / "fixtures" / f"{scenario_id}-expected.json"
        if not predicate_path.exists():
            print(
                f"ERROR: fixture not found: {predicate_path}",
                file=sys.stderr,
            )
            sys.exit(2)
        with predicate_path.open() as f:
            predicate = json.load(f)
        state = query_live_state()

    passed = assert_state(state, predicate)
    if passed:
        print("PASS — all assertions satisfied")
        sys.exit(0)
    else:
        print("FAIL — one or more assertions failed (see stderr)", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
