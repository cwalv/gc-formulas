# Debuggability — plan / notes for the validation-pack

The full-scenario LLM iteration loop is too slow and too lossy as a debugging
surface. Two of today's bugs (bd#4082, `.children` vs `.dependents`) hid
behind 30+ minutes of LLM runs that could not disambiguate "substrate lost
the write" from "agent didn't perform the step" from "fixture predicate
mismatch". A manual 4-second walkthrough surfaced both. We need that
walkthrough mode to be a first-class capability of the rig, not an
ad-hoc thing I do in a sleep-entrypoint container.

This doc captures what the rig should grow. Not a binding spec — a
direction-of-travel + the moves I'd make first.

## Pain points (observed this session)

1. **`docker compose run --rm`** — container is destroyed the instant the
   scenario exits. Bead state, tmux pane content, log files, all gone.
   Can't inspect "what did the agent actually write".
2. **JSONL/dolt divergence after restart** — restarting the container
   to re-inspect bd state re-imports stale JSONL and wipes in-dolt
   writes. The visible state after restart isn't the state the
   verifier saw.
3. **Verifier output is line-noise** — `FAIL: bead notes do not contain 'bash'`
   doesn't say what the notes DO contain. Operator has to re-run with a
   different verifier or dig manually.
4. **Driver runs all steps end-to-end** — there's no way to say "do the
   setup, stop before spawning the agent, drop me a shell". Each
   iteration of debugging requires running the agent (slow + costly).
5. **`gc events` / `ntm activity` outputs aren't correlated** — observing
   agent behavior means tailing tmux panes and bd state simultaneously,
   manually.

## What's already there (today)

- [x] **Run-scenario debug dump** (`scripts/run-scenario.sh` post-verifier) —
  iterates every bead referenced in the fixture, prints status / reason /
  assignee / metadata / notes to stderr. Lands in `docker logs` so it
  survives the container exit. Toggle off with `DEBUG_DUMP_BEADS=0`.
  This is the minimal "what did the agent actually do" probe. Just
  landed in this session.
- [x] **Failure-artifact capture** (`scripts/run-scenario.sh`) — on any
  failure, snapshots agent session logs, tmux pane scrollback, bd JSONL +
  dolt export, and the predicate fixture into a timestamped directory under
  `debug-artifacts/` (host-mounted). Captured before the `--rm` container
  exits so the state survives.
- **Manual debug container pattern** — `docker run -d --entrypoint sleep
  validation-pack:latest 3600`, then `docker exec` to step through.
  Useful but ad-hoc; surfaced today's bugs.

## Proposed additions, smallest first

### Tier 1 — cheap, useful immediately

- [ ] **Container preservation flag** — `DEBUG_KEEP_CONTAINER=1` skips
  `docker compose run --rm`, keeps the container around. Operator
  inspects with `docker exec` and `docker stop` when done. One-line
  change to a wrapper script in `scripts/`.

  **Out of scope for in-container implementation.** `DEBUG_KEEP_CONTAINER`
  must live in a *host-side* wrapper script that decides whether to pass
  `--rm` to `docker compose run`. The container itself has no way to
  suppress its own removal — that flag is set by the compose invocation
  before the container starts. A host wrapper is a separate deliverable
  outside the container boundary. Skipped for now; the checkpoint mechanism
  below (Tier 1b) achieves the same interactive-inspection goal without
  needing container preservation.

- [x] **`DEBUG_PAUSE_AT` checkpoint mechanism** — `scripts/checkpoint.sh`
  (sourced by drivers) + `checkpoint <name>` calls added to
  `scenarios/07-agent-loop.sh` (proof-of-concept) and the `verify`
  checkpoint wired into `scripts/run-scenario.sh`. Supported checkpoints:
  `pour`, `route`, `spawn`, `close`, `verify`. Set
  `DEBUG_PAUSE_AT=pour,spawn` (comma-separated) to pause at multiple points.
  Each pause sleeps 7200s and prints an inspect + unblock hint. Unblock
  with `docker exec <c> pkill -f "sleep 7200"`.

