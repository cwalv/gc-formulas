# Two-Phase Commit pattern + case — design fragment

Status: design only; implementation deferred (bead `fo-n41tp`).

## Why

`docs/choreography-idioms.md` enumerates five graph-shape templates.
The bench covers Map (fanout/sectioning), Map-Reduce (orchworkers), and
will cover Critique-Loop + Gatekeeper under E2 (voting +
evaluator-optimizer). The fifth — **Two-Phase Commit** ("Define
Contract" → "Implement against Contract", e.g. TDD) — has no runner or
case.

The graph-shape probes done in fo-d5fh9 surfaced a related signal: on
`enum-extension`, sonnet's preferred shape was
`two-phase-commit-with-contract-author` (1 contract-author bead writes
`codes.py`+`registry.py`, then 6 worker beads each implement one class).
The alternates extension in `reference-graph.json` already accepts that
shape as structurally sound. Two-Phase Commit at the *worker layer*
would empirically validate the architect-layer claim: does running
contract-first actually produce the same quality as synthesis-pipeline
(merge-after) at the worker layer?

That's the load-bearing experimental question for this bead.

## Case shape

**`evals/tpc-validator/`** — minimal case scoped to a single class.

Starting state:
```
tpc-validator/
├── README.md
├── spec.md
├── starting-state/
│   ├── validator/
│   │   └── __init__.py   (empty)
│   └── tests/
│       └── (empty — Phase 1 writes tests here)
├── visible-tests/
│   └── (Phase 1 outputs go here; scorer reads them too)
└── hidden-tests/
    └── test_quality.py   (edge cases scorer-only)
```

Spec: build a `PortValidator` class with a `validate(port: int) -> Result`
method. Required behavior listed at high level — "rejects negative,
zero, out-of-range; rejects reserved ranges per RFC; ..." — but per-
edge-case enumeration is left to Phase 1.

Why a single class: TPC's value lives in the *temporal ordering* of
phases, not multi-file scope. The smallest case that exposes the
ordering is enough; adding multi-file scope confounds with sectioning /
orchworkers.

## Runner architecture (`scripts/eval-tpc.sh`)

Two distinct phases, separated by a bead-graph dependency (or in the
bash-substrate fallback, a strict sequential call):

### Phase 1 — Contract author

- Worker: `claude -p` instance.
- Brief: "Read spec.md. Write a test file at `tests/test_contract.py`
  asserting the contract. Include edge cases derivable from the spec.
  Write a minimal interface stub at `validator/__init__.py` — just the
  class signature with `pass`. Do NOT implement the validator."
- Exit condition: file `tests/test_contract.py` exists and is
  non-trivial (≥ N test functions); `validator/__init__.py` defines
  the class.
- Allowed scope: `tests/`, `validator/__init__.py`.

### Phase 2 — Implementer

- Worker: separate `claude -p` instance (fresh context — no shared
  history with Phase 1).
- Brief: "Read spec.md and `tests/test_contract.py`. Implement
  `validator/__init__.py` so the contract tests pass. You MAY NOT
  modify any test file."
- Exit condition: `pytest tests/ visible-tests/` passes.
- Allowed scope: `validator/__init__.py` only.

The runner enforces the test-file lock by snapshotting `tests/` after
Phase 1 and checking the snapshot matches at Phase 2 exit (any diff →
the run fails as "implementer modified the contract").

## Comparison patterns

Each case-pattern run should produce data comparable to ralph on the
same case:

- **TPC**: as described.
- **Ralph baseline**: single agent loops over the whole task — writes
  tests + implementation in one session. Comparison axis: does the
  *forced separation* of phases produce measurably different
  outcomes?

Hypotheses going in (would be invalidated by the data):

1. **TPC hidden-test pass rate ≥ ralph's.** The contract-author has only
   one job — encode the spec as tests — so it explores the edge-case
   space more thoroughly than ralph (which is also implementing while
   testing). Higher hidden-test pass rate on edge cases ralph might
   skip.

2. **TPC wall-clock > ralph's.** Two phases sequentially > one phase
   end-to-end; even with bd-graph ready-state instant ("Phase 2 wakes
   the moment Phase 1 closes"), there's overhead from the second
   agent's cold context.

3. **TPC's tokens-out ≤ ralph's at higher quality.** Phase-isolated
   workers don't burn tokens on context-switching between testing
   and implementing.

If hypothesis 1 doesn't hold, the pattern's value is in *discipline*
(harder to skip edge cases when the contract is locked) rather than
*quality*. That's a finding either way.

## Edge: contract-author quality matters more than usual

Unlike fanout/sectioning where each worker has narrow scope, the
contract-author's output is what bounds Phase 2. If the contract is
incomplete, Phase 2 will produce a correct-but-incomplete implementation
that passes the visible contract tests but fails hidden-test edge cases.

Two design choices to surface this:

(a) **Same worker-tier for both phases** — Phase 1 quality is bounded
    by the same model that bounds Phase 2. Apples-to-apples vs ralph.
    Default choice; gives the cleanest comparison.
(b) **Asymmetric tiers** — e.g., opus contract-author + sonnet
    implementer. Tests whether the discipline value of TPC is
    *especially* useful when the implementer is cheaper. Out of scope
    for the first cut; ride on top of fo-vgam1's `PLANNER_MODEL` knob
    if/when wanted.

## Result schema

Per-run JSON gets two phase-distinct field groups:

```json
{
  "pattern": "tpc",
  "phase1_wall_clock_secs": ...,
  "phase1_tokens_in": ...,
  "phase1_tokens_out": ...,
  "phase1_cache_creation_input_tokens": ...,
  "phase1_cache_read_input_tokens": ...,
  "phase1_test_count": ...,        // # of test_* functions in the locked contract
  "phase2_wall_clock_secs": ...,
  "phase2_tokens_in": ...,
  "phase2_tokens_out": ...,
  "phase2_cache_creation_input_tokens": ...,
  "phase2_cache_read_input_tokens": ...,
  "wall_clock_secs": phase1 + phase2,
  "tokens_in":       phase1 + phase2,
  "tokens_out":      phase1 + phase2,
  "cache_creation_input_tokens": phase1 + phase2,
  "cache_read_input_tokens":     phase1 + phase2,
  ...
  "_meta": {
    "tests_locked_after_phase1": true|false,
    "implementer_modified_tests": false|<count>
  }
}
```

The driver aggregate reports both per-phase medians AND combined
medians, so the eval surfaces "where in the workflow the spend lives"
without losing comparability to ralph (single-phase pattern).

## Open questions (decisions deferred to implementation)

1. **Phase-1 exit criterion**: minimum test count? Spec coverage check
   (e.g., a separate lint step that asserts each spec section has at
   least one test)? Or just "non-empty test file" + trust the model?
   Cheapest is the third; introduces the failure mode where Phase 1
   writes only 2 tests and Phase 2 trivially passes them. Recommend
   starting with "test count ≥ N where N is set per-case" and
   evolving from there.

2. **Hidden-test alignment**: hidden tests already exist for quality
   measurement. Should the bench *also* check whether Phase 1's
   visible contract tests overlap with the hidden tests? A divergent
   contract (Phase 1 misses edge cases hidden tests catch) is signal,
   not noise — would surface "the architect's contract was incomplete."
   Recommend: yes, add a `phase1_contract_overlap_with_hidden` metric.

3. **Failure handling**: if Phase 1 fails (no tests written, or tests
   are nonsense), what happens? Three options:
   - (a) Mark the whole run failed; Phase 2 doesn't fire. Simplest.
   - (b) Phase 2 fires anyway with whatever Phase 1 produced.
     Captures "Phase 2 robustness under bad contracts."
   - (c) Retry Phase 1 N times before giving up.
   Recommend (a) for the first cut; (b) is a useful follow-up
   experiment.

4. **Spec partition**: should spec.md split "what the contract should
   look like" from "what behavior the implementation provides"? In
   real TDD, the test writer sees only the requirements, not the
   implementation strategy. Recommend keeping spec.md unified for the
   first case — adds nothing to the experimental signal and is more
   authoring work.

## T-shirt

Implementation: M. Roughly half a day to a day for the runner +
case + N=10 of TPC + N=10 of ralph baseline + write-up. Lower if
the existing fanout/orchworkers runner code can be cribbed for the
bash plumbing.

## Sequencing

This is the natural sibling of E1 (library-driven planner). Both
explore "what happens when the architect/planner role gets richer
substrate." Could land before or after the per-orchestrator runners
(C.2 / fo-07nux) — independent.
