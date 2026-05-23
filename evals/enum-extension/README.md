# Eval case: enum-extension

A Python error-class library with 6 sibling concrete error classes
(`NotFoundError`, `UnauthorizedError`, `ConflictError`, `RateLimitError`,
`TimeoutError`, `ValidationError`) sharing a `BaseError` ABC, an
`ErrorCode` enum, and an `ERROR_REGISTRY`. The starting state contains
the shared scaffolding (ABC implemented, enum and registry empty except
for an `UNKNOWN = 0` sentinel) plus a one-line stub per class. The task
is to complete each class.

Designed as the **shared-state stress test** for the plan-evals framework
after `validator-suite` (the original "shared-state" case) turned out to
have a pre-stocked enum, meaning workers never actually had to extend
shared state. `enum-extension` corrects that: `codes.py` and
`registry.py` start empty and are explicitly excluded from per-worker
scope under fanout/sectioning. Only patterns where some agent has
cross-file authority can satisfy the cross-cutting requirements.

## What this case differentiates vs validator-suite

| Axis | validator-suite | enum-extension |
|---|---|---|
| Pieces | 7 validators | 6 error classes |
| Per-piece complexity | Substantial (per-validator algorithm) | Trivial (1 property override + 1 enum variant + 1 registry entry) |
| Shared state | Pre-stocked (`Reason` enum has every code) | Empty (`ErrorCode` has only `UNKNOWN`; registry is `{}`) |
| Shared-state extension required? | No | **Yes** — workers MUST add their variant + register themselves |
| Shared files in worker scope? | n/a | **No** — `codes.py`, `registry.py`, `__init__.py` are in `fanout.json`'s `exclude` list |
| What this forces | Quality (long tail of edge cases) | Coordination (cross-file authority over shared state) |
| Differentiating axis | Hidden-test pass rate | Pattern pass rate (which patterns reach 100%) |

The starting state is **easy per-class** but **hard cross-cutting**.
That's the inversion that exposes pattern differentiation: ralph (single
agent owns everything) and orchworkers (workers + LLM merge) succeed;
sectioning (per-worker isolation, deterministic collation) often fails
on cross-file invariants; naive fanout (shared worktree, no merge)
fails because workers can't extend shared state in isolation.

## Contents

```
enum-extension/
├── README.md                    (this file)
├── spec.md                      (full design doc — file layout enumerated)
├── design-stripped.md           (designless probe variant; SPEC_FILE_OVERRIDE input)
├── reference-graph.json         (graph-shape eval reference; primary + alternates)
├── fanout.json                  ({"dir": "errors", "exclude": [shared files]})
├── starting-state/
│   ├── errors/
│   │   ├── __init__.py          (re-exports each class by name)
│   │   ├── base.py              (BaseError abstract class — implemented)
│   │   ├── codes.py             (ErrorCode IntEnum — only UNKNOWN = 0)
│   │   ├── registry.py          (ERROR_REGISTRY: dict = {} + register helper)
│   │   ├── conflict.py          (stub)
│   │   ├── not_found.py         (stub)
│   │   ├── rate_limit.py        (stub)
│   │   ├── timeout.py           (stub)
│   │   ├── unauthorized.py      (stub)
│   │   └── validation.py        (stub)
│   └── tests/
│       └── test_baseline.py     (6 baseline tests — BaseError abstract class)
├── visible-tests/
│   └── test_errors.py           (20 success-target tests)
└── hidden-tests/
    └── test_errors_hidden.py    (31 quality-axis tests; scorer-only)
```

## Scoring

- **Visible:** `pytest visible-tests/ starting-state/tests/` — combined
  pass count is the visible score.
- **Hidden:** `pytest hidden-tests/` — scorer-only; checks cross-file
  invariants like unique enum values, exhaustive registry, consistent
  class-to-code-to-name mapping, no `UNKNOWN` registrations.

## Calibration

Against the unmodified starting-state:

- `pytest starting-state/tests/` → **6/6 pass** (BaseError abstract baseline preserved)
- `pytest visible-tests/` → 0 pass / 1 collection error (no error classes implemented; `from errors.conflict import ConflictError` is a stub)
- `pytest hidden-tests/` → 0 pass / 1 collection error

The collection error mode is intentional — the starting-state stubs
import fine but the `code` property raises NotImplementedError (BaseError
contract). Tests fail in collection because the test imports trigger
the abstract-class check.

## How the runner uses this

Identical to other cases. See `validator-suite/README.md` for the steps.

`fanout.json` is consulted by the runner to bound worker scope: workers
get one of the per-class files (`conflict.py`, `not_found.py`, etc.)
and are explicitly told NOT to touch `codes.py` / `registry.py` /
`__init__.py`. This is what makes naive fanout fail on this case — the
shared state can't be extended from inside any single worker's scope.

## Results

See `RESULTS.md` (worker-pattern data: ralph / fanout / sectioning /
orchworkers all-pass rates) and `GRAPH-SHAPE-RESULTS.md` (architect-tier
graph-shape data: opus vs sonnet × spec'd vs designless × full vs
stripped vs half library).

Headline: pattern hierarchy is sharp on this case — ralph (10/10) ≈
orchworkers (5/5) >> sectioning (3/10) > fanout (2/10) at the worker
layer. At the architect layer, opus 10/10 sound, sonnet 6/10 sound
(2 primary + 4 two-phase-commit-with-contract-author alternate).
