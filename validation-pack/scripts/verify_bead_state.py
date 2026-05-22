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
        {"bead_id": "...", "reason_one_of": ["reason-a", "reason-b"]},
        ...
    ],
    "closed_unordered": [
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
    ],
    "metadata_match": [
        {"bead_id": "...", "key": "...", "value": "..."},
        ...
    ],
    "assignee_match": [
        {"bead_id": "...", "value": "<expected-assignee>"},
        ...
    ],
    "notes_contains": [
        {"bead_id": "...", "value": "<substring>"},
        ...
    ],
    "comments_contain": [
        {"bead_id": "...", "value": "<substring>"},
        ...
    ],
    "manual_check": [
        {"kind": "manual_check", "bead": "...", "field": "comments"|"notes", "max_len": 200},
        ...
    ]
}

- closed_in_order: beads that must be closed with a matching reason, in the
  specified order (by close timestamp ascending). Extra closed beads beyond
  those listed are tolerated unless they appear out of order relative to the
  listed ones. Each entry uses either "reason" (exact match) or "reason_one_of"
  (membership in the given list); specifying both in the same entry is an error.
- closed_unordered: beads that must be closed with a matching reason; no
  ordering constraint among them. Per-bead checks identical to closed_in_order
  entries but the ordering assertion is skipped.
- open: beads that must currently be in open state.
- hooked: beads that must currently be in hooked (claimed) state.
- metadata_match: each listed bead must have metadata[key] == value. Fetched
  on demand via `bd show <id> --json` (not eagerly with the list queries).
- assignee_match: each listed bead's assignee field must equal value. Fetched
  on demand via `bd show <id> --json`.
- notes_contains: each listed bead's notes field must contain value as a
  substring. Fetched on demand via `bd show <id> --json`.
- comments_contain: each listed bead must have at least one comment whose
  text contains value as a substring. Reads `bd show <id> --json | .[0].comments`
  (array of objects with a `text` field, or list of strings).
- manual_check: non-asserting predicate. Records a truncated snippet of
  the named field ("comments" or "notes") alongside any fail output for the
  same bead, or as an INFO line when the assertion passes. Helps operators
  see what the bead actually contains without re-running bd manually.
  Schema: {"kind": "manual_check", "bead": "<id>", "field": "comments"|"notes",
           "max_len": <int>}  (max_len defaults to 200).
  When a notes_contains or comments_contain assertion fails for the same bead,
  the snippet appears indented under the FAIL line. Use alongside assertions
  for surgical content inspection.

