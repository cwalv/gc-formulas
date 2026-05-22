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

## Comparison axes

What you'd vary to learn:

| Axis | Why |
|---|---|
| Planner model (haiku, sonnet, opus) | Cost/quality tradeoff at the planning layer |
| Worker model | Same one layer down |
| Library: none / markdown / formula | The thing the position is arguing about — does typed library help? |
| Isolation: shared / worktree-per-task | Does worktree boundary improve outcomes empirically? |
| Pattern | Sectioning vs voting vs eval-opt vs ralph baseline |

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

## Milestones

### M1: First data point (1-2 days)

**Goal:** answer "does fan-out beat ralph on wall-clock for one well-shaped case?"

**Deliverables:**
- One Tier-1 corpus case (e.g. "add `cancel()` method to 3 sibling files; existing tests pass"). Hand-crafted: starting fixture + visible-test assertion script.
- Ralph baseline runner — single agent in a loop, no orchestration.
- One fan-out runner — uses our existing scenario 05 (orchestrator-workers) shape.
- Metrics: wall-clock, token count, visible-test pass rate.
- Each runs 10× to get pass-rate + median wall-clock.

**Definition of done:** first data point. For this one case, does fan-out beat ralph on wall-clock at acceptable pass rate?

### M2: Tier breadth + quality dimension (3-5 days)

**Goal:** find the break-even region; add a quality axis.

**Deliverables:**
- Add 2 more cases:
  - **N=1 negative control** (single-file refactor; ralph should win or tie).
  - **N=10 case** (mass-substitution across files; fan-out should dominate).
- Add **hidden tests** to one of the cases (probably the N=10) — assertions only the scorer sees. Lets us measure pattern quality, not just correctness floor.
- Re-run all cases across both patterns.

**Definition of done:** observe the break-even region between ralph and fan-out; confirm hidden tests differentiate quality.

### M3: Library + composition (5-7 days)

**Goal:** test whether a curated library improves plan quality (this directly tests `position.md`'s claim 2).

**Deliverables:**
- Add a "library-driven planner" variant — same planner LLM but given a markdown library of canonical workflows to pick from. Compare to freeform planner.
- Add a case that **requires composition** (a step in the parent formula instantiates a child wisp). Tests the position's claim that "patterns compose without runtime infrastructure."
- Pattern variants: add voting + evaluator-optimizer to the eval matrix (they should differentiate on quality, not wall-clock).

**Definition of done:**
- Does a curated library improve plan quality vs freeform planner?
- Does composition work end-to-end?
- Do voting and evaluator-optimizer differentiate from sectioning on the quality axis?

### M4: Curated authoring workflow (3-5 days)

**Goal:** make corpus growth cheap.

**Deliverables:**
- Template directory structure for new cases:
  ```
  evals/<case-id>/
  ├── spec.md              # the intent given to the planner
  ├── starting-state/      # fixture: starting repo state
  ├── visible-tests/       # assertions the planner sees as spec
  ├── hidden-tests/        # assertions only the scorer sees
  └── expected-graph.md    # reference plan (for plan-only eval)
  ```
- A `scripts/add-eval-case.sh` or similar to scaffold a new case.
- Documentation: how to author a good case (reference back to "what makes a good goal" section above).
- Grow corpus to 5-10 cases total.

**Definition of done:** anyone can author a new case in <30 minutes; corpus has at least 5 cases.

### M5: Regular runs + trend tracking (ongoing)

**Goal:** make this load-bearing.

**Deliverables:**
- Scheduled or CI-integrated eval runs.
- Persist results across runs (model version, date, conditions, per-case scores).
- Simple trend report — pass rate by model, by pattern, by case over time.

**Definition of done:** trend visible across at least 3 model versions; regressions surface in the report.

### Stretch: SWE-bench Lite integration

**Goal:** representative corpus at scale.

Adapt 20-30 SWE-bench Lite cases into our runner. Useful for comparing our orchestration patterns to the broader research community's single-agent baselines.

## Open questions

- **Reference graph definition.** For plan-only evals: how do you specify "the right graph" without making it brittle to small valid variations? Probably semantic equivalence (right set of nodes, right deps, right scope) rather than exact-match.
- **Human-in-the-loop scoring.** Some failure modes need human judgment (ambiguous intent, worker drift). The framework should probably surface these for review rather than auto-scoring as fail. How that integrates with CI is unclear.
- **Hidden-test authoring cost.** Hand-curating hidden tests is the expensive part. Worth it for 5-10 cases where quality is load-bearing; not for all 30+.
- **Beyond Anthropic patterns.** The eval framework should be pattern-agnostic — any orchestration shape (including ralph-with-special-prompts, agent-mesh, etc.) should plug in. The matrix grows quickly; need to keep it manageable.

## See also

- [`position.md`](position.md) — particularly claim 3 (worker contracts) and claim 4 (it scales); plan-evals refine the wall-clock subset of claim 4.
- [`throughput-mode.md`](throughput-mode.md) — sister doc; measures *capacity under steady load* rather than *plan quality per task*.
- [`principles.md`](principles.md) — the "content over runtime" principle is what plan-evals would let us empirically test (does a typed library outperform markdown templates?).
