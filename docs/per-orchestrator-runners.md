# Per-orchestrator runners — design

Design fragment for plan-evals milestone **C.2**: scope the `scripts/eval-gc.sh` and
`scripts/eval-ntm.sh` runners that re-execute the existing `evals/` cases through real
orchestration substrates (gc supervisor, ntm shim) instead of bare `claude -p` calls.

Sibling doc: [`plan-evals.md`](plan-evals.md) — see "Comparison axes" (orchestration-substrate
row) and "Milestones — C.2".

This bead (`fo-6i6mt.4`) is **scope only**. No code change to `validation-pack/` or
`scripts/` is in this bead's scope. The output is enough specification that a future
implementation bead has a bounded, unambiguous interface to refactor against.

---

## 1. What "validation-pack takes external eval cases" means concretely

Today the validation-pack is closed: each `scenarios/0N-*.sh` script hardcodes a
`task_description` / `task_a` / etc. into the `bd mol wisp <formula> --var ...`
invocation. The harness runs one scenario per container; `verify_bead_state.py` asserts
the final bead DAG against a `fixtures/<scenario>-expected.json` predicate the same
driver wrote.

For plan-evals' C.2 we need the **same orchestration machinery** (gc supervisor +
formulas + personas + shims, or the ntm equivalent) executing one of our `evals/<case>/`
cases (`spec.md` + `starting-state/` + `visible-tests/` + `hidden-tests/`), and the
**existing `scripts/eval-scorer.py`** asserting pass-rate against the case — *not* the
hermetic bead-DAG predicate.

The two predicate worlds (bead-DAG-shape vs. pytest-pass-rate) stay separate. C.2 does
not unify them; it just adds an *external eval case* mode alongside the existing hermetic
scenarios.

### Concrete shape

```
gc-formulas/
├── evals/
│   └── validator-suite/                                # unchanged
│       ├── spec.md
│       ├── starting-state/
│       ├── visible-tests/
│       ├── hidden-tests/
│       └── fanout.json                                  # already there
├── validation-pack/
│   ├── scenarios/
│   │   └── 08-eval-case.sh                              # NEW — generic external-case driver
│   ├── formulas/
│   │   └── eval-orchestrator-workers.formula.toml       # NEW — orch-workers, parameterised brief
│   └── ...
└── scripts/
    ├── eval-gc.sh                                       # NEW — wraps scenario 08 with SHIM=gc
    ├── eval-ntm.sh                                      # NEW — wraps scenario 08 with SHIM=ntm
    └── eval-scorer.py                                   # unchanged
```

### Hand-off path (host → container)

The container needs three things from the host per run:

1. **The case** (`evals/<id>/{spec.md, starting-state/, fanout.json}`) — bind-mounted
   read-only into a known path inside the container.
2. **The case identifier and chosen formula/pattern** — passed via env vars on
   `docker compose run`.
3. **A writable worktree** for the workers to edit — bind-mounted so the host scorer
   can read post-state.

Concretely:

```
host:                                  container:
evals/<case>/                  →  /home/agent/eval-case/         (ro)
<output-dir>/<run-id>/worktree →  /home/agent/eval-worktree/     (rw)

env: EVAL_CASE_ID=<id>
     EVAL_PATTERN=orchestrator-workers   # or sectioning, ralph, etc.
     EVAL_FANOUT_DIR=validators          # from fanout.json
     EVAL_FANOUT_EXCLUDE="base.py __init__.py registry.py"
```

