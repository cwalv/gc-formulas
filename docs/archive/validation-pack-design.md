# Validation pack design — foundations agent-orchestration

**Status**: active design. Will move to a tracked epic/bead post-design/refine.

**Purpose**: exercise the agent-orchestration architecture (see [`agent-orchestration-architecture.md`](./agent-orchestration-architecture.md)) end-to-end, with one scenario per workflow pattern, in a hermetic container. Validates that the principles we've settled on actually work in practice — substrate-coordinated personas, formulas as multi-agent checklists, mail demoted out of the dispatch path, foreman as wisp-maker + observer, intra-phase iteration via hooked↔open, etc.

## Decisions locked

- **Pack location**: extend [`github/cwalv/gc-formulas`](https://github.com/cwalv/gc-formulas) — don't create a new repo.
- **Container shape**: single container, run as non-root user, orchestrated via `docker compose` (declarative config; easy to extend to multi-container when Phase 2 needs vendor diversity).
- **Persona content**: persona prompts are plain `.md` files in `personas/` — markdown is source-of-truth. Each orchestrator's config (city.toml for gc, ntm.toml for ntm) references the same .md file via its own schema. Avoid TOML wrappers around persona prompts; gc loads `prompt_template` as raw text and a wrapper would leak into the prompt.
- **Shim model**: scenarios are **shim-pluggable**. Each orchestrator (gc, ntm) provides a `shims/<name>.sh` implementing the spawn/prime/await primitives (see § Shim architecture). Substrate primitives (bd, claude binary, personas, formulas, verifier) are shared. **No vanilla / no `claude --print` shim**: `claude --print` uses API-billed per-token charges instead of the Claude Code subscription, and bypassing the orchestrator validates a path no production agent actually takes. The manually-walked substrate sanity check in [`scenario-01-call-chain.md`](./scenario-01-call-chain.md) covers what a vanilla shim would have proven.
- **Vendor coverage**: Claude only initially (no API key — uses Claude Code OAuth from the host).
- **OAuth handling**: bind-mount the single file `~/.claude/.credentials.json` read-only into the container at a staging path (e.g. `/mnt/host-claude/credentials.json`). The entrypoint copies it to `~/.claude/.credentials.json` at container start, preserving mode 600. This gives Claude Code a writable in-container copy (CoW-style): token refresh writes land on the copy, never on the host file. If the copy/refresh path turns out infeasible, accept hard fail — the container can be recreated. Nothing else from host `~/.claude/` is exposed (settings.json, history, plugins, sessions, telemetry stay on host). Because all OAuth state arrives pre-baked, there's no first-run/`claude login` handshake to worry about inside the container.
- **bd substrate**: in-container; shared across scenarios within a single container; no per-run cleanup or per-scenario prefix isolation. `bd init --prefix=vp` runs at image build time as the agent user (`fo-h8o87.1.3` — bd substrate inside container). Recreate the container for a fresh substrate.
- **types.custom registration**: gc expects custom issue types (`molecule`, `convoy`, `message`, `event`, `gate`, `merge-request`, `agent`, `role`, `rig`, `session`, `spec`, `convergence`, `step`) to be registered in bd's `types.custom` config. Without registration, `gc sling` / `gc session` / `gc converge` fail with `invalid issue type: <type>`. Registered at image build time via `gc doctor --fix` immediately after `bd init` (`fo-h8o87.1.11` — register gc custom types in container).
- **Formula `pour = true`**: scenarios that need multi-step DAG materialization must declare `pour = true` at the formula top level. `bd mol wisp` defaults to root-only after bd PR #2187 (commit `c459812e`, 2026-03-02); `pour = true` opts the formula into having children materialized even under wisp. Wisp is the right semantic fit for validation runs (ephemeral, not git-synced) — pour=true unblocks the multi-bead use case. Empirically verified in [`scenario-01-call-chain.md`](./scenario-01-call-chain.md) Phase 3.
- **Verification harness language**: Python. Lean — start with stdlib + `subprocess`; reach for `pytest` only if assertion patterns get repetitive.
- **gc city setup**: a minimal `city.toml` is baked into the image (`COPY` in the Dockerfile). Tests run against the in-image city without setup. To vary city config per test iteration without rebuilding image layers, bind-mount an override `city.toml` over the baked one in `docker-compose.yml`.

## Scope — 7 + 1 scenarios

One scenario per Anthropic workflow pattern (from `agent-orchestration-architecture.md` § Anthropic catalog), plus the pre-impl multi-vendor gate per sme2 input.

| # | Pattern | Scenario | Success predicate |
|---|---|---|---|
| 1 | Prompt chaining | 3-bead chain A→B→C; deps enforce order | All three closed with expected reasons in order |
| 2 | Routing | Foreman gets ambiguous scope; classifies; routes | Bead's `gc.routed_to` matches expected persona |
| 3 | Parallelization (sectioning) | Foreman wisps N parallel beads; atomic claims | All N closed concurrently; no collisions; join bead fires |
| 4 | Parallelization (voting) | Same description × N; aggregator-bead tallies | Aggregator's close-reason reflects the tally |
| 5 | Orchestrator-workers | v1-style full flow (foreman + implementer + treehugger) | Landing bead closes `landed` |
| 6 | Evaluator-optimizer | Single bead, hooked↔open ping-pong | Terminal `approved` after N iterations |
| 7 | Agent (dynamic loop) | Multi-step task; tool use within one bead | Bead closes `completed` with tool-use trace in notes |
| 8 | Pre-impl multi-vendor gate | Plan bead reviewed by N vendor agents; aggregated verdict | (deferred — Phase 2, requires vendor diversity) |

## Shim architecture

Scenarios are shim-pluggable. The substrate (bd primitives, formula files, persona prompts, the verifier) is universal. Each orchestrator provides a thin shim implementing three primitives the scenario driver calls:

| Primitive | Purpose | gc shim | ntm shim (later) |
|---|---|---|---|
| `shim_spawn(persona, count)` | Start `count` workers of `persona` (interactive `claude`, subscription-billed) | `gc session new --pool <persona>` (one per worker, or one pool config) | `ntm spawn <persona>:<count>` |
| `shim_prime(persona)` | Return the persona's system prompt | `gc prime <persona>` | ntm persona resolution |
| `shim_await(predicate)` | Block until predicate holds against live bd state | Poll `bd show <id> --json` every 5 s, check `.status` | ntm event/poll equivalent |

`scripts/run-scenario.sh` sources `shims/${SHIM:-gc}.sh` and exposes the primitives. A scenario then reads:

```bash
# scenarios/01-prompt-chaining.sh (illustrative)
WISP_JSON=$(bd mol wisp prompt-chaining --var task_a="..." --var task_b="..." --var task_c="..." --var assignee=implementer --json)
# parse step bead ids; write predicate fixture
for STEP_ID in "$STEP_A" "$STEP_B" "$STEP_C"; do
    bd update "$STEP_ID" --set-metadata routed_to=implementer
done
shim_spawn implementer 1
shim_await "$STEP_C closed"
```

The same scenario driver runs against any shim that implements the three primitives, giving cross-orchestrator validation for free.

**Routing**: scenarios set `bd update --set-metadata <key>=<pool>` directly rather than calling `gc sling`. This sidesteps gc's auto-convoy creation (only useful for parallel-fan-out scenarios where the convoy container makes sense). The metadata **key and value namespace are orchestrator-specific** — personas are orchestrator-specific (they reference `gc hook` / `gc runtime drain-ack` / etc.), so the routing convention follows the persona: gc shim uses `gc.routed_to=validation/<persona>` (gc's namespaced pool convention); an ntm shim would use ntm's equivalent. An earlier framing of "metadata-orchestrator-agnostic routing" over-rotated — personas embed orchestrator conventions in their query patterns, so routing namespace must align with them.

