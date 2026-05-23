"""Credit-card validator (naive starting implementation).

Length-only: 13-19 digits with the optional spaces stripped. The full
spec requires the Luhn check-digit algorithm — not yet implemented.
"""

from __future__ import annotations

from .base import Reason, Result, Validator, fail, ok


class CreditCardValidator(Validator):
    """Validate a credit-card primary account number (PAN).

    Naive starting behaviour — checks length only, no Luhn checksum
    yet and no brand-specific length rules.
    """

    name = "credit_card"

    def validate(self, value: object) -> Result:
        if not isinstance(value, str):
            return fail(Reason.WRONG_TYPE, f"expected str, got {type(value).__name__}")
        if not value:
            return fail(Reason.EMPTY)
        digits = value.replace(" ", "").replace("-", "")
        if not digits.isdigit():
            return fail(Reason.BAD_CHARSET, "only digits, spaces, hyphens allowed")
        if len(digits) < 13:
            return fail(Reason.TOO_SHORT)
        if len(digits) > 19:
            return fail(Reason.TOO_LONG)
        return ok()
