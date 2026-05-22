# cancel-method N=10 results

First plan-eval data point. Validates the M1 runner infrastructure end-to-end on a tier-1 case.

## Setup

- **Case:** `evals/cancel-method/` — add `cancel()` method to 5 sibling entity classes (User, Order, Subscription, Reservation, Membership). 10 baseline tests must keep passing; 15 visible tests added in `visible-tests/` are the success target.
- **Worker model:** `claude` CLI on the host (Claude Code default model, presumably sonnet 4.6 or similar — see `claude --version` if exact version needed).
- **Patterns evaluated:**
  - **ralph:** single `claude -p` invocation per run, one model turn does all 5 entities. *Note: this is "one-shot ralph" — no goal-check loop yet; see follow-ups.*
  - **fanout:** 5 parallel `claude -p` invocations per run, each scoped to one entity file. Host-side approximation; no validation-pack supervisor.
- **N:** 10 runs of each pattern.
- **Driver:** `scripts/eval-driver.py` runs reps serially within a pattern.

## Aggregate results

| Metric | Ralph | Fanout | Ratio (fanout/ralph) |
|---|---|---|---|
| **Median wall-clock (s)** | 83.55 | 28.85 | **0.345× — 2.9× speedup** |
| Mean tokens in | 25.6 | 51.8 | 2.02× |
| Mean tokens out | 4455.1 | 5327 | 1.20× |
| Visible pass rate (median) | 15/15 | 15/15 | identical |
| All-pass count (of 10) | 10 | 10 | identical |

## Interpretation

- **Wall-clock:** fan-out delivered the predicted ~3× speedup for N=5 independent pieces, in line with `docs/plan-evals.md` math (Ralph: N × T; Fan-out: T + planning + merge overhead, with planning ≈ 0 because the per-file decomposition is mechanical and merge ≈ 0 because the case has no integration step).
- **Quality:** no differentiation on this case. Both patterns one-shot it. Expected — `cancel-method` was designed for runner validation, not pattern-on-pattern comparison. Hidden tests would show whether fan-out's tighter per-worker context produces more consistent quality, but they weren't authored for this case.
- **Token cost:** fan-out spends ~2× input tokens (each of 5 workers reads the spec) and ~20% more output tokens. For a 2.9× wall-clock win, that's an obvious trade — ~$0.20 extra per run for 55s saved.
- **Operational confidence:** 100% pass rate at both patterns across all 10 runs. The runner infrastructure is solid; results are deterministic enough to draw conclusions.

## Calibration honesty

This case is too easy to differentiate orchestration patterns at the worker model's capability tier (claude default — sonnet-ish). Ralph one-shots it; fan-out one-shots each piece. Differentiation lives in WALL-CLOCK, not pass rate. **For pattern-on-quality differentiation, the next eval case needs to be at the worker model's edge** — see `docs/plan-evals.md` M2 for the path.

## Follow-ups surfaced by this run

1. **Ralph should be a goal-check loop, not one-shot.** Currently each ralph "run" is a single claude turn. For harder cases where one turn can't solve the task, real ralph would iterate (claude → check → retry on fail). The cancel-method case happens to fit in one turn, so this didn't matter here — but for the next eval case it will.
2. **Hidden tests not authored for this case.** Quality-axis signal requires them. If we want this case to also stress the quality dimension, add hidden tests for edge cases (idempotence, can't-cancel-already-cancelled, event timestamp, etc.).
3. **Token capture is reliable.** `claude --output-format json` exposes input + output tokens. No partial-coverage issues with the actual run.
4. **Worker model identification.** The runner doesn't capture which model the host's `claude` invocation defaulted to. Worth adding for reproducibility across model versions — needed for the regression-tracking dimension in `docs/plan-evals.md` M5.

## Reproducing

```sh
cd github/cwalv/gc-formulas
mkdir -p /tmp/eval-runs/<your-name>
python3 scripts/eval-driver.py --case cancel-method --pattern ralph --n 10 \
    --output-dir /tmp/eval-runs/<your-name>
python3 scripts/eval-driver.py --case cancel-method --pattern fanout --n 10 \
    --output-dir /tmp/eval-runs/<your-name>
```

Approximately 13 min wall-clock for ralph N=10 + ~5 min for fanout N=10 (or ~13 min in parallel). Real-token cost ~$5 total across both at sonnet pricing.
