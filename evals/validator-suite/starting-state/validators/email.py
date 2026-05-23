"""Email-address validator (naive starting implementation).

This is the smallest viable validator: it checks the value is a
non-empty string containing exactly one ``@`` and at least one ``.``
in the domain. The spec calls for considerably more — see
``spec.md`` for the rules this implementation does NOT yet enforce.
"""

from __future__ import annotations

from .base import Reason, Result, Validator, fail, ok


class EmailValidator(Validator):
    """Validate an email address per the suite's ``Email`` rules.

    Naive starting behaviour — only catches obviously broken inputs.
    """

    name = "email"

    def validate(self, value: object) -> Result:
        if not isinstance(value, str):
            return fail(Reason.WRONG_TYPE, f"expected str, got {type(value).__name__}")
        if not value:
            return fail(Reason.EMPTY)
        if value.count("@") != 1:
            return fail(Reason.BAD_FORMAT, "must contain exactly one '@'")
        local, _, domain = value.partition("@")
        if not local or not domain:
            return fail(Reason.BAD_FORMAT, "local and domain must be non-empty")
        if "." not in domain:
            return fail(Reason.BAD_FORMAT, "domain must contain a dot")
        return ok()
