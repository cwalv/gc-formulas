"""``ConflictError`` — raised when a request conflicts with the
current state of the target resource (e.g. concurrent edit, duplicate
unique key).

Worker: this stub is intentionally incomplete. To finish it you must:

1. Add a new variant to :class:`ErrorCode` in ``codes.py`` (e.g.
   ``CONFLICT``).
2. Register this class in ``registry.py`` under that variant.
3. Implement the class below: extend :class:`BaseError`, return your
   new variant from the ``code`` property.
"""

from __future__ import annotations

from .base import BaseError


class ConflictError(BaseError):
    pass  # TODO: implement — add ErrorCode variant, register, return it from `code`.
