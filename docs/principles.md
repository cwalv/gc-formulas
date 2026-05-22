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
