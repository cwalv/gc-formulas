"""Phone-number validator (naive starting implementation).

E.164-ish: starts with ``+``, followed by digits. The full spec
requires country-code awareness (length per country, etc.) — not yet
enforced.
"""

from __future__ import annotations

from .base import Reason, Result, Validator, fail, ok


class PhoneValidator(Validator):
    """Validate a phone number in international format.

    Naive starting behaviour — only the structural shape, no
    country-specific length/range rules yet.
    """

    name = "phone"

    def validate(self, value: object) -> Result:
        if not isinstance(value, str):
            return fail(Reason.WRONG_TYPE, f"expected str, got {type(value).__name__}")
        if not value:
            return fail(Reason.EMPTY)
        if not value.startswith("+"):
            return fail(Reason.BAD_FORMAT, "must start with '+'")
        digits = value[1:]
        if not digits.isdigit():
            return fail(Reason.BAD_CHARSET, "only digits allowed after '+'")
        if len(digits) < 4:
            return fail(Reason.TOO_SHORT)
        if len(digits) > 15:
            return fail(Reason.TOO_LONG)
        return ok()
