# Choreographer eval — design fragment

Status: design only; implementation deferred to a child bead.

Sibling docs: [`plan-evals.md`](plan-evals.md), [`choreography-idioms.md`](choreography-idioms.md), [`per-orchestrator-runners.md`](per-orchestrator-runners.md), [`two-phase-commit-eval.md`](two-phase-commit-eval.md).

## Why

Per `plan-evals.md` "What the bench actually tests (architect vs choreographer vs worker)", the bench has three roles to measure. Architect (Phase A→B static decomposition) is covered by the graph-shape eval. Worker (Phase C leaf work) is covered by the pattern runners (ralph/fanout/sectioning/orchworkers). The **choreographer** — centralized but **reactive**, observing worker close signals from a partial graph and mutating the graph in response — has no eval.

The substrate prerequisite (real bd-graph participation, not bash-parallelised `claude -p`) is now in place via fo-07nux's `eval-{gc,ntm}.sh`. This bead designs the eval that lives on top.

**Load-bearing experimental question:** does an LLM choreographer respond sensibly to worker signals — spawning the right child beads on revealed work, re-routing on blockers, escalating on out-of-scope, avoiding spurious mutations?

## Role boundaries (worth being explicit)

| Role | When it acts | What it can do | What it cannot do |
|---|---|---|---|
| Architect (foreman) | Once, before workers start | Initial graph decomposition | Mutate the graph mid-run |
| Choreographer | Continuously, while workers run | Spawn child beads, re-route, escalate, close beads | Do leaf work itself |
| Worker (implementer) | When its bead becomes ready | Edit files in its scope, close with structured signal | Read other beads, spawn children |

The choreographer is a *new persona* — not an extension of the foreman. The foreman is one-shot; the choreographer is event-driven. Both could exist in a single run (foreman lays initial graph; choreographer reshapes it as workers signal).

## Worker signaling vocabulary

Workers close beads with a **close reason** plus, when applicable, a **structured comment** the choreographer parses.

Canonical close reasons (extending the existing `completed` / `blocked` set):

| Reason | When | Structured comment shape |
|---|---|---|
| `completed` | Work done as specified, nothing more needed | None required |
| `blocked` | Couldn't progress | `BLOCKER: <code> — <one-line detail>` where code ∈ {MISSING-FILE, AMBIGUOUS-SPEC, DEP-FAILED, ENV-MISSING, OTHER} |
| `revealed-additional-work` | Work done, but discovered new work | One or more `SPAWN: <title>` lines, each optionally followed by `DESC: <description>` |
| `out-of-scope` | Bead asks for work outside this worker's competence | `OUT-OF-SCOPE: <one-line reason>; suggest re-route to <persona>` |

The vocabulary is universal across cases. It lives in `personas/implementer.md` (one-time persona update; not per-bead).

**Workers do not** spawn beads themselves, do not read sibling beads, do not re-route. They emit signals and close. Discipline matters — the choreographer's job is meaningless if workers cross the line.

## Choreographer persona

`validation-pack/personas/choreographer.md` — new persona, lifecycle:

```
1. Connect to bd substrate.
2. Loop:
   a. Poll bd list --status=closed --since=<watermark> for newly-closed beads.
      (gc events --watch is noisier — its --payload-match doesn't descend into
      nested fields, so we can't filter to a bead. Polling against bd's own
      state is authoritative; 5s cadence keeps latency human-perceptible.)
   b. For each newly-closed bead:
       i.   Read close_reason + comments.
       ii.  Interpret per the worker-signaling vocabulary above.
       iii. Decide and execute graph mutation:
            - completed              → no-op (advance watermark only)
            - blocked / OTHER        → bd update <id> --status=open and notes; sling to same pool for retry
            - blocked / DEP-FAILED   → identify failed dep, spawn fix-bead, add dep edge
            - blocked / AMBIGUOUS    → flag via bd human <id>; do not re-sling
            - revealed-additional-work + SPAWN lines → bd create one per SPAWN; route to appropriate pool
            - out-of-scope           → bd update <id> --assignee=<suggested persona>
   c. Update watermark to max(close_ts) seen.
   d. Check exit condition: no open beads other than the choreographer's own
      tracking bead, OR all open beads have at least one closed-or-spawned
      dependency chain to a leaf. (If neither: keep polling.)
3. On clean exit: drain-ack.
```

