# gc-formulas docs

Working docs for the foundations agent-orchestration position and its
validation. Designed to be short and load-bearing.

The formula/molecule workflow runtime this repo was originally built
around is abandoned (2026-07-25 reorg) — `position.md`'s
model-as-orchestrator side won per the operator verdict, validated by
the choreograph practice. What survives is the theory, the empirical
evidence, and the bench harness that produced it.

| Doc | Purpose |
|---|---|
| [`position.md`](position.md) | The architectural position + 5 testable claims |
| [`principles.md`](principles.md) | Load-bearing design principles |
| [`choreography-idioms.md`](choreography-idioms.md) | The idiom library: Phase A/B/C lifecycle + five graph-shape templates |
| [`state.md`](state.md) | Frozen claim-1 validation record |
| [`plan-evals.md`](plan-evals.md) | The live empirical-evidence hub: findings tables, architect-tier results, the bench methodology |
| [`choreographer-eval.md`](choreographer-eval.md) | Choreographer-tier eval design: role contract, worker signaling vocabulary, mutation rubric |
| [`two-phase-commit-eval.md`](two-phase-commit-eval.md) | Two-phase-commit choreography idiom eval design |
| [`beads-ui-docs-refresh-runbook.md`](beads-ui-docs-refresh-runbook.md) | Runbook: refreshing the beads-ui handbook against upstream tips |
| [`journey.html`](journey.html) | Generated narrative of the four-phase pivot from formula pack to model-as-orchestrator |
| [`deleted.md`](deleted.md) | Index of what the 2026-07-25 reorg removed, with recovery instructions |

Start with `position.md`.

## Where the rest went

The formula runtime (`formulas/`, `pack.toml`, `prompts/`), the
validation-pack container rig, and several docs (`throughput-mode.md`,
`debugging.md`, `per-orchestrator-runners.md`, `docs/archive/`) were
deleted in the 2026-07-25 reorg. See [`deleted.md`](deleted.md) for
the one-line-per-item index of what's recoverable and how; everything
is recoverable via `git show pre-reorg-2026-07-25:<path>` regardless
of whether it has an index entry.

Six tools from validation-pack survive, relocated (still live,
formula-runtime-independent):

- [`../personas/choreographer.md`](../personas/choreographer.md) —
  the choreographer role contract + worker signaling vocabulary,
  consumed by `scripts/eval-choreographer.sh`.
- `../tools/scripts/verify_bead_state.py` (+ `../tools/fixtures/`) — a
  general bead-DAG predicate engine, formula-independent.
- `../tools/scripts/bd-record-shim.sh`, `../tools/scripts/replay-bd.sh`
  — bd invocation trace/replay forensics.

The bench (`scripts/eval-*`, `evals/`) is unaffected and still
re-runnable against new models — it never depended on the runtime.
