# Task

Add six concrete error classes to an existing Python package:
`NotFoundError`, `UnauthorizedError`, `ConflictError`, `RateLimitError`,
`TimeoutError`, `ValidationError`.

Each class must:

1. Inherit from a shared abstract base class (`BaseError`).
2. Have a unique numeric error code, exposed via a shared enum.
3. Be discoverable via a shared registry that maps error codes back to
   the class.

The package's `__init__.py` imports each class by name, so renaming any
class breaks the package's import path.

The starting state contains the scaffolding: the abstract base class is
implemented, the shared enum exists but only has a sentinel `UNKNOWN = 0`,
and the shared registry exists but is empty. A one-line stub per class is
in place. Inspect the directory tree (provided alongside this design) to
see the file layout.

## Per-class behavior

The behavior each class encodes is straightforward — read the inline
docstring of each stub file in the starting state for the per-class
acceptance criteria. The interesting structural questions are about
*how* the six classes coordinate on the shared enum and the shared
registry, not about per-class details.

## Tests

Visible and hidden tests assert: each class is importable from the
package; each class's error code is unique; each class is registered
(round-trip from code to class works); each class's docstring matches
the per-class spec.
