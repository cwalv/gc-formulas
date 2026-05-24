"""Application error taxonomy.

Re-exports the abstract :class:`BaseError`, the :class:`ErrorCode`
enum, the shared registry, and each concrete error class. Importing
this package is enough to populate :data:`ERROR_REGISTRY` (each
concrete module registers itself at import time).
"""

from .base import BaseError
from .codes import ErrorCode
from .conflict import ConflictError
from .not_found import NotFoundError
from .rate_limit import RateLimitError
from .registry import ERROR_REGISTRY, lookup, register
from .timeout import TimeoutError
from .unauthorized import UnauthorizedError
from .validation import ValidationError

__all__ = [
    "BaseError",
    "ConflictError",
    "ERROR_REGISTRY",
    "ErrorCode",
    "NotFoundError",
    "RateLimitError",
    "TimeoutError",
    "UnauthorizedError",
    "ValidationError",
    "lookup",
    "register",
]