Synthetic state schema (fixtures/self-test-state.json):
{
    "closed": [
        {"bead_id": "...", "reason": "...", "closed_at": "<ISO8601>"},
        ...
    ],
    "open": [{"bead_id": "..."}, ...],
    "hooked": [{"bead_id": "..."}, ...],
    "bead_details": {
        "<bead_id>": {
            "metadata": {"key": "value", ...},
            "notes": "...",
            "comments": ["comment-text-1", "comment-text-2", ...]
        },
        ...
    }
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


def query_bead_metadata(bead_id: str) -> "dict | None":
    """Fetch a single bead's metadata dict via `bd show <id> --json`.

    Returns the metadata dict or None if the field is absent/empty.
    Exits the process on bd command failure.
    """
    rows = _run_bd("show", bead_id)
    if not rows:
        return None
    item = rows[0] if isinstance(rows, list) else rows
    meta = item.get("metadata")
    if not meta:
        return None
    return meta


def query_bead_notes(bead_id: str) -> str:
    """Fetch a single bead's notes field via `bd show <id> --json`.

    Returns the notes string, or empty string if absent.
    Exits the process on bd command failure.
    """
    rows = _run_bd("show", bead_id)
    if not rows:
        return ""
    item = rows[0] if isinstance(rows, list) else rows
    return item.get("notes") or ""


def query_bead_comments(bead_id: str) -> list[str]:
    """Fetch a single bead's comment texts via `bd show <id> --json`.

    Returns a list of comment-text strings (may be empty).
    comments field is either a list of objects with a "text" key, or a list
    of plain strings. Both shapes are normalised to a list of strings.
    Exits the process on bd command failure.
    """
    rows = _run_bd("show", bead_id)
    if not rows:
        return []
    item = rows[0] if isinstance(rows, list) else rows
    raw = item.get("comments") or []
    texts: list[str] = []
    for entry in raw:
        if isinstance(entry, dict):
            texts.append(entry.get("text") or "")
        else:
            texts.append(str(entry))
    return texts


def load_synthetic_state() -> dict:
    path = PACK_ROOT / "fixtures" / "self-test-state.json"
    with path.open() as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# Predicate engine helpers
# ---------------------------------------------------------------------------

def _check_reason(bead_id: str, exp: dict, actual_by_id: dict) -> "tuple[bool, str]":
    """Check close reason for one expected entry against actual_by_id.

    Returns (passed: bool, display_string: str).  The display string is
    suitable for a PASS/FAIL line.  Enforces mutual exclusion of "reason" and
    "reason_one_of" in the same entry.

    `bd list --status=closed` excludes some closed ephemeral wisps in
    practice (depends on the bd version's list filtering). If the bead is
    not in the listed `actual_by_id`, fall back to `bd show <id>` to read
    its status + close_reason directly. That call sees ephemerals too.
    """
    if "reason" in exp and "reason_one_of" in exp:
        msg = (
            f"FAIL: bead {bead_id!r} entry has both 'reason' and 'reason_one_of' — "
            "only one is allowed"
        )
        return False, msg

    if bead_id not in actual_by_id:
        # Fallback: probe the bead directly. Per-bead lookup is reliable
        # for ephemeral wisps that don't surface in `bd list --status=closed`.
        rows = _run_bd("show", bead_id)
        bead = (rows[0] if isinstance(rows, list) and rows
                else rows if isinstance(rows, dict) else None)
        if not isinstance(bead, dict):
            return False, f"FAIL: bead {bead_id!r} expected closed but not found"
        if bead.get("status") != "closed":
            return False, (
                f"FAIL: bead {bead_id!r} expected closed; "
                f"bd show reports status={bead.get('status')!r}"
            )
        actual_by_id[bead_id] = {
            "bead_id": bead_id,
            "reason": bead.get("close_reason", "") or "",
            "closed_at": bead.get("closed_at", "") or "",
        }

    actual_reason = actual_by_id[bead_id].get("reason", "")

    if "reason" in exp:
        exp_reason = exp["reason"]
        if actual_reason != exp_reason:
            return False, (
                f"FAIL: bead {bead_id!r} close reason mismatch: "
                f"expected={exp_reason!r} actual={actual_reason!r}"
            )
        return True, f"PASS: bead {bead_id!r} closed with reason={exp_reason!r}"

    if "reason_one_of" in exp:
        allowed = exp["reason_one_of"]
        if not isinstance(allowed, list):
            return False, (
                f"FAIL: bead {bead_id!r} 'reason_one_of' must be a list, "
                f"got {type(allowed).__name__!r}"
            )
        if actual_reason not in allowed:
            return False, (
                f"FAIL: bead {bead_id!r} close reason {actual_reason!r} "
                f"not in reason_one_of={allowed!r}"
            )
        return True, (
            f"PASS: bead {bead_id!r} closed with reason={actual_reason!r} "
            f"(one of {allowed!r})"
        )

    return False, f"FAIL: bead {bead_id!r} entry has neither 'reason' nor 'reason_one_of'"


# ---------------------------------------------------------------------------
# Predicate engine
# ---------------------------------------------------------------------------

def assert_state(state: dict, predicate: dict, *, live: bool = True) -> bool:
    """Walk the predicate spec and check against state.

    Returns True if all assertions pass; prints PASS/FAIL lines and returns
    False on first failure.

    When live=True (normal mode), metadata_match, assignee_match,
    notes_contains, and comments_contain predicates call bd show via subprocess.
    When live=False (self-test mode), they read from state["bead_details"] instead.
    """
    all_passed = True

    # ------------------------------------------------------------------ #
    # Helpers for on-demand bead details (metadata + notes).              #
    # In self-test mode these read from state["bead_details"]; in live    #
    # mode they call bd show.                                              #
    # ------------------------------------------------------------------ #
    _bead_details_cache: dict = {}  # cache for live mode

    def _get_metadata(bead_id: str) -> dict:
        if not live:
            details = state.get("bead_details", {}).get(bead_id, {})
            return details.get("metadata", {}) or {}
        if bead_id not in _bead_details_cache:
            _bead_details_cache[bead_id] = query_bead_metadata(bead_id) or {}
        return _bead_details_cache[bead_id]

    def _get_notes(bead_id: str) -> str:
        if not live:
            details = state.get("bead_details", {}).get(bead_id, {})
            return details.get("notes", "") or ""
        return query_bead_notes(bead_id)

    def _get_comments(bead_id: str) -> list[str]:
        if not live:
            details = state.get("bead_details", {}).get(bead_id, {})
            raw = details.get("comments") or []
            texts: list[str] = []
            for entry in raw:
                if isinstance(entry, dict):
                    texts.append(entry.get("text") or "")
                else:
                    texts.append(str(entry))
            return texts
        return query_bead_comments(bead_id)

    # --- closed_in_order ---
    if "closed_in_order" in predicate:
        expected_closed = predicate["closed_in_order"]
        actual_closed = state.get("closed", [])
        actual_by_id = {item["bead_id"]: item for item in actual_closed}

        for exp in expected_closed:
            bead_id = exp["bead_id"]
            passed, msg = _check_reason(bead_id, exp, actual_by_id)
            if not passed:
                print(msg, file=sys.stderr)
                all_passed = False
            else:
                print(msg)

        # Verify ordering: expected beads must appear in the same relative
        # order within the actual closed list (by closed_at position).
        expected_ids = [e["bead_id"] for e in expected_closed]
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

    # --- closed_unordered ---
    if "closed_unordered" in predicate:
        expected_unordered = predicate["closed_unordered"]
        actual_closed = state.get("closed", [])
        actual_by_id = {item["bead_id"]: item for item in actual_closed}

        for exp in expected_unordered:
            bead_id = exp["bead_id"]
            passed, msg = _check_reason(bead_id, exp, actual_by_id)
            if not passed:
                print(msg, file=sys.stderr)
                all_passed = False
            else:
                print(msg)
        # No ordering assertion — any permutation is valid.

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

    # --- metadata_match ---
    if "metadata_match" in predicate:
        for exp in predicate["metadata_match"]:
            bead_id = exp["bead_id"]
            key = exp["key"]
            expected_value = exp["value"]
            metadata = _get_metadata(bead_id)
            actual_value = metadata.get(key)
            if actual_value != expected_value:
                print(
                    f"FAIL: bead {bead_id!r} metadata[{key!r}] mismatch: "
                    f"expected={expected_value!r} actual={actual_value!r}",
                    file=sys.stderr,
                )
                all_passed = False
            else:
                print(
                    f"PASS: bead {bead_id!r} metadata[{key!r}]={expected_value!r}"
                )

    # --- assignee_match ---
    if "assignee_match" in predicate:
        for exp in predicate["assignee_match"]:
            bead_id = exp["bead_id"]
            expected_value = exp["value"]
            if not live:
                details = state.get("bead_details", {}).get(bead_id, {})
                actual_value = details.get("assignee")
            else:
                rows = _run_bd("show", bead_id)
                if not rows:
                    actual_value = None
                else:
                    item = rows[0] if isinstance(rows, list) else rows
                    actual_value = item.get("assignee")
            if actual_value != expected_value:
                print(
                    f"FAIL: bead {bead_id!r} assignee mismatch: "
                    f"expected={expected_value!r} actual={actual_value!r}",
                    file=sys.stderr,
                )
                all_passed = False
            else:
                print(
                    f"PASS: bead {bead_id!r} assignee={expected_value!r}"
                )

    # ------------------------------------------------------------------ #
    # Failure-mode classifier                                              #
    # Runs after any individual assertion failure to print one diagnostic  #
    # line describing the bead's observable state. Covers four cases:      #
    #   - not claimed + not closed  → agent never picked it up             #
    #   - claimed but not closed    → agent started, didn't finish         #
    #   - closed but no comments    → agent closed without recording work  #
    #   - has comments, content mismatch → agent worked but wrote wrong    #
    # ------------------------------------------------------------------ #
    def _bead_status_for_diag(bead_id: str) -> dict:
        """Return lightweight status dict for the classifier.

        In self-test mode reads from state; in live mode calls bd show.
        Returns keys: status, assignee, comment_count.
        """
        if not live:
            details = state.get("bead_details", {}).get(bead_id, {})
            assignee = details.get("assignee") or ""
            comments = details.get("comments") or []
            # Infer status from synthetic state lists
            closed_ids = {c["bead_id"] for c in state.get("closed", [])}
            hooked_ids = {h["bead_id"] for h in state.get("hooked", [])}
            open_ids = {o["bead_id"] for o in state.get("open", [])}
            if bead_id in closed_ids:
                status = "closed"
            elif bead_id in hooked_ids:
                status = "hooked"
            elif bead_id in open_ids:
                status = "open"
            else:
                status = "unknown"
            return {"status": status, "assignee": assignee, "comment_count": len(comments)}
        # Live: fetch from bd show
        try:
            rows = _run_bd("show", bead_id)
            item = rows[0] if isinstance(rows, list) and rows else {}
            assignee = item.get("assignee") or ""
            raw_comments = item.get("comments") or []
            return {
                "status": item.get("status", "unknown"),
                "assignee": assignee,
                "comment_count": len(raw_comments),
            }
        except SystemExit:
            return {"status": "unknown", "assignee": "", "comment_count": 0}

    def _print_diagnosis(bead_id: str) -> None:
        """Print one indented diagnosis line after a FAIL for bead_id."""
        d = _bead_status_for_diag(bead_id)
        status = d["status"]
        assignee = d["assignee"]
        comment_count = d["comment_count"]
        claimed = bool(assignee)

        if status != "closed" and not claimed:
            label = "never claimed"
        elif status != "closed" and claimed:
            label = "claimed but not closed"
        elif status == "closed" and comment_count == 0:
            label = "closed, no comments"
        else:
            label = f"non-empty, no match" if comment_count > 0 else "empty"

        claimed_str = "yes" if claimed else "no"
        closed_str = "yes" if status == "closed" else "no"
        print(
            f"  diagnosis: claimed={claimed_str}, closed={closed_str},"
            f" comment_count={comment_count} ({label})",
            file=sys.stderr,
        )

    # ------------------------------------------------------------------ #
    # manual_check predicate index                                         #
    # Predicates of kind="manual_check" record a field snippet alongside  #
    # fail output (or as INFO when the assertion passes). They do not     #
    # assert anything themselves — see comments_contain/notes_contains     #
    # for the asserting counterparts.                                      #
    # Schema: {"kind": "manual_check", "bead": "<id>",                    #
    #          "field": "comments"|"notes", "max_len": <int>}             #
    # ------------------------------------------------------------------ #
    _manual_checks: dict[str, list[dict]] = {}  # bead_id -> list of check specs
    for mc in predicate.get("manual_check", []):
        bid = mc.get("bead") or mc.get("bead_id", "")
        _manual_checks.setdefault(bid, []).append(mc)

    def _emit_manual_checks(bead_id: str, *, as_info: bool = False) -> None:
        """Print manual_check output for bead_id, if any checks are registered."""
        for mc in _manual_checks.get(bead_id, []):
            field = mc.get("field", "comments")
            max_len = int(mc.get("max_len", 200))
            if field == "comments":
                texts = _get_comments(bead_id)
                raw = " | ".join(texts)
            else:  # notes
                raw = _get_notes(bead_id)
            snippet = raw[:max_len]
            truncated = len(raw) > max_len
            suffix = "... (truncated)" if truncated else ""
            tag = "INFO" if as_info else "FAIL"
            print(
                f"  manual_check ({field}): {snippet!r}{suffix}",
                file=sys.stdout if as_info else sys.stderr,
            )

    # --- notes_contains ---
    if "notes_contains" in predicate:
        for exp in predicate["notes_contains"]:
            bead_id = exp["bead_id"]
            substring = exp["value"]
            notes = _get_notes(bead_id)
            if substring not in notes:
                print(
                    f"FAIL: bead {bead_id!r} notes do not contain {substring!r}",
                    file=sys.stderr,
                )
                _print_diagnosis(bead_id)
                _emit_manual_checks(bead_id, as_info=False)
                all_passed = False
            else:
                print(
                    f"PASS: bead {bead_id!r} notes contain {substring!r}"
                )
                _emit_manual_checks(bead_id, as_info=True)

    # --- comments_contain ---
    if "comments_contain" in predicate:
        for exp in predicate["comments_contain"]:
            bead_id = exp["bead_id"]
            substring = exp["value"]
            comments = _get_comments(bead_id)
            if not any(substring in text for text in comments):
                print(
                    f"FAIL: bead {bead_id!r} comments do not contain {substring!r}",
                    file=sys.stderr,
                )
                _print_diagnosis(bead_id)
                _emit_manual_checks(bead_id, as_info=False)
                all_passed = False
            else:
                print(
                    f"PASS: bead {bead_id!r} comments contain {substring!r}"
                )
                _emit_manual_checks(bead_id, as_info=True)

    # --- manual_check (standalone pass) ---
    # Emit any manual_check entries for beads not already processed above.
    # This handles manual_check-only predicates (no notes/comments assertion).
    _processed_by_above = set()
    for section in ("notes_contains", "comments_contain"):
        for exp in predicate.get(section, []):
            _processed_by_above.add(exp["bead_id"])
    for bead_id in _manual_checks:
        if bead_id not in _processed_by_above:
            _emit_manual_checks(bead_id, as_info=True)

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

    passed = assert_state(state, predicate, live=not args.self_test)
    if passed:
        print("PASS — all assertions satisfied")
        sys.exit(0)
    else:
        print("FAIL — one or more assertions failed (see stderr)", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
