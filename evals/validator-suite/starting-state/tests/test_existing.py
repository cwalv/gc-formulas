"""Baseline tests covering the naive starting-state behaviour.

These all pass against the unmodified fixture; they must keep passing
after the agent improves the validators (the agent's work is an
*extension* of behaviour, not a regression of what already works).

Each test below pins behaviour the naive validator already produces
correctly. The hard cases live in ``visible-tests/`` and
``hidden-tests/``.
"""

from __future__ import annotations

import pytest

from validators import (
    CreditCardValidator,
    EmailValidator,
    IBANValidator,
    ISBNValidator,
    PhoneValidator,
    Reason,
    SemverValidator,
    URLValidator,
    get,
    names,
)


# --- Cross-validator shape --------------------------------------------------


def test_registry_lists_all_seven() -> None:
    assert names() == [
        "credit_card",
        "email",
        "iban",
        "isbn",
        "phone",
        "semver",
        "url",
    ]


def test_all_validators_have_a_name() -> None:
    for n in names():
        assert get(n).name == n


# --- Email ------------------------------------------------------------------


def test_email_accepts_simple() -> None:
    assert EmailValidator().validate("alice@example.com").valid


def test_email_rejects_empty() -> None:
    r = EmailValidator().validate("")
    assert not r.valid
    assert r.reason is Reason.EMPTY


def test_email_rejects_missing_at() -> None:
    assert not EmailValidator().validate("no-at-sign.example.com").valid


# --- Phone ------------------------------------------------------------------


def test_phone_accepts_international() -> None:
    assert PhoneValidator().validate("+14155552671").valid


def test_phone_rejects_missing_plus() -> None:
    r = PhoneValidator().validate("14155552671")
    assert not r.valid
    assert r.reason is Reason.BAD_FORMAT


# --- Credit-card -------------------------------------------------------------


def test_credit_card_accepts_16_digits() -> None:
    # naive: any 16 digits pass; Luhn comes later
    assert CreditCardValidator().validate("4111111111111111").valid


def test_credit_card_strips_spaces() -> None:
    assert CreditCardValidator().validate("4111 1111 1111 1111").valid


def test_credit_card_rejects_letters() -> None:
    r = CreditCardValidator().validate("4111aaaa11111111")
    assert not r.valid
    assert r.reason is Reason.BAD_CHARSET


# --- IBAN -------------------------------------------------------------------


def test_iban_accepts_shape() -> None:
    # GB-style shape; checksum comes later
    assert IBANValidator().validate("GB29NWBK60161331926819").valid


def test_iban_rejects_short() -> None:
    # Naive impl returns TOO_SHORT; a length-aware impl may instead
    # return BAD_FORMAT (GB is a known country with a fixed length).
    # Either is a valid rejection for an obviously-too-short input.
    r = IBANValidator().validate("GB29")
    assert not r.valid
    assert r.reason in {Reason.TOO_SHORT, Reason.BAD_FORMAT}


# --- ISBN -------------------------------------------------------------------


def test_isbn_accepts_13_shape() -> None:
    # 13-digit shape; full checksum validation comes later, but this
    # particular ISBN happens to also pass mod-10 so the test stays
    # green both before and after the agent's improvement.
    assert ISBNValidator().validate("9780306406157").valid


def test_isbn_accepts_10_with_x_check() -> None:
    # 020161622X happens to also pass mod-11; stays green both before
    # and after the agent's improvement.
    assert ISBNValidator().validate("020161622X").valid


def test_isbn_rejects_wrong_length() -> None:
    r = ISBNValidator().validate("12345")
    assert not r.valid
    assert r.reason is Reason.BAD_FORMAT


# --- Semver -----------------------------------------------------------------


def test_semver_accepts_basic() -> None:
    assert SemverValidator().validate("1.2.3").valid


def test_semver_rejects_two_parts() -> None:
    r = SemverValidator().validate("1.2")
    assert not r.valid
    assert r.reason is Reason.BAD_FORMAT


# --- URL --------------------------------------------------------------------


def test_url_accepts_https() -> None:
    assert URLValidator().validate("https://example.com").valid


def test_url_rejects_missing_scheme_sep() -> None:
    r = URLValidator().validate("example.com")
    assert not r.valid
    assert r.reason is Reason.BAD_FORMAT