## Pack structure (extends gc-formulas)

```
github/cwalv/gc-formulas/
├── ... (existing content unchanged)
└── validation-pack/
    ├── README.md
    ├── Dockerfile
    ├── docker-compose.yml          service definition, mounts, env, entrypoint args
    ├── city.toml                   minimal gc city baked into image; override via mount
    ├── AGENTS.md                   pack-level conventions for in-container agents
    ├── personas/                   shared persona prompts (plain markdown — orchestrator-agnostic)
    │   ├── foreman.md
    │   ├── implementer.md
    │   ├── treehugger.md
    │   └── evaluator.md
    ├── formulas/                   one per pattern (bd-native TOML; declare pour=true)
    │   ├── prompt-chaining.formula.toml
    │   ├── routing.formula.toml
    │   ├── sectioning.formula.toml
    │   ├── voting.formula.toml
    │   ├── orchestrator-workers.formula.toml
    │   ├── evaluator-optimizer.formula.toml
    │   └── agent-loop.formula.toml
    ├── shims/                      orchestrator adaptors (spawn/prime/await primitives)
    │   ├── gc.sh                   Phase 0 — primary
    │   └── ntm.sh                  Phase 1+ — re-runs same scenarios under tmux/persona model
    ├── scenarios/                  driver scripts per scenario (shim-aware)
    │   ├── 01-prompt-chaining.sh
    │   ├── 02-routing.sh
    │   └── ...
    ├── fixtures/                   test data per scenario
    └── scripts/
        ├── entrypoint.sh           one-time per-container: install credentials, exec run-scenario
        ├── run-scenario.sh         per-scenario: sources shim, invokes scenario driver, runs verifier
        └── verify_bead_state.py    assert final bead DAG matches expected predicate (Python)
```

## Container shape

```dockerfile
FROM ubuntu:24.04

# Base toolchain: bd v1.0.4, gc v1.1.0, claude-code CLI, jq, python3, basics.
# (exact RUN commands per fo-h8o87.1.10)

# Ubuntu 24.04 ships a 'ubuntu' user at uid 1000 — delete it so 'agent' is the
# sole uid 1000 entry (avoids /etc/passwd lookup ambiguity).
RUN userdel -r ubuntu && useradd -m -u 1000 -s /bin/bash agent

WORKDIR /home/agent
COPY --chown=agent:agent validation-pack/ /home/agent/validation-pack/
USER agent

# bd substrate (fo-h8o87.1.3): embedded Dolt, prefix `vp`, owned by agent uid 1000.
RUN cd /home/agent/validation-pack && bd init --prefix=vp --non-interactive

# Register gc's required custom issue types into bd.types.custom (fo-h8o87.1.11).
# Without this, gc sling/session/converge fail with "invalid issue type: <name>".
RUN gc doctor --fix --city /home/agent/validation-pack

ENTRYPOINT ["/home/agent/validation-pack/scripts/entrypoint.sh"]
```

