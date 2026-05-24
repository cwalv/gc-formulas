# Spec: PortValidator

Build a `PortValidator` class in `validator/__init__.py` with the method:

```python
def validate(self, port: int) -> Result
```

`Result` should also be defined (or importable) from `validator/__init__.py`.

## Result shape

```python
Result(valid: bool, reason: str, detail: str)
```

- `valid`: `True` if the port is acceptable, `False` otherwise.
- `reason`: short category string, e.g. `"ok"`, `"invalid_type"`, `"out_of_range"`, `"reserved"`.
- `detail`: human-readable explanation string (non-empty).

`Result` may be a dataclass, namedtuple, or plain class — callers access fields by attribute name.

## Validation rules

1. **Type check** — `port` must be an `int`. If it is not (e.g. float, str, None), return `valid=False, reason="invalid_type"`.

2. **Range check** — valid port numbers are 1–65535 inclusive (TCP/UDP port space per RFC 793 / IANA). Return `valid=False, reason="out_of_range"` for:
   - `port <= 0` (zero and negatives are not assignable)
   - `port > 65535`

3. **Reserved range check** — some sub-ranges within 1–65535 are administratively reserved and must not be accepted:
   - Ports 49152–65535 are the IANA ephemeral/dynamic range (RFC 6335 §6). Return `valid=False, reason="reserved"`.

4. **Well-known ports (0–1023)** are explicitly **valid** for this validator — they are registered system ports and are perfectly legal to specify. Do not reject them as reserved.

5. **Registered ports (1024–49151)** are valid.

So the accepted window is: **1–49151** (inclusive).

## Examples

| Input | valid | reason |
|-------|-------|--------|
| `22`  | True  | `"ok"` |
| `80`  | True  | `"ok"` |
| `8080`| True  | `"ok"` |
| `0`   | False | `"out_of_range"` |
| `-1`  | False | `"out_of_range"` |
| `65536` | False | `"out_of_range"` |
| `49152` | False | `"reserved"` |
| `65535` | False | `"reserved"` |
| `49151` | True  | `"ok"` |
| `"80"` | False | `"invalid_type"` |
| `3.14` | False | `"invalid_type"` |

## Notes

- `bool` is a subclass of `int` in Python. Treat `True`/`False` as `invalid_type` (they are not meaningful port numbers).
- `detail` content is not validated by tests (any non-empty string is acceptable).
- No external dependencies — stdlib only.
