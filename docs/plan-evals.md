# Plan-evals

Empirical bench for the question: **does the orchestration pipeline (planner → graph → workers → merge) produce correct outcomes more reliably and faster than a single agent could?** Sister doc to [`throughput-mode.md`](throughput-mode.md); both validate [`position.md`](position.md)'s harder claims, but on different axes.

## Why this exists

The validation-pack's 7 unit-test scenarios prove the substrate *can* do single-level fan-out (claim 1 in `position.md`). Plan-evals test whether the *whole pipeline* — including the planner-LLM's decomposition — produces *reliably good outcomes* across a varied corpus. Without this layer, "model-as-orchestrator works" is a stance; with it, it's a measurable number that goes up or down with each model release.

This is the planner-side analog of `gascity-focus-areas.md`'s "protocol evals" idea (which was worker-side).

## Core framing

**Wall-clock is the primary metric.** The reason orchestration exists is to get N hours of agent work done in 1 hour of human time. Ralph (single agent in a loop) is the floor — almost anything is reachable given enough iterations. Fan-out earns its keep when it delivers wall-clock improvements proportional to parallelism, within planning + merge overhead.

The math, for N independent parallel sub-tasks each taking T seconds:

- Ralph: ~N × T
- Fan-out: ~T + planning_overhead + merge_overhead

For T=60s and (planning + merge) ≈ 30s, fan-out break-even is around N=2-3. A useful corpus spans the break-even region.

**Token cost is secondary.** Spending 2-3× tokens for 5-10× wall-clock improvement is an obvious trade. Within reason, the eval shouldn't penalize fan-out for higher spend.

**Pass rate is a floor.** At unbounded budget, ralph passes almost everything eventually. The eval has to fix a budget (tokens, wall-clock, or iterations) and ask: at this budget, what's the pass rate? Then compare patterns at fixed budget.

## Pattern-specific win conditions

Each Anthropic pattern earns its keep on a different axis. The eval shape has to make each one's win measurable.

| Pattern | Primary win axis | How to measure |
|---|---|---|
| Sectioning | Wall-clock (parallel pieces) | Wall-clock vs ralph at N=3+ |
| Voting | Quality (variance reduction) | Pass rate at fixed-budget; hidden-test pass rate |
| Routing | Quality (expert-task match) | Pass rate when given a specialist library vs generalist baseline |
| Orchestrator-workers | Wall-clock + quality (decompose + specialise) | Wall-clock vs ralph; hidden-test pass rate |
| Evaluator-optimizer | Quality (iterative refinement) | Hidden-test pass rate; round-over-round delta on visible tests |
| Prompt-chaining | Quality (focused-context per step) | Visible-test pass rate at long-task lengths |
| Agent-loop | Floor pattern — ralph itself | Baseline for everything else |

This is enough structure that each pattern can be tested *for the reason it exists*, not just "did it pass." Without it, e.g., evaluator-optimizer looks like pure overhead (slower than single-pass with no measurable win).

**Empirical caveat (from milestone A-C, sonnet workers):**

- **Naive fanout** is *not* a valid implementation of sectioning — it shares a worktree and has no merge step. It succeeds only when (a) pieces are truly file-isolated *and* (b) workers don't need to extend shared state. The earlier "naive fanout produces broken results on shared-state" framing was first measured against `validator-suite` under a buggy brief; the corrected re-run shows naive fanout succeeds on `validator-suite` (10/10) because that case doesn't force shared-state extension (the `Reason` enum was pre-stocked). The structural failure mode survives — but is now demonstrated on `enum-extension`, where shared `ErrorCode`/`ERROR_REGISTRY` are empty in starting-state and excluded from worker scope.

