"""Hidden quality-axis tests.

The scorer runs these but the agent never sees them. They probe edge
cases that *follow from* the spec but aren't enumerated explicitly,
so an agent has to reason about the rules rather than copy them.

Roughly 2-3 per validator. Patterns that explore more of the input
space (eval-optimizer with rounds, voting across attempts) should
hit more of these than one-shot ralph.
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


def test_email_rejects_leading_dot_in_local() -> None:
    r = EmailValidator().validate(".alice@example.com")
    assert not r.valid


def test_email_rejects_label_starting_with_hyphen() -> None:
    r = EmailValidator().validate("user@-example.com")
    assert not r.valid


def test_email_rejects_label_ending_with_hyphen() -> None:
    r = EmailValidator().validate("user@example-.com")
    assert not r.valid


def test_email_rejects_local_over_64_chars() -> None:
    local = "a" * 65
    r = EmailValidator().validate(f"{local}@example.com")
    assert not r.valid


def test_email_rejects_non_str() -> None:
    r = EmailValidator().validate(12345)
    assert not r.valid
    assert r.reason is Reason.WRONG_TYPE


# --- Phone ------------------------------------------------------------------


def test_phone_rejects_too_few_digits_under_known_country() -> None:
    # +1 followed by 3 digits — total 4 digits, below the 7-digit minimum.
    r = PhoneValidator().validate("+1234")
    assert not r.valid


def test_phone_accepts_short_country_code_7() -> None:
    # Russia is country code 7; total 11 digits, ok.
    assert PhoneValidator().validate("+79161234567").valid


def test_phone_rejects_letters() -> None:
    r = PhoneValidator().validate("+1ABC2345678")
    assert not r.valid


# --- Credit-card ------------------------------------------------------------


def test_credit_card_accepts_15_digit_amex_luhn() -> None:
    # 378282246310005 — Amex test PAN, 15 digits, valid Luhn.
    assert CreditCardValidator().validate("378282246310005").valid


def test_credit_card_accepts_hyphenated_formatting() -> None:
    assert CreditCardValidator().validate("4111-1111-1111-1111").valid


def test_credit_card_rejects_12_digits_even_if_luhn_passes() -> None:
    # Constructed 12-digit number; even if Luhn would pass, length is wrong.
    r = CreditCardValidator().validate("411111111111")  # 12 digits
    assert not r.valid
    assert r.reason in {Reason.TOO_SHORT, Reason.BAD_FORMAT}


# --- IBAN -------------------------------------------------------------------


def test_iban_accepts_valid_de() -> None:
    # DE89370400440532013000 — German example IBAN, valid mod-97.
    assert IBANValidator().validate("DE89370400440532013000").valid


def test_iban_accepts_with_internal_spaces() -> None:
    assert IBANValidator().validate("GB29 NWBK 6016 1331 9268 19").valid


def test_iban_rejects_wrong_length_for_known_country() -> None:
    # GB IBAN must be 22 chars; this is 21.
    r = IBANValidator().validate("GB29NWBK6016133192681")  # 21 chars
    assert not r.valid
    assert r.reason in {Reason.BAD_FORMAT, Reason.TOO_SHORT}


# --- ISBN -------------------------------------------------------------------


def test_isbn_rejects_failed_10_checksum() -> None:
    # Last char tweaked: 0201616220 doesn't satisfy mod-11.
    r = ISBNValidator().validate("0201616220")
    assert not r.valid
    assert r.reason is Reason.BAD_CHECKSUM


def test_isbn_accepts_hyphenated_13() -> None:
    # Sipser, "Introduction to the Theory of Computation" 3rd ed.
    assert ISBNValidator().validate("978-1-133-18779-0").valid


def test_isbn_rejects_lower_x_check_with_failed_sum() -> None:
    # "0201616221" — change check from X (=10) to 1 -> wrong sum.
    r = ISBNValidator().validate("0201616221")
    assert not r.valid
    assert r.reason is Reason.BAD_CHECKSUM


# --- Semver -----------------------------------------------------------------


def test_semver_accepts_prerelease_with_build() -> None:
    assert SemverValidator().validate("1.0.0-beta.2+exp.sha.5114f85").valid


def test_semver_rejects_leading_zero_numeric_prerelease() -> None:
    # Numeric pre-release identifiers must not have leading zeros.
    r = SemverValidator().validate("1.0.0-alpha.01")
    assert not r.valid


def test_semver_accepts_zero_major() -> None:
    assert SemverValidator().validate("0.0.0").valid


def test_semver_rejects_empty_prerelease_identifier() -> None:
    # 1.0.0- with nothing after, or with empty between dots.
    r = SemverValidator().validate("1.0.0-")
    assert not r.valid


# --- URL --------------------------------------------------------------------


def test_url_accepts_ipv4_host() -> None:
    assert URLValidator().validate("http://192.168.1.1/").valid


def test_url_rejects_ipv4_octet_overflow() -> None:
    r = URLValidator().validate("http://192.168.1.300/")
    assert not r.valid


def test_url_accepts_bracketed_ipv6() -> None:
    assert URLValidator().validate("https://[2001:db8::1]:443/").valid


def test_url_rejects_port_zero() -> None:
    r = URLValidator().validate("http://example.com:0/")
    assert not r.valid


def test_url_rejects_port_over_max() -> None:
    r = URLValidator().validate("http://example.com:99999/")
    assert not r.valid
