# enum-extension graph-shape results

Phase B (architect-quality) eval. Plan-only: the planner is given the design
doc (`spec.md`) + the choreography idioms library + the starting-state tree,
and must produce a bead graph (idiom + nodes + deps). Scored against
`reference-graph.json` for semantic equivalence on three axes: idiom, per-
persona node counts, and dep topology.

## Reference shape

- Idiom: `synthesis-pipeline`
- 6 worker beads (one per concrete error class) → 1 merger bead (extends
  `codes.py` + `registry.py`).
- Topology: 6 roots, 1 sink, max_depth 2, fan_in_to_sink 6.

The merger is load-bearing: workers can't extend shared state in parallel
without colliding, so the architect must split *who edits what*.

## Results

| Planner model | N | idiom | persona | shape | overall |
|---|---|---|---|---|---|
| **opus 4.7** | 10 | 10/10 | 10/10 | 10/10 | **10/10** |
| sonnet 4.6 | 5 | 0/5 | 0/5 | 0/5 | 0/5 |

## Headline finding

**Opus is a competent architect on this case; sonnet is not.** Opus picks
synthesis-pipeline every time with the correct 6+1 topology. Sonnet picks
`two-phase-commit` (contract-author + N workers) in 5/5 — a defensible-
sounding mistake. Two-phase-commit's contract-author writes the contract
(here: extends `codes.py` + `registry.py`?) and workers implement against
it — but for that to work the workers must NOT write shared state, and
sonnet's graphs leave the per-class workers responsible for both their
own file AND adding their variant to `codes.py`/`registry.py`. That's the
exact race-write failure mode the case was designed to surface.

The model recognizes "there is a contract" but mis-locates the cross-file
authority — it puts the contract-author *before* the workers when the
case actually wants the merge step *after* the workers.

## Per-rep detail (sonnet)

All 5 reps picked `two-phase-commit`. Worker count varied (2, 3, 3, 6, 6) —
sometimes the planner generated only a subset of the 6 error classes.
Persona breakdown: `{contract-author: 1, worker: N}`.

## Token cost

~5 tokens in, ~565 tokens out per planner call. Plan-only is **dirt cheap** —
no worker fan-out. 10 reps of both cases under both models fit in well
under one session quota window.

## Calibration implication

This is the first plan-evals data point where opus and sonnet differ at the
architect layer. The worker-level calibration finding (`docs/plan-evals.md`
"Calibration: why sonnet workers") established that sonnet is the Goldilocks
worker model. This result suggests the architect layer wants opus —
consistent with the role split in `position.md`'s terminology note.

## Follow-ups

1. **Bigger N for sonnet** to confirm "0/5 picks two-phase-commit" isn't
   a small-sample artifact (likely not — every rep picked the same wrong
   idiom — but N=10 would be cleaner).
2. **Probe the failure mode**: when sonnet picks two-phase-commit, does its
   generated *contract* actually pre-stock `codes.py` + `registry.py`? If
   so, the graph is wrong but the implicit plan might still work. If not,
   the model has structurally misallocated cross-file authority. Hand-read
   2-3 graph.json outputs to decide.
3. **A "designless" variant**: strip `spec.md` to pure prose intent (drop
   the explicit file enumeration). Does opus still nail it without the
   layout hint?
