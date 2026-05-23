"""Hidden quality-axis tests — cross-file invariants.

The scorer runs these; the agent never sees them. They probe the kind
of subtle inconsistency that creeps in when several workers extend
shared state independently: enum value collisions, missing registry
entries, naming-convention drift, round-trip mismatches.

Visible tests already cover "each class works in isolation". These
focus on "they all fit together".
"""

from __future__ import annotations

import re

import pytest

from errors import (
    BaseError,
    ConflictError,
    ERROR_REGISTRY,
    ErrorCode,
    NotFoundError,
    RateLimitError,
    TimeoutError,
    UnauthorizedError,
    ValidationError,
)


# All six concrete error classes this case defines. The hidden tests
# treat this list as authoritative — if a worker swapped class names
# the import above already fails, surfacing the mismatch.
_CONCRETE_ERROR_CLASSES: list[type[BaseError]] = [
    ConflictError,
    NotFoundError,
    RateLimitError,
    TimeoutError,
    UnauthorizedError,
    ValidationError,
]


# --- Enum integrity ---------------------------------------------------------


def test_error_code_values_are_unique() -> None:
    """No two ``ErrorCode`` members share an integer value.

    ``IntEnum`` silently aliases duplicates (the second name becomes
    an alias for the first), so we check ``__members__`` (which keeps
    aliases) against ``list(ErrorCode)`` (which doesn't).
    """
    declared_names = [
        name for name, _ in ErrorCode.__members__.items()
    ]
    canonical_names = [member.name for member in ErrorCode]
    assert sorted(declared_names) == sorted(canonical_names), (
        f"ErrorCode has aliases (duplicate values): "
        f"declared={declared_names}, canonical={canonical_names}"
    )


def test_error_code_has_more_than_just_unknown() -> None:
    """Workers must have added at least one variant beyond the
    ``UNKNOWN`` sentinel — one per concrete class."""
    non_sentinel = [c for c in ErrorCode if c is not ErrorCode.UNKNOWN]
    assert len(non_sentinel) >= len(_CONCRETE_ERROR_CLASSES)


def test_error_code_names_are_screaming_snake_case() -> None:
    """Enum variant names follow ``[A-Z][A-Z0-9_]*`` (no lowercase,
    no leading digit, no leading underscore)."""
    pattern = re.compile(r"^[A-Z][A-Z0-9_]*$")
    bad = [name for name in ErrorCode.__members__ if not pattern.fullmatch(name)]
    assert bad == [], f"non-SCREAMING_SNAKE_CASE enum names: {bad}"


# --- Registry integrity -----------------------------------------------------


def test_registry_exhaustive_over_non_sentinel_codes() -> None:
    """Every non-sentinel ``ErrorCode`` variant has a registered class.

    A variant in the enum with no registry entry means a caller
    decoding that integer can't recover the class — a silent gap.
    """
    missing = [
        code for code in ErrorCode
        if code is not ErrorCode.UNKNOWN and code not in ERROR_REGISTRY
    ]
    assert missing == [], (
        f"ErrorCode variants without a registry entry: "
        f"{[c.name for c in missing]}"
    )


def test_registry_values_are_unique_classes() -> None:
    """No two registry entries point at the same class.

    Two codes pointing at one class means the class has lost its
    1:1 binding with a variant — likely a copy-paste in registration.
    """
    classes = list(ERROR_REGISTRY.values())
    assert len(classes) == len(set(classes)), (
        f"Duplicate class registrations in ERROR_REGISTRY: "
        f"{[c.__name__ for c in classes]}"
    )


def test_registry_keys_are_error_code_members() -> None:
    """Registry keys are ``ErrorCode`` instances, not bare ints or
    strings — guards against ``ERROR_REGISTRY[404] = ...`` style
    drift."""
    bad = [k for k in ERROR_REGISTRY if not isinstance(k, ErrorCode)]
    assert bad == [], f"non-ErrorCode keys in ERROR_REGISTRY: {bad}"


def test_unknown_sentinel_not_registered() -> None:
    """``UNKNOWN`` is a sentinel, not a class identity — nothing
    should register itself under it."""
    assert ErrorCode.UNKNOWN not in ERROR_REGISTRY


# --- Per-class round-trip ---------------------------------------------------


@pytest.mark.parametrize("cls", _CONCRETE_ERROR_CLASSES)
def test_code_round_trips_through_registry(cls: type[BaseError]) -> None:
    """For each concrete class, ``registry[instance.code]`` returns
    the class itself — proves the worker registered under the same
    variant that ``code`` returns."""
    err = cls(message="x")
    assert ERROR_REGISTRY[err.code] is cls


@pytest.mark.parametrize("cls", _CONCRETE_ERROR_CLASSES)
def test_each_class_uses_distinct_code(cls: type[BaseError]) -> None:
    """Each concrete class returns a different ``ErrorCode`` variant.

    If two classes return the same variant, lookup is ambiguous —
    the registry can only point at one of them.
    """
    err = cls(message="x")
    others = [c for c in _CONCRETE_ERROR_CLASSES if c is not cls]
    other_codes = {c(message="x").code for c in others}
    assert err.code not in other_codes, (
        f"{cls.__name__} shares code {err.code.name} with another class"
    )


# --- Serialisation invariants -----------------------------------------------


@pytest.mark.parametrize("cls", _CONCRETE_ERROR_CLASSES)
def test_to_dict_code_field_is_int_not_enum(cls: type[BaseError]) -> None:
    """``to_dict()['code']`` is the integer value, not the enum
    member — the contract is JSON-safe wire format."""
    err = cls(message="x")
    d = err.to_dict()
    assert type(d["code"]) is int  # not just isinstance — IntEnum *is* int
    assert d["code"] == err.code.value


@pytest.mark.parametrize("cls", _CONCRETE_ERROR_CLASSES)
def test_str_includes_variant_name_and_message(cls: type[BaseError]) -> None:
    """``str(err)`` includes both the variant name and the message,
    in that order, separated by ``": "``."""
    err = cls(message="something failed")
    s = str(err)
    assert err.code.name in s
    assert "something failed" in s
    assert s.index(err.code.name) < s.index("something failed")
