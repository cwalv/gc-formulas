# Task

Complete the six error classes in `errors/`. The starting state contains
the shared scaffolding (an abstract base class, an empty enum, an empty
registry) plus a one-line stub per class. Your job is to finish each
class.

## Layout

```
errors/
├── __init__.py        (re-exports — already wired up)
├── base.py            (BaseError abstract class — already implemented)
├── codes.py           (ErrorCode IntEnum — currently has only UNKNOWN = 0)
├── registry.py        (ERROR_REGISTRY + register/lookup helpers — empty)
├── conflict.py        (ConflictError stub)
├── not_found.py       (NotFoundError stub)
├── rate_limit.py      (RateLimitError stub)
├── timeout.py         (TimeoutError stub)
├── unauthorized.py    (UnauthorizedError stub)
└── validation.py      (ValidationError stub)
```

Read `errors/base.py` to understand the `BaseError` interface — every
concrete error inherits from it.

## What each worker class must do

For each of the six error classes (`NotFoundError`, `UnauthorizedError`,
`ConflictError`, `RateLimitError`, `TimeoutError`, `ValidationError`),
you must do **three things**:

### 1. Add a variant to `ErrorCode` in `errors/codes.py`

The enum currently has only `UNKNOWN = 0`. Add one variant per class,
e.g. `NOT_FOUND = 1`, `UNAUTHORIZED = 2`, etc.

- Use `SCREAMING_SNAKE_CASE` for variant names.
- Pick distinct integer values (no two variants on the same int).
- Don't reorder or change the value of `UNKNOWN`.

### 2. Register the class in `errors/registry.py`

`ERROR_REGISTRY: dict[ErrorCode, type[BaseError]]` starts empty. Add an
entry for each class mapping its `ErrorCode` variant to the class. You
can either edit the registry dict literal directly, or use the provided
`register(code, cls)` helper (works as a decorator or a function call).

### 3. Implement the class in `errors/<name>.py`

Each stub currently contains:

```python
class NotFoundError(BaseError):
    pass  # TODO: implement
```

Replace `pass` with an implementation. At minimum, the class must
override the abstract `code` property to return its `ErrorCode`
variant:

```python
class NotFoundError(BaseError):
    @property
    def code(self) -> ErrorCode:
        return ErrorCode.NOT_FOUND
```

That's the entire contract. `BaseError` provides `__str__` and
`to_dict()`; you do not need to override either.

## Shared rules

- All six classes share the *shape* of the work (enum variant + registry
  entry + `code` override) but each is a separate class with its own
  variant.
- Don't modify `base.py` — the abstract contract is fixed.
- Don't break the existing baseline tests under `tests/`.
- The `ErrorCode` variant a class returns from `code` MUST match the
  variant under which it is registered. (Mismatches will cause registry
  lookups to return the wrong class.)
- `UNKNOWN` is a sentinel; nothing should register itself under
  `UNKNOWN`.

## Success criteria

Run from the worktree root:

```
pytest tests/ visible-tests/
```

All tests pass. The scorer additionally runs hidden tests that check
cross-file invariants (unique enum values, exhaustive registry,
consistent naming, etc.) — those follow from the shared rules above.
