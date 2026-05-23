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

**Empirical caveat (from M1+M2):** naive-fanout — concurrent unsynchronized writes to a shared worktree, no isolation, no merge — is *not* a valid implementation of "sectioning." It only succeeds when pieces are truly file-isolated and have no shared state (cancel-method case). On shared-state tasks (validator-suite case), it produces broken output, not just slow output. The valid sectioning implementation requires either per-worker isolation (separate worktrees + file-scoped collation) or orchestrator-workers' explicit LLM merge step. Treat naive-fanout as an anti-pattern, useful only as a measurement of *what happens when you skip reconciliation*.

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
- **Token count** across all LLM calls (planner + workers).
- **Visible-test pass rate** (the visible assertion script the planner sees as the spec).
- **Hidden-test pass rate** (assertions only the scorer sees — proxies quality).
- **Round-over-round delta** (for iterative patterns only — improvement between attempts).

Each case run multiple times (5-10) to get distributions, not single points.

## Model calibration

**Worker model must be at the edge of its capability for the task tier.** Otherwise the pattern doesn't matter — a sufficiently strong worker one-shots everything and ralph wins by default. Differentiation lives in the regime where the worker model needs help.

| Role | Default model | Why |
|---|---|---|
| Worker | **haiku** (currently 4.5) | Weakest; task tier calibrated to its edge — multi-file consistency, context-management, etc. start failing here |
| Planner | sonnet or opus | Decomposition quality matters; planner is one call vs N worker calls so cost is bounded |
| Evaluator (in eval-optimizer pattern) | sonnet | Needs to judge well but is a rare call |
| Case author (offline, one-time) | opus | Authoring quality matters; not what we're evaluating |

This gives the eval a built-in regression mechanism: as haiku gets smarter, tasks that used to differentiate stop differentiating. Two valid outcomes:
1. The corpus needs harder cases (capability frontier moved; the eval shows it).
2. Haiku is now strong enough for ralph-mode (a real finding about model capability).

Either way the eval becomes a tracking surface for *where the capability frontier moves*, not a static benchmark.

**The core question this frames empirically:** "does orchestration close the gap so a haiku-shaped team produces opus-shaped output?" If yes, the orchestration pillar pays for itself across model classes — you can scale work using cheap models if the structure is right. If no (orchestration overhead exceeds the capability lift), the position has to retreat.

**Actual practice (M1+M2):** worker = `claude-opus-4-7[1m]` (the `claude -p` default). Cases were authored at opus-4-7's capability edge, not haiku's — opus is what's actually doing the work in current Claude Code sessions, so it's the most operationally relevant tier. The haiku-as-worker axis is a future expansion: re-run the same cases with haiku workers and measure whether orchestration closes the capability gap. Currently aspirational; the per-tier comparison hasn't been executed.

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

Two cases authored at opus-4-7's capability edge:

| Case | Pattern | N | Median wall-clock | All-pass | Notes |
|---|---|---|---|---|---|
| cancel-method | Ralph (one-shot) | 10 | 83.6s | 10/10 | Case too easy at this tier — both patterns one-shot it |
| cancel-method | Naive fan-out | 10 | 28.9s | 10/10 | 2.9× speedup; pieces truly file-isolated so no shared-state corruption |
| validator-suite | Ralph (loop) | 10 | 197.6s | 10/10 | One-shot at iter 1 in all runs; slowest, correct |
| validator-suite | Naive fan-out | 10 | 25.7s | **0/10** | Workers corrupted shared `base.py`/`registry.py`/`Reason` enum without merge |
| validator-suite | Orch-workers | 10 | 99.5s | 10/10 | 2× faster than ralph at same quality; LLM merge reconciles shared state |

**Two findings, in tension:**
1. **The right pattern wins on wall-clock at equal or better quality.** Orch-workers vs ralph on validator-suite: 2× faster, same 100% pass rate.
2. **The wrong pattern produces broken results, not just slow ones.** Naive concurrent writes to shared state degrade quality, not throughput — validator-suite naive-fanout was 6.5× faster than ralph but 0/10 passing.

**Implication for the planner:** pattern selection is the load-bearing decision. Hardcoding a pattern (as the current M1 runners do) bypasses the value the planner is supposed to add. This is the most direct test of `position.md`'s "model-as-orchestrator" claim and is the next milestone (B below).

