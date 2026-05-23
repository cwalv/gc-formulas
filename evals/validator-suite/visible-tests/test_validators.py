"""Visible success criteria.

These tests cover the spec's literal requirements per validator. The
agent sees them as part of the success target; the job is to make
them pass without breaking ``starting-state/tests/``.

There is typically one positive plus one or two key negatives per
validator. Hidden tests probe additional edge cases not enumerated
here.
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
)


# --- Email ------------------------------------------------------------------


def test_email_rejects_consecutive_dots_in_local() -> None:
    r = EmailValidator().validate("a..b@example.com")
    assert not r.valid
    assert r.reason in {Reason.BAD_FORMAT, Reason.BAD_CHARSET}


def test_email_rejects_all_digit_tld() -> None:
    r = EmailValidator().validate("user@example.123")
    assert not r.valid


def test_email_accepts_plus_addressing() -> None:
    assert EmailValidator().validate("user+tag@example.com").valid


# --- Phone ------------------------------------------------------------------


def test_phone_accepts_uk_country_code_44() -> None:
    # +44 then 9 digits — total 11 digits, in [7,15].
    assert PhoneValidator().validate("+442071838750").valid


def test_phone_rejects_unknown_country_code() -> None:
    # 999 isn't in the allow-list.
    r = PhoneValidator().validate("+9991234567")
    assert not r.valid
    assert r.reason is Reason.UNKNOWN_COUNTRY


def test_phone_rejects_spaces_inside() -> None:
    r = PhoneValidator().validate("+1 415 555 2671")
    assert not r.valid


# --- Credit-card ------------------------------------------------------------


def test_credit_card_accepts_valid_luhn() -> None:
    # Standard Visa test PAN, passes Luhn.
    assert CreditCardValidator().validate("4111111111111111").valid


def test_credit_card_rejects_failed_luhn() -> None:
    # Flip last digit of a valid Luhn -> fails.
    r = CreditCardValidator().validate("4111111111111112")
    assert not r.valid
    assert r.reason is Reason.BAD_CHECKSUM


# --- IBAN -------------------------------------------------------------------


def test_iban_accepts_valid_gb() -> None:
    assert IBANValidator().validate("GB29NWBK60161331926819").valid


def test_iban_rejects_unknown_country() -> None:
    # ZZ isn't in the country table.
    r = IBANValidator().validate("ZZ29NWBK60161331926819")
    assert not r.valid
    assert r.reason is Reason.UNKNOWN_COUNTRY


def test_iban_rejects_failed_checksum() -> None:
    # Tweak one body char of the valid GB IBAN -> mod-97 fails.
    r = IBANValidator().validate("GB29NWBK60161331926810")
    assert not r.valid
    assert r.reason is Reason.BAD_CHECKSUM


# --- ISBN -------------------------------------------------------------------


def test_isbn_accepts_valid_13() -> None:
    # Clean Code by Robert Martin — ISBN-13 9780132350884 is the real
    # one; the hyphenated form below is canonical group-aware spacing.
    assert ISBNValidator().validate("978-0-13-235088-4").valid


def test_isbn_rejects_failed_13_checksum() -> None:
    r = ISBNValidator().validate("9780132350880")  # last digit wrong
    assert not r.valid
    assert r.reason is Reason.BAD_CHECKSUM


def test_isbn_accepts_valid_10_with_x() -> None:
    # 020161622X passes ISBN-10 (Knuth Vol 1, 2nd ed)
    assert ISBNValidator().validate("020161622X").valid


# --- Semver -----------------------------------------------------------------


def test_semver_accepts_prerelease() -> None:
    assert SemverValidator().validate("1.0.0-alpha.1").valid


def test_semver_accepts_build_metadata() -> None:
    assert SemverValidator().validate("1.0.0+20130313144700").valid


def test_semver_rejects_leading_zero_in_major() -> None:
    r = SemverValidator().validate("01.2.3")
    assert not r.valid
    assert r.reason is Reason.BAD_FORMAT


# --- URL --------------------------------------------------------------------


def test_url_accepts_http_with_port() -> None:
    assert URLValidator().validate("http://example.com:8080/path?q=1").valid


def test_url_rejects_unknown_scheme() -> None:
    r = URLValidator().validate("javascript:alert(1)")
    assert not r.valid
    # Naive parser hits BAD_FORMAT before scheme check; spec wants UNKNOWN_SCHEME
    # only when there *is* a scheme. We accept either, depending on shape.
    assert r.reason in {Reason.UNKNOWN_SCHEME, Reason.BAD_FORMAT}


def test_url_rejects_unknown_scheme_with_separator() -> None:
    r = URLValidator().validate("gopher://example.com")
    assert not r.valid
    assert r.reason is Reason.UNKNOWN_SCHEME
