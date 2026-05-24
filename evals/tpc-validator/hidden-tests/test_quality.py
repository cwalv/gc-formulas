"""
Hidden quality tests for PortValidator.

These are scorer-only edge-case tests that Phase 1 (contract-author) may or
may not enumerate. Divergence between hidden_pass and visible_pass is the
signal: it means Phase 1 wrote an incomplete contract.

Tests use PortValidator from validator/__init__.py (worktree).
"""
import pytest
from validator import PortValidator


@pytest.fixture
def v():
    return PortValidator()


# ---------------------------------------------------------------------------
# Type rejection
# ---------------------------------------------------------------------------

def test_rejects_string(v):
    r = v.validate("80")
    assert not r.valid
    assert r.reason == "invalid_type"


def test_rejects_float(v):
    r = v.validate(3.14)
    assert not r.valid
    assert r.reason == "invalid_type"


def test_rejects_none(v):
    r = v.validate(None)
    assert not r.valid
    assert r.reason == "invalid_type"


def test_rejects_bool_true(v):
    # bool is a subclass of int in Python — must be rejected as invalid_type
    r = v.validate(True)
    assert not r.valid
    assert r.reason == "invalid_type"


def test_rejects_bool_false(v):
    r = v.validate(False)
    assert not r.valid
    assert r.reason == "invalid_type"


# ---------------------------------------------------------------------------
# Range rejection — out_of_range
# ---------------------------------------------------------------------------

def test_rejects_zero(v):
    r = v.validate(0)
    assert not r.valid
    assert r.reason == "out_of_range"


def test_rejects_negative(v):
    r = v.validate(-1)
    assert not r.valid
    assert r.reason == "out_of_range"


def test_rejects_large_negative(v):
    r = v.validate(-9999)
    assert not r.valid
    assert r.reason == "out_of_range"


def test_rejects_65536(v):
    r = v.validate(65536)
    assert not r.valid
    assert r.reason == "out_of_range"


# ---------------------------------------------------------------------------
# Ephemeral / reserved range — reason="reserved"
# ---------------------------------------------------------------------------

def test_rejects_49152_as_reserved(v):
    """49152 is the first ephemeral port (RFC 6335 §6)."""
    r = v.validate(49152)
    assert not r.valid
    assert r.reason == "reserved"


def test_rejects_65535_as_reserved(v):
    """65535 is within the ephemeral range."""
    r = v.validate(65535)
    assert not r.valid
    assert r.reason == "reserved"


def test_rejects_60000_as_reserved(v):
    r = v.validate(60000)
    assert not r.valid
    assert r.reason == "reserved"


# ---------------------------------------------------------------------------
# Valid cases
# ---------------------------------------------------------------------------

def test_accepts_1(v):
    """Port 1 is the lowest valid port."""
    r = v.validate(1)
    assert r.valid
    assert r.reason == "ok"


def test_accepts_22_ssh(v):
    """SSH (22) is a well-known port — must be valid."""
    r = v.validate(22)
    assert r.valid
    assert r.reason == "ok"


def test_accepts_80_http(v):
    r = v.validate(80)
    assert r.valid
    assert r.reason == "ok"


def test_accepts_443_https(v):
    r = v.validate(443)
    assert r.valid
    assert r.reason == "ok"


def test_accepts_8080(v):
    r = v.validate(8080)
    assert r.valid
    assert r.reason == "ok"


def test_accepts_49151_boundary(v):
    """49151 is the last valid registered port — must be accepted."""
    r = v.validate(49151)
    assert r.valid
    assert r.reason == "ok"


# ---------------------------------------------------------------------------
# Result shape contract
# ---------------------------------------------------------------------------

def test_result_has_valid_field(v):
    r = v.validate(80)
    assert hasattr(r, "valid")
    assert isinstance(r.valid, bool)


def test_result_has_reason_field(v):
    r = v.validate(80)
    assert hasattr(r, "reason")
    assert isinstance(r.reason, str)


def test_result_has_detail_field(v):
    r = v.validate(80)
    assert hasattr(r, "detail")
    assert isinstance(r.detail, str)
    assert len(r.detail) > 0
