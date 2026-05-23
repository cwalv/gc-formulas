# Eval case: validator-suite

A Python validator library with 7 sibling validators (Email, Phone,
Credit-card, IBAN, ISBN, Semver, URL) sharing a `Validator` ABC and a
machine-readable `Reason` taxonomy. The starting state contains a
**naive** implementation of every validator — each handles the obvious
happy path but misses the spec's edge cases. The task is to bring each
validator up to spec.

Designed as the **second eval case** for the plan-evals framework
(`docs/plan-evals.md` M2). Where `cancel-method` is a calibration /
runner-validation case at the easy end of the worker-model tier, this
case is intentionally sized so one-shot ralph at sonnet should struggle
with the long tail of edge cases.

## What this case differentiates vs cancel-method

| Axis | cancel-method | validator-suite |
|---|---|---|
| Pieces | 5 entities | 7 validators |
| Per-piece complexity | Trivial (1 method, ~5 LoC) | Substantial (checksum / parser / state-machine per validator; 20-50 LoC each) |
| Pieces share *shape* | Yes (`cancel()` interface) | Yes (`Validator` ABC + `Reason` enum) |
| Pieces share *logic* | Mostly yes — almost copy-paste | No — each piece is its own algorithm |
| Cross-piece coupling | None | Shared `Reason` taxonomy; consistent rejection of `WRONG_TYPE`/`EMPTY` |
| Spec verbosity | ~30 lines | ~120 lines (per-validator rules) |
| Visible tests | 15 | 20 |
| Hidden tests | 0 in M1 (planned for M2 hidden-tests subagent work) | 26 |
| Existing tests | 10 | 19 |
| Files in starting-state | 9 | 16 |
| One-shot sonnet baseline | 100% pass in ~80s | **Expected to be lower** — long tail of edge cases per validator (Luhn, mod-97, semver pre-release rules, IPv4 octets, etc.) |

### Why this should differentiate patterns

- **Fan-out wins on wall-clock.** 7 independent validators; each can be
  worked in parallel. cancel-method already showed ~3× speedup at
  N=5; expect similar or better at N=7.
- **Eval-optimizer wins on hidden-test pass rate.** Edge cases like
  "label cannot start/end with hyphen" or "port out of range" follow
  from the spec but aren't enumerated. One-shot ralph plausibly
  misses 3-5 of them per validator; a round-2 iteration with hidden
  test feedback should catch them.
- **Voting wins on variance reduction.** Subtleties like "are leading
  zeros in numeric pre-release identifiers allowed?" admit two
  plausible-but-wrong answers; voting across attempts converges to
  the spec-correct one.

The cancel-method case has none of these — both ralph and fan-out
one-shot it, so the only metric that differentiated was wall-clock.

## Contents

```
validator-suite/
├── README.md                              (this file)
├── spec.md                                (the task as given to the planner/agents)
├── starting-state/                        (fixture; copied to a worktree at run-start)
│   ├── validators/
│   │   ├── __init__.py
│   │   ├── base.py                        (Validator ABC, Reason enum, Result)
│   │   ├── registry.py                    (name -> validator map)
│   │   ├── email.py                       (naive)
│   │   ├── phone.py                       (naive)
│   │   ├── credit_card.py                 (naive — no Luhn)
│   │   ├── iban.py                        (naive — no mod-97)
│   │   ├── isbn.py                        (naive — no checksum)
│   │   ├── semver.py                      (naive — no pre-release / build)
│   │   └── url.py                         (naive — no scheme allow-list / IPv4 / port)
│   └── tests/
│       └── test_existing.py               (19 baseline regression tests; must keep passing)
├── visible-tests/
│   └── test_validators.py                 (20 success-target tests)
└── hidden-tests/
    └── test_validators_hidden.py          (26 quality-axis tests; scorer-only)
```

## Scoring

- **Visible:** `pytest visible-tests/ starting-state/tests/` — combined
  pass count is the visible score. Hitting all visible without
  breaking any existing tests is the correctness floor.
- **Hidden:** `pytest hidden-tests/` — independent count, scorer-only.
  This is the **quality dimension**. Hidden test pass rate is how
  patterns differentiate beyond ralph's "good enough to pass visible".

## Calibration

Against the unmodified starting-state:

- `pytest starting-state/tests/` → **19/19 pass** (baseline preserved)
- `pytest visible-tests/` → **9/20 pass, 11 fail** (the spec's edge
  cases — the agent's job)
- `pytest hidden-tests/` → **14/26 pass, 12 fail** (subtler
  edge cases — the quality dimension)

Against the author's reference implementation (not committed; see
build notes in commit message): **65/65 pass** across all three suites
combined.

## How the runner uses this

Identical to cancel-method:

1. Copy `starting-state/` into a fresh worktree per run.
2. Show `spec.md` to the agent(s).
3. Let the agent(s) work in the worktree.
4. Run `pytest visible-tests/ tests/` against the worktree.
5. (Scorer also runs `hidden-tests/` for the quality dimension.)
6. Capture wall-clock + token cost + visible-pass + hidden-pass.

Repeat 10× to get distributions; aggregate.

## Authoring notes

- Test data is independently verified for mathematical correctness
  (Luhn, mod-97, ISBN-10 mod-11, ISBN-13 mod-10).
- Reference implementation existed during authoring to verify that
  all visible+hidden tests can simultaneously pass. The reference is
  not committed (the case must be solved by the agent under test).
- `test_iban_rejects_short` in `starting-state/tests/` accepts either
  `TOO_SHORT` (the naive impl's answer) or `BAD_FORMAT` (a
  length-aware impl's answer) so the test stays green across both
  implementations.
- Existing `test_isbn_*` tests use values that happen to satisfy the
  checksum, so they pass both with and without checksum logic.