`docker-compose.yml` sketch:

```yaml
services:
  validation:
    build: .
    user: "1000:1000"
    volumes:
      # Host credentials mounted RO at a staging path; entrypoint copies to
      # ~/.claude/.credentials.json so Claude Code can refresh in-container
      # without writing back to the host file.
      - ~/.claude/.credentials.json:/mnt/host-claude/credentials.json:ro
    # scenario id passed via `docker compose run validation <scenario-id>`
```

Run invocation:

```bash
docker compose run --rm validation <scenario-id>
```

The credentials file is the only host filesystem path touched, and the mount is read-only. The entrypoint's first step is `install -m 600 /mnt/host-claude/credentials.json /home/agent/.claude/.credentials.json`. Anything Claude Code writes inside `/home/agent/.claude/` after that — refreshed tokens, settings cache, history — lives in the container's writable layer and disappears with the container; nothing leaks back to the host.

## Phased implementation

- **Phase 0** — skeleton + scenario 1 (prompt-chaining), single vendor, **gc shim only**. Validates the whole rig: container build, OAuth mount, bd substrate, gc session/hook/events primitives, scenario verification harness. Smallest viable end-to-end via gc.
- **Phase 1** — scenarios 2–7 (the remaining single-vendor patterns), all run against gc shim.
- **Phase 2** — scenario 8 (multi-vendor pre-impl gate). Requires adding a non-Claude vendor; may force multi-container.
- **Phase 3** (optional) — negative scenarios: agent dies mid-bead, multi-agent claim race, mid-flight operator interrupt, RO-credentials-file refresh failure, etc.
- **Later — ntm shim**: re-run the same scenarios under ntm's tmux+persona model. Same substrate, same scenario drivers; only `shims/ntm.sh` is new. Gives cross-orchestrator comparison.

## Open questions

- **Substrate-prep location**: the scenario 01 driver (kicked back as `fo-h8o87.1.8` — VP: scenario 01-prompt-chaining driver and fixtures) currently does some setup per-scenario (formula symlink at `.beads/formulas/`, git config for bd's audit). Cleaner to move into `entrypoint.sh` or Dockerfile so scenarios start from a fully-prepped substrate. Defer until Phase 0 actually lands; revisit if multiple scenarios duplicate the prep.
- **gc session lifecycle in scenarios**: does `gc session new` require a gc controller running, or is the session a direct claude invocation tracked by the gc CLI? If it needs a controller, `entrypoint.sh` also needs to start it. Confirm empirically during fo-h8o87.1.8 rework.
- **Scenario-driver-as-foreman**: with the driver dispatching via raw metadata writes (no `gc sling`), is the foreman persona still needed for one-shot scenarios, or does the driver fill that role? Decide per-scenario; for prompt-chaining the driver-as-foreman is fine.

## Cross-references

- [`agent-orchestration-architecture.md`](./agent-orchestration-architecture.md) — the architecture this pack validates.
- [`gascity-focus-areas.md`](./gascity-focus-areas.md) — the "opinionated UI for humans, content for agents" principle.
- [`scenario-01-call-chain.md`](./scenario-01-call-chain.md) — manually-walked substrate sanity check; covers what a vanilla shim would have proven, done once by hand.
- sme2 mail `gc-wisp-bj2` — <!-- TODO: <context to be filled in by reviewer; mail ID was the original source> --> Flywheel pre-impl multi-vendor gate input that informs scenario 8.
- bd PR #2187 (commit `c459812e`, 2026-03-02): flipped `bd mol wisp` default to root-only unless formula declares `pour=true`.
- `fo-8fdbk` (closed — VP: beads-ui-prototype docs: reconcile with current bd wisp/pour behavior + audit for similar gaps): updated `formulas.md` with the `pour` field; extended `gaps-audit.md` C12/C14.

## Bead tree

The design is settled and tracked as the `fo-h8o87` epic tree (see `bd show fo-h8o87`). Phase 0 children include the scenario-driver rework (`fo-h8o87.1.8`, kicked back to open) and the gc-custom-types-registration step (`fo-h8o87.1.11`). The .md stays as the source-of-truth narrative; the beads carry tracked work.

## Current status (end of latest session)

- 7/7 gc-shim scenarios pass on bd v1.0.3. ntm-shim scenario 07 passes; scenarios 02-06 under ntm gated on conversion completing per validation-pack-decisions.md.
  - v1.0.4 broke concurrent-write safety; we pin v1.0.3. See decisions doc for the upstream issue refs (gastownhall/beads#3948, #3964, #3822, #3969).
