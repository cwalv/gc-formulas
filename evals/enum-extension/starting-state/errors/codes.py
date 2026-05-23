"""Canonical taxonomy of error codes.

Every concrete error class is paired with a member of
:class:`ErrorCode`. The integer value is the stable wire-format
identifier; the *name* is the in-code identifier callers branch on.

Workers extending this package add their own variants here. Pick
distinct, non-overlapping integer values and keep the naming
convention consistent (SCREAMING_SNAKE_CASE). The sentinel
``UNKNOWN = 0`` stays reserved for "we don't have a code for this".
"""

from __future__ import annotations

from enum import IntEnum


class ErrorCode(IntEnum):
    """Stable integer codes for application errors.

    ``UNKNOWN`` is the only pre-defined variant — it is reserved for
    legacy data or for the rare case where a callsite genuinely
    cannot classify a failure. Concrete error classes MUST define
    their own variant here and reference it from their ``code``
    property.
    """

    UNKNOWN = 0
    # Workers: add new variants below. Pick distinct integer values
    # and use SCREAMING_SNAKE_CASE names. Don't reorder or renumber
    # existing variants — the integer is the wire-format contract.


__all__ = ["ErrorCode"]