- **Sectioning** (per-worker isolated worktrees + deterministic collation) succeeds on file-isolated tasks (no different from naive fanout, just without the worktree write races) and partially on forced-shared-state tasks (~30% all-pass on `enum-extension` — sometimes workers happen to land on consistent names, sometimes don't).

- **Orchestrator-workers** wins both axes on forced-shared-state tasks (5/5 on `enum-extension`). On non-forced-state tasks, the merge step is pure overhead (validator-suite: 111s orch-workers vs 83s fanout, both 10/10).

- **Ralph** wins on forced-shared-state tasks too (10/10 on `enum-extension`), often at the lowest token cost since failure modes burn tokens. Wall-clock is the cost: ralph serializes work the parallel patterns do concurrently.

See "Findings to date" below for the data tables.

## What makes a good goal (corpus case)

A corpus case must be:

- **Mechanically scoreable.** Cycles count, test pass rate, file diff matching expected end-state, exit code 0. Outcomes needing human judgment can't be in a regression suite.
- **Stable in time.** Outcome tied to fixed inputs (frozen code, frozen test corpus, frozen benchmark binary). Don't tie outcomes to "best practices" or current model knowledge.
- **Constraint-pinned.** "Improve performance" is too loose; "reduce to <200ms, all existing tests pass" is pinned.
- **Underspecified enough to require planning.** "Run X then Y" has no plan to make.
- **Re-runnable from a fixture.** Starting state is fixed; running the eval doesn't pollute the next run.

And to be *interesting* (i.e., differentiate orchestration patterns from ralph), at least one of:

- **Independent parallelisable pieces.** "Add method `cancel()` to entities A, B, C, D" — fan-out runs concurrently; ralph serialises.
- **Specialisation advantage.** "Frontend + backend + db migration." Specialists each in tighter context.
- **Iterative-refinement structure.** A draft is improved over rounds — structured evaluator-optimizer should beat ralph's "try differently."

Corpus cases that *don't* require fan-out (single-file changes, linear refactors, pure debugging) are useful only as **negative controls** — confirming fan-out's overhead is real and ralph wins where appropriate.

## What we measure

Per case, per run:

- **Wall-clock** to terminal state.
- **Per-turn tokens** (`tokens_in` / `tokens_out`): the incremental cost of the LLM call. This is what the API *bills* you per turn — small because the API prompt-caches the system prompt + tool definitions across turns.
- **Contract length** (`cache_creation_input_tokens` + `cache_read_input_tokens`): the full context the model actually saw, including the cached prefix. **This is the load-bearing number for `position.md` claim 3** ("worker contracts stay short"). Per-turn `tokens_in` is misleading — typical worker per-turn input is 5-20 tokens, but the *actual contract* (brief + spec + tool defs + history) is 11K-30K tokens.
- **Visible-test pass rate** (the visible assertion script the planner sees as the spec).
- **Hidden-test pass rate** (assertions only the scorer sees — proxies quality).
- **Round-over-round delta** (for iterative patterns only — improvement between attempts).

Each case run multiple times (5-10) to get distributions, not single points.

**Cache fields landed 2026-05-23** (fo-vgam1 / C.4 refinement). All six runners (`ralph`, `fanout`, `sectioning`, `orchworkers`, `planner`, `graph-shape`) emit `cache_creation_input_tokens` + `cache_read_input_tokens` at the top level of result JSON, and the per-worker records inside `workers[]`. The driver's aggregate surfaces `median_cache_creation_input_tokens` + `median_cache_read_input_tokens` per pattern. Schema is additive — pre-existing `tokens_in`/`tokens_out` semantics (per-turn cost) preserved for back-compat.

Observed cache spend per pattern (`enum-extension`, sonnet workers, single-run smoke):

| Pattern | per-turn tokens_in | cache_creation (contract length) | cache_read (re-use volume) | Notes |
|---|---|---|---|---|
| graph-shape (planner-only) | 5 | 14K | 17K | Pure planning call. cache_creation = idioms + spec + tree. |
| fanout (6 workers) | 77 | **116K** | 1.8M | 19K cache_create per worker; 300K cache_read per worker. |
| orchworkers (6 workers + 1 merge) | 142 | **178K** | 4.1M | 32K cache_create per worker (workers iterate more) + 36K cache_create for merge; cache_read dominated by worker turns. |

Useful framing: `cache_creation` is the **first-time** size of the prompt-cache prefix (effectively "what fit into the context window"). `cache_read` is **how many times** the cached prefix got re-used across turns — a multiplier on contract length. Per-turn `tokens_in` of 77 vs cache_creation of 116K is a ~1500× gap on fanout; orchworkers' multi-iteration workers stretch the cache_read-to-cache_creation ratio further (4.1M / 178K ≈ 23×).

Implication for claim 3: the load-bearing measurement is **cache_creation of the brief slice** (what the persona prompt asks the worker to do, before the tool defs and spec are appended). The full cache_creation conflates persona contract + spec + system prompt, so a separate measurement of just the brief portion is still useful for tracking the position over time.

## Model calibration

**Worker model must be at the edge of its capability for the task tier.** Otherwise the pattern doesn't matter — a sufficiently strong worker one-shots everything and ralph wins by default. Differentiation lives in the regime where the worker model needs help.

| Role | Default model | Why |
|---|---|---|
| Worker | **sonnet** (4.6) | Operationally relevant cheap-worker tier; pinned in `scripts/eval-config.sh` as `WORKER_MODEL`. Highly capable but cheaper-per-token and lower session-quota cost than opus, which matters at N parallel workers per rep × N reps. |
| Planner / orchworkers-merge | opus (4.7) | Decomposition + reconciliation quality matters; only one call per rep so cost is bounded. Pinned as `PLANNER_MODEL`. |
| Evaluator (in eval-optimizer pattern, future) | sonnet or opus (TBD) | Rare call per rep; quality matters but tier isn't load-bearing. Decide when E2 lands. |
| Case author (offline, one-time) | opus | Authoring quality matters; not what we're evaluating. |

This gives the eval a built-in regression mechanism: as haiku gets smarter, tasks that used to differentiate stop differentiating. Two valid outcomes:
1. The corpus needs harder cases (capability frontier moved; the eval shows it).
2. Haiku is now strong enough for ralph-mode (a real finding about model capability).

Either way the eval becomes a tracking surface for *where the capability frontier moves*, not a static benchmark.

**The core question this frames empirically:** "does orchestration close the gap so a haiku-shaped team produces opus-shaped output?" If yes, the orchestration pillar pays for itself across model classes — you can scale work using cheap models if the structure is right. If no (orchestration overhead exceeds the capability lift), the position has to retreat.

**Actual practice (post-A):** worker = `claude-sonnet-4-6`, planner / orchworkers-merge = `claude-opus-4-7`. Configured via `scripts/eval-config.sh` (constants `WORKER_MODEL` and `PLANNER_MODEL`), pinned in each runner via `claude -p --model`. Rationale: sonnet 4.6 is highly capable and shoulders the per-worker load at substantially lower session-quota cost; opus handles the smaller-N planning + reconciliation calls where decomposition quality matters more. The haiku-as-worker axis is deferred — sonnet is the operationally relevant cheap-worker tier today, not haiku.

**Historical note:** M1 + M2 baselines (cancel-method, validator-suite) were collected with opus workers (the previous `claude -p` default). Those results survive as comparison rows. Going forward, the bench's default is the sonnet/opus split described above; override per-invocation with `WORKER_MODEL=opus bash scripts/eval-X.sh ...` if testing the model axis.

## Comparison axes

What you'd vary to learn:

| Axis | Why |
|---|---|
| Planner model (haiku, sonnet, opus) | Cost/quality tradeoff at the planning layer |
| Worker model | Same one layer down |
| Library: none / markdown / formula | The thing the position is arguing about — does typed library help? |
| Isolation: shared / worktree-per-task | Does worktree boundary improve outcomes empirically? |
| Pattern | Ralph / naive-parallel / orchestrator-workers / eval-optimizer / voting |
| **Orchestration substrate** | **bare bash + claude / gc supervisor / ntm shim / bd formulas in the loop** |

The orchestration-substrate axis was added after M1+M2 surfaced it. The current `scripts/eval-{ralph,fanout,orchworkers}.sh` runners are *bare-bash baselines* — they invoke `claude -p` directly with no orchestrator between them. That's the floor; a production setup would route the same patterns through a real orchestrator (gc supervisor, ntm shim, validation-pack scenarios with bd formulas). Per-orchestrator runners are an M4+ milestone — wiring validation-pack scenarios to take *external eval cases* (instead of their hardcoded task briefs) is the bounded refactor needed.

Then we can ask the genuinely interesting comparisons: "How much overhead does the gc supervisor add over bare-bash for the same task?" / "Does running through formulas improve plan reliability vs inline briefs?" / "Is the supervisor's startup cost paid back by its coordination value?" Tests `position.md` claims 3 and 4 empirically.

Full sweeps are expensive (~$1000+ per pass at scale). Use fake-worker variants for cheap iteration:

- **Plan-only eval** — planner outputs a graph; assertion script checks the graph is the right shape. No execution. Cheap.
- **Plan + fake-worker eval** — planner outputs graph; fake workers do mechanical bd ops; merge runs. Tests *plan correctness end-to-end* without LLM execution cost.
- **Full plan + execute eval** — real LLM workers. Tests the whole pipeline. Expensive; smaller sample.

## Corpus sourcing

Three plausible sources, in increasing order of fidelity:

1. **Hand-crafted synthetic** (5-10 cases). You control every detail; scoring is robust; toys but useful for negative controls and tier breakdowns.
2. **Mined PR history** (10-20 cases). Real complexity; harder to make re-runnable; harder to score mechanically. The trick is finding PRs where the test suite at HEAD-1 caught the bug + the fix is small enough for the tier you're building.
3. **Adapted benchmarks (SWE-bench Lite)** has 300 cases at the right complexity tier; could subset to 20-30. Pre-baked fixtures + assertions + a research community has scored single-agent baselines on them. Most efficient way to get a real corpus.

Probably start (1) for the first data point, expand to (3) once the eval runner is stable.

## Findings to date

Three cases authored, all run under sonnet workers + opus planner / merge:

### Cases and what they test

- **`cancel-method`** — 5 sibling entity classes sharing an EventBus. File-isolated work; no forced cross-file coordination. Validates the runner infrastructure (M1).
- **`validator-suite`** — 7 sibling validators sharing a `Validator` ABC, `Reason` enum, and registry. Initial calibration target, but the `Reason` enum was pre-stocked with every code the validators need — workers never actually have to extend shared state. Control case for "patterns succeed when state isn't forced."
- **`enum-extension`** — 6 sibling error classes sharing an `ErrorCode` enum and `ERROR_REGISTRY`. Both shared structures are empty in starting-state; workers MUST add their variant + register themselves, but those files are excluded from worker scope under fanout/sectioning. Only patterns where some agent has cross-file authority can succeed. Authored specifically to expose pattern differentiation.

### Empirical results

**enum-extension (forced shared-state extension):**

| Pattern | N | All-pass | Median wall | Mean tokens out | Failure mode |
|---|---|---|---|---|---|
| Ralph (single-agent loop) | 10 | **10/10** | 81.2s | 4,018 | — |
| Orchworkers | 5 | **5/5** | ~376s | ~14k | — |
| Sectioning | 10 | 3/10 | 216s | 36,960 | Workers reference variants others added; sometimes converges by luck, often pytest collection fails |
| Naive fanout | 10 | 2/10 | 281s | 54,192 | Same import-fail mode plus shared-worktree write races |

**validator-suite (control — shared state pre-stocked, no forced extension):**

| Pattern | N | All-pass | Median wall |
|---|---|---|---|
| Ralph | 3 (killed) | 3/3 | ~382s |
| Fanout | 10 | 10/10 | 83.4s |
| Sectioning | 10 | 10/10 | 83.0s |
| Orchworkers | 10 | 10/10 | 111.3s |

### Findings

1. **Pattern differentiation requires a case that forces cross-file coordination.** `validator-suite` doesn't (`Reason` enum is pre-stocked). `enum-extension` does. The differentiation that surfaces on `enum-extension` is the load-bearing empirical result; `validator-suite` is now best understood as the negative control.

2. **On forced-shared-state tasks, pattern hierarchy is sharp:** ralph (100%) ≈ orchworkers (100%) >> sectioning (30%) > fanout (20%). The merge step in orchworkers is the load-bearing differentiator vs sectioning; ralph wins by owning the whole task sequentially.

3. **On non-forced-state tasks, all patterns succeed at similar quality.** Differentiation is on wall-clock only, and orchworkers' merge step is pure overhead (~34% slower than fanout, no quality benefit).

4. **Token cost surprise: ralph is the cheapest by a wide margin when the task fits.** ~4k tokens out vs orchworkers' ~14k vs sectioning's ~37k vs fanout's ~54k on `enum-extension`. Failure modes burn tokens — fanout/sectioning workers retry and explore when their code can't import. This inverts the naive "parallel = cheaper" intuition.

5. **A historical 0/10 validator-suite naive-fanout result was a brief-bug artifact** (cancel-method-specific brief was hardcoded). Fixed in milestone A; the corrected re-run is 10/10 at 83.4s. The "naive fanout fails on shared state" narrative survives — but only via `enum-extension`, where the failure is intrinsic to the pattern, not the brief.

### Implication for the planner

Pattern selection is the load-bearing decision *only on shared-state-forcing cases*. The planner needs to:

- Recognize whether the task forces cross-file coordination (and how).
- Pick orchworkers or ralph when it does.
- Pick the cheapest valid pattern (fanout) when it doesn't.

`eval-planner.sh` (milestone B) tests this directly. Preliminary smoke (N=3, opus workers, opus planner — pre-sonnet-switch) showed the planner defaulting to orchworkers regardless of case shape; sometimes correct as "cheap insurance" on shared-state cases, sometimes pure overhead on file-isolated ones. E1 (library-driven planner) is the next test of whether a typed pattern menu breaks this default-to-orchworkers bias.

### Calibration: why sonnet workers

Sonnet sits at the Goldilocks tier (independently confirmed in Gemini's review — see "Feedback" section below). Opus one-shots everything (no differentiation visible — the M1+M2 baselines under opus mostly showed all patterns succeeding). Haiku would produce nonsense that orchestration can't reconcile (wrong test). Sonnet generates good-faith attempts that stumble on cross-cutting bits — exactly where orchestration earns its keep.

### See also

- [`evals/enum-extension/RESULTS.md`](../evals/enum-extension/RESULTS.md) — case-level write-up with per-rep detail.
- [`evals/validator-suite/RESULTS.md`](../evals/validator-suite/RESULTS.md) — case-level write-up.
- [`choreography-idioms.md`](choreography-idioms.md) — pattern templates as graph shapes (the canonical library E1 would draw from).

## What the bench actually tests (architect vs choreographer vs worker)

The `Feedback (gemini)` section below distinguishes **orchestration** (a single conductor reading from a fixed score) from **choreography** (skilled performers + a choreographer reading the room and adapting). `choreography-idioms.md` operationalizes that distinction as graph primitives. Three roles emerge from the Phase A / Phase B / Phase C model, not two:

| Role | Phase | What they do | What the bench tests today |
|---|---|---|---|
| **Architect** | A → B (design → graph) | One-shot decomposition from a design doc into the initial bead graph. Static, top-down. | Tested. `eval-planner.sh` does the pattern-selection slice; `eval-graph-shape.sh` (fo-d5fh9, 2026-05-23) scores the full graph shape against a per-case reference (primary + alternates). **Headline: opus produces a structurally-sound graph 10/10 on both seeded cases; sonnet 6/10 on enum-extension and 0/10 on validator-suite, with two distinct failure modes — under-decomposing on shared-state cases (batches classes) and over-structuring on embarrassingly-parallel cases (adds an unneeded coordinator).** See per-case `GRAPH-SHAPE-RESULTS.md`. |
| **Choreographer** | B onward (graph evolves during execution) | Centralized but **reactive**: observes the graph + worker close signals (status, reasons, notes), modifies the graph in response (sling, spawn child beads, re-route, escalate). Like a foreman. | **Not tested.** Our bench has no role that observes execution and reshapes the graph mid-run |
| **Worker** | C (do the leaf work) | Stays focused on its own bead. Signals state via bead close reason, status, and notes. Does NOT read other beads or spawn children itself. | Partial — workers do leaf work, but they're bash-parallelized `claude -p` subprocesses on a shared filesystem, not bd-graph participants. Close-signaling and the choreographer's reaction to those signals are absent |

This is the honest gap. The current bench's "patterns" (fanout / sectioning / orchworkers) are **static decomposition followed by isolated parallel execution** — only worker work is partially tested; architect and choreographer roles aren't tested at all. The pattern-task-fit findings above survive any reframing (they're real measurements), but they're testing something weaker than `position.md`'s claims.

What's missing:

- **Architect (Phase B) eval**: score the *graph shape* the architect persona produces from a design doc. Cheap (no execution, just plan-only scoring). Tests "did the model decompose well." **Done as of 2026-05-23** (bead fo-d5fh9): `scripts/eval-graph-shape.sh` + per-case `reference-graph.json` (with `idiom_alternates` for structurally-equivalent shapes) + driver wiring. Result: opus produces a structurally-sound graph 10/10 on both seeded cases. Sonnet 6/10 on enum-extension (4 reps land on a defensible two-phase-commit-with-contract-author alternate; 4 reps under-decompose by batching classes or pick plain fanout that breaks shared state) and 0/10 on validator-suite (always adds an unneeded coordinator bead — the "add a manager" bias). The two failure modes are oppositely signed but both reach for *more aggregation than the case wants*: under-decomposing the shared-state case, over-structuring the embarrassingly-parallel one. This is the **first plan-evals result distinguishing the model tiers at the architect layer** — complements the worker-layer Goldilocks finding (sonnet workers, see below).
- **Choreographer (Phase B-onward) eval**: a choreographer persona observes worker close signals from a partial / under-specified graph and modifies the graph in response. Scored on whether the work completes correctly *and* whether the choreographer's graph mutations are sensible. Requires substrate (real bd-graph primitives, not bash) — equivalent to milestone C.2.
- **Worker-as-bd-graph-participant**: workers should signal via bead close reason, not via filesystem side-effects. Also requires substrate. Tests "do narrow personas stay narrow + signal usefully."

Implication: **C.2 (per-orchestrator runners) is more central than the original "scope only" framing suggested.** It's not "later cleanup"; it's the substrate prerequisite for testing the choreographer role at all. See `per-orchestrator-runners.md` for the design fragment.

**Scale note**: a single choreographer may itself fan out into multiple choreographers each watching a sub-graph for large bead-graphs. That's orthogonal to the architect/worker distinction — it's the choreographer role parallelized, with sub-choreographers signaling to a top-level choreographer via the same bead-close mechanics workers use. Worth its own eval axis when corpus has cases big enough to motivate it; not in scope for the first cut.

## Milestones

### M1 — done

Initial runner infrastructure (`eval-ralph.sh`, `eval-fanout.sh`, `eval-scorer.py`, `eval-driver.py`) + cancel-method case. Result: fan-out 2.9× faster than ralph at identical pass rate (100%) on a file-isolated task. See `evals/cancel-method/RESULTS.md`.

### M2 — done

- Validator-suite case authored (7 sibling validators sharing ABC + Reason enum + registry; 19 baseline + 20 visible + 26 hidden tests).
- Hidden tests authored for all cases; scorer surfaces `hidden_pass`/`hidden_total` alongside visible.
- `eval-orchworkers.sh` added (sectioning + LLM merge step).
- N=10 comparisons across all 4 patterns on both validator-suite and enum-extension. See "Findings to date" above.
- Worker-model identification in result JSON (`worker_model` field, captured as `OBSERVED_MODEL`).

### A — Runner correctness — done

- **A.1** ✓: Fixed cancel-method-specific hardcoded brief in `scripts/eval-fanout.sh` and `scripts/eval-orchworkers.sh`. Brief now uses `${FANOUT_DIR_NAME}` and references `spec.md` for the verb. Workers no longer get a stale instruction on cases other than cancel-method.
- **A.2** ✓: Re-ran validator-suite naive-fanout N=10 with fixed brief. Recovered from 0/10 to 10/10 at 72.2s (opus) / 83.4s (sonnet). The original 0/10 was a brief-bug artifact; the "naive fanout fails on shared-state tasks" narrative survives via `enum-extension`, not `validator-suite`.
- **A.3** ✓: cancel-method N=10 regression-checked at 10/10. No regression.
- **A.4** (added during A): per-worker token tracking — result JSON now includes a `workers` array `[{file, tokens_in, tokens_out}, ...]` alongside aggregated totals.

### B — Pattern-selection eval — done

`scripts/eval-planner.sh` shipped. Planner brief shows case spec + starting-state tree summary + pattern menu (ralph / fanout / sectioning / orchworkers); returns JSON choice + reasoning. Dispatched runner's result is merged with planner fields (`planner_choice`, `planner_reasoning`, `planner_tokens_in`/`out`, `planner_model`). Driver aggregation surfaces a `planner_choices` distribution.

Smoke results (N=3 each case, opus workers, opus planner — collected pre-sonnet-switch): planner picked orchworkers 3/3 on both `cancel-method` and `validator-suite`. Consistent "cheap insurance" framing in the reasoning even when fanout would suffice. Documents the default-to-orchworkers bias that E1 (library-driven planner) is meant to probe.

### B.2 — Graph-shape (architect) eval — done (fo-d5fh9)

`scripts/eval-graph-shape.sh` shipped 2026-05-23. Plan-only architect eval: the planner is given a design doc + the choreography idioms library + the starting-state tree, and must produce a bead graph (idiom + nodes + deps). Scored against per-case `reference-graph.json` for semantic equivalence (idiom, per-persona node counts, dep topology). References can declare `idiom_alternates` — alternative shapes accepted as structurally sound — with the scorer surfacing both strict-primary and structurally-sound counts.

Headline N=10 results:

| Case | Opus structurally sound | Sonnet structurally sound | Failure modes |
|---|---|---|---|
| `enum-extension` (shared state) | 10/10 | 6/10 | Sonnet under-decomposes (batches 2 classes/worker, 3 reps) or picks plain fanout (1 rep). |
| `validator-suite` (embarrassingly parallel) | 10/10 | 0/10 | Sonnet always adds an unneeded coordinator parent (over-structures). |

Designless variant (N=5 each, layout hint stripped from spec.md):

| Model | Sound (designless) | Notes |
|---|---|---|
| opus 4.7 | 3/5 | 2 reps pick plain fanout; opus loses the "shared state is separate from per-leaf work" signal when the layout enumeration is gone. |
| sonnet 4.6 | 4/5 | sonnet's two-phase-commit default happens to land in the structurally-sound set for shared-state cases. |

Implications:
- Architect quality is a capability × prompt-quality interaction, not pure capability. Bullet lists of "files this work will touch" in design docs are load-bearing — they distinguish "fanout works" from "fanout will race-write."
- Sonnet has a consistent "add structure" bias; correctable partway by explicit topology instructions (`EXTRA_INSTRUCTION` env var probe: 4/5 fix rate on validator-suite).

### C — Bench completeness

- **C.1** ✓: `scripts/eval-sectioning.sh` — per-worker isolated worktrees + deterministic file-scoped collation, no LLM merge. The correct implementation of Anthropic's sectioning pattern. On `enum-extension` it produces the "individually correct but cross-file invariants broken" failure mode (3/10 all-pass; one rep had 20/20 visible + 0/2 hidden).
- **C.2** ✓ (scope only): Per-orchestrator runners design fragment landed — see [`per-orchestrator-runners.md`](per-orchestrator-runners.md). T-shirt: M. Implementation deferred; 8 known blockers documented.
- **C.3** ✓ (this section): Pattern-specific win conditions table revised to reflect empirics; "Findings to date" rewritten with sonnet-baseline data; case-level `RESULTS.md` files updated.
- **C.4** ✓ (folded into A.4): Per-worker token tracking in result JSON. ~~Caveat: the `tokens_in`/`tokens_out` come from claude's per-turn `usage` field, not cache-creation/cache-read totals — measures per-turn cost, not full contract length. Refinement needed if measuring claim 3 (short worker contracts) is load-bearing for the position.~~ **Resolved 2026-05-23 (fo-vgam1):** cache fields now emitted at both per-worker and per-run level across all four worker runners; aggregate driver surfaces medians. Single-rep smoke on `fanout enum-extension` (sonnet workers) recorded per-worker `cache_creation_input_tokens` of 11K-29K (the actual contract length per worker), vs per-turn `tokens_in` of 5-22 (the per-turn billing cost). The 1000× gap confirms why the per-turn number was misleading for claim 3.

### D1 — Scale the evidence base

3-5 more synthetic cases at opus-4-7's edge, covering shapes the current two miss:
- Cross-cutting refactor (one logical change touching N files; no clean per-file decomposition).
- Debugging-no-spec (read code, find bug, fix; no test-target).
- Integration (multiple subsystems, coordination across module boundaries).

Plus: N≥20 per cell for tighter confidence intervals; cost/quality Pareto plots ("at this token budget, which pattern wins") instead of just headline wall-clock medians.

### D2 — Real-world validation

Replay 5-10 real beads from foundations history (refinery failures, formula authoring, supervisor bugs) through the eval framework. Strip back to "starting state + spec" form; run patterns; score. Tests external validity — does the bench predict reality, or have we built a synthetic-cases optimum?

**Run D2 before D1.** One real-world case that breaks the pattern-task-fit story is worth ten synthetic confirmations.

### D3 — Cash out the position

After A-C + D2, rewrite `docs/position.md` as a grounded claim. Cite the eval data. Make the falsifiable version of "model-as-orchestrator, with these patterns, on these substrates, at these costs, with these failure modes." This is the deliverable — the bench was always evidence; the position is what the evidence supports.

### E — Parallel tracks (not stretch, different concerns from D)

The D-tier is about evidence (more cases, real-world cases, position cash-out). E1-E5 are about *different concerns the bench needs to address*. They can run in parallel with the D-tier; sequence by what each one unlocks.

### E1 — Library-driven planner

Variant of B's `eval-planner.sh`: same planner LLM, but given a markdown library of canonical patterns + when each one wins (curated; not neutral one-liners). Compare to the freeform planner from B.

More relevant after B's finding that opus defaults to orchworkers regardless of case shape — a library that says "when pieces are file-isolated with no shared invariants, prefer fanout" might break that bias. Tests `position.md` claim 2 directly: does a typed library improve planner output?

Result fields: same as planner runs + `library_used` (string) + the library markdown file as an artifact.

### E2 — Pattern matrix expansion

Add the patterns we haven't tried:

- **Voting** (`scripts/eval-voting.sh`) — N parallel workers each solve the whole task; an evaluator LLM picks the best, OR majority vote on shared invariants. Differentiates on quality (variance reduction), not wall-clock.
- **Evaluator-optimizer** (`scripts/eval-optimizer.sh`) — single worker iterates; an evaluator LLM critiques each round. Differentiates on quality (iterative refinement). Captures round-over-round delta as a result metric.

Each enables the corresponding row in the "Pattern-specific win conditions" table to have measured data instead of hypotheses.

### E3 — Composition

Author a case that REQUIRES composition — a step in a parent formula instantiates a child wisp. Tests `position.md`'s claim that "patterns compose without runtime infrastructure."

Concrete shape: a task where one of the worker beads in orchworkers itself fans out (e.g., the merge step is itself orchworkers'd: per-file merge sub-workers + meta-merge). Or where the planner's chosen pattern is "ralph + invoke a sub-orchworkers when blocked."

Hardest milestone — requires either substrate refactor (bd formula composition) or careful host-side scripting. Schedule after E1+E2 because composition's value is greatest when the patterns being composed are well-characterized.

### E4 — Case authoring scaffold

`scripts/add-eval-case.sh` — scaffolds a new case directory with the canonical layout. Plus `docs/case-authoring.md` documenting "what makes a good case" + an actionable companion to the "What makes a good goal" section above.

Becomes infrastructure once D1 (more synthetic cases) + post-A calibration cases (e.g., enum-extension) scale beyond 2-3. Cheap to build, high leverage. Should probably happen in parallel with D1's first 1-2 new cases.

### E5 — Trend tracking

Make the bench load-bearing. Scheduled or CI-integrated runs across model versions; persist results to a versioned store; simple trend report (pass rate by model, by pattern, by case, over time).

Definition of done: trend visible across at least 3 model versions; regressions surface in the report. Needs E4 in place because corpus growth is the bottleneck otherwise.

### Stretch (deferred)

- **Haiku-worker axis.** Re-run cases with haiku-as-worker to test "does orchestration close the capability gap." Was the original M3-era framing; deferred because the operationally relevant tier today is opus.
- **Cross-model orchestration** (opus orchestrating sonnet/haiku workers — is the tier relationship load-bearing?).
- **Persistent multi-session work** (current evals are one-shot; real work has handoffs).
- **Substrate-failure-mode evals** (dolt flake mid-run, supervisor restart, etc.).
- **Plan-only / fake-worker eval** for cheap iteration on planning logic without LLM execution cost.
- **Prompt-chaining pattern** added to the matrix (E2 covers voting + eval-optimizer; chaining is a third).
- **Worker-driver swap (ntm via tmux).** `claude -p` bills against the API; plumbing the eval scripts to optionally drive workers through `ntm` + tmux would use the Claude Code subscription model instead. Eval logic doesn't change, only the worker invocation backend. Low-priority follow-up; partial overlap with C.2 (per-orchestrator runners) but separable — C.2 is about substrate-as-orchestrator, this is about substrate-as-worker-driver.
- **SWE-bench Lite integration** — 20-30 cases at the right complexity tier; lets us compare to research-community single-agent baselines.

## Open questions

- **Reference graph definition.** For plan-only evals: how do you specify "the right graph" without making it brittle to small valid variations? Probably semantic equivalence (right set of nodes, right deps, right scope) rather than exact-match.
- **Human-in-the-loop scoring.** Some failure modes need human judgment (ambiguous intent, worker drift). The framework should probably surface these for review rather than auto-scoring as fail. How that integrates with CI is unclear.
- **Hidden-test authoring cost.** Hand-curating hidden tests is the expensive part. Worth it for 5-10 cases where quality is load-bearing; not for all 30+.
- **Beyond Anthropic patterns.** The eval framework should be pattern-agnostic — any orchestration shape (including ralph-with-special-prompts, agent-mesh, etc.) should plug in. The matrix grows quickly; need to keep it manageable.

## See also

- [`position.md`](position.md) — particularly claim 3 (worker contracts) and claim 4 (it scales); plan-evals refine the wall-clock subset of claim 4.
- [`throughput-mode.md`](throughput-mode.md) — sister doc; measures *capacity under steady load* rather than *plan quality per task*.
- [`principles.md`](principles.md) — the "content over runtime" principle is what plan-evals would let us empirically test (does a typed library outperform markdown templates?).

## Feedback (gemini)

### Primitives vs. Runtimes
It can initially seem contradictory that a project focused on removing rigid "orchestrators" is spending so much effort rigorously evaluating orchestration patterns. The resolution lies in the difference between a **Workflow Runtime** and **Orchestration Primitives**. 

By dropping the runtime (the Go engine reading TOML), the architecture relies on the raw primitives provided by the graph (Beads: create, depend, claim, close). The Anthropic patterns being evaluated here are not rigid pipelines enforced by the system, but rather **idioms** that the *Planner LLM* is taught to use. The `plan-evals` are effectively the performance review to prove the LLM is actually competent enough to orchestrate itself using these primitives.

### Orchestration vs. Choreography
This architectural bet perfectly mirrors the shift from Orchestration to Choreography in distributed systems:
- **Orchestration:** Like a conductor and an orchestra. The musicians don't need to know the grand plan; they just stare at the sheet music and wait for the conductor to point at them. If the conductor loses their place, the whole symphony crashes. (This is the old Go runtime executing a TOML file).
- **Choreography:** Like a group of highly skilled dancers given a shared rhythm and spatial rules. They read the room, react to each other, and adapt in real-time. If someone trips, the others naturally adjust their spacing so the routine keeps going. (This is LLM agents reading the Beads graph and figuring out the next best move).

Choreography depends entirely on the **competence of the performers**. The `plan-evals` framework is essentially holding auditions to ensure the dancers are skilled enough to pull off the choreography before firing the conductor.

### Evaluating Frontier Models
When designing synthetic tasks for plan-evals, there is a risk of evaluating the architecture against a weakened worker model (like Haiku) out of fear that a frontier model (like Sonnet or Opus) will simply one-shot the task, masking the value of orchestration. However, if the goal is to build an architecture for experts, the eval must challenge experts.

Instead of artificially inflating the *logical complexity* of the synthetic task to stump a frontier model, **constrain the physics of its context window.** Orchestration proves its worth against a single genius agent ("Ralph") when it overcomes volume, context-bleeding, and tunnel vision:

1. **Volume ("Wide but Shallow" tasks):** E.g., updating 40 isolated files. A single frontier model fails via attention decay or output token truncation. Orchestration wins via Fan-Out/Sectioning.
2. **Context-Bleeding ("Cross-Boundary" tasks):** E.g., changing DB schema, backend API, and frontend simultaneously. A single model confuses state across boundaries. Orchestration wins by providing cognitive isolation (separate workers per domain) and structured merging.
3. **Tunnel Vision ("Flaky Heuristic" tasks):** E.g., fixing a race condition. A single model often loops on its own assumptions. Orchestration wins via the Evaluator-Optimizer pattern, breaking the loop with a fresh context critique.

By designing tasks that attack these structural limits, the eval demonstrates that orchestration scales frontier model capabilities beyond the physics of a single prompt.

#### Applying Context Physics to the `cancel-method` Eval
The benchmark results for the existing `cancel-method` scenario (N=5 entities) perfectly illustrate the need to attack context physics. Because N=5 is too small to trigger attention decay in a frontier model, the single-agent baseline ("Ralph") achieved a 15/15 pass rate and matched the fan-out pattern in quality. The only differentiation was in wall-clock time.

To evolve this scenario to test orchestration quality (not just speed), you must push it past the model's physical limits:
- **Increase Volume:** Scale the refactor from 5 entities to 50 entities. A single Ralph prompt will hit output token limits or start hallucinating `// ... unchanged` omissions by file 20. The Fan-Out pattern will continue to execute perfectly.
- **Introduce Cross-Boundary Dependencies:** Instead of 5 independent entities, require that downstream consumers of the `EventBus` (e.g., an email notification worker or a database migration script) also be updated to handle the new `"cancelled"` event payload. Ralph will struggle to hold both the producer logic and consumer logic in its head simultaneously without bleeding context.

### The Calibration Goldilocks Problem
When selecting the worker model for these evals, you face a conflicting set of goals. The goal is to prove that "orchestration is a force-multiplier on capable models." However, this creates a calibration trap:
- **The Case Against Haiku:** If you use a weak model (Haiku) to force failures in the baseline, you end up measuring the wrong thing. If the workers produce nonsense, orchestration's coordination role is moot because there's nothing coherent to coordinate. It proves a smart manager can babysit interns, not that the architecture works for experts.
- **The Case Against Opus:** If you use the absolute smartest frontier model (Opus), it will trivially one-shot the scenario (as seen in the `cancel-method` results). If Ralph wins by default, no force-multiplication is visible, and the eval merely proves "Opus is smart," obscuring the value of the orchestration layer.
- **The Sonnet Sweet Spot:** Sonnet represents the "Goldilocks" tier. It is smart enough to generate coherent, good-faith attempts (avoiding the Haiku trap), but just bounded enough by context physics that it will stumble on massive, cross-cutting tasks (avoiding the Opus trap). This is exactly where orchestration earns its keep: providing the cognitive isolation and structure needed to help highly capable, but physically bounded, workers succeed.
