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
- **bd substrate**: in-container; shared across scenarios within a single container; no per-run cleanup or per-scenario prefix isolation. `bd init --prefix=vp` runs at image build time as the agent user (`fo-h8o87.1.3`). Recreate the container for a fresh substrate.
- **types.custom registration**: gc expects custom issue types (`molecule`, `convoy`, `message`, `event`, `gate`, `merge-request`, `agent`, `role`, `rig`, `session`, `spec`, `convergence`, `step`) to be registered in bd's `types.custom` config. Without registration, `gc sling` / `gc session` / `gc converge` fail with `invalid issue type: <type>`. Registered at image build time via `gc doctor --fix` immediately after `bd init` (`fo-h8o87.1.11`).
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
| `shim_await(predicate)` | Block until predicate holds against live bd state | `gc events --watch --filter ...` | ntm event/poll equivalent |

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

- **Substrate-prep location**: the scenario 01 driver (kicked back as `fo-h8o87.1.8`) currently does some setup per-scenario (formula symlink at `.beads/formulas/`, git config for bd's audit). Cleaner to move into `entrypoint.sh` or Dockerfile so scenarios start from a fully-prepped substrate. Defer until Phase 0 actually lands; revisit if multiple scenarios duplicate the prep.
- **gc session lifecycle in scenarios**: does `gc session new` require a gc controller running, or is the session a direct claude invocation tracked by the gc CLI? If it needs a controller, `entrypoint.sh` also needs to start it. Confirm empirically during fo-h8o87.1.8 rework.
- **Scenario-driver-as-foreman**: with the driver dispatching via raw metadata writes (no `gc sling`), is the foreman persona still needed for one-shot scenarios, or does the driver fill that role? Decide per-scenario; for prompt-chaining the driver-as-foreman is fine.

## Cross-references

- [`agent-orchestration-architecture.md`](./agent-orchestration-architecture.md) — the architecture this pack validates.
- [`gascity-focus-areas.md`](./gascity-focus-areas.md) — the "opinionated UI for humans, content for agents" principle.
- [`scenario-01-call-chain.md`](./scenario-01-call-chain.md) — manually-walked substrate sanity check; covers what a vanilla shim would have proven, done once by hand.
- sme2 mail `gc-wisp-bj2` — Flywheel pre-impl multi-vendor gate input that informs scenario 8.
- bd PR #2187 (commit `c459812e`, 2026-03-02): flipped `bd mol wisp` default to root-only unless formula declares `pour=true`.
- `fo-8fdbk` (closed): beads-ui-prototype docs reconciliation — updated `formulas.md` with the `pour` field; extended `gaps-audit.md` C12/C14.

## Bead tree

The design is settled and tracked as the `fo-h8o87` epic tree (see `bd show fo-h8o87`). Phase 0 children include the scenario-driver rework (`fo-h8o87.1.8`, kicked back to open) and the gc-custom-types-registration step (`fo-h8o87.1.11`). The .md stays as the source-of-truth narrative; the beads carry tracked work.

## Validation findings — 2026-05-21 autonomous session

Drove substrate + shims to a working baseline. Findings:

### What works (verified in-container)

- **gc shim spawn**: `gc session new <persona> --no-attach --alias <name> --city <pack-root>` creates a tmux session, gc supervisor reconciler starts the claude process under it. Verified with `gc session list` showing active sessions.
- **ntm shim spawn**: `ntm spawn <name> --cc=1 --no-user` (with the projects_base directory pre-created) creates a tmux session, launches a claude pane, starts a session monitor. Verified.
- **OAuth bind-mount**: `~/.claude/.credentials.json` mounted RO at staging path; entrypoint copies to writable `~/.claude/.credentials.json` mode 600. Pre-seeded `~/.claude.json` skips claude's first-run wizard.
- **bd substrate init at image build**: `bd init --prefix=vp --non-interactive` + `bd config set dolt.auto-commit on` + `bd config set dolt.auto-start on`.
- **gc custom types registration**: `gc doctor --fix --city <pack-root> || true` after `bd init` registers the 12 required custom types (molecule, convoy, session, etc.).
- **Pack pruning**: strip `gastown` + `maintenance` packs entirely; keep `bd` + `dolt` packs but rm their `orders/`, `formulas/`, `agents/` subdirs. Removes most of the supervisor's persona-spawn noise. Declared a stub `dog` agent for the bundled orders that still target it; suspend dog at entrypoint to keep it from spawning.
- **Formula materialization via `bd mol pour`**: creates root + step beads in liquid (persistent) phase. Driver parses `id_mapping` via `python3 raw_decode` to tolerate bd's `auto-importing N bytes` stdout noise.
- **Routing via direct metadata write**: `bd update --set-metadata gc.routed_to=validation/<persona> <bead-id>` (sidesteps `gc sling` auto-convoy). Persona's pool query `bd ready --metadata-field gc.routed_to=validation/<persona> --unassigned` picks it up.
- **Persona loop**: implementer prompt updated to explicit work-pickup query + loop instruction. Closing one bead returns to the query.
- **`bd mol pour` enforces blocker semantics**: step-b/c stay blocked until step-a closes (verified empirically). `bd mol wisp` does NOT (per bd PR #2187 root-only default), and `--include-ephemeral` bypasses blockers — so pour is the right primitive for our chained scenarios.
- **Single-step close** (step-a closing) verified end-to-end with real claude work.

### Update: ALL 7 scenarios PASS in parallel on bd v1.0.3 (2026-05-21)

All seven Anthropic catalog patterns now validate end-to-end against the
gc shim in isolated docker containers (one container per scenario, run in
parallel from a single shared image):

| # | Pattern | Reason | Latency |
|---|---|---|---|
| 01 | prompt-chaining (a → b → c) | completed | ~3-step run |
| 02 | routing (foreman classify) | classified | 88 s |
| 03 | sectioning (3 slices + join) | completed | 207 s |
| 04 | voting (3 voters + tally) | tallied / completed | 114 s |
| 05 | orchestrator-workers (decompose → 2 workers → land) | landed | 245 s |
| 06 | evaluator-optimizer (implementer ⇄ evaluator) | approved | 174 s |
| 07 | agent-loop (multi-step bash trace) | completed | 95 s |

Key substrate-shape changes that landed during the parallel sweep:

- **`bd mol wisp` everywhere with `pour = true` in formulas** (not `bd mol pour`).
  Pour creates persistent beads that pile up and grind throughput; wisps are
  ephemeral by design. Pollers (implementer, foreman, evaluator personas) pass
  `--include-ephemeral` to `bd ready`.
- **Persona work-loops align across roles**. Foreman + evaluator rewritten
  from descriptive/one-shot to the same `poll → claim → execute → close →
  loop` shape as implementer. The bead description carries the close reason
  (`classified`, `approved`, etc.) so the personas don't need scenario-specific
  knowledge.
- **`min_active_sessions = 1` on implementer + evaluator** in city.toml. The
  evaluator-optimizer ping-pong stalls without it: when one side drains
  between rounds, the supervisor only respawns if `min` enforces it.
- **`shim_await` polls bd directly** (5 s cadence). `gc events --watch`
  exits on the first event of the requested type regardless of subject;
  `--payload-match` doesn't descend into nested fields (bead ID lives at
  `payload.bead.id`, not `payload.id`); `--follow` only streams *future*
  events and misses closes that fire before attach. Polling is simple and
  predictable; comment in `shims/gc.sh` notes this for future readers.
- **`verify_bead_state.py` falls back to `bd show` per bead** when
  `bd list --status=closed` omits a closed ephemeral wisp (the filter is
  inconsistent in v1.0.3). Per-bead lookup is reliable.
- **`docker-compose.yml` uses `image: validation-pack:latest`** (not `build:`).
  Parallel `docker compose -p <name> run` invocations were each building their
  own per-project image and silently caching stale source; a fixed image tag
  rebuilt manually before each sweep keeps all runs on the same code.

### Update: scenario 01 PASSES cleanly on bd v1.0.3

Pivoted to bd v1.0.3 (from v1.0.4). Scenario 01 ran clean end-to-end on first try:

```
PASS: bead 'va-mol-3rua' (step-a) closed with reason='completed'
PASS: bead 'va-mol-4eyl' (step-b) closed with reason='completed'
PASS: bead 'va-mol-3ati' (step-c) closed with reason='completed'
PASS: closed_in_order sequence matches
PASS — all assertions satisfied
```

Real LLM content cascaded through:
- step-a notes: "Result: azure, navy, indigo"
- step-b notes: "Result: Azure evokes a sense of calm openness and vast sky-like serenity. Navy c..."
- step-c notes: "Result: The palette of blue encompasses remarkably distinct emotional territorie..."

### Root cause: bd v1.0.4 regression in concurrent-write safety (upstream-known)

Subagent investigation surfaced the relevant upstream issues:

- **`gastownhall/beads#3948`** (OPEN): "Auto-import upgrade path fires on every bd command despite non-empty database" — describes our exact symptom (closed bead reverts ~5s later) verbatim.
- **`gastownhall/beads#3964`** (OPEN): `bd update --append-notes` silently drops writes in rapid succession.
- **`gastownhall/beads#3822`** (OPEN): "Import/Export JSONL in server mode may result in data loss" (filed by Dolt maintainer).
- **`gastownhall/beads#3969`** (CLOSED, fixed in main): Diagnoses the underlying dispatch error — v1.0.4's CGO build path triggered auto-import on every command.

**What v1.0.4 broke**: PR #3630 ("Fix maybeAutoImportJSONL concurrency race in embedded mode") moved the `TotalIssues > 0` emptiness guard inside a fast-path that didn't cover the server-mode store. Server-mode bd fell through to the unguarded fallback path, running `importFromLocalJSONLFull` unconditionally on every command. PR #3614 also removed the embedded-mode flock that had been serializing writes.

**What main has post-v1.0.4** (partial fix):
- Commit `1cf833734` (PR #3691, 2026-05-09) restores the emptiness guard for the fallback path.
- PR #3889 (`da73b7511`, 2026-05-11) split-writes work in the dolt transaction layer.
- PRs #3944, #3865, #3995 are still open and represent the more complete server-mode-aware fix.

**Recommendation for downstream consumers**: pin v1.0.3 (which has the guard intact + flock) OR build from main at/after `1cf833734`. Do NOT use v1.0.4 for any workload with concurrent bd processes.

### What was flaky on v1.0.4 (now resolved by version pin)

- **Multi-step chain under multi-process load** — bd v1.0.4's persistence model exports `.beads/issues.jsonl` after every CLI write. Concurrent bd processes (claude implementer + gc supervisor's control-dispatcher + dog patrols + scenario driver) interleave their import-modify-export cycles, causing classic last-writer-wins lost-update races. Observed: step-a closes, persists briefly, then a concurrent process's JSONL export overwrites without the close, and step-a appears open again.

**Fix**: set `ENV BEADS_EXPORT_AUTO=false` in the Dockerfile. This matches what gc's own supervisor does for its bd subshells — it disables the JSONL re-export entirely. Writes go through embedded dolt directly; dolt has transactional semantics. JSONL stays at the initial snapshot but isn't needed for the validation use case (container is ephemeral).

After this fix + suspending dog + stricter implementer persona (no drain-after-claim, no substrate investigation), scenario 01's full 3-step chain executed end-to-end:

```
va-mol-ssyx (step-a): closed (reason: blocked — persona bug, step-a doesn't have a predecessor to fall through on)
va-mol-aekq (step-b): closed (reason: completed) ✓
va-mol-e4m1 (step-c): closed (reason: completed) ✓
va-mol-0hdv (root):   closed (auto-cascade when all children closed) ✓
```

Verifier predicate output:
```
FAIL: bead 'va-mol-ssyx' close reason mismatch: expected='completed' actual='blocked'
PASS: bead 'va-mol-aekq' closed with reason='completed'
PASS: bead 'va-mol-e4m1' closed with reason='completed'
PASS: closed_in_order sequence matches
```

Remaining issue is **persona-side**: claude closed step-a as `blocked` instead of `completed`. The strict persona's "if you can't proceed, close blocked" branch incorrectly fired on step-a (which has no predecessor's notes to read because step-a IS the first step). One-line persona fix to make step-a's `completed` reason the default and only fall through to `blocked` if a downstream step genuinely can't read its predecessor.

### What's authored but not validated end-to-end

- Scenarios 02–07 (routing, sectioning, voting, orchestrator-workers, evaluator-optimizer, agent-loop): formulas + drivers + fixtures committed. Will share the same multi-process bd contention pattern; would benefit from a bd-level fix or single-writer scenarios.
- ntm shim end-to-end: `ntm spawn` confirmed but not exercised against scenario 01 (the gc shim's bd issues would apply equally since the substrate is shared).

### Open follow-ups

- File against beads: lost-update vulnerability in concurrent bd CLI usage; consider row-level locking or making dolt the single source of truth (skip JSONL re-import on every invocation).
- Verifier extensions for new predicate kinds (`closed_unordered`, `metadata_match`, `notes_contains`, `reason_one_of`) landed and self-test passes — ready when scenarios run cleanly.
- ntm shim runtime config (NTM_CONFIG, projects_base dir): currently the shim auto-creates `~/ntm-work`; works but does a write at first call. Could bake into Dockerfile for cleanliness.
- gc session start-deadline (1m04s) — sonnet/opus + `--effort max` blew it; switching implementer to `haiku` alias avoids the overrun.

### Concrete artifacts committed

- 7 scenario drivers + formulas + fixtures (01-prompt-chaining through 07-agent-loop)
- 2 shim implementations (shims/gc.sh, shims/ntm.sh)
- 4 personas (foreman, implementer, treehugger, evaluator) + dog stub + ntm-implementer variant
- Verifier extended with 4 new predicate kinds
- Container image with bd + gc + ntm + dolt CLIs, OAuth handling, custom types registered, dog suspended on start
- 25+ commits in github/cwalv/gc-formulas validating the architecture step by step
