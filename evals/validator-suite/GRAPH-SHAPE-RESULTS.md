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
| opus 4.7 designless (`design-stripped.md`) | 5 | 5/5 | 2/5 | 2/5 | **2/5** |
| sonnet 4.6 + stripped library (fanout-only) | 5 | 5/5 | 5/5 | 5/5 | **5/5** |

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

## Stripped-library variant (sonnet 4.6, N=5)

Probes whether sonnet's "add a coordinator" bias is **taught by the
choreography-idioms library** or intrinsic to the model. The full library
(`docs/choreography-idioms.md`) presents five idioms — fanout, synthesis-
pipeline, critique-loop, two-phase-commit, gatekeeper. Four of them have
explicit hierarchy (a parent / synthesizer / contract-author / merger
bead aggregating children). Hypothesis: sonnet reads "good graphs have
hierarchy" from this curriculum and applies it to embarrassingly-parallel
cases too.

Stripped library (`evals/_probes/idioms-fanout-only.md`) shows ONLY the
fire-and-forget fan-out idiom, with the explicit framing "there is no
parent bead, no coordinator bead — the leaves are the entire graph."

Pointed the runner at the stripped library via `IDIOMS_FILE_OVERRIDE` env
var (added to `eval-graph-shape.sh` for this probe).

### Result

| Library | Model | N | idiom | persona | shape | overall |
|---|---|---|---|---|---|---|
| full library | sonnet | 10 | 10/10 | 0/10 | 0/10 | **0/10** |
| stripped (fanout-only) | sonnet | 5 | 5/5 | 5/5 | 5/5 | **5/5** |
| full library | opus | 10 | 10/10 | 10/10 | 10/10 | **10/10** |
| stripped (fanout-only) | opus | 5 | 5/5 | 5/5 | 5/5 | **5/5** |

**The bias is taught, not intrinsic — but only for sonnet.** When the
library only models fire-and-forget, sonnet correctly produces the flat
7-leaf fan. The "add a coordinator" preference is *learned from the
library's hierarchical examples* and applied even when those examples
don't fit the case.

Opus is **library-insensitive**: full library and stripped library both
yield perfect flat fans on validator-suite. Opus's structural judgment
is robust against the library's framing in a way sonnet's isn't.

This is a clean tier-distinction signal: **opus's architect-quality
*default* is library-independent; sonnet's is library-dependent.**
Combined with the designless variant (opus IS spec-dependent for scope
discipline) and the enum-extension stripped-library probe (both tiers
obey the library's enumeration as a hard constraint, neither goes
off-menu), this gives a layered picture:

| Sensitivity axis | Opus | Sonnet |
|---|---|---|
| Spec content (file enumeration) | Yes (scope discipline) | Yes (worse) |
| Library default-shifting (which idiom is preferred) | No | Yes |
| Library enumeration (won't go off-menu) | **Yes** | **Yes** |

The third row is the sharpest practical implication: **the library
defines the architect's solution space for both tiers.** Neither model
invents idioms outside what the library offers. So library curation
directly determines what structural moves are available, regardless of
tier. Tier-distinction is about *defaults* within the available menu,
not *expansion* of the menu.

See `evals/enum-extension/GRAPH-SHAPE-RESULTS.md` "Stripped-library
variant" for the enumeration-constraint experiment.

### Library breadth vs. correctness — sonnet's continuum

Three points on the library-breadth axis for sonnet on validator-suite:

| Library | Idioms offered | Sound rate (validator-suite) |
|---|---|---|
| Full (`choreography-idioms.md`) | 5 (fanout + 4 hierarchical) | 0/10 |
| Half (`evals/_probes/idioms-half.md`) | 2 (fanout + synthesis-pipeline) | 3/5 |
| Stripped (`evals/_probes/idioms-fanout-only.md`) | 1 (fanout only) | 5/5 |

The "add structure" bias **scales with the number of coordinated idioms
offered.** Even when sonnet has only two options on validator-suite, it
picks synthesis-pipeline 2/5 — adding a merger that has nothing to merge.
The only library variant where sonnet reliably produces a flat fan on an
embarrassingly-parallel case is the one that doesn't *have* a coordinated
alternative.

For enum-extension (shared state), sonnet with half library is 5/5
perfect synthesis-pipeline — without two-phase-commit available, it
defaults cleanly to synthesis-pipeline.

The practical implication: **per-case library curation is the path to
reliable sonnet-tier architect quality.** A pre-routing step that
decides "this case has shared state, show synthesis-pipeline; this case
doesn't, show only fanout" would let sonnet hit 5/5 on both. Without
that routing, sonnet's structural bias leaks proportionally to how many
coordinated idioms it sees.

### Implication

The choreography-idioms library is doing real work — and the work is
**not just providing options the architect picks from.** It's actively
biasing the architect's structural preferences. For real-world use:

1. **Per-case library curation**: show the architect only the idioms
   that could plausibly fit. (Would require a routing layer above the
   architect — "is this shared-state or parallel? show only matching
   idioms.")
2. **Reframe the library**: make fire-and-forget the explicit baseline
   ("only add structure if shared state forces it"). Other idioms are
   *exceptions*, not equal options.
3. **Use opus for the architect role**: opus appears less library-
   influenced — it produced flat fans on validator-suite with the full
   library, where sonnet over-structured. (Spec'd data; the designless
   probe shows opus has its own dependencies.)

This is the kind of finding that's almost impossible to surface without
a bench — "the prompt library is the bias" looks like a generic warning,
but having two N=10 distributions and one N=5 distribution that flip
the headline (0/10 → 5/5) makes it concrete.

## Designless variant (opus 4.7, N=5)

Companion to the enum-extension designless variant. Validator-suite's
spec.md enumerates each validator file (`validators/email.py`, etc.) and
explicitly says "implementing one doesn't require touching another."
Strip that to higher-level prose only ("a set of input validators...
the starting state directory tree shows the file layout"):

| Model | N | idiom | persona | shape | overall |
|---|---|---|---|---|---|
| opus 4.7 (spec'd) | 10 | 10/10 | 10/10 | 10/10 | 10/10 |
| opus 4.7 (designless) | 5 | 5/5 | 2/5 | 2/5 | **2/5** |

### What goes wrong without the layout enumeration

Opus designless picked `fanout` correctly 5/5 (no coordinator-bias —
that's intrinsic, not layout-hint-driven). But 3/5 reps had 8 workers
instead of 7; opus hallucinated an extra worker, presumably for a file
in the starting state that wasn't supposed to be in scope (`base.py`,
maybe). Same failure mode sonnet showed when given the strong
no-coordinator constraint earlier.

### Implication

The file-layout enumeration in spec.md was doing **two** things, both
load-bearing:

1. **Surfacing shared infrastructure** (e.g., `codes.py` + `registry.py`
   for enum-extension) so the architect knows what's NOT a per-leaf file.
2. **Bounding worker scope** — telling the architect which files in the
   starting state are in scope for fan-out and which aren't.

Stripping the enumeration hurts opus on validator-suite via (2) — it
over-counts workers. On enum-extension it hurt via (1) — opus sometimes
picked fanout-without-shared-state-owner.

Opus's structural instincts (no coordinator, leaf-only fan) survive
without the layout. Its **scope discipline** doesn't — it needs the
explicit file list to bound the work. Sonnet has both problems; opus
has just the scoping one.

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
