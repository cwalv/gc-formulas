# Design principles

The load-bearing principles behind the [position](position.md). Each is short, with a one-sentence test for "you're violating this when..."

## Content over runtime

Prefer markdown templates / prose contracts over DSLs + runtime interpreters. The model is fluent in prose; every typed-config interpretation is a translation surface that doesn't survive model improvement.

**Violating it when:** you build a TOML/YAML format whose contents are read by an LLM, then add a Go interpreter to mediate.

## Opinionated UI for humans, content for agents

Form should match consumer. Where the artifact is consumed by a human, opinionated UI (kanban, dashboards, dependency graphs) is great — it compresses agreements about how to think and surfaces structure at a glance. Where the artifact is consumed by a model, prose is the universal interface.

**Violating it when:** you build agent-facing TOML for a workflow whose semantics the model could read directly from the bead description.

## Form matches consumer

Generalization. AGENTS.md is read by an agent (prose works). Per-step `gc.outcome` metadata is read by the substrate (typed works). Pipeline scrollback regex parsing an LLM's prose response (form mismatch — fragile, breaks on phrasing drift).

**Violating it when:** you parse an LLM's prose output with a regex, or expect typed structure from a prose channel.

## Roles live in beads, not in personas

The model is the role-system. A single generic worker persona's work-loop is universal: poll → claim → read bead → do exactly what the bead says → close. Role-specific behavior lives in the bead's description ("You are the foreman; classify..."). Personas describe the universal contract; beads describe the work.

**Violating it when:** you have an `if persona == "foreman"` branch in Go code, or a separate persona file per role with substantially identical work-loops.

## Worker contract should shrink as the architecture matures

Every line of bash in a worker prompt is a place where the protocol leaks. As the runtime grows more capable, the agent-side contract should get shorter — typed CLI verbs handle what bash recipes used to. Line count of the worker prompt is a falsifiable proxy for whether the protocol is crystallizing or churning.

**Violating it when:** new orchestrator features keep adding sections to the worker prompt.

## Substrate provides infrastructure, never roles

The orchestrator (gc, ntm, anything else) supplies primitives — session lifecycle, work-queue operations, hooks, event bus. It does not supply named roles. From gascity's AGENTS.md: "If a line of Go references a specific role name, it's a bug." Roles are configuration on top of the substrate.

**Violating it when:** the substrate hard-codes a "mayor" or "treehugger" notion.

## Feedback (gemini)

These principles are pointing towards a classic architectural shift, mapping well onto established patterns in distributed systems and AI history. The core realization—that LLMs struggle with rigid State Machines but excel at navigating fuzzy data graphs—is sound. 

When you build a YAML/TOML workflow engine, you are doing **Orchestration** (central brain telling workers exactly what to do), which forces the LLM into a dumb worker role and requires massive, fragile prompt contracts (like the old `graph-worker.md`). By moving to a system where tasks are markdown files in a graph (Beads) and agents poll to claim work, you are shifting to **Choreography** (independent agents reacting to state changes).

### Prior Art to Consider

To ground these principles in established theory, consider referencing:

1. **The Blackboard Architecture (1980s AI)**
   The "Beads" substrate is effectively a Blackboard. A shared, durable central data store where independent "Knowledge Sources" (LLM agents) watch for problems they know how to solve, execute them, and post the results back. It completely eliminates the need for a central workflow runtime.
2. **Promise Theory (Mark Burgess / CFEngine)**
   The principle "Roles live in beads, not in personas" maps perfectly to Promise Theory. Instead of a central server pushing commands, autonomous nodes look at a desired state (the "Bead") and make a "promise" to fulfill it. It provides theoretical backing for why a text-based contract (the bead description) is more resilient than top-down scripting.
3. **Choreography vs. Orchestration (Microservices)**
   The realization that YAML workflow engines age badly is a known lesson from microservices. Orchestration (Step Functions/Airflow) is great for deterministic code but brittle for AI. Choreography (Event-Driven Architecture) relies on services emitting and reacting to events, matching how the "Foreman" and "Treehugger" agents act on bead state changes.
4. **ReAct and Tool-Using Agent Loops**
   As mentioned in Anthropic's "Building Effective Agents", the industry is moving away from heavy Cognitive Architectures (like LangGraph) that force agents into rigid DAGs, and towards simple loops with tools. The "Worker contract should shrink" principle aligns with giving agents better CLI tools (`bd claim`, `bd close`) rather than writing bash recipes in the system prompt.