The choreographer **does not** edit files, does not run pytest, does not synthesise work output. It mutates the graph and stops.

## Case template — `enum-extension-choreo`

A variant of `enum-extension` (the existing shared-state stress case) re-engineered so the initial decomposition is **deliberately incomplete**.

```
evals/enum-extension-choreo/
├── README.md
├── spec.md                 (same as enum-extension's, but augmented with
│                            scripted "revealed work" hooks)
├── starting-state/         (same as enum-extension)
├── visible-tests/          (same)
├── hidden-tests/           (same)
├── fanout.json             (same)
├── initial-graph.json      (NEW — declares which beads start open + their signals)
├── reference-mutations.json (NEW — the choreographer's expected response graph)
└── worker-signals.json     (NEW — for deterministic-mode workers, pre-decided
                                 SIGNAL per bead)
```

**initial-graph.json**: the under-specified starting graph. For enum-extension-choreo:

```json
{
  "beads": [
    {"id": "epic",                "title": "Implement 6 error classes",  "type": "epic"},
    {"id": "design-codes",        "title": "Decide ErrorCode variants",  "needs": [],          "assignee": "validation/foreman"},
    {"id": "impl-conflict",       "title": "Implement ConflictError",    "needs": ["design-codes"], "assignee": "validation/implementer"},
    {"id": "impl-not-found",      "title": "Implement NotFoundError",    "needs": ["design-codes"], "assignee": "validation/implementer"},
    {"id": "impl-rate-limit",     "title": "Implement RateLimitError",   "needs": ["design-codes"], "assignee": "validation/implementer"},
    {"id": "impl-timeout",        "title": "Implement TimeoutError",     "needs": ["design-codes"], "assignee": "validation/implementer"},
    {"id": "impl-unauthorized",   "title": "Implement UnauthorizedError","needs": ["design-codes"], "assignee": "validation/implementer"},
    {"id": "impl-validation",     "title": "Implement ValidationError",  "needs": ["design-codes"], "assignee": "validation/implementer"},
    {"id": "land",                "title": "Land + reconcile",           "needs": ["impl-*"], "assignee": "validation/treehugger"}
  ]
}
```

The **missing** scope: nothing in the initial graph for "extend BaseError to support new abstract method", "add cross-error-class invariant tests", or "wire up registry helpers" — work the implementers will *discover* and *signal* about.

**worker-signals.json** (for deterministic mode): pre-decided signals per bead.

```json
{
  "impl-conflict":     {"reason": "completed"},
  "impl-not-found":    {"reason": "revealed-additional-work",
                        "spawns": [{"title": "Add abstract method to BaseError",
                                    "desc":  "Subclasses need a `code` property; lift to ABC"}]},
  "impl-rate-limit":   {"reason": "blocked", "blocker": "AMBIGUOUS-SPEC",
                        "detail": "Spec says rate-limit but doesn't define retry-after semantics"},
  "impl-timeout":      {"reason": "completed"},
  "impl-unauthorized": {"reason": "completed"},
  "impl-validation":   {"reason": "out-of-scope",
                        "suggest": "evaluator"}
}
```

**reference-mutations.json**: the choreographer's *expected* response.

```json
{
  "expected_mutations": [
    {"on_close": "impl-not-found",    "action": "spawn",  "title_match": "abstract method.*BaseError"},
    {"on_close": "impl-rate-limit",   "action": "human",  "note_match":  "ambiguous"},
    {"on_close": "impl-validation",   "action": "reassign", "to": "evaluator"}
  ],
  "forbidden_mutations": [
    {"action": "spawn", "after": "impl-conflict"},
    {"action": "spawn", "after": "impl-timeout"},
    {"action": "spawn", "after": "impl-unauthorized"}
  ]
}
```

## Scoring rubric

A new scoring dimension, layered on top of `eval-scorer.py`'s existing pass-rate output:

**mutation_recall** = (expected mutations that occurred) / (expected mutations total)
**mutation_precision** = (mutations matching the expected set or implied no-op) / (total mutations the choreographer made)
**forbidden_violations** = count of mutations matching `forbidden_mutations` entries
**terminal_state_ok** = boolean: did all open beads reach a closed state OR are explicitly human-flagged?

