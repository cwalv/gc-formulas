# Throughput / orchestration mode — open design questions

The existing 7 scenarios are unit tests of orchestrator primitives: each
boots a fresh city, runs one workflow end-to-end, tears down. That validates
"can the orchestrator do *one* workflow correctly?" The per-scenario container
isolation is load-bearing for that goal.

The orchestrator's actual purpose, though, is different: take a backlog of
work, drain it, scale workers up/down as the queue grows/shrinks, recover
from individual failures without losing the queue. We don't currently test
any of that.

This doc captures the questions we'd want to answer before building a
throughput/orchestration mode. The unit-test scenarios stay as the regression
layer; this would be an additional layer on top.

## What the new mode tests

Three orthogonal axes that the unit-test layer doesn't surface:

1. **Throughput.** N workflow instances in, total wall-clock to drain.
   Comparable across orchestrators ("gc drains 21 in T1, ntm drains 21 in T2,
   bare bd+bash drains 21 in T3"). Currently we can only say "both pass 7/7
   unit tests" — no throughput comparison.

2. **Worker elasticity.** Does the orchestrator spawn new workers when the
   backlog grows, drain them when it shrinks?
   - gc has explicit pool semantics (`min_active_sessions`, scale_check,
     pool reconciler) — testable.
   - ntm has no reconciler. For ntm this axis collapses to "given a fixed
     pool of M workers, can it drain N>M items?" Still useful as a separate
     question.

3. **Fairness / starvation.** When multiple personas have work, does the
   orchestrator interleave or starve one? Especially mixed iterative
   (evaluator-optimizer) + one-shot (agent-loop) loads where pool slots
   could lock up around the iterative pattern.

## Open questions

### Scale

- How many work items? Big enough to exercise scaling, small enough to fit a
  reasonable test budget. Candidate: 14-21 (each of the 7 patterns × 2-3
  instances).
- Should the load be heterogeneous (mix of patterns) or homogeneous (N copies
  of one pattern)? Heterogeneous is closer to real workloads; homogeneous
  is cleaner to reason about. Maybe both, as separate sub-scenarios.

### Success predicate

- "All beads close with expected reasons within T seconds." T calibrated per
  orchestrator — but absolute time isn't meaningful without baseline. Likely
  shape: T<sub>orch</sub> / T<sub>bd-only-bash-baseline</sub> ≤ some ratio.
- Or: "no beads still open after queue drain signal" + "all expected
  per-bead predicates pass" (i.e., the per-pattern fixture predicates from
  the unit-test layer, run against the batch).

### Observability

- How do we observe the worker pool over time? Options:
  - Sample `gc session list` every N seconds, build a timeseries.
  - Subscribe to `gc events --watch --type session.*` and record.
  - Read from gc's pool-state internal API if exposed.
- The output is "workers active over time" + "work pending over time"; a
  successful run shows the active line rising with the pending line then
  draining together.

### Container model

- The new mode requires container reuse (boot once, run N workflows). The
  per-scenario container isolation we use today fights this goal.
- Likely shape: `docker compose up -d` once, then drive the batch via
  `docker exec` calls or a host-side coordinator that pours wisps and waits.
- Cleanup between workflows: drain stale claimed-but-dead beads, prune
  finished sessions. The "wisp-compact" maintenance order would have done
  this in gascity; we stripped it. Need to either re-add or do it manually.

### Bead-store growth

- Across many workflows the supervisor accumulates background beads (mol-dog
  bookkeeping, autoclose hooks, continuation_group state). Eventually `bd
  ready` and `bd list` slow down. At what N does this start mattering?
- Mitigation: enable wisp-compact, or call `bd close` on closed-but-not-yet-
  pruned wisps periodically.

### Per-orchestrator scope

- For gc: full elasticity + throughput + fairness all testable.
- For ntm: throughput + fairness testable; elasticity testable only as
  "fixed pool drains backlog" since ntm has no reconciler. This is itself a
  useful comparison point — quantifies the value of a reconciler.

### Persona model

- Currently we ship 4 personas (foreman, implementer, evaluator, treehugger)
  × 2 shims = 8 files. Many beads are routed by `--assignee=validation/<persona>`.
- For the throughput mode it might make sense to collapse to one generic
  "worker" persona whose role-specific behavior is *in the bead description*
  (matches gascity's "ZERO hardcoded roles" principle — see
  github/gastownhall/gascity/AGENTS.md). Treats each bead's spec as the
  contract; the persona is just an executor.
