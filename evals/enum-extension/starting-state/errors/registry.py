"""Central registry: ``ErrorCode`` -> concrete error class.

A caller decoding an error payload looks up the right class by
integer code via this registry, rather than maintaining its own
match-statement. Concrete error classes register themselves at
import time by calling :func:`register`.

The registry starts empty. Workers extending this package MUST add
an entry per error class.
"""

from __future__ import annotations

from .base import BaseError
from .codes import ErrorCode


ERROR_REGISTRY: dict[ErrorCode, type[BaseError]] = {}


def register(code: ErrorCode, cls: type[BaseError]) -> type[BaseError]:
    """Register ``cls`` as the handler for ``code``.

    Returns ``cls`` so the function can be used as a decorator. Raises
    :class:`ValueError` if the same code is registered twice — two
    classes claiming the same variant is a programming error, not
    something to silently overwrite.
    """
    if code in ERROR_REGISTRY:
        existing = ERROR_REGISTRY[code]
        if existing is cls:
            return cls
        raise ValueError(
            f"ErrorCode.{code.name} is already registered to "
            f"{existing.__name__}; cannot re-register to {cls.__name__}"
        )
    ERROR_REGISTRY[code] = cls
    return cls


def lookup(code: ErrorCode) -> type[BaseError]:
    """Return the class registered for ``code``.

    Raises :class:`KeyError` if no class is registered for that code.
    """
    try:
        return ERROR_REGISTRY[code]
    except KeyError as exc:
        raise KeyError(f"No error class registered for ErrorCode.{code.name}") from exc


__all__ = ["ERROR_REGISTRY", "register", "lookup"]
