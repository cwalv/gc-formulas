# Debugging a failing scenario

Operational reference for the validation-pack's debuggability features.

## Run a scenario

```bash
cd validation-pack
docker compose -f docker-compose.yml -p vp-debug run --rm validation 07-agent-loop
```

Use `docker-compose.ntm.yml` for the ntm shim. Replace `07-agent-loop` with any scenario (`00-microscope` is the smallest single-bead scenario, useful as a rig sanity check).

## Fake-worker mode — fastest path, no LLM

Skip the LLM by setting `SCENARIO_MODE=fake`. Each scenario has a `scenarioN_fake_worker()` function that performs the deterministic bd ops a passing agent would; verifier passes against fake output unchanged.

```bash
docker compose -f docker-compose.ntm.yml -p vp-debug run --rm \
    -e SCENARIO_MODE=fake validation 07-agent-loop
```

Used for substrate/shim/persona regression checks without LLM cost. ~24s wall-clock for all 7 scenarios in parallel under ntm.

## Pause at a checkpoint

`DEBUG_PAUSE_AT=<checkpoint>` halts the driver at specific steps so you can `docker exec` in and inspect:

```bash
docker compose run --rm -e DEBUG_PAUSE_AT=spawn validation 07-agent-loop
```

Valid: `pour`, `route`, `spawn`, `close`, `verify`. Comma-separated for multiple. Each pause sleeps 7200s; unblock with:

```bash
docker exec <container> pkill -f "sleep 7200"
```

## Inspect a running container

```bash
docker exec <container> /home/agent/validation-pack/scripts/inspect.sh
```

One-shot snapshot: all bd wisps (status, reason, assignee, comment count), gc supervisor status, tmux session list with last 5 pane lines, JSONL vs dolt match check. Read-only, target < 2s.

## Failure-artifact capture

Set `DEBUG_ARTIFACTS=/path/to/host/dir` on the docker run:

```bash
DEBUG_ARTIFACTS=/tmp/vp-debug docker compose run --rm \
    -e DEBUG_PAUSE_AT=close validation 07-agent-loop
```

On scenario failure (or via the pause mechanism), the rig captures bd JSONL + dolt export, tmux pane scrollback, agent session logs, and the predicate fixture to a timestamped subdir under that path. Survives `--rm`.

## bd invocation tracing

Set `DEBUG_BD_RECORD=1` to record every bd command (args, rc, stdout excerpt) to `bd-trace.jsonl` in the debug-artifacts dir. Replay against a fresh substrate via:

```bash
scripts/replay-bd.sh <trace.jsonl>
```

Useful for "did this scenario's bd ops produce the same end-state in isolation as it did under supervisor load?"

## Bead state dump

Every scenario exits with a state dump of every bead referenced in its predicate fixture (`DEBUG_DUMP_BEADS=1`, default on). Lands in `docker logs` so it survives `--rm` even when bd is unreachable.

## Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `Error claiming X: issue already claimed by validation/Y` | `bd update --claim` fails on pool-assigned bead (bd v1.0.3 only claims null assignees) | Use `--status=in_progress` instead, or clear assignee first |
| `Dolt server unreachable at 127.0.0.1:0` | dolt sql-server died or never bound port | Check `gc supervisor logs`; may be dolt-startup contention under parallel load |
| Scenario hangs at `awaiting <bead> close` | Agent pane exited before completing iterative work | `tmux capture-pane`; iterate-handoff issues need poll-with-retry in persona |
| `notes do not contain '<marker>'` | `--notes` was overwritten by a later write | Use `bd comment` (append) instead; verifier predicate becomes `comments_contain` |
| `closed order mismatch: actual=[]` | Verifier read closed beads from `bd list` which excludes ephemerals | Already fixed via `bd show` fallback; if regressing, check `verify_bead_state.py:closed_in_order` |
| All 7 gc scenarios fail at `Adopting sessions` ~213s | dolt sql-server startup saturating under parallel load | Run serial or ≤3-parallel for gc shim |
| ntm session blocks at "Trust this folder?" | Spawned dir isn't in `.claude.json` trust list | Pre-trust the exact spawn dir (Claude trust is per-directory, not prefix) |

## When to file upstream

If the bug is in bd/gc/ntm itself, file there. Already filed:

- `gastownhall/beads#4082` — `--include-ephemeral --metadata-field` ignores the filter (worked around with `--assignee` routing).
- `Dicklesworthstone/ntm#158` — `ntm spawn --prompt` races with agent ready marker.

Existing-and-relevant: `gastownhall/beads#3948`, `#3964`, `#3822` — all worked around via `bd comment` + `export.auto=false` + JSONL removal.
