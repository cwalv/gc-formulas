"""IBAN validator (naive starting implementation).

Shape-only: 2 letter country code, 2 check digits, then a body of
alphanumerics. The full spec requires per-country length validation
*and* the ISO 13616 mod-97 checksum — not yet implemented.
"""

from __future__ import annotations

from .base import Reason, Result, Validator, fail, ok


class IBANValidator(Validator):
    """Validate an International Bank Account Number.

    Naive starting behaviour — structural shape only.
    """

    name = "iban"

    def validate(self, value: object) -> Result:
        if not isinstance(value, str):
            return fail(Reason.WRONG_TYPE, f"expected str, got {type(value).__name__}")
        if not value:
            return fail(Reason.EMPTY)
        compact = value.replace(" ", "").upper()
        if len(compact) < 15:
            return fail(Reason.TOO_SHORT)
        if len(compact) > 34:
            return fail(Reason.TOO_LONG)
        # First two chars country, next two check digits, rest alnum.
        if not compact[:2].isalpha():
            return fail(Reason.BAD_FORMAT, "first two chars must be country letters")
        if not compact[2:4].isdigit():
            return fail(Reason.BAD_FORMAT, "chars 3-4 must be check digits")
        if not compact[4:].isalnum():
            return fail(Reason.BAD_CHARSET, "body must be alphanumeric")
        return ok()
