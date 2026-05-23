# Task

Strengthen a set of input validators that each enforce different
domain-specific rules. The validators are already wired up: there's a
shared abstract base class and a shared `Reason` enum used by all of
them. The starting state contains a **naive** implementation of every
validator — happy path works, but edge cases are missed. Your job is to
bring each one up to the per-validator spec.

The validators cover: email, phone numbers, credit cards, IBAN, ISBN,
semver versions, and URLs. The exact rules for each are in the starting
state's docstrings — read them.

## Tests

Each validator has its own visible-test suite asserting the specific
edge cases that matter for its domain. The shared `Reason` enum is the
machine-readable contract for failure reasons. Don't invent new reason
codes unless absolutely necessary; the enum should stay stable.

The starting state directory tree (provided alongside this design) shows
the file layout — each validator's logic is one file; the base ABC and
enum are separate.
