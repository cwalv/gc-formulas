"""Base contract for validators.

All validators implement the same interface: ``validate(value) -> Result``.
The ``Result`` carries the boolean outcome plus a machine-readable
``reason`` code when invalid. Reason codes are drawn from the
:class:`Reason` enum so that callers can branch on them without
string-matching.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from enum import Enum


class Reason(str, Enum):
    """Canonical taxonomy of why a value failed validation.

    Every validator MUST use a member of this enum for its ``reason``
    field; callers rely on these codes being stable and shared. Adding
    new validators may extend this enum, but existing codes must keep
    their meaning.
    """

    OK = "ok"  # sentinel for valid results

    # Structural / shape issues
    EMPTY = "empty"
    TOO_SHORT = "too_short"
    TOO_LONG = "too_long"
    BAD_FORMAT = "bad_format"

    # Character-set issues
    BAD_CHARSET = "bad_charset"

    # Domain-specific
    BAD_CHECKSUM = "bad_checksum"
    UNKNOWN_COUNTRY = "unknown_country"
    UNKNOWN_SCHEME = "unknown_scheme"
    UNKNOWN_TLD = "unknown_tld"

    # Type-level
    WRONG_TYPE = "wrong_type"


@dataclass(frozen=True)
class Result:
    """Outcome of a single validation call.

    ``valid`` is the boolean answer. ``reason`` is :attr:`Reason.OK`
    when valid; otherwise it carries the specific reason code. The
    ``detail`` field is a free-form human-readable note — tests should
    never assert against its exact text (only its presence/absence).
    """

    valid: bool
    reason: Reason
    detail: str = ""

    def __bool__(self) -> bool:  # convenience: `if result: ...`
        return self.valid


def ok() -> Result:
    """Shorthand: a successful result."""
    return Result(valid=True, reason=Reason.OK)


def fail(reason: Reason, detail: str = "") -> Result:
    """Shorthand: a failing result with a reason code."""
    if reason is Reason.OK:
        raise ValueError("fail() called with Reason.OK")
    return Result(valid=False, reason=reason, detail=detail)


class Validator(ABC):
    """Abstract base class for all validators.

    Subclasses MUST:

    - Set :attr:`name` to a stable, short identifier (e.g. ``"email"``).
    - Implement :meth:`validate` returning a :class:`Result`.

    Subclasses SHOULD:

    - Return ``fail(Reason.WRONG_TYPE)`` for non-``str`` inputs rather
      than raising ``TypeError`` — validators are expected to be
      defensive against caller bugs.
    - Normalise leading/trailing whitespace consistently per the
      validator's spec (e.g. ``IBAN`` strips spaces; ``Email`` does
      not).
    """

    name: str = ""

    @abstractmethod
    def validate(self, value: object) -> Result:
        """Return a :class:`Result` for ``value``."""

    def is_valid(self, value: object) -> bool:
        """Convenience: bool-only answer."""
        return bool(self.validate(value))


__all__ = ["Reason", "Result", "Validator", "ok", "fail"]
