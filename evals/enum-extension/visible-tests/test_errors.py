"""Visible success criteria — per-class behaviour.

These tests pin the spec's literal requirements for each concrete
error class. They FAIL on the starting state (workers haven't done
anything yet) and PASS once each worker has:

1. Added a variant to :class:`ErrorCode`,
2. Registered the class in :data:`ERROR_REGISTRY` under that variant,
3. Implemented the class so ``code`` returns that variant.

There is one positive instantiation test, one ``to_dict()`` shape
test, one ``__str__`` test, and one registry-lookup test per class.
"""

from __future__ import annotations

import pytest

from errors import (
    ConflictError,
    ERROR_REGISTRY,
    ErrorCode,
    NotFoundError,
    RateLimitError,
    TimeoutError,
    UnauthorizedError,
    ValidationError,
    lookup,
)


# --- NotFoundError ----------------------------------------------------------


def test_not_found_instantiable_with_code() -> None:
    err = NotFoundError(message="user 42 not found")
    assert isinstance(err.code, ErrorCode)
    assert err.code is not ErrorCode.UNKNOWN


def test_not_found_to_dict_shape() -> None:
    err = NotFoundError(message="user 42 not found")
    d = err.to_dict()
    assert set(d) == {"code", "message"}
    assert d["message"] == "user 42 not found"
    assert isinstance(d["code"], int)
    assert d["code"] == int(err.code)


def test_not_found_str_format() -> None:
    err = NotFoundError(message="user 42 not found")
    assert str(err) == f"{err.code.name}: user 42 not found"


def test_not_found_registered() -> None:
    assert lookup(NotFoundError(message="x").code) is NotFoundError


# --- UnauthorizedError ------------------------------------------------------


def test_unauthorized_instantiable_with_code() -> None:
    err = UnauthorizedError(message="token expired")
    assert isinstance(err.code, ErrorCode)
    assert err.code is not ErrorCode.UNKNOWN


def test_unauthorized_to_dict_shape() -> None:
    err = UnauthorizedError(message="token expired")
    d = err.to_dict()
    assert set(d) == {"code", "message"}
    assert d["message"] == "token expired"
    assert d["code"] == int(err.code)


def test_unauthorized_str_format() -> None:
    err = UnauthorizedError(message="token expired")
    assert str(err) == f"{err.code.name}: token expired"


def test_unauthorized_registered() -> None:
    assert lookup(UnauthorizedError(message="x").code) is UnauthorizedError


# --- ConflictError ----------------------------------------------------------


def test_conflict_instantiable_with_code() -> None:
    err = ConflictError(message="version mismatch")
    assert isinstance(err.code, ErrorCode)
    assert err.code is not ErrorCode.UNKNOWN


def test_conflict_to_dict_shape() -> None:
    err = ConflictError(message="version mismatch")
    d = err.to_dict()
    assert set(d) == {"code", "message"}
    assert d["message"] == "version mismatch"
    assert d["code"] == int(err.code)


def test_conflict_registered() -> None:
    assert lookup(ConflictError(message="x").code) is ConflictError


# --- RateLimitError ---------------------------------------------------------


def test_rate_limit_instantiable_with_code() -> None:
    err = RateLimitError(message="429 — slow down")
    assert isinstance(err.code, ErrorCode)
    assert err.code is not ErrorCode.UNKNOWN


def test_rate_limit_to_dict_shape() -> None:
    err = RateLimitError(message="429 — slow down")
    d = err.to_dict()
    assert set(d) == {"code", "message"}
    assert d["message"] == "429 — slow down"
    assert d["code"] == int(err.code)


def test_rate_limit_registered() -> None:
    assert lookup(RateLimitError(message="x").code) is RateLimitError


# --- TimeoutError -----------------------------------------------------------


def test_timeout_instantiable_with_code() -> None:
    err = TimeoutError(message="deadline exceeded")
    assert isinstance(err.code, ErrorCode)
    assert err.code is not ErrorCode.UNKNOWN


def test_timeout_to_dict_shape() -> None:
    err = TimeoutError(message="deadline exceeded")
    d = err.to_dict()
    assert set(d) == {"code", "message"}
    assert d["message"] == "deadline exceeded"
    assert d["code"] == int(err.code)


def test_timeout_registered() -> None:
    assert lookup(TimeoutError(message="x").code) is TimeoutError


# --- ValidationError --------------------------------------------------------


def test_validation_instantiable_with_code() -> None:
    err = ValidationError(message="age must be >= 0")
    assert isinstance(err.code, ErrorCode)
    assert err.code is not ErrorCode.UNKNOWN


def test_validation_to_dict_shape() -> None:
    err = ValidationError(message="age must be >= 0")
    d = err.to_dict()
    assert set(d) == {"code", "message"}
    assert d["message"] == "age must be >= 0"
    assert d["code"] == int(err.code)


def test_validation_registered() -> None:
    assert lookup(ValidationError(message="x").code) is ValidationError
