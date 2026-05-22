# Scenario 01 prompt-chaining — verified call/event chain

Manual walkthrough of the mechanical substrate operations that scenario 01 performs, run inside a `validation-pack` container. Each step shows the command issued and the observed substrate response. Captured 2026-05-20 against bd v1.0.4, gc v1.1.0, validation-pack at gc-formulas/validation-pack/.

Purpose: ground the scenario driver in observed primitive behavior so we know what's mechanical fact vs. what's a design-doc assumption.

## Setup

```
docker compose run -d --rm --entrypoint sleep --name vp-walkthrough validation 3600
docker exec -u agent -w /home/agent/validation-pack vp-walkthrough <cmd>
```

## Phase 1 — pre-state

| Probe | Observation |
|---|---|
| `bd where` | `/home/agent/validation-pack/.beads`, prefix `vp`, backend `embeddeddolt` |
| `bd ready` | `✨ No open issues` |
| `bd list` | `No issues found.` |
| `bd formula list` | `No formulas found.` (search paths: `.beads/formulas`, `~/.beads/formulas`) |

✓ Clean substrate. bd init ran at image build time per fo-h8o87.1.3.

## Phase 2 — formula discovery

Formula files live under `validation-pack/formulas/`. bd looks in `.beads/formulas/`. Bridge with a symlink:

```bash
mkdir -p .beads/formulas
ln -sf /home/agent/validation-pack/formulas/prompt-chaining.formula.toml .beads/formulas/
```

After symlink:

- `bd formula list` shows `prompt-chaining (4 vars)` under "Workflow".
- `bd formula show prompt-chaining` renders the full description and lists the 4 vars (`task_a`/`b`/`c` required, `assignee` default `implementer`).

✓ Symlink-based discovery works. Driver does this at run time; could move into the Dockerfile for cleanliness.

## Phase 3 — materialization: wisp vs pour

This is where the doc-framing surprise surfaced.

### `bd mol wisp prompt-chaining --var task_a=... --var task_b=... --var task_c=... --var assignee=implementer --json`

```json
{
  "created": 1,
  "id_mapping": { "prompt-chaining": "vp-wisp-7uw" },
  "new_epic_id": "vp-wisp-7uw",
  "phase": "vapor",
  "schema_version": 1
}
```

