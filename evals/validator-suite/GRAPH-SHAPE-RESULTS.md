# validator-suite graph-shape results

Phase B (architect-quality) eval. See sibling `enum-extension/GRAPH-SHAPE-
RESULTS.md` for framework framing.

## Reference shape

- Idiom: `fanout` (fire-and-forget)
- 7 worker beads (one per validator: email, phone, credit_card, iban, isbn,
  semver, url). No merger.
- Topology: 7 roots, 7 sinks, max_depth 1, fan_in_to_sink 0.

The reference has **no parent / coordinator bead** because the `Reason`
enum and `Validator` ABC are pre-stocked. Workers genuinely don't need
to coordinate. The honest shape is 7 independent leaves.

## Results

| Planner model | N | idiom | persona | shape | overall |
|---|---|---|---|---|---|
| **opus 4.7** | 10 | 10/10 | 10/10 | 10/10 | **10/10** |
| sonnet 4.6 | 5 | 5/5 | 0/5 | 0/5 | 0/5 |

## Headline finding

**Opus produces the honest shape; sonnet always adds an unneeded coordinator.**
Sonnet picks `fanout` correctly (idiom 5/5), but inserts a parent bead in
every rep — typically titled something like "Coordinate validator
strengthening" or "Plan validator updates" — yielding a 1-root / 7-sink graph
with fan_in_to_sink=1 (each worker depends on the coordinator), instead of
the reference's 7-root / 7-sink shape with no dependencies at all.

This is the "add a manager" bias: when given a multi-worker task, sonnet
reaches for a hierarchical shape even when the task is genuinely embarrassingly
parallel. The coordinator bead does no work (the contract is already in
`Validator`/`Reason`), so it's pure overhead that real execution would have
to either skip or no-op through.

Opus, in contrast, produces a flat fan of 7 independent leaves every time —
matching what the idiom library calls "fire-and-forget."

## Per-rep detail (sonnet)

5/5 reps: idiom=`fanout`, 8 nodes (1 coordinator + 7 workers) — except one
rep with 9 nodes (1 coordinator + 7 workers + 1 verifier/integrator). Shape:
1 root, 7 sinks, max_depth 2, fan_in_to_sink 1 (4 reps) or 1 root, 1 sink,
max_depth 3, fan_in_to_sink 7 (1 rep — chained the coordinator → workers → 1
integrator).

## Token cost

~5 tokens in, ~535 tokens out per planner call.

## Cross-case calibration signal

Combined with `enum-extension`:
- Opus is consistently right on both cases at N=10 (10/10 overall on each).
- Sonnet is consistently wrong on both, but in different ways:
  - enum-extension: picks the wrong idiom (two-phase-commit vs synthesis-
    pipeline) → mis-allocates cross-file authority.
  - validator-suite: picks the right idiom but adds an unneeded coordinator
    → over-structures embarrassingly-parallel work.

The pattern: sonnet's architect output skews toward more structure than
the case warrants. On the easy case it over-structures; on the hard case it
picks a structure that *looks* like more coordination but actually
under-protects shared state.

## Follow-ups

1. **N=10 for sonnet** (same as the enum-extension follow-up).
2. **Sonnet under "no coordinator" instruction**: if we tell sonnet
   explicitly "do not include any coordinator/parent bead unless absolutely
   required," does it produce the flat fan? That would distinguish
   "doesn't know better" from "biased toward more structure."
3. **A case between these two**: something that genuinely needs a small
   amount of coordination but not full synthesis-pipeline (e.g., 2-3
   workers extending a 1-line shared constant). Where does sonnet sit on
   the structure spectrum?
