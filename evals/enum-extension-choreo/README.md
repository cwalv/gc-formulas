# Eval case: enum-extension-choreo

A choreographer-eval variant of `enum-extension`. The implementation task
is identical (complete the six error classes), but the bead graph starts
**deliberately incomplete** — some work that implementers will discover is
omitted from the initial graph. The choreographer's job is to reshape the
graph in response to worker close signals.

## What this case tests

Where `enum-extension` tests worker-layer patterns (ralph / fanout /
sectioning / orchworkers), `enum-extension-choreo` tests the **choreographer**
tier: given a partial initial graph and a stream of pre-decided worker signals,
does the choreographer respond correctly?

- `impl-not-found` signals `revealed-additional-work` → choreographer should
  spawn "Add abstract method to BaseError".
- `impl-rate-limit` signals `blocked / AMBIGUOUS-SPEC` → choreographer should
  flag for human review (not re-sling).
- `impl-validation` signals `out-of-scope` with `suggest: evaluator` →
  choreographer should reassign to the evaluator pool.
- `impl-conflict`, `impl-timeout`, `impl-unauthorized` signal `completed` →
  choreographer should take no action (no spurious spawns).

Scoring adds a **mutation rubric** on top of the standard pass-rate axes:
`mutation_recall`, `mutation_precision`, `forbidden_violations`, `terminal_state_ok`.

## Contents

```
enum-extension-choreo/
├── README.md               (this file)
├── spec.md                 (same as enum-extension)
├── starting-state/         (same as enum-extension)
├── visible-tests/          (same as enum-extension)
├── hidden-tests/           (same as enum-extension)
├── fanout.json             (same as enum-extension)
├── initial-graph.json      (under-specified starting graph for the choreo run)
├── worker-signals.json     (pre-decided signals per bead for deterministic workers)
└── reference-mutations.json (expected + forbidden choreographer mutations)
```

## Design source

`docs/choreographer-eval.md` (fragment commit 501ba17). This bead
implements Phase C of plan-evals.

## Scoring axes

| Axis | Definition |
|---|---|
| `mutation_recall` | expected mutations that occurred / expected total |
| `mutation_precision` | mutations matching expected set / total mutations made |
| `forbidden_violations` | count of mutations matching `forbidden_mutations` |
| `terminal_state_ok` | all open beads closed OR human-flagged at loop exit |
| `visible_pass`, `hidden_pass` | standard pytest pass-rate on the worktree |

Structurally sound: `mutation_recall >= 0.66 AND forbidden_violations = 0 AND terminal_state_ok`.
