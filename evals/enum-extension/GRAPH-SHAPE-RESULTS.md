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

## Designless variant (2026-05-23)

To test whether opus's 10/10 is intrinsic architect skill or relied on
the file-layout hint in `spec.md`, ran both models against a stripped
design (`evals/enum-extension/design-stripped.md`) — same task intent,
but no `## Layout` block enumerating each `errors/*.py` file. Just prose
about "shared enum / shared registry / six concrete classes."

Runner extension: `SPEC_FILE_OVERRIDE` env var swaps the input file.

| Model | N | Primary | Alternate | **Sound** | Broken |
|---|---|---|---|---|---|
| opus 4.7 (spec'd) | 10 | 10/10 | 0/10 | **10/10** | 0/10 |
| **opus 4.7 (designless)** | 5 | 1/5 | 2/5 | **3/5** | 2/5 (plain fanout) |
| sonnet 4.6 (spec'd) | 10 | 2/10 | 4/10 | 6/10 | 4/10 |
| **sonnet 4.6 (designless)** | 5 | 0/5 | 4/5 | **4/5** | 1/5 |

### Headline (designless)

**The opus-vs-sonnet gap inverts.** With the file layout enumerated,
opus dominates (10/10 vs 6/10). Without it, sonnet edges ahead (4/5 vs
3/5) — its two-phase-commit default happens to be the right shape for a
shared-state case more often than opus's "find the right idiom from
scratch" search.

### Where opus fails without the layout

Both opus designless failures picked **plain `fanout` with 6-7 workers
and no shared-state owner.** Reasoning quotes:

- "Six near-identical per-class implementations are naturally independent
  work units; fan-out scales linearly."
- "Six structurally identical class implementations are independent
  per-class work; fanout scales naturally."

Without the file enumeration explicitly distinguishing per-class files
(`not_found.py`, etc.) from shared infrastructure (`codes.py`,
`registry.py`), opus's instinct is "6 identical things = parallel fanout."
The layout block in `spec.md` was effectively highlighting "these two
files are NOT your own per-class file." That hint was carrying real
structural information.

### Implication

The architect-quality finding has a hidden dependency on **how design
docs surface shared-state risk.** Opus is a competent architect when the
shared infrastructure is visibly distinct from the per-leaf work; without
that signal it sometimes misses the structure entirely.

Two consequences:

1. **Real-world architect runs need design docs that surface shared-state
   explicitly.** Bullet lists of "files this work will touch" aren't
   decoration — they're the load-bearing signal that distinguishes
   "fanout works" from "fanout will race-write."
2. **The "opus wins" finding from the spec'd runs is partly a finding
   about the prompt**, not just the model. A bench that uses well-scoped
   design docs flatters opus more than a bench with terse prose.

This doesn't undo the prior result — opus *is* better at translating
explicit-layout design docs into the right graph — but it does narrow
the claim. The architect role isn't a pure capability test; it's a
capability × prompt-quality interaction.

## Stripped-library variant (2026-05-23)

Companion to the validator-suite stripped-library probe. Same probe
library (`evals/_probes/idioms-fanout-only.md`), this time on the
shared-state case. The library only offers fire-and-forget fanout —
which is the *wrong* shape for enum-extension because workers can't
extend shared state in isolation.

| Model | N | idiom | persona | shape | structurally sound |
|---|---|---|---|---|---|
| opus 4.7 | 5 | 5/5 fanout | 0/5 | 0/5 | **0/5** |
| sonnet 4.6 | 5 | 5/5 fanout | 0/5 | 0/5 | **0/5** |

### Headline (stripped library, enum-extension)

**Both models obey the library as a hard constraint.** Neither tier
went off-library to add a contract-author / merger / coordinator bead
even though the case structurally requires one. They produced plain
fanout 5/5 each.

Opus was more *scope-disciplined* (5/5 reps with exactly 6 workers, one
per error class); sonnet ranged 6-8 workers per rep (some off-by-one
hallucinations). But neither found a way to encode the shared-state need
because the library didn't give them an idiom that allows it.

### Refined library-sensitivity picture

Combining this with the validator-suite stripped-library result:

| Library behavior | Opus | Sonnet |
|---|---|---|
| Default-shifting (idiom preference bias) | No | **Yes** |
| Enumeration constraint (won't go off-menu) | **Yes** | **Yes** |

The library is a **hard constraint on idiom choice for both tiers**.
What differs is whether it *also* shifts the model's structural defaults.
Sonnet absorbs the library's hierarchical examples as preferences;
opus doesn't.

The practical implication for real-world use is sharper than the
earlier "library biases sonnet" finding suggested: **the library
defines the architect's solution space.** Both tiers will pick from
what's offered — they won't invent shapes outside the menu. So library
curation directly determines what structural moves the architect can
make, regardless of tier. The tier-distinction is only about whether
the *order* of presentation (or relative prominence of hierarchical
vs flat examples) biases the default pick.

## Follow-ups

1. **Designless N=10**: replicate the 3/5 vs 4/5 finding with N=10 each.
   The current numbers are suggestive, not confirmed (would benefit from
   tighter CI).
2. **Why does sonnet batch?** Hand-read the 3 "incomplete" reps to see
   whether it's confused about the case (3 classes vs 6), or genuinely
   choosing 2/worker as a structural decision. (Look at reasoning fields.)
   — partially done; reasoning explicitly says "three parallel
   implementer beads," confirming conscious choice.
3. **Execute the two sound idioms back-to-back**: run synthesis-pipeline
   AND two-phase-commit-with-contract-author on enum-extension at the
   worker layer. Do both 100%? Or does one fail in practice for reasons
   the plan-only eval can't see (e.g., contract-author has to guess all
   the enum names ahead of time, vs. merger gets to see the worker output
   first)? This would resolve the "which is better" question empirically.
4. **`EXTRA_INSTRUCTION` and `SPEC_FILE_OVERRIDE` knobs** added to the
   runner (env vars) — lets us probe variations without forking the
   runner. Useful for exploration but not the default mode.