The scenario driver (`scenarios/08-eval-case.sh`) reads `EVAL_*` env vars, copies
`/home/agent/eval-case/starting-state/` into `/home/agent/eval-worktree/`, builds the
formula brief by templating `${SPEC}` (the case's spec.md, slurped into a `--var`),
pours the appropriate `eval-*` formula, spawns agents via shim, awaits terminal, and
exits. No pytest runs inside the container.

### Where the scorer runs (host)

`scripts/eval-scorer.py` runs **on the host**, after the container exits. The container
mutates `/home/agent/eval-worktree/` (which is the same host directory as
`<output-dir>/<run-id>/worktree`), so on container exit the host sees the agents' edits.
The host then runs:

```bash
python3 scripts/eval-scorer.py \
    --case-path evals/<case>/ \
    --worktree  <output-dir>/<run-id>/worktree/
```

Output format is identical to the existing bare-bash runners (`visible_pass`,
`hidden_pass`, `existing_pass`, plus tokens, wall-clock, exit code).

**Rationale for host-side scoring:** the validation-pack image deliberately doesn't
include pytest, the Python test deps, or the case fixtures. Adding them would couple
the container's build to the eval corpus (rebuild the image whenever a case is added).
Scoring on the host keeps `scripts/eval-scorer.py` the single scoring path across all
runners (`eval-ralph.sh`, `eval-fanout.sh`, `eval-orchworkers.sh`, `eval-sectioning.sh`,
`eval-gc.sh`, `eval-ntm.sh`) — same scorer means cross-substrate comparisons are
apples-to-apples.

### Result extraction

Per-run JSON is assembled by `eval-gc.sh` / `eval-ntm.sh` (host) by combining:

- **Wall-clock**: measured around the `docker compose run` call (host).
- **Worker tokens**: not directly available from gc/ntm today; the supervisor/shim
  emits per-session activity but not aggregated token counts. Two options for the
  first cut: (a) accept `tokens_in=tokens_out=0` and add a `token_coverage:
  "unavailable (substrate)"` flag; (b) post-process Claude Code's per-session JSONL
  under `~/.claude/projects/` (already captured to `debug-artifacts/` on failure;
  would need to be captured unconditionally for this flow). Recommend (a) for the
  first pass and (b) as a follow-up bead.
- **Pass/fail counts**: from `eval-scorer.py` (host).
- **Substrate metadata**: `pattern`, `substrate` ("gc" | "ntm"), `formula`,
  `worker_model` (from city.toml's `[agent.option_defaults] model` for gc, or
  `personas.toml` for ntm).

JSON schema additions (over `eval-orchworkers.sh`'s output):

```jsonc
{
  ...,
  "substrate": "gc",                 // NEW
  "formula":   "eval-orchestrator-workers",
  "_meta": {
    "approach": "validation-pack scenario via gc shim",
    "container_image": "validation-pack:latest",
    "token_coverage": "unavailable (substrate)"
  }
}
```

---

## 2. Minimal refactor scope (validation-pack)

The smallest set of files that have to change in `validation-pack/`. Order is rough
implementation order, not dependency order.

| File | Change | Why |
|---|---|---|
| `scenarios/08-eval-case.sh` | **NEW**. Generic driver: reads `EVAL_*` env vars, copies starting-state into the worktree, pours the right formula, spawns shim agents, awaits, exits. | Replaces the per-pattern hardcoded `0N-*.sh` drivers for external-case runs. |
| `formulas/eval-orchestrator-workers.formula.toml` | **NEW**. Variant of `orchestrator-workers.formula.toml` that templates `task_description` from a `${SPEC_CONTENT}` var AND a `${WORKTREE_PATH}` var. Subtask count parameterised (see blockers — current formula hard-codes 2). | The hermetic formula's two-subtask shape doesn't fit "modify N files in `validators/`". |
| `formulas/eval-sectioning.formula.toml` | **NEW**. Parameterised over `slice_count = N` (number of files in the fanout target) and per-slice brief templates. | For the sectioning baseline comparison. |
| `docker-compose.yml` | Add `eval-case` volume mounts (case ro, worktree rw) under env var control (`EVAL_CASE_DIR`, `EVAL_WORKTREE_DIR`). | Hand-off path. Keep existing single-scenario mounts intact. |
| `docker-compose.ntm.yml` | Same volume additions as above. | ntm shim parity. |
| `scripts/entrypoint-gc.sh` | If `EVAL_CASE_ID` is set, exec `08-eval-case.sh` instead of the named scenario. Otherwise unchanged. | Backward compat with hermetic scenarios. |
| `scripts/entrypoint-ntm.sh` | Same. | ntm parity. |
| `scripts/run-scenario.sh` | Skip the `verify_bead_state.py` call when `EVAL_CASE_ID` is set. Skip the bead-state dump too (it's noise — the worktree is the artifact). | The bead-DAG predicate doesn't apply; scoring is host-side. |
| `personas/implementer.md` | One-line tweak: when a bead description says "edit file X in worktree", treat the worktree as the work area (no bd notes assertion). Today the persona says "produce a concrete answer/artifact in bd comments" which is wrong for file-edit work. | Implementer lifecycle currently encodes "answer lives in bd comments"; for eval cases the answer is in `/home/agent/eval-worktree/` file edits. |

### Interface change (concise)

**Entrypoint env contract (new):**

```
EVAL_CASE_ID         required if external-eval mode. Mounts /home/agent/eval-case/.
EVAL_PATTERN         one of: orchestrator-workers, sectioning, agent-loop.
EVAL_FANOUT_DIR      from <case>/fanout.json#dir. Becomes a formula --var.
EVAL_FANOUT_EXCLUDE  space-separated, from <case>/fanout.json#exclude.
EVAL_TIMEOUT_SECS    optional; default 2000s (matches scenario 05).
```

**Formula contract (new):**

The eval-* formulas take additional vars:

```toml
[vars.spec_content]
description = "Full spec.md text the worker brief embeds."
required = true

[vars.worktree_path]
description = "Absolute container path the workers should edit files in."
required = true
default = "/home/agent/eval-worktree"

[vars.fanout_files]
description = "Newline-joined list of paths under worktree_path that should be edited."
required = true
```

The formula's step descriptions are rewritten to reference `{{worktree_path}}` and
`{{spec_content}}` instead of asking the worker to write a bd comment. Workers `cd
{{worktree_path}}` and edit files there.

### What does NOT change

- `personas/foreman.md`, `personas/treehugger.md`, `personas/evaluator.md` — the
  orchestration roles are unchanged; only the implementer's "where is the artifact"
  contract changes.
- `shims/gc.sh`, `shims/ntm.sh` — spawn/await/prime stay identical. The case-specific
  knowledge is in the formula, not the shim.
- `verify_bead_state.py` — unused in this code path; left in place for hermetic scenarios.
- Existing `scenarios/0[0-7]-*.sh` — untouched; they keep their hardcoded briefs for
  the hermetic-validation use case (claim 1 in `position.md`).

---

## 3. Shape of `scripts/eval-gc.sh` and `scripts/eval-ntm.sh` (schema-level pseudo-script)

Both scripts have the same shape; only the compose file and shim name differ. They
mirror `scripts/eval-orchworkers.sh`'s interface (positional `<case-id>`,
`--output-dir`, `--run-id`).

### eval-gc.sh

```bash
#!/usr/bin/env bash
# eval-gc.sh — run a case through the validation-pack container under gc shim.
set -euo pipefail
CASE_ID="$1"; shift                             # positional, required
# parse --output-dir, --run-id, --pattern (default: orchestrator-workers)

CASE_DIR="${REPO_ROOT}/evals/${CASE_ID}"
WORKTREE="${OUTPUT_DIR}/${RUN_ID}/worktree"
mkdir -p "${WORKTREE}" && cp -r "${CASE_DIR}/starting-state/." "${WORKTREE}/"

# Read fanout.json (host-side; container only sees env vars).
FANOUT_DIR="$(jq -r .dir    "${CASE_DIR}/fanout.json")"
FANOUT_EXC="$(jq -r '.exclude|join(" ")' "${CASE_DIR}/fanout.json")"

WALL_START=$(date +%s%3N)
docker compose -f validation-pack/docker-compose.yml -p "vp-${RUN_ID}" run --rm \
    -v "${CASE_DIR}:/home/agent/eval-case:ro" \
    -v "${WORKTREE}:/home/agent/eval-worktree" \
    -e EVAL_CASE_ID="${CASE_ID}" \
    -e EVAL_PATTERN="${PATTERN:-orchestrator-workers}" \
    -e EVAL_FANOUT_DIR="${FANOUT_DIR}" \
    -e EVAL_FANOUT_EXCLUDE="${FANOUT_EXC}" \
    validation 08-eval-case
WALL_SECS=$(( ( $(date +%s%3N) - WALL_START ) / 1000 ))

SCORER_JSON=$(python3 scripts/eval-scorer.py --case-path "${CASE_DIR}" --worktree "${WORKTREE}")
emit_result_json "$RUN_ID" gc "$PATTERN" "$WALL_SECS" "$SCORER_JSON" > "${OUTPUT_DIR}/results-${RUN_ID}.json"
```

### eval-ntm.sh

Identical except:

```bash
docker compose -f validation-pack/docker-compose.ntm.yml -p "vp-${RUN_ID}" run --rm \
    ... \
    validation 08-eval-case
# substrate field in result JSON = "ntm".
```

Two differences from `eval-orchworkers.sh`:

1. **No host-side `claude -p` calls.** Workers spawn inside the container under the
   shim; the host just bind-mounts the case + worktree and waits for the container
   to exit.
2. **No token aggregation in the host script.** As noted in §1, first cut emits
   `tokens_in=tokens_out=0` with a coverage flag; follow-up bead adds per-session
   JSONL aggregation.

---

## 4. Blockers — assumptions in validation-pack that don't generalise

These are the concrete dependencies in the current code that the refactor has to break,
plus pre-existing bugs that will surface under the new load shape. Listed roughly in
order of how blocking they are.

### 4.1 Hardcoded subtask count (formula-level)

`formulas/orchestrator-workers.formula.toml` declares exactly two `step-implement-*`
beads (lines 116-232). The eval cases need N from `fanout.json`: cancel-method has
5 entities, validator-suite has 7. **Cannot reuse the existing formula** — formulas
in `bd mol` are static TOML, not runtime-expanded.

**Mitigation:** the new `eval-orchestrator-workers.formula.toml` either (a) declares
the max-N case (e.g. 10 implementer steps), and the driver routes only the first N to
the implementer pool — extra beads stay open and the verifier ignores them; or (b)
treats the implementer step as a single bd bead and the implementer claims it,
fans out internally via N parallel sub-shells. Option (a) is more substrate-honest
(each file becomes its own bead, parallel-claimable); option (b) is simpler but
loses the substrate's parallel-claim mechanic.

**Recommendation:** option (a) with N up to a reasonable ceiling (10). Cases with
more files than the ceiling are excluded from C.2 and surface as a follow-up bead.

### 4.2 Implementer persona's "answer in bd comment" assumption

`personas/implementer.md` steps 5 + 6 expect the work product to live in a bd
comment. For file-edit work the answer is in the worktree filesystem; the bd
comment should just say "done; edited X.py" as a closing signal. **Persona prompt
needs a one-line tweak.** Not a blocker for the refactor mechanics, but evals
won't pass with the current prompt because the implementer will lean toward typing
code into comments.

### 4.3 gc supervisor startup-timeout (60s default)

`Dockerfile:129-148` documents the gc session-start 60s timeout that kills sessions
on initial-turn SSE if the Claude welcome screen takes too long. The workaround
(`hasCompletedOnboarding` + pre-trust 7 scenario paths) is keyed on the *seven hermetic
scenario session paths*. The new `08-eval-case.sh` will use a single session-path
template (e.g. `vp-eval-<case-id>`); pre-trust list needs to be extended OR generated
at runtime from `EVAL_CASE_ID`.

**Not a separate bug** — but the Dockerfile's pre-trust list is the kind of static
data that breaks silently when the session-path scheme changes. **Implementation bead
needs to either:** (a) update Dockerfile's pre-trust loop to include `vp-eval-<all
known cases>`, OR (b) move the pre-trust generation into `entrypoint-gc.sh` so it
runs at container start with knowledge of `EVAL_CASE_ID`. Option (b) is cleaner.

### 4.4 dolt sql-server contention under parallel load (CARRY-OVER, NOT NEW)

`Dockerfile:33-37` notes the lost-update race in bd v1.0.4 that forced the pin to
v1.0.3. For C.2's load shape — 5+ implementer workers all hitting bd concurrently —
this is the **scaling axis** the existing pin protects against. Verify with a smoke
test (run validator-suite case under gc shim N=5 implementers) before declaring
v1.0.3 sufficient at this scale. If contention surfaces at higher fan-out widths,
that's its own bead.

**Recommendation:** include a single-iteration smoke run in the implementation bead's
acceptance criteria. If it fails on contention, file a follow-up bead and gate C.2's
N=10 stats on it.

### 4.5 Hermetic-scenario predicate orthogonality

`run-scenario.sh:43-46` unconditionally runs `verify_bead_state.py`. The eval-case
mode has no fixture predicate; the verifier will fail to find
`fixtures/08-eval-case-expected.json` and exit non-zero. The wrapper currently treats
that as "scenario failed". **Fix:** the run-scenario.sh skip-verifier-when-EVAL-mode
change listed in §2 above.

### 4.6 Container worker model

`city.toml` sets `model = "haiku"` for the implementer pool (with rationale: the
hermetic scenarios were calibrated for haiku and sonnet/opus over-investigates).
The plan-evals corpus is currently calibrated at **opus-4-7's** edge
(`plan-evals.md:93`). **Two reasonable choices:** (a) keep the haiku default and
report that gc-shim runs are haiku-shaped — that's its own data point ("does
orchestration close the capability gap for haiku workers?", which is the original
M3 framing); (b) override the model via formula var or override file per run.

**Recommendation:** (a) for the first cut — exposes the haiku-shape comparison that
`plan-evals.md` cites as aspirational. Add a `--worker-model` flag in a follow-up
bead if (a) shows orch-substrates uniformly fail at haiku.

### 4.7 dog persona's bd-write traffic

`scripts/entrypoint-gc.sh:40` suspends the `dog` persona because its concurrent
bd writes corrupted the substrate. **No new work needed here** — keep the suspension.
Note it so the implementation bead doesn't accidentally re-enable dog.

### 4.8 Token-count gap (already discussed)

See §1. Not a hard blocker — the implementation bead can ship with
`token_coverage: unavailable`. Aggregating Claude Code's per-session JSONL is a
**separate follow-up bead** (call it C.2.1).

---

## 5. T-shirt size estimate

**M (medium).**

The mechanical work is bounded: one new scenario script (modelled on
`scenarios/05-orchestrator-workers.sh`), two new formulas, env-var plumbing through
two compose files and two entrypoints, host-side wrapper scripts that follow
`eval-orchworkers.sh`'s template. None of that is hard.

What pushes it past S:

- The N-implementer formula synthesis (§4.1) requires a real design decision
  (option a vs b) that propagates through the formula contract.
- The implementer persona's "where does the artifact live" contract (§4.2) is a
  semantic change to a prompt that downstream eval correctness depends on.
- The session-path scheme + pre-trust list (§4.3) is fiddly Dockerfile/entrypoint
  surgery with quiet failure modes.
- A smoke test under realistic parallel load (§4.4) is required acceptance.
- Two substrates (gc + ntm) doubles the integration-test matrix.

What keeps it from L/XL:

- The scorer is unchanged.
- The shim layer is unchanged.
- The existing hermetic scenarios stay completely untouched (no regression risk).
- The case format (`evals/<id>/`) is unchanged.
- The 7 known issues in §4 are each individually small; none requires architectural
  rework.

**Implementation bead should be scoped to:** one case (validator-suite, since it
exercises both fan-out and shared-state reconciliation), one pattern
(orchestrator-workers), one shim (gc), N=1 smoke. Sectioning, ntm shim, cancel-method,
and N=10 stats are follow-up beads once the substrate-mode runner shape proves out.
