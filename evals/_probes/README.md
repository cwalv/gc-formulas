# `_probes/` — plan-evals probe artifacts

This directory holds **probe inputs** for plan-evals — not real eval
cases. Each file here is a hand-authored variant of some bench input
(idioms library, design doc, etc.) used to investigate a specific
architect/worker-quality question, then committed so the experiment is
re-runnable.

Use the leading underscore on the directory name so the eval driver's
case discovery doesn't pick these up as runnable cases.

## Current probes

### Idiom library variants

These swap in for `docs/choreography-idioms.md` via the
`IDIOMS_FILE_OVERRIDE` env var on `scripts/eval-graph-shape.sh`.

- **`idioms-fanout-only.md`** — exposes only the fire-and-forget fan-out
  idiom (1 of 5). Used to test whether sonnet's "add a coordinator" bias
  on `validator-suite` is taught by the full library's hierarchical
  examples or intrinsic. **Finding:** taught. Sonnet 0/10 → 5/5 on
  validator-suite. Opus 10/10 → 5/5 (library-default-insensitive). Both
  tiers obey enumeration as a hard constraint (enum-extension 5/5
  fanout from both, even though that's structurally unsound for the
  shared-state case).

- **`idioms-half.md`** — exposes two idioms: fire-and-forget fan-out and
  synthesis-pipeline. Tests whether per-case library curation gives
  reliable sonnet-tier routing. **Finding:** sonnet 5/5 on
  enum-extension (picks synth-pipe cleanly without two-phase-commit
  available) + 3/5 on validator-suite (still adds synthesis-pipeline as
  unneeded merger 2/5 times). The "add structure" bias scales with
  number of coordinated idioms offered.

### Design-doc variants

These swap in for `evals/<case>/spec.md` via the
`SPEC_FILE_OVERRIDE` env var on `scripts/eval-graph-shape.sh`.

- **`evals/enum-extension/design-stripped.md`** — same case intent
  without the explicit file-layout enumeration. **Finding:** opus 10/10
  → 3/5 sound; sonnet 6/10 → 4/5 sound. The opus-vs-sonnet gap inverts.
  Layout enumeration was lifting opus from variable to perfect by
  surfacing the shared-state distinction.

- **`evals/validator-suite/design-stripped.md`** — same case intent
  without the explicit file enumeration. **Finding:** opus 10/10 → 2/5
  sound. 3/5 reps hallucinated an extra worker (probably for `base.py`).
  Confirms layout enumeration also does *scope-bounding* work, not just
  shared-state-surfacing.

## Why probes live in the repo

They're cheap to author and quick to re-run; the value is in
reproducibility. A finding like "sonnet's structural bias is taught,
not intrinsic" is hand-wavy without the exact library file that
produced 5/5. Committing the file means the next observer can re-run
the probe and verify the claim from primary evidence.

These are *not* eval cases — they're inputs to existing eval cases
under a probe variant. See `evals/<case>/GRAPH-SHAPE-RESULTS.md` for
the per-case probe results write-ups.
