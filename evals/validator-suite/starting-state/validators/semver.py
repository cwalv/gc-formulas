"""Semantic-version validator (naive starting implementation).

Triple-dotted-digits: ``MAJOR.MINOR.PATCH``. The full spec also
supports pre-release tags (``-alpha.1``) and build metadata
(``+sha.deadbeef``) per semver.org 2.0 — not yet implemented.
"""

from __future__ import annotations

from .base import Reason, Result, Validator, fail, ok


class SemverValidator(Validator):
    """Validate a semantic-version string.

    Naive starting behaviour — supports only ``MAJOR.MINOR.PATCH``
    with non-negative integer parts; rejects pre-release and build
    metadata (which the spec requires accepting).
    """

    name = "semver"

    def validate(self, value: object) -> Result:
        if not isinstance(value, str):
            return fail(Reason.WRONG_TYPE, f"expected str, got {type(value).__name__}")
        if not value:
            return fail(Reason.EMPTY)
        parts = value.split(".")
        if len(parts) != 3:
            return fail(Reason.BAD_FORMAT, "must be MAJOR.MINOR.PATCH")
        for part in parts:
            if not part.isdigit():
                return fail(Reason.BAD_FORMAT, f"non-numeric part: {part!r}")
        return ok()