A run is **structurally sound** if: `mutation_recall ≥ 0.66 AND forbidden_violations = 0 AND terminal_state_ok`.

The thresholds are knobs. 0.66 recall accommodates one-out-of-three reasonable misses on the smallest expected-mutations set. Tune empirically once data lands.

Semantic-equivalence matcher: title regex on spawned-bead titles; persona-name equality on reassigns; bead-id resolution on human-flags.

## Runner shape — `scripts/eval-choreographer.sh`

Mirrors `eval-orchworkers.sh` / `eval-gc.sh` argument shape. Crucial differences:

1. **Three actors, two real**:
   - The **choreographer** is a real `claude -p` (or, for first-cut isolation, host-side scripted; see below).
   - The **workers** are scripted (deterministic mode) — bash that reads `worker-signals.json` and closes beads accordingly. No LLM, no file edits except as required to satisfy hidden tests.
   - A treehugger runs at the end (real LLM) only if the terminal state requires reconciliation.

2. **No formula**: the initial graph is materialised by the runner directly from `initial-graph.json` (one `bd create` per bead + `bd dep add` per edge). Formulas are static; the choreographer's job is to break the static contract.

3. **Choreographer execution mode** — two options the implementation bead decides between:
   - **(a) Single `claude -p` with poll loop in the prompt**: the agent runs the loop described in the persona once, then exits. Risk: agent's prompt has to encode the full loop including state tracking. Realistic but heavy.
   - **(b) Multi-turn `claude -p` driven by the host**: host polls bd; on each closed-bead event, invokes `claude -p` with the event context and consumes the suggested mutation. The host owns the loop; the agent owns the *decision*. Cleaner separation; cheaper to debug.
   Recommend **(b)** for first cut — keeps the scoring focused on per-event decision quality, isolates loop bugs from decision bugs.

4. **Smoke**: N=3 reps of `enum-extension-choreo × choreographer × deterministic-workers`. Score each on recall / precision / violations / terminal.

## Open questions (decisions deferred to implementation)

1. **Single-event prompt vs full-trace prompt** — should the choreographer see one event at a time (no memory of prior decisions) or the full trace so far? Recall is easier with trace; precision is easier with single-event. Recommend single-event for first cut; trace-based as follow-up.

2. **Choreographer model tier** — opus (architect-level reasoning) vs sonnet (worker-level)? The role is interpretation, not generation, so sonnet may suffice. Recommend sonnet for first cut; opus for the comparison axis.

3. **Forbidden-mutation severity** — fail-the-run vs warn-and-continue? Recommend warn-and-continue with the count surfaced in result JSON. The bench reports the data; doesn't gate on it.

4. **Worker LLM mode follow-up** — once deterministic-mode results are clean, swap deterministic workers for real LLM workers with the new signaling persona. Compare: does real-worker noise meaningfully change mutation_recall/precision? Separate bead.

5. **Multi-choreographer scale variant** — out of scope per the parent bead. Worth its own eval axis when corpus has cases big enough.

## T-shirt

**M+** (medium-plus).

Bounded mechanical work: choreographer persona (~150 lines), eval-choreographer.sh runner (~250 lines mirroring eval-orchworkers.sh structure), case directory + 3 JSON files (~200 lines hand-authored), scorer extension for mutation rubric (~150 lines). Smoke N=3.

What pushes it past M:
- The mutation rubric and reference-mutations.json are genuinely novel — likely 1-2 cycles of "the rubric over-penalises X" / "the rubric misses Y" before it stabilises.
- The host-driven loop in choreographer mode (b) is new substrate code, not a crib from existing runners.
- Deterministic-worker scripts must produce file edits sufficient to satisfy hidden tests for the success path (impl-conflict, impl-timeout, impl-unauthorized cases) — bounded but careful.

What keeps it from L:
- Substrate (bd / supervisor / shim) is unchanged.
- Existing eval cases untouched.
- Scorer extension is additive (a new mutations-rubric function alongside the existing pass-rate function).
- One case, one pattern, deterministic workers — the multi-axis variants are all explicit follow-ups.

## Sequencing

Natural successor to fo-07nux. The implementation bead should reference this fragment as the design source; the eval that bead ships unblocks `position.md` claims 4 and 5 (choreography-as-bd-primitive empirically validated).
