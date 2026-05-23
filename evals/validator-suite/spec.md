# Task

Strengthen the seven validators in `validators/` so they each enforce the
domain-specific rules listed below. The starting state contains a
**naive** implementation of every validator: each handles the obvious
happy path but misses edge cases. Your job is to bring each one up to
the spec.

Validators live under `validators/`:

- `validators/email.py` — `EmailValidator`
- `validators/phone.py` — `PhoneValidator`
- `validators/credit_card.py` — `CreditCardValidator`
- `validators/iban.py` — `IBANValidator`
- `validators/isbn.py` — `ISBNValidator`
- `validators/semver.py` — `SemverValidator`
- `validators/url.py` — `URLValidator`

All return a `Result(valid, reason, detail)` from `validators.base`; the
machine-readable `Reason` enum is the contract. Don't invent new
reason codes — extend the enum in `base.py` if and only if a new code
is genuinely needed.

## Required behaviour per validator

### 1. `EmailValidator`

- Must contain exactly one `@`.
- Local part: 1-64 chars, allowed = ASCII letters, digits, and any of
  `. _ % + - !` (no leading/trailing `.`; no consecutive `..`).
- Domain part: 1-255 chars total. At least one `.`; each label 1-63
  chars; labels contain ASCII letters, digits, or `-` (not at start
  or end of a label).
- TLD (last label) must be at least 2 chars and all ASCII letters
  (no all-digit TLD).
- Reject `WRONG_TYPE`, `EMPTY`, `TOO_LONG`, `BAD_FORMAT`,
  `BAD_CHARSET` as appropriate.

### 2. `PhoneValidator`

- E.164 shape: `+` then 1-15 digits.
- The first digit after `+` is the country code; the country code
  must be one of: `1`, `7`, `20`, `27`, `30`, `31`, `32`, `33`, `34`,
  `39`, `40`, `41`, `43`, `44`, `45`, `46`, `47`, `48`, `49`, `51`,
  `52`, `54`, `55`, `56`, `57`, `58`, `60`, `61`, `62`, `63`, `64`,
  `65`, `66`, `81`, `82`, `84`, `86`, `90`, `91`, `92`, `93`, `94`,
  `95`, `98`. (Validators check the longest matching prefix.)
- Total digit count (including the country code) must be between 7
  and 15 inclusive.
- Unknown country codes return `UNKNOWN_COUNTRY`, not `BAD_FORMAT`.
- Spaces or hyphens inside the number are NOT allowed (E.164 is the
  canonical form). For credit-card-style spacing use a different
  validator.

### 3. `CreditCardValidator`

- Strip spaces and hyphens, then check digit charset.
- Length must be 13-19 digits.
- Must pass the **Luhn check-digit algorithm** (standard mod-10).
- Failed Luhn returns `BAD_CHECKSUM`.

### 4. `IBANValidator`

- Strip whitespace; case-normalise to upper.
- Country code (first 2 chars) must be one of these and have the
  per-country length:

  | Code | Length |
  |------|--------|
  | GB   | 22 |
  | DE   | 22 |
  | FR   | 27 |
  | ES   | 24 |
  | IT   | 27 |
  | NL   | 18 |
  | BE   | 16 |
  | CH   | 21 |
  | AT   | 20 |
  | IE   | 22 |

  Other countries → `UNKNOWN_COUNTRY`.
- Wrong length for a known country → `BAD_FORMAT`.
- Must pass the **ISO 13616 mod-97 checksum**: move first 4 chars to
  end, convert letters (`A=10..Z=35`) to digits, parse as int, must
  ≡ 1 (mod 97). Failure → `BAD_CHECKSUM`.

### 5. `ISBNValidator`

- Accept either 10-char (digits, optional trailing `X`) or 13-char
  (all digits) after stripping `-` and spaces.
- For ISBN-10: weighted sum (i=1..10) of digit×(11-i) ≡ 0 (mod 11);
  the `X` represents 10.
- For ISBN-13: weighted sum with weights `1,3,1,3,...,1` over the
  13 digits ≡ 0 (mod 10).
- Failed checksum → `BAD_CHECKSUM`.

### 6. `SemverValidator`

Per [semver.org 2.0](https://semver.org/):

- Required: `MAJOR.MINOR.PATCH` where each part is a non-negative
  integer with no leading zero (except the value `0` itself).
- Optional pre-release: a `-` followed by dot-separated identifiers.
  Each identifier is non-empty ASCII alphanumeric or `-`; if purely
  numeric, must have no leading zero (except `0`).
- Optional build metadata: a `+` followed by dot-separated
  identifiers. Each identifier is non-empty ASCII alphanumeric or
  `-`; leading zeros allowed here.
- Order: `MAJOR.MINOR.PATCH[-pre][+build]`.
- Invalid shape → `BAD_FORMAT`.

### 7. `URLValidator`

- Scheme must be one of an allow-list: `http`, `https`, `ftp`,
  `ftps`, `ws`, `wss`. Other schemes → `UNKNOWN_SCHEME`.
- After `://` there must be a host. Host is either:
  - A domain (same label rules as Email's domain), OR
  - An IPv4 dotted-quad (each octet 0-255, no leading zeros
    except `0` itself), OR
  - A bracketed `[...]` form (assume IPv6 — accept any non-empty
    content; deeper IPv6 validation is out of scope).
- Optional `:PORT` after host: port is 1-65535 with no leading zero
  (`:0` and `:65536` are invalid; `:80` is fine).
- After host[:port], anything is permitted (path/query/fragment).
- Domain TLD must be 2+ ASCII letters (same rule as Email).

## Shared rules

- Non-`str` input → `Reason.WRONG_TYPE` (don't raise).
- Empty string → `Reason.EMPTY`.
- The seven validators are independent — implementing one doesn't
  require touching another.
- `base.py` and `registry.py` exist and work; don't break their
  contracts. You MAY extend `Reason` (only if needed). Don't change
  the meaning of an existing reason code.
- Don't modify any tests under `tests/`.
- Each validator's `name` attribute must stay the same.

## Success criteria

`pytest tests/ visible-tests/` (with `PYTHONPATH=<worktree>`) passes
all tests.
