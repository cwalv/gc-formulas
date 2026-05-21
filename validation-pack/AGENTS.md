# AGENTS.md — in-container conventions

Terse guidance for agents (LLM or human) operating inside the validation-pack container. Assumes familiarity with `bd` and `gc`; if not, see [`projects/foundations/docs/agent-orchestration-architecture.md`](../../../projects/foundations/docs/agent-orchestration-architecture.md) and the [design doc](../../../projects/foundations/docs/validation-pack-design.md).

## Personas

gascity named-pool model. The pack uses four roles; each maps to a persona toml under `personas/`.

- **foreman** — wisp-maker and observer. Materializes formulas into beads, routes scope to the right persona via `gc sling`, watches for terminal states. **Never executes the bead's work itself.** If foreman finds itself implementing, that's a routing bug.
- **implementer** — does the bead's work. Claims the bead, produces the artifact (code, plan, analysis, whatever the scenario asks for), closes with a reason.
- **treehugger** — quality gate / landing role. In orchestrator-worker flows, picks up an implementer's output, validates, and lands (or kicks back). Holds the bar; not a rubber stamp.
- **evaluator** — review/approve in evaluator-optimizer loops. Reads the implementer's current pass, decides approve vs. iterate; on iterate, hands back for another pass.

## bd lifecycle

Three states: `open` → `hooked` (claimed) → `closed` (terminal).

- Claim: `bd update <id> --claim` (transitions to `hooked`).
- Finish: `bd close <id> --reason="..."` (terminal — `landed`, `approved`, `completed`, `rejected`, etc., depending on scenario).
- Intra-phase iteration (evaluator-optimizer): flip `hooked` → `open` to hand back for another pass. **Do not close-and-reopen** — closing is terminal semantics; abusing it pollutes the state machine and breaks predicates that distinguish "iterating" from "redone after failure".

A bead's full state history is queryable; predicates in `verify_bead_state.py` assert against it.

## Dispatch and metadata

- Persona routing rides on the `gc.routed_to` metadata key. **Always set it via `gc sling <target> <bead-id>`** — that's the public interface. Don't write `gc.routed_to` directly except in atomicity-sensitive paths (e.g., rejection transitions), and even then justify it.
- Mail (`gc mail`) is a UX layer for humans on top of beads. Agent-to-agent dispatch goes through bd routing, not mail. Treat mail as out-of-band for in-container scenarios.

## Formulas

A formula is a multi-agent checklist — the unit of "this is how we run this pattern". Each formula's steps become beads; dependencies between steps are explicit in the formula.

- Materialize: `bd mol wisp <formula-name>` — emits the bead DAG.
- Formulas in this pack live under `formulas/`, one per Anthropic workflow pattern.
- Formulas must be self-contained: behavior must not depend on container env vars or host state beyond what the entrypoint guarantees.

## Substrate scope

The in-container `bd` substrate is shared across scenarios within a single container. Run scenario 01, then 02, and 02 sees 01's beads in the history. This is intentional — it keeps the rig simple. **To reset, recreate the container** (a fresh `docker compose run --rm`). Do not try to garbage-collect or prefix-isolate within a single container.
