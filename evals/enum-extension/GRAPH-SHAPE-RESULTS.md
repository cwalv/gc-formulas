# enum-extension graph-shape results

Phase B (architect-quality) eval. Plan-only: the planner sees the design
doc (`spec.md`) + the choreography idioms library + the starting-state tree,
and must produce a bead graph (idiom + nodes + deps). Scored against
`reference-graph.json` for semantic equivalence on three axes: idiom, per-
persona node counts, and dep topology.

## Reference shape

Two shapes accepted as **structurally sound** (both pre-stock shared-state
authority in a single bead; they differ only on whether it runs before or
after the workers):

| Reference | Idiom | Personas | Notes |
|---|---|---|---|
| **Primary** | `synthesis-pipeline` | 6 worker → 1 merger | "merge-after." Pairs with the orchworkers worker-layer pattern (validated empirically). |
| Alternate | `two-phase-commit` (with contract-author) | 1 contract-author → 6 worker | "contract-first." Pre-stocks codes.py + registry.py before the per-class fan-out. Arguably more execution-safe — workers don't reference enum members that haven't been defined yet. |

Both shapes solve the core problem: **codes.py + registry.py have a single
writer**, not 6 race-writers. The plan-only eval can't tell us which is
*better* (would require running both under matched worker patterns), but it
can tell us which the model converges to.

## Results

| Planner model | N | Primary match | Alternate match | **Structurally sound** | Failure (no-match) |
|---|---|---|---|---|---|
| **opus 4.7** | 10 | **10/10** | 0/10 | **10/10** | 0/10 |
| sonnet 4.6 | 10 | 2/10 | 4/10 | **6/10** | 4/10 |

## Headline finding (corrected)

**Both opus and sonnet converge to structurally-sound shapes on this case,
but they pick *different* idioms.** Opus consistently picks synthesis-
pipeline (merge-after); sonnet consistently picks two-phase-commit
(contract-first) when it gets a sound shape at all.

Earlier framing of "sonnet picks the wrong idiom" was wrong: sonnet's
two-phase-commit graphs include a `contract-author` bead that pre-stocks
codes.py + registry.py before the per-class fan-out. That's defensible —
arguably more so than synthesis-pipeline, which would have workers writing
class code referencing `ErrorCode.NOT_FOUND` before NOT_FOUND exists.

The honest gap is at the bottom: **sonnet produces an unsound graph
40% of the time** (4 reps: three of them only emitted 3 workers instead of
6, dropping half the error classes; one picked plain fanout with no
contract-author or merger, which actually would race-write shared state).
Opus's failure rate at the same task is 0/10.

## Per-rep detail (sonnet N=10)

| Rep | Idiom | Personas | Status |
|---|---|---|---|
| 01 | two-phase-commit | {contract-author:1, worker:6} | sound (alt) |
| 02 | two-phase-commit | {contract-author:1, worker:6} | sound (alt) |
| 03 | synthesis-pipeline | {worker:6, merger:1} | sound (primary) |
| 04 | two-phase-commit | {contract-author:1, worker:6} | sound (alt) |
| 05 | fanout | {worker:7} | **broken** (no shared-state owner) |
| 06 | two-phase-commit | {contract-author:1, worker:3} | **incomplete** (only 3 of 6 classes) |
| 07 | two-phase-commit | {contract-author:1, worker:6} | sound (alt) |
| 08 | two-phase-commit | {contract-author:1, worker:3} | **incomplete** |
| 09 | synthesis-pipeline | {worker:6, merger:1} | sound (primary) |
| 10 | two-phase-commit | {contract-author:1, worker:3} | **incomplete** |

3 of the 4 "broken" reps are the same failure mode: sonnet emits a graph
with only 3 implementer beads, each scoped to 2 class files — i.e. it
batched 2 classes per worker. **This is a deliberate structural choice**,
not a counting error: all three reps' `reasoning` field explicitly says
"three parallel implementer beads" / "the three implementer beads run
concurrently." Sonnet is *consciously* choosing 2-classes-per-worker as
its parallelism granularity, presumably reading 6-of-anything as "too many
parallel workers for the task."

Whether 2 classes/worker is genuinely worse than 1/worker depends on the
worker layer; for plan-eval purposes we score it as wrong because it
doesn't match the per-class-leaf shape both references prescribe. The
deeper question — "what's the right granularity?" — is itself something
the bench could measure with the right case design.

## Token cost

~5 tokens in, ~565-630 tokens out per planner call. Plan-only is **dirt
cheap** — N=10 across both cases × both models is under one minute of
wall-clock and ~$0.02 of token spend.

## Calibration implication

This is the first plan-evals data point where opus and sonnet differ at
the architect layer. The worker-tier calibration already established
sonnet as the Goldilocks worker model (`docs/plan-evals.md` "Calibration:
why sonnet workers"). This case suggests **architect-tier wants opus**,
with two distinct gaps from sonnet:

1. **Idiom convergence**: sonnet has variance (synthesis-pipeline, two-phase-
   commit, occasional fanout); opus is consistent.
2. **Decomposition discipline**: sonnet sometimes under-decomposes
   (batches classes); opus produces the canonical leaf-per-class graph
   every time.

Both gaps are at the *architecture-quality* level, not the
*executes-the-task* level. That's the right distinction for a plan-only
eval to surface.

## Follow-ups

1. **Why does sonnet batch?** Hand-read the 3 "incomplete" reps to see
   whether it's confused about the case (3 classes vs 6), or genuinely
   choosing 2/worker as a structural decision. (Look at reasoning fields.)
2. **A "designless" variant**: strip `spec.md` of the explicit file
   enumeration. Does opus still nail it without the layout hint?
3. **Execute the two sound idioms back-to-back**: run synthesis-pipeline
   AND two-phase-commit-with-contract-author on enum-extension at the
   worker layer. Do both 100%? Or does one fail in practice for reasons
   the plan-only eval can't see (e.g., contract-author has to guess all
   the enum names ahead of time, vs. merger gets to see the worker output
   first)? This would resolve the "which is better" question empirically.
4. **`EXTRA_INSTRUCTION` knob** added to the runner (env var) — lets us
   probe "what if we tell the architect to use synthesis-pipeline
   specifically" or "what if we ban contract-author beads." Useful for
   exploration but not the default mode.
