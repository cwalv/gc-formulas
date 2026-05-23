# The foundations position on agent orchestration

## TL;DR

Multi-agent coding workflows should use **model-as-orchestrator with substrate-coordinated personas**. No workflow runtime. The bead graph is the durable coordination state. Named agent roles (foreman, treehugger, implementer, evaluator, ...) act on the substrate via typed CLI verbs and prose contracts. Whatever workflow shape a job needs is decided by the foreman LLM at runtime, not encoded in a DSL the runtime walks.

This is a contrarian position. Gascity's graph.v2, NTM's pipeline, and most TOML/YAML formula DSLs are workflow-runtime-shaped. The position is that they're structurally wrong: they constrain exactly what better models are getting better at — decomposition, ordering, retry judgment — and pay ongoing maintenance costs for ambition that model improvement is erasing.

> **Terminology note (open):** "Model-as-orchestrator" collapses three distinct roles. The architect (Phase A → B) produces the initial decomposition from a design doc — static, top-down. The **choreographer** (Phase B onward) observes the bead graph + worker close signals and reshapes the graph in response — centralized but reactive, like a foreman. The workers (Phase C) stay focused on their own beads and signal via close reason / status; they don't read other beads or spawn children. (At scale, a single choreographer may itself fan out into multiple choreographers each watching a sub-graph — orthogonal to the architect/worker distinction.) The choreographer framing — from `choreography-idioms.md` and Gemini's review — is sharper for the execution layer than "orchestrator." A more accurate title might be "model-as-architect-and-choreographer." The rename is held until D3 (position cash-out) when there's empirical evidence for all three roles; see `plan-evals.md` "What the bench actually tests" for what's currently measured vs. claimed.

Full narrative: [`archive/agent-orchestration-architecture.md`](archive/agent-orchestration-architecture.md). Load-bearing principles: [`principles.md`](principles.md).

## Five testable claims

The position implies these specific claims; each is a falsifiable proposition.

1. **The patterns work without a workflow runtime.** All 7 Anthropic patterns (prompt chaining, routing, sectioning, voting, orchestrator-workers, evaluator-optimizer, agent-loop) run end-to-end on bd + personas + bash drivers, with no orchestrator state machine between agents.

2. **Patterns compose without runtime infrastructure.** A step in a parent formula can pour a child wisp; the parent's await blocks on the child's terminal close. The bead graph already does the dependency math. No workflow engine needed for composition.

3. **Worker contracts stay short as workflows get richer.** As the architecture handles more, the persona prompt shouldn't grow linearly. Track line counts over time. If new features keep adding to the prompt, the protocol is leaking; if line count is flat or shrinks, the position is holding. **Measurement (2026-05-23, plan-evals fo-vgam1):** worker contracts measured via `cache_creation_input_tokens` (not per-turn `tokens_in`, which is the API billing slice). Baseline on `enum-extension` under fanout/sonnet: per-worker contract length 11K-29K tokens. Variance comes from how much the worker explores during the task; the *brief* itself is small. Future tracking should watch the *brief* + *system-prompt* portion holding flat as more substrate features land.

4. **It scales.** N concurrent workflows draining a backlog work without an orchestration layer above the substrate. Worker pools, dispatch, retry are all substrate-level, not runtime concerns.

5. **Better models do worse with cages.** Constraining the model with a workflow DSL hurts as model capability grows. Counter-experiment: build the same workflow with-DSL vs without; measure success rate against model versions. **Adjacent finding (2026-05-23, plan-evals graph-shape probes):** the choreography idioms library — meant as an *enabling* substrate, not a cage — biases sonnet but not opus. Sonnet 0/10 → 5/5 on validator-suite when the library is stripped from 5 idioms to fire-and-forget-only; opus stays 5/5 either way. The library's hierarchical examples train sonnet's structural defaults; opus's defaults are robust against the framing. Same direction as claim 5: better-tier models are less prompt-induced. Different framing: it's not just "cages" (constraints) but also "suggestions" (idiom libraries) that weaker tiers absorb as defaults.

## What's validated so far

Claim 1: yes. See [`state.md`](state.md). 7/7 patterns pass under two shims (gc, ntm) with no workflow runtime between agents.

Claims 2-5: not yet. The validation-pack as currently structured tests one-workflow-at-a-time in fresh containers — that's a unit-test level for primitives. The harder claims need different scaffolding; the plan is in [`throughput-mode.md`](throughput-mode.md).

## What this position doesn't yet answer

Even if all five claims hold empirically, the practical authoring question remains:

> Given that the architecture is model-as-orchestrator without a runtime, **what's the right level of abstraction for the most-specific formulas?** What goes in arguments, what becomes a canonical building-block formula, and where's the line between "compose existing formulas" and "write a new one"?

There are different layers of composition:
- Arguments inside one formula (parameterize the same workflow shape).
- Canonical building-block formulas (small reusable pieces).
- Composite formulas built from building-blocks.
- One-off formulas for specific jobs.

The right balance is probably a matter of taste. But there could be reasonable guidelines, and the only way to develop them is to practice — author many real formulas (the "refinery with repoweave" role is one concrete starting point), see what breaks down, abstract from the failure modes. Throughput-mode will surface some of these as we build it against richer workloads.

## See also

- [`principles.md`](principles.md) — the load-bearing design principles.
- [`state.md`](state.md) — current empirical footing.
- [`throughput-mode.md`](throughput-mode.md) — plan for testing claims 2-5.
- [`archive/`](archive/) — historical exploration: the position's full prose, decisions log, ntm tutorial, conversation that mapped the landscape.
