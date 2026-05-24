"""Baseline tests for the abstract :class:`BaseError` contract.

These tests pin behaviour of the unmodified scaffolding — they pass
against the starting state and must keep passing after workers fill
in their classes. Workers extend the package; they don't refactor the
base contract.
"""

from __future__ import annotations

import pytest

from errors import BaseError, ERROR_REGISTRY, ErrorCode, lookup, register


# --- ErrorCode sentinel -----------------------------------------------------


def test_unknown_sentinel_is_zero() -> None:
    """``UNKNOWN`` is reserved for "no code"; its integer value is 0."""
    assert ErrorCode.UNKNOWN.value == 0
    assert int(ErrorCode.UNKNOWN) == 0


# --- BaseError abstract contract --------------------------------------------


def test_base_error_is_abstract() -> None:
    """``BaseError`` cannot be instantiated directly — ``code`` is
    abstract and must be supplied by a subclass."""
    with pytest.raises(TypeError):
        BaseError(message="oops")  # type: ignore[abstract]


def test_concrete_subclass_with_code_works() -> None:
    """A subclass that supplies ``code`` is instantiable and round-trips
    through :meth:`to_dict` and :meth:`__str__`."""

    class DummyError(BaseError):
        @property
        def code(self) -> ErrorCode:
            return ErrorCode.UNKNOWN

    err = DummyError(message="boom")
    assert err.message == "boom"
    assert err.code is ErrorCode.UNKNOWN
    assert err.to_dict() == {"code": 0, "message": "boom"}
    assert str(err) == "UNKNOWN: boom"


# --- Registry helpers -------------------------------------------------------


def test_registry_starts_empty_at_module_import() -> None:
    """Before any concrete error module is imported, the registry only
    contains entries registered by already-imported modules — none in
    the starting state."""
    # In the starting state, no concrete error class has registered itself.
    # After workers implement their classes, this count will rise.
    # We pin a *minimum* invariant: ``UNKNOWN`` is never auto-registered
    # (it's a sentinel, not a class identity).
    assert ErrorCode.UNKNOWN not in ERROR_REGISTRY


def test_register_and_lookup_round_trip() -> None:
    """``register`` then ``lookup`` returns the registered class."""

    class TempError(BaseError):
        @property
        def code(self) -> ErrorCode:
            return ErrorCode.UNKNOWN

    # Save/restore the registry slot so this test doesn't leak.
    sentinel = object()
    saved = ERROR_REGISTRY.get(ErrorCode.UNKNOWN, sentinel)
    try:
        register(ErrorCode.UNKNOWN, TempError)
        assert lookup(ErrorCode.UNKNOWN) is TempError
    finally:
        if saved is sentinel:
            ERROR_REGISTRY.pop(ErrorCode.UNKNOWN, None)
        else:
            ERROR_REGISTRY[ErrorCode.UNKNOWN] = saved  # type: ignore[assignment]


def test_register_duplicate_raises() -> None:
    """Registering two distinct classes for the same code is an error."""

    class A(BaseError):
        @property
        def code(self) -> ErrorCode:
            return ErrorCode.UNKNOWN

    class B(BaseError):
        @property
        def code(self) -> ErrorCode:
            return ErrorCode.UNKNOWN

    sentinel = object()
    saved = ERROR_REGISTRY.get(ErrorCode.UNKNOWN, sentinel)
    try:
        register(ErrorCode.UNKNOWN, A)
        with pytest.raises(ValueError):
            register(ErrorCode.UNKNOWN, B)
        # Re-registering the *same* class is idempotent (not an error).
        assert register(ErrorCode.UNKNOWN, A) is A
    finally:
        if saved is sentinel:
            ERROR_REGISTRY.pop(ErrorCode.UNKNOWN, None)
        else:
            ERROR_REGISTRY[ErrorCode.UNKNOWN] = saved  # type: ignore[assignment]
