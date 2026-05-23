# enum-extension results

The case the bench was supposed to have. Authored after the validator-suite calibration finding — that the `Reason` enum was pre-stocked and so workers never actually had to extend shared state. `enum-extension` forces extension: `ErrorCode` and `ERROR_REGISTRY` are both empty in the starting state, and workers can only modify their own per-class file.

## Case shape

- 6 sibling error classes: `NotFoundError`, `UnauthorizedError`, `ConflictError`, `RateLimitError`, `TimeoutError`, `ValidationError`.
- Shared state in `errors/codes.py` (only `UNKNOWN = 0` sentinel) and `errors/registry.py` (empty `ERROR_REGISTRY: dict = {}` + `register()` helper). Both files are in `fanout.json`'s `exclude` list.
- `errors/__init__.py` imports each class by name — so workers that rename their class break the package's import path.
- Each worker must (1) add a variant to `ErrorCode`, (2) register itself in `ERROR_REGISTRY`, (3) implement the class extending `BaseError`. Only patterns where some agent has cross-file authority can satisfy (1) and (2).
- 6 baseline tests (BaseError abstract class) + 20 visible tests + 31 hidden tests.

## Setup

- **Worker model:** `claude-sonnet-4-6` (pinned via `WORKER_MODEL` in `scripts/eval-config.sh`).
- **Planner / merge-step model:** `claude-opus-4-7` (pinned via `PLANNER_MODEL`).
- **N:** 10 per pattern, except orchworkers which was killed at N=5 to preserve session quota (already 5/5 perfect).
- **Output dir:** `/tmp/eval-runs/sonnet-baseline/`.

## Results (sonnet workers)

| Pattern | N | All-pass | Median wall | Mean tokens out | Failure mode |
|---|---|---|---|---|---|
| **Ralph** | 10 | **10/10** | 81.2s | 4,018 | — |
| **Orchworkers** | 5 | **5/5** | ~376s | ~14k | — |
| Sectioning | 10 | 3/10 | 216.2s | 36,960 | Workers reference variants others added (or attempted); pytest collection often fails on missing-import |
| Naive fanout | 10 | 2/10 | 281.4s | 54,192 | Same import-fail mode plus shared-worktree write races |

### Per-rep detail

**Sectioning (10 reps):**
- 3 reps: 20/20 visible + 31/31 hidden (full pass — workers landed on consistent names)
- 1 rep: 20/20 visible + 0/2 hidden (workers individually correct, cross-file invariants broken — this is the "individually correct but don't fit together" failure mode the bead predicted)
- 6 reps: 0/1 visible + 0/1 hidden (pytest collection failed — `from .codes import ErrorCode.X` where X doesn't exist in codes.py)

**Naive fanout (10 reps):**
- 1 rep: 20/20 + 31/31 (full pass, by luck)
- 1 rep: 20/20 + 0/2 (cross-file broken)
- 8 reps: 0/1 + 0/1 (collection fail)

## Headline finding

**Patterns differentiate sharply on this case.** Ralph and orchworkers reach 100%; sectioning and naive fanout fail most of the time. The differentiator is whether some agent has authority over the shared files (`codes.py`, `registry.py`):

- **Ralph** is single-agent; it owns everything sequentially. It extends `codes.py` and `registry.py` as part of its work.
- **Orchworkers** has the merge step — an LLM reads the full worktree after workers finish and reconciles shared files. The merge step is the load-bearing differentiator vs sectioning.
- **Sectioning** has per-worker isolation (each worker gets a fresh starting-state copy), but the deterministic collator only copies each worker's own file — extensions to shared files are discarded. Sometimes workers happen to pick consistent enum names AND the collated final state happens to compile, but most of the time imports fail.
- **Naive fanout** has neither isolation nor merge. Workers either obey the brief (don't touch shared files → imports fail) or violate it (race-write shared files → garbage).

## Token cost surprise

Ralph is the **cheapest** by a wide margin (~4k tokens out vs orchworkers' ~14k vs sectioning's ~37k vs fanout's ~54k). The failure modes are token-expensive: sectioning/fanout workers retry, explore, and write speculative code when their imports won't resolve. Ralph's single sequential pass produces less waste even though it's wall-clock slower.

This inverts the naive "parallel = cheaper" intuition. **When the task fits the worker's context window, single-agent ralph is the cheap baseline; parallel patterns earn their keep only on wall-clock, and only on shapes that don't force cross-file reconciliation.**

## Calibration

This case worked as the bench needed:
- Ralph one-shotted it (10/10) — confirms sonnet is strong enough to solve the task. Not the haiku regime where workers can't produce coherent attempts.
- Naive fanout and sectioning failed most of the time — confirms the case actually stresses shared-state coordination. Not the opus regime where everything one-shots.
- Orchworkers succeeded fully — confirms the merge step does meaningful work.

Sonnet at the operationally-relevant Goldilocks tier; see `docs/plan-evals.md` "Calibration: why sonnet workers" for the framing.

## Reproducing

```sh
cd github/cwalv/gc-formulas
mkdir -p /tmp/eval-runs/<your-name>
python3 scripts/eval-driver.py --case enum-extension --pattern ralph       --n 10 --output-dir /tmp/eval-runs/<your-name>
python3 scripts/eval-driver.py --case enum-extension --pattern fanout      --n 10 --output-dir /tmp/eval-runs/<your-name>
python3 scripts/eval-driver.py --case enum-extension --pattern sectioning  --n 10 --output-dir /tmp/eval-runs/<your-name>
python3 scripts/eval-driver.py --case enum-extension --pattern orchworkers --n 10 --output-dir /tmp/eval-runs/<your-name>
```

Approximately 80 min wall-clock if run serially; ~30 min in parallel (dominated by ralph + orchworkers). Watch session quota — 5-hour windows fill up at this load.

## Follow-ups

1. **Hidden tests caught the cross-file failure mode in sectioning** (one rep had visible 20/20 + hidden 0/2). Validates the hidden-test investment.
2. **Token cost asymmetry between success and failure** is worth its own measurement axis — the workers array surfaces per-worker token spend, but the failure-mode-burns-tokens dynamic is currently visible only in aggregate.
3. **enum-extension is a small case (6 classes).** A larger variant ("enum-extension-wide" with 20+ classes) would test whether the orchworkers merge step scales — the merge call gets a worktree proportional to N to reconcile.
4. **Planner-routing N=10 on this case** would tell us whether the planner correctly picks orchworkers/ralph for shared-state cases (B's smoke showed default-to-orchworkers under opus planner; needs sonnet-planner re-run + library-driven variant from E1).
