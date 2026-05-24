"""``UnauthorizedError`` — raised when the caller is not authenticated
or lacks permission for the requested operation.

Worker: this stub is intentionally incomplete. To finish it you must:

1. Add a new variant to :class:`ErrorCode` in ``codes.py`` (e.g.
   ``UNAUTHORIZED``).
2. Register this class in ``registry.py`` under that variant.
3. Implement the class below: extend :class:`BaseError`, return your
   new variant from the ``code`` property.
"""

from __future__ import annotations

from .base import BaseError


class UnauthorizedError(BaseError):
    pass  # TODO: implement — add ErrorCode variant, register, return it from `code`.