- `bd list`: shows `vp-wisp-7uw` only (no children).
- `bd ready`: empty (the wisp root isn't itself a unit of work).
- `bd mol show vp-wisp-7uw`: `Steps: 1` — confirms the wisp materialized only the root.

**Conclusion**: at bd v1.0.4, `bd mol wisp` creates a single root issue marked ephemeral (vapor phase, not synced via git). It does NOT materialize the formula's `[[steps]]` array as child beads. The help text confirms: "Ephemeral work that auto-cleans up — Release workflows (one-time execution)".

### `bd mol pour prompt-chaining --var task_a=... --var task_b=... --var task_c=... --var assignee=implementer --json`

```json
{
  "created": 4,
  "id_mapping": {
    "prompt-chaining":         "vp-mol-du0",
    "prompt-chaining.step-a":  "vp-mol-hqp",
    "prompt-chaining.step-b":  "vp-mol-v9m",
    "prompt-chaining.step-c":  "vp-mol-m19"
  },
  "new_epic_id": "vp-mol-du0",
  "phase": "liquid",
  "schema_version": 1
}
```

- `bd list`: root + 3 step beads as a tree.
- `bd ready`: only `vp-mol-hqp` (step-a) — substrate enforces deps; B and C are gated.

**Conclusion**: `bd mol pour` materializes the formula's full DAG (root + all `[[steps]]`) as persistent beads in liquid phase. This is the primitive that matches our architecture-doc framing of "formula as multi-bead checklist".

### Architecture-doc reconciliation (resolved)

Initial reading: the architecture doc's "use `bd mol wisp`" framing was empirically wrong because wisp produced root-only. Resolved differently than first proposed: the **`pour = true` formula field** is the actual bridge. Per bd PR #2187 (commit `c459812e`, 2026-03-02), `bd mol wisp` defaults to root-only **unless the formula declares `pour = true`** at the top level, in which case wisp materializes children just like pour does. Wisp stays the right semantic for ephemeral validation runs (no git audit needed); the formula opts in to multi-bead materialization.

Reconciliation:

- The architecture doc's `bd mol wisp` framing stays — wisp is the right primitive for ephemeral phase materialization.
- Formula gets `pour = true` so wisp materializes the full DAG.
- `beads-ui-prototype/docs/formulas.md` was updated (`fo-8fdbk`) to document the `pour` field, the wisp×pour interaction matrix, and the convoy formula type.
- The architecture doc's "Terminology: `bd mol wisp` vs `bd mol pour`" section was expanded with the persistence-vs-weight distinction and the `pour = true` requirement.
- This pack's `prompt-chaining.formula.toml` now carries `pour = true`.

Wisp's root-only-without-`pour=true` default is intentional (per the source comment and the PR title): default ephemeral work is single-issue; multi-step ephemeral requires explicit opt-in. Not a bd bug.

## Phase 4 — routing via `gc sling`

```bash
gc sling implementer vp-mol-hqp --city /home/agent/validation-pack
```

- Pre-sling metadata: `{}`
- Post-sling metadata: `{"gc.routed_to": "implementer"}`
- Sling output: `Slung vp-mol-hqp → implementer` (followed by a non-blocking warning: `creating auto-convoy: bd create: exit status 1: invalid issue type: convoy` — initially read as a `gc`-vs-`bd` version skew; actually a **setup gap** — gc expects `convoy` to be registered in bd's `types.custom`, which `gc doctor --fix` handles. The Dockerfile currently misses this step; tracked as `fo-h8o87.1.11`. Once registered, the convoy auto-create succeeds and the warning disappears.)
- `bd ready --metadata-field gc.routed_to=implementer` returns step-a — pool-filtered queries work.

✓ Routing primitive sets `gc.routed_to`. Note: the design pivoted away from `gc sling` for the validation-pack scenario drivers in favor of direct `bd update --set-metadata routed_to=implementer <id>` — simpler, no auto-convoy noise, orchestrator-agnostic for the shim model (see `validation-pack-design.md` § Shim architecture). `gc sling` remains the right primitive when the auto-convoy is desired (parallel-fan-out scenarios that need a container bead).

## Phase 5 — dep enforcement under sequential close

State machine: open → hooked (`bd update --claim`) → closed (`bd close --reason=...`). The substrate gates downstream steps via the formula's `needs` deps.

Sequence:

| Action | `bd ready --metadata-field gc.routed_to=implementer` |
|---|---|
| (initial, after slinging A/B/C) | `vp-mol-hqp` (step-a) only |
| `bd close vp-mol-hqp --reason=completed` | `vp-mol-v9m` (step-b) only |
| `bd close vp-mol-v9m --reason=completed` | `vp-mol-m19` (step-c) only |
| `bd close vp-mol-m19 --reason=completed` | empty |

Two observed bonuses on the final close:

1. **Auto-parent-close**: `✓ Auto-closed completed molecule vp-mol-du0 — prompt-chaining`. When all children of a molecule root close, the root closes automatically. No manual close-parent step needed in the driver.
2. **Tree rendering**: `bd close` output shows the full closed-molecule tree, useful for confirming structure.

✓ Substrate correctly enforces strict A→B→C ordering. Cascade-on-completion works. Verifier predicate (`closed_in_order: [A:completed, B:completed, C:completed]`) holds.

## Phase 6 — agent execution (deferred to scenario rework)

The substrate-level chain is verified. The remaining piece — having a Claude agent execute each step's described work — is the C8 (`fo-h8o87.1.8`) driver rework. **Not `claude --print`**: that path is API-billed per-token and bypasses the orchestrator. Production-shaped invocation uses `gc session new` (interactive `claude`, subscription-billed):

```bash
# Approximate shape — actual shim implementation TBD during fo-h8o87.1.8 rework.
gc session new --pool implementer --system-prompt "$(gc prime implementer)" \
    -- "<task: loop gc hook → bd update --claim → execute → bd close → gc runtime drain-ack>"
gc events --watch --filter 'kind=closed,bead=<step-c-id>' --wait-for=1
```

The shim model (per `validation-pack-design.md` § Shim architecture) lets the scenario driver call `shim_spawn implementer 1` and `shim_await <predicate>` without hard-coding `gc session new` / `gc events --watch`. An ntm shim would implement the same primitives via `ntm spawn` and ntm's event surface.

Substrate side is proven. Agent-execution side adds: (a) claude reads its routed beads via `gc hook`, (b) follows the bead descriptions to produce output, (c) closes with the right reason. (d) `gc runtime drain-ack` when the queue is empty. Any failure here will be in claude's tool-use loop, not in the substrate primitives this walkthrough verified.

## Substrate verdict

- bd init at build time → ✓ clean substrate per container
- Formula symlink → ✓ formula discovery
- `bd mol wisp` + formula `pour = true` → ✓ full DAG materialization, ephemeral phase (the right primitive for validation scenarios; pour stays for persistent multi-session work)
- `gc sling` → ✓ sets `gc.routed_to` but emits "invalid issue type: convoy" until `gc doctor --fix` runs (tracked as `fo-h8o87.1.11`). Validation-pack drivers use direct `bd update --set-metadata` instead.
- `bd ready --metadata-field` → ✓ pool-filtered ready
- Dep enforcement → ✓ strict order; auto-parent-close on cascade

## Driver implications

The first-draft scenario driver (`scenarios/01-prompt-chaining.sh`) uses `bd mol pour` plus `gc sling` and spawns the agent via `claude --print`. Two of those three choices are wrong against this verification:

1. **`bd mol pour` → switch to `bd mol wisp`** with the formula declaring `pour = true`. Wisp is the right semantic for ephemeral validation runs (no git audit needed); `pour = true` unblocks multi-bead materialization. Formula edit is in place (commit `edf2c20`).
2. **`gc sling` → switch to direct `bd update --set-metadata routed_to=implementer <id>`**. Sidesteps the convoy auto-create attempt (which needs `gc doctor --fix` to work) and keeps the routing-write orchestrator-agnostic for the shim model.
3. **`claude --print` → switch to `gc session new` (under the shim)**. Subscription-billed; exercises the gc orchestration path agents actually take in production.

All three are tracked in the `fo-h8o87.1.8` kickback notes for the driver rework.

## Cleanup notes

- The walkthrough left orphaned beads (`vp-wisp-7uw`, the pour molecule, etc.) in the running container. Container is ephemeral; recreate to reset.
- The `gc sling` "convoy" stderr noise stops being noise once `fo-h8o87.1.11` lands (`gc doctor --fix` in the Dockerfile registers `convoy` in `types.custom`). No `grep -v` workaround needed in the driver after that.
