"""``ValidationError`` — raised when caller-supplied input fails
shape, type, or constraint checks.

Worker: this stub is intentionally incomplete. To finish it you must:

1. Add a new variant to :class:`ErrorCode` in ``codes.py`` (e.g.
   ``VALIDATION``).
2. Register this class in ``registry.py`` under that variant.
3. Implement the class below: extend :class:`BaseError`, return your
   new variant from the ``code`` property.
"""

from __future__ import annotations

from .base import BaseError


class ValidationError(BaseError):
    pass  # TODO: implement — add ErrorCode variant, register, return it from `code`.
