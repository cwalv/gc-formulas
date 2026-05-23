"""Central registry of validators.

The registry maps short names ("email", "iban", ...) to their
:class:`Validator` instances. Callers go through the registry rather
than importing concrete classes directly, so a downstream system can
swap an implementation without touching call sites.
"""

from __future__ import annotations

from .base import Validator
from .credit_card import CreditCardValidator
from .email import EmailValidator
from .iban import IBANValidator
from .isbn import ISBNValidator
from .phone import PhoneValidator
from .semver import SemverValidator
from .url import URLValidator


_REGISTRY: dict[str, Validator] = {
    "credit_card": CreditCardValidator(),
    "email": EmailValidator(),
    "iban": IBANValidator(),
    "isbn": ISBNValidator(),
    "phone": PhoneValidator(),
    "semver": SemverValidator(),
    "url": URLValidator(),
}


def get(name: str) -> Validator:
    """Return the validator registered under ``name``.

    Raises ``KeyError`` if no validator is registered under that name.
    """
    try:
        return _REGISTRY[name]
    except KeyError as exc:
        raise KeyError(
            f"No validator named {name!r}; "
            f"known: {sorted(_REGISTRY)}"
        ) from exc


def names() -> list[str]:
    """Return the sorted list of registered validator names."""
    return sorted(_REGISTRY)


def all_validators() -> list[Validator]:
    """Return all registered validators in name-sorted order."""
    return [_REGISTRY[n] for n in names()]


__all__ = ["get", "names", "all_validators"]