**Known runner correctness issue:** `eval-fanout.sh` and `eval-orchworkers.sh` have a cancel-method-specific hardcoded brief at ~line 178 ("add a `cancel()` method to ONLY the file: entities/...") that's still used even when running validator-suite. Workers got a brief that didn't match the spec for the latter. Partially invalidates the 0/10 validator-suite naive-fanout interpretation; A.1 below fixes this.

## Milestones

### M1 — done

Initial runner infrastructure (`eval-ralph.sh`, `eval-fanout.sh`, `eval-scorer.py`, `eval-driver.py`) + cancel-method case. Result: fan-out 2.9× faster than ralph at identical pass rate (100%) on a file-isolated task. See `evals/cancel-method/RESULTS.md`.

### M2 — partial

What's done:
- Validator-suite case authored at opus-4-7's edge (7 sibling validators sharing ABC + Reason enum + registry; 19 baseline + 20 visible + 26 hidden tests).
- Hidden tests authored for both cases; scorer surfaces `hidden_pass`/`hidden_total` alongside visible.
- `eval-orchworkers.sh` added (sectioning + LLM merge step).
- Three-pattern comparison N=10 each on validator-suite. Orch-workers wins (99.5s vs ralph 197.6s, both 10/10).
- Worker-model identification in result JSON (`worker_model` field).

What's not yet done (deferred to A-C ladder below):
- A: Brief-bug fix + clean re-run.
- B: Pattern selection as an eval axis.
- C: True sectioning impl (per-worker isolation, deterministic file-scoped collation); per-orchestrator runners.

### A — Runner correctness (cheap)

- **A.1**: Fix the cancel-method-specific hardcoded brief in `scripts/eval-fanout.sh` (lines ~174, 180, 182) and `scripts/eval-orchworkers.sh`. Use `${FANOUT_DIR_NAME}` instead of literal `entities/`; remove the `cancel() method` verb and the `event_bus.py` exclusion (rely on the `exclude` list in `fanout.json`); have the brief reference the case's `spec.md` for the verb.
- **A.2**: Re-run validator-suite naive-fanout N=10 with the fixed brief. Update `evals/validator-suite/RESULTS.md` with either confirmation (broken impl, structurally bad — the 0/10 result holds) or revision (was a brief bug).
- **A.3**: Regression-check cancel-method N=10 to confirm the fix didn't break the working case.

### B — Pattern-selection eval

`scripts/eval-planner.sh` — show the planner the case (spec.md + starting-state directory tree summary), present the pattern menu (ralph / sectioning / orch-workers / eval-optimizer), get back JSON `{"pattern": "...", "reasoning": "..."}`, then dispatch the chosen runner.

Result JSON adds `planner_choice`, `planner_reasoning`, `planner_tokens_in`/`out` on top of the chosen pattern's normal fields. Score the planner's choice against the empirically best pattern for the case — does opus correctly route validator-suite to orch-workers, cancel-method to fan-out?

The most direct test of `position.md`'s "model-as-orchestrator" claim. Without it, the bench measures only "given pattern X, how does it score" — the actual orchestration decision is offstage.

### C — Bench completeness

- **C.1**: `scripts/eval-sectioning.sh` — per-worker isolated worktrees + deterministic file-scoped collation (no LLM merge). The correct implementation of Anthropic's sectioning pattern; replaces naive-fanout as the canonical "isolation without merge" baseline.
- **C.2**: Per-orchestrator runners — `scripts/eval-gc.sh`, `scripts/eval-ntm.sh`. Re-run the same patterns through validation-pack scenarios. Requires validation-pack refactor to take *external* eval cases (instead of hardcoded task briefs). Most complex item; treat as its own milestone if scope grows. **Design fragment:** [`per-orchestrator-runners.md`](per-orchestrator-runners.md) (T-shirt: M).
- **C.3**: Update the `Pattern-specific win conditions` table above to reflect empirics — naive-fanout is structurally broken; sectioning needs either isolation or merge; orch-workers wins both axes when state is shared.
- **C.4**: Worker-contract length tracking — capture per-worker prompt and output token counts in result JSON, not just aggregates. Tests `position.md` claim 3 (short worker contracts) empirically.

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
