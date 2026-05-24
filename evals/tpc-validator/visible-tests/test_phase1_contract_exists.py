"""
Visible test: asserts that after Phase 1, tests/test_contract.py exists
and is non-trivial (contains at least 5 test functions).
"""
import ast
import os
import pathlib
import sys
import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _find_worktree_root() -> pathlib.Path:
    """Locate the worktree root.

    The scorer invokes pytest with PYTHONPATH=<worktree>, so we can look for
    the worktree in sys.path entries that contain a 'tests/' subdirectory.
    Also tries cwd (works when running from the worktree directly).
    """
    # Try PYTHONPATH entries first (what the scorer uses)
    pythonpath = os.environ.get("PYTHONPATH", "")
    for entry in pythonpath.split(os.pathsep):
        if not entry:
            continue
        p = pathlib.Path(entry)
        if (p / "tests").is_dir():
            return p

    # Fall back to cwd (for direct invocation from worktree)
    cwd = pathlib.Path(os.getcwd())
    if (cwd / "tests").is_dir():
        return cwd

    # Last resort: search sys.path
    for entry in sys.path:
        if not entry:
            continue
        p = pathlib.Path(entry)
        if (p / "tests").is_dir():
            return p

    return cwd  # give up; tests will fail with a clear message


def _find_contract_file() -> pathlib.Path:
    return _find_worktree_root() / "tests" / "test_contract.py"


def _count_test_functions(path: pathlib.Path) -> int:
    """Parse the file and count functions/methods named test_*."""
    source = path.read_text(encoding="utf-8")
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return 0

    count = 0
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if node.name.startswith("test_"):
                count += 1
    return count


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

MIN_TEST_COUNT = 5


def test_contract_file_exists():
    """tests/test_contract.py must exist after Phase 1."""
    contract_file = _find_contract_file()
    assert contract_file.exists(), (
        f"Phase 1 did not produce tests/test_contract.py "
        f"(looked at {contract_file})"
    )


def test_contract_file_non_empty():
    """tests/test_contract.py must be non-empty."""
    contract_file = _find_contract_file()
    if not contract_file.exists():
        pytest.skip("contract file absent — covered by test_contract_file_exists")
    assert contract_file.stat().st_size > 0, "test_contract.py exists but is empty"


def test_contract_has_enough_test_functions():
    """tests/test_contract.py must contain at least 5 test_* functions."""
    contract_file = _find_contract_file()
    if not contract_file.exists():
        pytest.skip("contract file absent — covered by test_contract_file_exists")
    count = _count_test_functions(contract_file)
    assert count >= MIN_TEST_COUNT, (
        f"test_contract.py has only {count} test_* function(s); "
        f"need at least {MIN_TEST_COUNT}"
    )
