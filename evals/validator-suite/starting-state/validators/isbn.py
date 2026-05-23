"""ISBN validator (naive starting implementation).

Length-only: 10 or 13 digits with hyphens/spaces stripped. The full
spec requires the checksum (mod-11 for ISBN-10, mod-10 for ISBN-13)
— not yet implemented.
"""

from __future__ import annotations

from .base import Reason, Result, Validator, fail, ok


class ISBNValidator(Validator):
    """Validate an ISBN-10 or ISBN-13.

    Naive starting behaviour — checks length and digit charset only,
    no checksum validation yet.
    """

    name = "isbn"

    def validate(self, value: object) -> Result:
        if not isinstance(value, str):
            return fail(Reason.WRONG_TYPE, f"expected str, got {type(value).__name__}")
        if not value:
            return fail(Reason.EMPTY)
        compact = value.replace("-", "").replace(" ", "")
        if len(compact) not in (10, 13):
            return fail(Reason.BAD_FORMAT, "ISBN must be 10 or 13 chars")
        # ISBN-10 allows trailing 'X' as the check char; full validation
        # below; here we accept either all-digit or digit-with-X-suffix.
        if len(compact) == 10:
            body, check = compact[:-1], compact[-1]
            if not body.isdigit():
                return fail(Reason.BAD_CHARSET, "ISBN-10 body must be digits")
            if not (check.isdigit() or check.upper() == "X"):
                return fail(Reason.BAD_CHARSET, "ISBN-10 check must be digit or X")
        else:  # 13
            if not compact.isdigit():
                return fail(Reason.BAD_CHARSET, "ISBN-13 must be digits")
        return ok()
