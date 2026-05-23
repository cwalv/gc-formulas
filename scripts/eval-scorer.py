#!/usr/bin/env python3
"""Scorer for plan-evals M1.

Usage:
    python3 scripts/eval-scorer.py --case-path <path> --worktree <path>

Runs three pytest suites against the worktree's modules and emits JSON:

    {
        "visible_pass": N,
        "visible_total": M,
        "hidden_pass": N,
        "hidden_total": M,
        "existing_pass": N,
        "existing_total": M
    }

Exit 0 always (test failures are data; only crash if scoring infra itself
is broken).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Pytest discovery
# ---------------------------------------------------------------------------

def _find_pytest() -> list[str]:
    """Return a command prefix that can run pytest.

    Preference order:
    1. pytest on PATH (covers the uv-tool install at ~/.local/bin/pytest)
    2. The uv-tool pytest interpreter directly
    3. Raise RuntimeError
    """
    exe = shutil.which("pytest")
    if exe:
        return [exe]

    # Fallback: known uv-tool location used on this host
    uv_pytest = os.path.expanduser("~/.local/share/uv/tools/pytest/bin/pytest")
    if os.path.isfile(uv_pytest):
        return [uv_pytest]

    raise RuntimeError(
        "pytest not found on PATH and uv-tool fallback not present. "
        "Install pytest (e.g. `uv tool install pytest`)."
    )


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

_SUMMARY_RE = re.compile(
    r"(?:(\d+) passed)?[,\s]*(?:(\d+) failed)?[,\s]*(?:(\d+) error(?:ed|s)?)?",
)
_RESULT_LINE_RE = re.compile(r"=+ (.+?) in [\d.]+s =+$", re.MULTILINE)


def _parse_counts(output: str, returncode: int) -> tuple[int, int]:
    """Return (passed, total) from pytest -q --no-header stdout.

    Handles:
      - "10 passed in 0.02s"
      - "15 failed in 0.03s"
      - "5 passed, 10 failed in 0.10s"
      - "no tests ran" / empty output / collection errors
    """
    # Find the last summary line (the one inside === ===)
    # It looks like: "=== 15 failed in 0.03s ===" or "=== 10 passed in 0.02s ==="
    matches = _RESULT_LINE_RE.findall(output)
    if matches:
        summary = matches[-1]
    else:
        # -q mode: last non-empty line is the summary
        lines = [l.strip() for l in output.splitlines() if l.strip()]
        summary = lines[-1] if lines else ""

    # "no tests ran" or truly empty
    if "no tests ran" in summary or not summary:
        return 0, 0

    m = _SUMMARY_RE.search(summary)
    if not m:
        return 0, 0

    passed = int(m.group(1)) if m.group(1) else 0
    failed = int(m.group(2)) if m.group(2) else 0
    errors = int(m.group(3)) if m.group(3) else 0

    total = passed + failed + errors
    return passed, total


# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------

def _run_pytest(
    test_path: str,
    pythonpath_dirs: list[str],
    pytest_cmd: list[str],
) -> tuple[int, int]:
    """Run pytest on *test_path* with PYTHONPATH set.

    Returns (passed, total).  Never raises — errors become (0, 0).
    """
    env = os.environ.copy()
    existing_pp = env.get("PYTHONPATH", "")
    extra = os.pathsep.join(pythonpath_dirs)
    env["PYTHONPATH"] = f"{extra}{os.pathsep}{existing_pp}" if existing_pp else extra

    try:
        result = subprocess.run(
            pytest_cmd + [test_path, "--tb=no", "-q", "--no-header"],
            capture_output=True,
            text=True,
            env=env,
        )
    except Exception as exc:  # noqa: BLE001
        print(f"[scorer] pytest invocation failed: {exc}", file=sys.stderr)
        return 0, 0

    combined = result.stdout + result.stderr
    return _parse_counts(combined, result.returncode)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="Eval scorer — runs visible + hidden + existing tests.")
    parser.add_argument("--case-path", required=True, help="Absolute path to the eval case dir (e.g. evals/cancel-method)")
    parser.add_argument("--worktree", required=True, help="Absolute path to the agent's output worktree")
    args = parser.parse_args()

    case_path = Path(args.case_path).resolve()
    worktree = Path(args.worktree).resolve()

    if not case_path.is_dir():
        print(f"[scorer] --case-path does not exist: {case_path}", file=sys.stderr)
        sys.exit(1)
    if not worktree.is_dir():
        print(f"[scorer] --worktree does not exist: {worktree}", file=sys.stderr)
        sys.exit(1)

    try:
        pytest_cmd = _find_pytest()
    except RuntimeError as exc:
        print(f"[scorer] {exc}", file=sys.stderr)
        sys.exit(1)

    # Visible tests: case-path/visible-tests/ against worktree's modules
    visible_tests = str(case_path / "visible-tests")
    visible_pass, visible_total = _run_pytest(
        visible_tests,
        pythonpath_dirs=[str(worktree)],
        pytest_cmd=pytest_cmd,
    )

    # Hidden tests: case-path/hidden-tests/ against worktree's modules (quality axis)
    hidden_tests_dir = case_path / "hidden-tests"
    if hidden_tests_dir.is_dir():
        hidden_pass, hidden_total = _run_pytest(
            str(hidden_tests_dir),
            pythonpath_dirs=[str(worktree)],
            pytest_cmd=pytest_cmd,
        )
    else:
        hidden_pass, hidden_total = 0, 0

    # Existing tests: worktree/tests/ against worktree's modules
    existing_tests = str(worktree / "tests")
    existing_pass, existing_total = _run_pytest(
        existing_tests,
        pythonpath_dirs=[str(worktree)],
        pytest_cmd=pytest_cmd,
    )

    result = {
        "visible_pass": visible_pass,
        "visible_total": visible_total,
        "hidden_pass": hidden_pass,
        "hidden_total": hidden_total,
        "existing_pass": existing_pass,
        "existing_total": existing_total,
    }
    print(json.dumps(result))


if __name__ == "__main__":
    main()
