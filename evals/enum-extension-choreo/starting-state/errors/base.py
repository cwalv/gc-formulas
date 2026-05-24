"""Base contract for application-level errors.

Every concrete error in this package extends :class:`BaseError`. The
contract is intentionally tiny: a class-level :pyattr:`code` linking the
class to its :class:`ErrorCode` variant, and an instance-level
:pyattr:`message` describing what went wrong.

Callers serialise errors via :meth:`BaseError.to_dict` to ship them
over the wire; the :class:`ErrorCode` value (an int) is stable across
versions while the message is free-form human text.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any

from .codes import ErrorCode


@dataclass
class BaseError(ABC):
    """Abstract base class for all concrete errors.

    Subclasses MUST:

    - Override the :pyattr:`code` property to return a member of
      :class:`ErrorCode`. The variant should be specific to the
      subclass (e.g. ``ErrorCode.NOT_FOUND`` for ``NotFoundError``).
    - Register themselves in
      :data:`errors.registry.ERROR_REGISTRY` so callers can look up
      the class by code without importing it directly.

    Subclasses inherit ``__str__`` and :meth:`to_dict` from this base;
    they should NOT override those unless they have a strong reason.
    The dataclass shape (``message: str``) is fixed so serialisation
    stays consistent across the package.
    """

    message: str = ""

    @property
    @abstractmethod
    def code(self) -> ErrorCode:
        """Return the :class:`ErrorCode` variant identifying this error."""

    def to_dict(self) -> dict[str, Any]:
        """Serialise to a JSON-safe ``dict``.

        The shape is ``{"code": <int>, "message": <str>}`` — callers
        can ``json.dumps`` the result directly. The ``code`` field is
        the *integer* value of the enum variant (stable across enum
        renames), not the variant's name.
        """
        return {"code": int(self.code), "message": self.message}

    def __str__(self) -> str:
        """Human-readable form: ``"<CODE_NAME>: <message>"``.

        The code name (not int) appears first so logs are scannable.
        ``str(err)`` is intended for diagnostics, not wire format —
        prefer :meth:`to_dict` when sending across a boundary.
        """
        return f"{self.code.name}: {self.message}"


__all__ = ["BaseError"]
