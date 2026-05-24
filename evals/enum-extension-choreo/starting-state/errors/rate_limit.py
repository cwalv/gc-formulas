"""``RateLimitError`` — raised when the caller has exceeded the
allowed request rate and should back off and retry.

Worker: this stub is intentionally incomplete. To finish it you must:

1. Add a new variant to :class:`ErrorCode` in ``codes.py`` (e.g.
   ``RATE_LIMIT``).
2. Register this class in ``registry.py`` under that variant.
3. Implement the class below: extend :class:`BaseError`, return your
   new variant from the ``code`` property.
"""

from __future__ import annotations

from .base import BaseError


class RateLimitError(BaseError):
    pass  # TODO: implement — add ErrorCode variant, register, return it from `code`.
