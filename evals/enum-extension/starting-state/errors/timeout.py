"""``TimeoutError`` — raised when an operation exceeded its time
budget. This is the application-level timeout, not the builtin
``TimeoutError`` from the runtime.

Worker: this stub is intentionally incomplete. To finish it you must:

1. Add a new variant to :class:`ErrorCode` in ``codes.py`` (e.g.
   ``TIMEOUT``).
2. Register this class in ``registry.py`` under that variant.
3. Implement the class below: extend :class:`BaseError`, return your
   new variant from the ``code`` property.
"""

from __future__ import annotations

from .base import BaseError


class TimeoutError(BaseError):  # noqa: A001 — package-local alias for the builtin
    pass  # TODO: implement — add ErrorCode variant, register, return it from `code`.
