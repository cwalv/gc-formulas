# validation-pack

Hermetic validation harness for the foundations agent-orchestration architecture. One scenario per Anthropic workflow pattern (prompt chaining, routing, parallelization, orchestrator-workers, evaluator-optimizer, agent loop, plus a pre-impl multi-vendor gate), each run end-to-end inside a single container against an in-image `bd` substrate and `gc` city.

The pack exercises the principles that architecture has settled on: substrate-coordinated personas, formulas as multi-agent checklists, mail demoted out of the dispatch path, foreman as wisp-maker + observer, intra-phase iteration via hooked↔open, and so on. If the pack passes, those principles work in practice on this stack.

Full design narrative — including the scenario table, decisions locked, OAuth-mount approach, and phased rollout — lives in [`projects/foundations/docs/validation-pack-design.md`](../../../projects/foundations/docs/validation-pack-design.md).

**Current status**: Phase 0 in progress — skeleton + scenario 01 (prompt chaining).

## Build

From inside this directory:

```bash
docker compose build
```

The image bakes in `bd`, `gc`, the Claude Code CLI, a minimal `city.toml`, and this pack's `personas/`, `formulas/`, `scenarios/`, `fixtures/`, and `scripts/`. The only host-filesystem dependency at runtime is the Claude Code OAuth credentials file (see design doc).

## Run a scenario

```bash
docker compose run --rm validation <scenario-id>
```

For example:

```bash
docker compose run --rm validation 01-prompt-chaining
```

The entrypoint installs the bind-mounted host credentials into the container's writable `~/.claude/`, then dispatches to `scripts/run-scenario.sh <scenario-id>`. The in-container `city.toml` is baked into the image — no runtime city init needed. The scenario sets up bead state, wisps the matching formula, spawns the personas, awaits a terminal state, and runs `verify_bead_state.py` to assert the final bead DAG matches the success predicate.

The in-container `bd` substrate is shared across scenarios within a single container — recreate the container (`--rm` plus a fresh `docker compose run`) for a clean substrate.

## Layout

```
validation-pack/
├── README.md                       this file
├── AGENTS.md                       agent-facing conventions for in-container work
├── Dockerfile
├── docker-compose.yml              service definition, mounts, env, entrypoint args
├── city.toml                       minimal gc city baked into image; override via mount
├── personas/                       gc named-pool personas
│   ├── foreman.toml
│   ├── implementer.toml
│   ├── treehugger.toml
│   └── evaluator.toml
├── formulas/                       one per pattern (plus shared base flows)
│   ├── prompt-chaining.formula.toml
│   ├── routing.formula.toml
│   ├── sectioning.formula.toml
│   ├── voting.formula.toml
│   ├── orchestrator-workers.formula.toml
│   ├── evaluator-optimizer.formula.toml
│   └── agent-loop.formula.toml
├── scenarios/                      driver scripts per scenario
│   ├── 01-prompt-chaining.sh
│   ├── 02-routing.sh
│   └── ...
├── fixtures/                       test data per scenario
└── scripts/
    ├── entrypoint.sh               per-container: install credentials, gc init, exec run-scenario
    ├── run-scenario.sh             per-scenario: bd setup, wisp formula, spawn agents, await terminal
    └── verify_bead_state.py        assert final bead DAG matches expected predicate
```

Not every file above necessarily exists yet — the pack is being built up in phases per the design doc. The tree reflects the target shape.

## See also

- [`projects/foundations/docs/validation-pack-design.md`](../../../projects/foundations/docs/validation-pack-design.md) — full design narrative, scenario table, decisions, phasing.
- [`projects/foundations/docs/agent-orchestration-architecture.md`](../../../projects/foundations/docs/agent-orchestration-architecture.md) — the architecture this pack validates.
