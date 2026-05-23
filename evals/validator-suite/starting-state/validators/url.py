"""URL validator (naive starting implementation).

Scheme + ``://`` + non-empty host. The full spec requires scheme
allow-listing, host validation (domain / IPv4 literal / bracketed
IPv6 literal), port-range checks, and reserved-char handling — not
yet implemented.
"""

from __future__ import annotations

from .base import Reason, Result, Validator, fail, ok


class URLValidator(Validator):
    """Validate a URL.

    Naive starting behaviour — accepts anything with a scheme,
    ``://``, and a non-empty host substring. No scheme allow-list,
    no host parsing, no port checks.
    """

    name = "url"

    def validate(self, value: object) -> Result:
        if not isinstance(value, str):
            return fail(Reason.WRONG_TYPE, f"expected str, got {type(value).__name__}")
        if not value:
            return fail(Reason.EMPTY)
        if "://" not in value:
            return fail(Reason.BAD_FORMAT, "missing scheme separator '://'")
        scheme, _, rest = value.partition("://")
        if not scheme:
            return fail(Reason.BAD_FORMAT, "missing scheme")
        if not scheme.isalpha():
            return fail(Reason.BAD_FORMAT, "scheme must be alphabetic")
        # take host as everything up to first '/' or '?' or '#'
        host = rest
        for sep in ("/", "?", "#"):
            host = host.split(sep, 1)[0]
        if not host:
            return fail(Reason.BAD_FORMAT, "missing host")
        return ok()