- Tradeoff: less specialization in the persona prompt (no foreman-vs-
  treehugger work-loop differences) vs much simpler scenario authoring
  + better matches the gascity SDK design. Worth a sub-experiment.

### Failure injection

- The orchestrator's job includes recovering from individual workflow
  failures without losing the queue. Should the throughput mode include
  fault injection (kill an agent mid-flight, drop a bead) to test recovery?
  Open question — could be Phase 2 of this work.

### Composition + catalog redundancy

The 7 Anthropic patterns aren't orthogonal primitives — they're idioms.
Structurally, 02 (routing), 03 (sectioning), 04 (voting), and 05
(orchestrator-workers) are all variations of one fan-out shape parameterised
by `(decompose_yes/no, fan_out_N, aggregation_kind)`:

| Pattern | Decompose? | N | Aggregation |
|---|---|---|---|
| 02 routing | no | 1 | none |
| 03 sectioning | no | fixed | simple join |
| 04 voting | no | fixed | consensus |
| 05 orchestrator-workers | yes | dynamic | validation + land |

Our existing scenarios prove the skeleton works under each parameter
combination. Useful for the unit-test layer (each variation does work as
advertised). Less useful for the integration layer — there's no scenario
that *combines* shapes, and combination is what real agent systems actually
do.

**The composition mechanic is already free in bd/molecule:** a step in a
parent formula is itself the root of a child formula. When the persona
running a step calls `bd mol wisp <child-formula>` from inside the step's
work body, bd creates a child wisp whose root inherits the parent step as
its parent. `bd dep tree` shows it as nested; the parent's `shim_await`
blocks until the child's terminal bead closes. No new infrastructure
needed.

A scenario that would test this:

```
nested-workflow root
└── step-orchestrate (implementer persona; bead description says
                       "pour orchestrator-workers for this task")
    └── orchestrator-workers child wisp
        ├── step-orchestrate (foreman)
        ├── step-implement-1 (impl)
        ├── step-implement-2 (impl)
        └── step-land (treehugger) → closes; parent step sees it
```

Verifier predicates:

- Parent bead closes only after the child wisp's terminal bead closes
  (timestamp ordering).
- Parent's `comments_contain` includes a marker only the child workflow
  could have written (e.g., the treehugger's `landed` summary).
- `bd dep tree <parent-root>` shows the nested structure.

What this tests that the existing scenarios don't:
- The composition mechanic (parent waits on child wisp; bd handles the
  dependency edge correctly).
- The bead-as-spec idea — role behaviour lives in the bead's description,
  not the persona prompt. The parent step's persona is just "implementer";
  the *bead description* says "pour child workflow X". Same persona could
  do many things based on what its bead says.
- A natural subsumption of the redundant fan-out variants — if you have
  one composing-scenario + one fan-out scenario, the rest become
  parameter combinations you can derive rather than scenarios you have
  to maintain.

Open questions before building it:

- How does the bead-as-spec idea interact with the persona work-loop's
  poll behaviour? The implementer persona currently polls `bd ready
  --assignee=validation/implementer`. If the step's bead description says
  "do X" but X happens to be "pour child workflow", does anything in the
  work-loop need to know? Hopefully no — pour is just another bd command.
- Aggregation across composed levels: if the child wisp produces N comments,
  does the parent step see them, or does it see only the child's terminal
  close event? The parent step's persona needs to read child outputs
  somehow. Likely: `bd show <child-terminal-bead> --json` from the parent's
  step body. Worth verifying.
- Does this make the catalog redundancy actively wasteful? Or does each
  variant still earn its keep as a unit-test fixture? Argument for keeping:
  shape-level regression coverage. Argument for collapsing: maintenance cost.

## Non-goals

- Replacing the unit-test scenarios. They stay as the regression layer.
- Cross-orchestrator code sharing — gc and ntm can have separate driver code
  for the new mode if it's cleaner. The shim layer abstraction is for the
  per-scenario unit tests.
- LLM-driven mode initially. Fake-worker should be the first cut so we're
  measuring orchestrator throughput, not LLM throughput.

## Plan-ish

Phase 0 (this doc): capture questions.
Phase 1: pick concrete answers for scale + success predicate + observability,
build a single-orchestrator throughput driver.
Phase 2: cross-orchestrator comparison, add elasticity + fairness axes.
Phase 3: failure injection + recovery.
