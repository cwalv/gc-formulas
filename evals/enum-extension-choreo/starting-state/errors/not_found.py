"""``NotFoundError`` — raised when a requested resource does not exist.

Worker: this stub is intentionally incomplete. To finish it you must:

1. Add a new variant to :class:`ErrorCode` in ``codes.py`` (e.g.
   ``NOT_FOUND``).
2. Register this class in ``registry.py`` under that variant.
3. Implement the class below: extend :class:`BaseError`, return your
   new variant from the ``code`` property.
"""

from __future__ import annotations

from .base import BaseError


class NotFoundError(BaseError):
    pass  # TODO: implement — add ErrorCode variant, register, return it from `code`.
