#!/usr/bin/env python3
"""Mutation-rubric scorer for the choreographer eval.

Usage:
    python3 scripts/eval-mutation-scorer.py \\
        --reference  evals/enum-extension-choreo/reference-mutations.json \\
        --mutations  eval-runs/<run-id>/mutations.jsonl

Reads `reference-mutations.json` and the per-mutation log emitted by the
runner.  Scores on four axes:

    mutation_recall     -- expected mutations that occurred / expected total
    mutation_precision  -- mutations matching expected set / total mutations made
    forbidden_violations -- count of mutations matching forbidden_mutations entries
    terminal_state_ok   -- passed in from runner (bool, default true if unset)

Emits JSON to stdout:

    {
        "mutation_recall": <float>,
        "mutation_precision": <float>,
        "forbidden_violations": <int>,
        "terminal_state_ok": <bool>,
        "matched_expected": [<list of matched expected-mutation ids>],
        "missed_expected": [<list>],
        "extra_mutations": [<list of mutation indices not matching anything expected>]
    }

Semantic matching per choreographer-eval design fragment §"Scoring rubric":
  - spawn:    title regex match against the expected title_match pattern
  - human:    bead-id match on expected on_close
  - reassign: persona equality (to field, case-insensitive prefix match)
  - noop:     always counts as no-action (not scored as a mutation)

Exit 0 always — scoring errors are data, not crashes.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Matching helpers
# ---------------------------------------------------------------------------

def _match_spawn(mutation: dict, expected: dict) -> bool:
    """Return True if a spawn mutation matches the expected entry."""
    title = mutation.get("title", "")
    pattern = expected.get("title_match", "")
    if not pattern:
        return False
    try:
        return bool(re.search(pattern, title, re.IGNORECASE))
    except re.error:
        return title.lower() == pattern.lower()


def _match_human(mutation: dict, expected: dict) -> bool:
    """Return True if a human-flag mutation matches the expected entry."""
    # Match by: bead that triggered the event (on_close) OR note_match regex
    on_close = expected.get("on_close", "")
    note_match = expected.get("note_match", "")

    trigger = mutation.get("on_close_bead", "") or mutation.get("bead_id", "")
    note = mutation.get("note", "") or mutation.get("comment", "")

    if on_close and trigger and on_close == trigger:
        return True
    if note_match:
        try:
            if re.search(note_match, note, re.IGNORECASE):
                return True
        except re.error:
            pass
    return False


def _match_reassign(mutation: dict, expected: dict) -> bool:
    """Return True if a reassign mutation matches the expected entry."""
    to_expected = (expected.get("to") or "").lower()
    to_actual = (mutation.get("to") or "").lower()
    if not to_expected or not to_actual:
        return False
    # Prefix match: "evaluator" matches "validation/evaluator"
    return to_actual == to_expected or to_actual.endswith("/" + to_expected)


def _mutation_matches_expected(mutation: dict, expected: dict) -> bool:
    """Return True if mutation matches the expected entry (action + semantics)."""
    action = mutation.get("action", "")
    expected_action = expected.get("action", "")
    if action != expected_action:
        return False

    if action == "spawn":
        return _match_spawn(mutation, expected)
    elif action == "human":
        return _match_human(mutation, expected)
    elif action == "reassign":
        return _match_reassign(mutation, expected)
    elif action == "reopen":
        # Reopen matches if on_close bead matches
        on_close = expected.get("on_close", "")
        trigger = mutation.get("on_close_bead", "") or mutation.get("bead_id", "")
        return on_close == trigger if on_close else False
    elif action == "noop":
        return False  # noops are not counted as mutations for precision

    return False


def _mutation_matches_forbidden(mutation: dict, forbidden: dict) -> bool:
    """Return True if mutation matches a forbidden entry."""
    action = mutation.get("action", "")
    forbidden_action = forbidden.get("action", "")
    if action != forbidden_action:
        return False

    after = forbidden.get("after", "")
    if not after:
        return True  # action-only forbidden — any such action violates

    trigger = mutation.get("on_close_bead", "") or mutation.get("trigger_bead", "")
    return trigger == after


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Mutation-rubric scorer for the choreographer eval."
    )
    parser.add_argument(
        "--reference",
        required=True,
        help="Path to reference-mutations.json",
    )
    parser.add_argument(
        "--mutations",
        required=True,
        help="Path to mutations.jsonl (one JSON object per line, emitted by runner)",
    )
    parser.add_argument(
        "--terminal-state-ok",
        dest="terminal_state_ok",
        action="store_true",
        default=True,
        help="Pass terminal_state_ok=true (default; runner sets this)",
    )
    parser.add_argument(
        "--no-terminal-state-ok",
        dest="terminal_state_ok",
        action="store_false",
        help="Pass terminal_state_ok=false",
    )
    args = parser.parse_args()

    reference_path = Path(args.reference)
    mutations_path = Path(args.mutations)

    # Load reference
    try:
        ref = json.loads(reference_path.read_text())
    except Exception as exc:
        print(f"[mutation-scorer] Failed to load reference: {exc}", file=sys.stderr)
        _emit_zero(args.terminal_state_ok)
        return

    expected_mutations = ref.get("expected_mutations", [])
    forbidden_mutations = ref.get("forbidden_mutations", [])

    # Load actual mutations log (JSONL)
    actual_mutations: list[dict] = []
    if mutations_path.exists():
        for lineno, line in enumerate(mutations_path.read_text().splitlines(), 1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                actual_mutations.append(obj)
            except json.JSONDecodeError as exc:
                print(
                    f"[mutation-scorer] Skipping bad JSONL line {lineno}: {exc}",
                    file=sys.stderr,
                )
    else:
        print(
            f"[mutation-scorer] mutations log not found: {mutations_path}",
            file=sys.stderr,
        )

    # Filter out noops — they don't count as mutations for precision
    scored_mutations = [m for m in actual_mutations if m.get("action", "") != "noop"]

    # --- Recall: which expected mutations occurred? ---
    matched_expected_ids: list[str] = []
    missed_expected_ids: list[str] = []

    for exp in expected_mutations:
        exp_id = exp.get("id", exp.get("action", "?"))
        found = any(_mutation_matches_expected(m, exp) for m in scored_mutations)
        if found:
            matched_expected_ids.append(exp_id)
        else:
            missed_expected_ids.append(exp_id)

    total_expected = len(expected_mutations)
    matched_count = len(matched_expected_ids)
    recall = matched_count / total_expected if total_expected > 0 else 1.0

    # --- Precision: of mutations made, how many match the expected set? ---
    extra_mutation_indices: list[int] = []
    matched_mutation_set: list[int] = []  # indices into scored_mutations

    for idx, mut in enumerate(scored_mutations):
        if any(_mutation_matches_expected(mut, exp) for exp in expected_mutations):
            matched_mutation_set.append(idx)
        else:
            extra_mutation_indices.append(idx)

    total_mutations = len(scored_mutations)
    precision = (
        len(matched_mutation_set) / total_mutations if total_mutations > 0 else 1.0
    )

    # --- Forbidden violations ---
    forbidden_violations = 0
    for mut in scored_mutations:
        for forb in forbidden_mutations:
            if _mutation_matches_forbidden(mut, forb):
                forbidden_violations += 1
                break  # count bead once even if it matches multiple forbidden entries

    result = {
        "mutation_recall": round(recall, 3),
        "mutation_precision": round(precision, 3),
        "forbidden_violations": forbidden_violations,
        "terminal_state_ok": args.terminal_state_ok,
        "matched_expected": matched_expected_ids,
        "missed_expected": missed_expected_ids,
        "extra_mutations": [
            scored_mutations[i] for i in extra_mutation_indices
        ],
    }

    print(json.dumps(result, indent=2))


def _emit_zero(terminal_state_ok: bool) -> None:
    """Emit a zero-fill result on scoring infrastructure failure."""
    result = {
        "mutation_recall": 0.0,
        "mutation_precision": 0.0,
        "forbidden_violations": 0,
        "terminal_state_ok": terminal_state_ok,
        "matched_expected": [],
        "missed_expected": [],
        "extra_mutations": [],
        "_error": "scoring infrastructure failure — see stderr",
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
