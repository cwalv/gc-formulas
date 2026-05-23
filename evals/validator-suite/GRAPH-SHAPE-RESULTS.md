# validator-suite graph-shape results

Phase B (architect-quality) eval. See sibling `enum-extension/GRAPH-SHAPE-
RESULTS.md` for framework framing.

## Reference shape

- Idiom: `fanout` (fire-and-forget)
- 7 worker beads (one per validator). No merger, no coordinator.
- Topology: 7 roots, 7 sinks, max_depth 1, fan_in_to_sink 0.

The reference has **no parent / coordinator bead** because the `Reason`
enum and `Validator` ABC are pre-stocked. Workers genuinely don't need
to coordinate. The honest shape is 7 independent leaves.

No idiom alternates declared here: fanout-with-coordinator is *not*
structurally sound for an embarrassingly-parallel case — the coordinator
does no real work, so it's pure overhead.

## Results

| Planner model | N | idiom | persona | shape | **overall** |
|---|---|---|---|---|---|
| **opus 4.7** | 10 | 10/10 | 10/10 | 10/10 | **10/10** |
| sonnet 4.6 | 10 | 10/10 | 0/10 | 0/10 | 0/10 |
| sonnet 4.6 + "no coordinator" hint (soft) | 5 | 5/5 | 3/5 | 1/5 | 1/5 |
| sonnet 4.6 + "no coordinator" hint (strong) | 5 | 5/5 | 4/5 | 4/5 | 4/5 |

## Headline finding

**Sonnet picks the right idiom every time, but always adds an unneeded
coordinator bead.** In 10/10 reps it added a parent bead — usually titled
something like "Coordinate validator strengthening" or "Plan validator
updates" — yielding a 1-root / 7-sink graph with fan_in_to_sink=1,
instead of the reference's 7-root / 7-sink shape with no dependencies at
all.

This is the **"add a manager" bias**: given a multi-worker task, sonnet
reaches for a hierarchical shape even when the task is genuinely
embarrassingly parallel. The coordinator does no work (the contract is
already in `Validator`/`Reason`), so it's pure overhead that real
execution would have to either skip or no-op through.

Opus, in contrast, produces a flat fan of 7 independent leaves every time —
matching what the idioms library calls "fire-and-forget."

## "No coordinator" instruction variant

To test whether sonnet's coordinator bias is correctable, the runner now
supports an `EXTRA_INSTRUCTION` env var that appends a constraint to the
planner brief. Ran N=5 with:

> If the task has no shared state to coordinate, do not add a coordinator
> or parent bead. Leaf-only flat fans are the correct shape for
> embarrassingly-parallel work; an idle coordinator bead is overhead, not
> safety.

Result with the soft instruction above: **idiom 5/5, persona 3/5, shape
1/5, overall 1/5**. The instruction moves the needle (persona-match
jumped from 0/10 to 3/5), but full shape match only landed once. Common
partial-failure mode: sonnet drops the "coordinator" label but still
chains the workers via a depends-on edge.

A **stronger** structural instruction:

> STRUCTURAL CONSTRAINT: the graph MUST have exactly N independent root
> beads with NO dependencies between them, where N equals the number of
> leaf files to write. Do not add a coordinator, parent, planning, or
> supervising bead. Do not chain workers via depends-on edges. Each
> worker is a root AND a sink — a truly independent leaf.

Result: **idiom 5/5, persona 4/5, shape 4/5, overall 4/5**. The bias is
*largely correctable* with explicit topology guidance. The 1 residual
failure was a different mode entirely: sonnet hallucinated an 8th worker
bead for `base.py`, which is in the starting state but not in scope to
modify. So the strong instruction fixed the "extra coordinator" bias but
exposed a different "extra worker" tendency. **The architecture biases
toward adding nodes; the type of node varies but the urge to add structure
persists.**

## Per-rep detail (sonnet baseline, N=10)

All 10 reps picked `fanout` for the idiom. Shape variants:

- 8 reps: 1 root + 7 sinks, max_depth 2, fan_in_to_sink 1 — coordinator → 7 workers
- 2 reps: 1 root + 1 sink, max_depth 3, fan_in_to_sink 7 — coordinator → 7 workers → 1 integrator

## Cross-case calibration signal

Combined with `enum-extension`:

| Failure mode | enum-extension | validator-suite |
|---|---|---|
| Wrong idiom | rare for sonnet (most picks defensible) | n/a (sonnet picks correctly) |
| Under-decomposed (batching) | 3/10 sonnet (2-classes-per-worker) | not observed |
| Over-structured (adds coordinator) | not observed (every persona had real work) | 10/10 sonnet (coordinator with no real work) |
| Opus failure rate | 0/10 | 0/10 |

Sonnet's two failure modes (under-decompose on real-shared-state, over-
structure on no-shared-state) are oppositely-signed: in both cases it
reaches for *more aggregation than the case wants*. Opus produces the
right granularity in both directions.

This is exactly the kind of calibration signal the bench is for. The
worker-layer calibration found sonnet was Goldilocks for execution (haiku
too weak, opus one-shots everything). The architect-layer calibration
finds opus is preferred for decomposition — the role split in
`position.md`'s terminology note is empirically grounded for the first
time.

## Follow-ups

1. **Stronger no-coordinator instruction**: try a per-shape constraint
   ("the graph MUST have exactly N root beads where N equals the number
   of independent files to write"). Does sonnet comply fully?
2. **Probe the bias source**: is it the idiom library teaching sonnet that
   coordinators are normal? (The library has examples with parent beads.)
   Run with a stripped-down library showing only fire-and-forget. Does
   sonnet still add a coordinator?
3. **A case between these two**: something that genuinely needs a small
   amount of coordination but not full synthesis-pipeline (e.g., 2-3
   workers extending a 1-line shared constant). Where does sonnet sit on
   the structure spectrum then?
