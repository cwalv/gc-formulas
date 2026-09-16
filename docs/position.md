# The foundations position on agent orchestration

## TL;DR

Multi-agent coding workflows should use **model-as-orchestrator with substrate-coordinated personas**. No workflow runtime. The bead graph is the durable coordination state. Named agent roles (foreman, treehugger, implementer, evaluator, ...) act on the substrate via typed CLI verbs and prose contracts. Whatever workflow shape a job needs is decided by the foreman LLM at runtime, not encoded in a DSL the runtime walks.

This is a contrarian position. Gascity's graph.v2, NTM's pipeline, and most TOML/YAML formula DSLs are workflow-runtime-shaped. The position is that they're structurally wrong: they constrain exactly what better models are getting better at — decomposition, ordering, retry judgment — and pay ongoing maintenance costs for ambition that model improvement is erasing.

> **Terminology note (open):** "Model-as-orchestrator" collapses three distinct roles. The architect (Phase A → B) produces the initial decomposition from a design doc — static, top-down. The **choreographer** (Phase B onward) observes the bead graph + worker close signals and reshapes the graph in response — centralized but reactive, like a foreman. The workers (Phase C) stay focused on their own beads and signal via close reason / status; they don't read other beads or spawn children. (At scale, a single choreographer may itself fan out into multiple choreographers each watching a sub-graph — orthogonal to the architect/worker distinction.) The choreographer framing — from `choreography-idioms.md` and Gemini's review — is sharper for the execution layer than "orchestrator." A more accurate title might be "model-as-architect-and-choreographer." The rename is held until D3 (position cash-out) when there's empirical evidence for all three roles; see `plan-evals.md` "What the bench actually tests" for what's currently measured vs. claimed.

Full narrative: `archive/agent-orchestration-architecture.md`, deleted in the 2026-07-25 reorg — see [`deleted.md`](deleted.md) (recoverable at `pre-reorg-2026-07-25`). Load-bearing principles: [`principles.md`](principles.md).

## Five testable claims

The position implies these specific claims; each is a falsifiable proposition.

1. **The patterns work without a workflow runtime.** All 7 Anthropic patterns (prompt chaining, routing, sectioning, voting, orchestrator-workers, evaluator-optimizer, agent-loop) run end-to-end on bd + personas + bash drivers, with no orchestrator state machine between agents.

2. **Patterns compose without runtime infrastructure.** A step in a parent formula can pour a child wisp; the parent's await blocks on the child's terminal close. The bead graph already does the dependency math. No workflow engine needed for composition.

3. **Worker contracts stay short as workflows get richer.** As the architecture handles more, the persona prompt shouldn't grow linearly. Track line counts over time. If new features keep adding to the prompt, the protocol is leaking; if line count is flat or shrinks, the position is holding. **Measurement (2026-05-23, plan-evals fo-vgam1):** worker contracts measured via `cache_creation_input_tokens` (not per-turn `tokens_in`, which is the API billing slice). Baseline on `enum-extension` under fanout/sonnet: per-worker contract length 11K-29K tokens. Variance comes from how much the worker explores during the task; the *brief* itself is small. Future tracking should watch the *brief* + *system-prompt* portion holding flat as more substrate features land.

4. **It scales.** N concurrent workflows draining a backlog work without an orchestration layer above the substrate. Worker pools, dispatch, retry are all substrate-level, not runtime concerns.

5. **Better models do worse with cages.** Constraining the model with a workflow DSL hurts as model capability grows. Counter-experiment: build the same workflow with-DSL vs without; measure success rate against model versions. **Adjacent finding (2026-05-23, plan-evals graph-shape probes):** the choreography idioms library has *two* effects, and tier-sensitivity differs between them. (a) **Enumeration as hard constraint** — both tiers obey the library's idiom menu; neither opus nor sonnet invents shapes outside what the library offers (validated on enum-extension with a fanout-only library — both tiers picked fanout 5/5 even though that's structurally unsound for the case). (b) **Default-shifting** — sonnet absorbs the library's hierarchical examples as preferences (0/10 → 5/5 on validator-suite when stripped); opus's defaults are library-independent (5/5 either way). Sharper than claim 5's "cages" framing: the library is the architect's solution space for both tiers. Curate carefully; library curation is architecture work.

## What's validated so far

Claim 1: yes. See [`state.md`](state.md). 7/7 patterns pass under two shims (gc, ntm) with no workflow runtime between agents.

Claims 2-5: not yet cashed out against the original validation-pack
capacity-under-load plan (`throughput-mode.md`, deleted in the
2026-07-25 reorg — see [`deleted.md`](deleted.md)) — that rig tested
one-workflow-at-a-time in fresh containers, a unit-test level for
primitives, and nobody built the capacity harness on top of it. But
`plan-evals.md`'s bench answers the sharper version of claims 3 and 5
directly (contract-length measurement, the architect-tier
coordinator-bias-is-taught finding), and the choreograph practice
running on real epics is claims 1, 2 and 4 exercised in production
rather than in a rig.

## What this position doesn't yet answer (2026-07-25 update: mostly answered by practice)

This section originally posed an open authoring question in terms of
**formulas** — what's the right granularity for a workflow DSL the
runtime walks. That framing is moot: the formula/molecule runtime is
abandoned (2026-07-25), so there is no DSL layer left to size. The
practical question that survives is the same one restated one layer
up:

> Given that decomposition happens once, at the architect tier, as a
> bead graph with no runtime underneath it — **what's the right level
> of abstraction for that graph?** What goes in one bead's brief, what
> becomes a template shape reused across jobs, and where's the line
> between "compose existing idioms" and "invent a new graph shape"?

Practice answered this, not more theorizing:

- The **idiom library is the answer to "where's the line."**
  `choreography-idioms.md`'s five graph-shape templates (fan-out,
  synthesis pipeline, critique loop, two-phase commit, gatekeeper) are
  the enumerated menu; the graph-shape probes (`plan-evals.md`) showed
  enumeration is a hard constraint on both tiers — neither opus nor
  sonnet invents shapes outside what the library offers. So "compose
  existing idioms" isn't optional taste, it's what actually happens;
  curating that menu is the architecture work, not authoring formulas.
- **Granularity lives in the bead graph, not in argument-passing
  between static templates.** A bead's brief is the unit that varies
  per job; the graph shape (which idiom, how the beads wire together)
  is the reusable part. There's no separate "canonical building-block
  formula" layer to worry about sizing — the architect just picks an
  idiom and instantiates it as beads.
- **The choreographer is the composition mechanism claim 2 was
  reaching for**, not a wisp-pours-a-child-wisp runtime primitive: it
  observes close signals and mutates the graph in response
  (`choreographer-eval.md`, the `choreo-n10` eval data). Composition
  is a live tier's judgment call, not a static contract.

The remaining open question is narrower than the original one:
library curation quality (which idioms are in the menu, how they're
described) directly bounds what the architect can produce, so
*that's* the surface worth iterating on — not formula granularity.

## See also

- [`principles.md`](principles.md) — the load-bearing design principles.
- [`state.md`](state.md) — frozen claim-1 validation record.
- [`plan-evals.md`](plan-evals.md) — the live empirical-evidence hub (claims 3, 5, and the architect/choreographer bench).
- [`choreography-idioms.md`](choreography-idioms.md) — the idiom library referenced above.
- [`deleted.md`](deleted.md) — index of what the 2026-07-25 reorg removed, including the archive/ this section used to point at.