- [x] **`scripts/inspect.sh`** — one-shot in-container snapshot:
  all bd wisps (id, status, close_reason, assignee, comment_count via
  `bd list --json`; fallback to `bd show <id>` for fixture-referenced
  beads); gc supervisor status + active sessions; tmux session list with
  last 5 pane lines; JSONL line count + TRUE/FALSE dolt-vs-JSONL match.
  Run via `docker exec <container> /home/agent/validation-pack/scripts/inspect.sh`.
  Idempotent (read-only), target < 2 s.

### Tier 2 — moderate effort, big leverage

- **Manual driver mode** — refactor each scenario driver so its steps
  are named bash functions (`scenario02_pour`, `scenario02_route`,
  `scenario02_spawn_foreman`, `scenario02_await`, `scenario02_verify`).
  The current end-to-end script is just `main()` calling them in order.
  Add a `--step <name>` flag that runs ONE step and exits. Operator
  can drive the scenario step-by-step with `docker exec` to inspect
  between.

- **Failure-mode classifier in the verifier** — when an assertion fails,
  print a quick diagnosis: did the bead get claimed? closed? are notes
  empty entirely, or non-empty-but-mismatched? Each class points at a
  different root cause (substrate / persona / fixture / model). Cuts
  the "what failed?" question by 80%.

- **Predicate-of-predicates** — verifier supports a `manual_check` kind
  that records a substring of the actual value alongside the assertion
  fail line. e.g. `FAIL: bead X notes do not contain 'bash' — actual:
  'computed sha256 a3f4..., counted 26 lines'`. Tier 1's bead dump
  achieves this for full state; this is the surgical variant.

### Tier 3 — bigger investment, biggest payoff

- **Substrate replay** — record every `bd update` invocation during a
  scenario run (one line of `bash -x` or a bd subprocess wrapper). On
  failure, replay against a fresh bd to confirm the substrate is the
  variable (or rule it out).

- [x] **No-LLM smoke mode** — each scenario has a "fake worker" path that
  scripts the exact bd operations a passing agent would perform (claim,
  set metadata, append notes, close). Run it pre-flight on every
  scenario. If the fake-worker version fails, the issue is rig-side,
  not LLM-side. This is the manual-walkthrough pattern, formalised.
  Note: validation-pack-design.md already references a planned "fake
  mode"; the bug fo-kdsaw blocked it earlier. Worth unblocking.

  **Proof-of-concept landed (fo-geqsj):** scenario 07 has `scenario07_fake_worker()`
  which performs `bd update <id> --claim`, `bd comment <id> "ran: bash ..."`, and
  `bd close <id> --reason completed`. Enable via:
  `SCENARIO_MODE=fake bash scenarios/07-agent-loop.sh`
  The verifier runs unchanged against the fake-worker output. Also accessible
  step-by-step: `bash scenarios/07-agent-loop.sh --step fake_worker`.

- **Single-bead microscope mode** — a 30-second scenario that wisps ONE
  trivial bead, pre-routes it, spawns one agent, and asserts the agent
  did the work. Faster than scenario 07 (currently ~40-95s) for
  re-validating shim/persona/Dockerfile changes. The current scenarios
  are all "exercise an Anthropic catalog pattern end-to-end"; a
  microscope scenario serves the orthogonal goal of "validate the rig
  itself".

## Direction-of-travel principle

Keep the LLM-in-the-loop scenarios as the **outer** test — they validate
end-to-end correctness. Add the manual / fake / single-step tools as the
**inner** loop — they exist so a treehugger / operator can iterate at
seconds-not-minutes when something is broken. The two should share the
same scenario drivers and substrate; the difference is just "does the
agent step run, or does a deterministic stand-in run".

## What I'd land first if continuing

1. Tier 1 container-preservation flag (5 min).
2. Tier 2 manual driver mode for scenario 02 + 07 (an afternoon's
   refactor; biggest leverage). Convert scenarios to "step-named bash
   functions" + a CLI driver.
3. Tier 2 failure classifier in the verifier (~1 day).
4. Tier 3 fake-worker for scenario 07 (proof-of-concept of the no-LLM
   smoke mode).

The bead dump in `run-scenario.sh` (just landed) is Tier 0 — the smallest
useful step. Future work files against this doc.
