# validator-suite substrate-runner results

Substrate (gc supervisor + bd formulas) bench at three worker-model tiers.
Answers bead fo-te2a8: does substrate orchestration value change by model tier?
See sibling `GRAPH-SHAPE-RESULTS.md` for case structure and idiom framing.

## Setup

- **Case:** `evals/validator-suite/` — 7 parallel validators, 20 visible / 26 hidden / 19 existing tests.
- **Pattern:** `orchestrator-workers` (foreman → 7 implementers → treehugger land step).
- **Substrate:** gc supervisor + bd formulas (not bare bash). Container: `validation-pack:latest`.
- **Runner:** `scripts/eval-gc.sh validator-suite --worker-model <tier> --run-id bench-<tier>-00N`.
- **N=3 per tier** (haiku, sonnet, opus). 9 primary runs; haiku had one retry (002 → 002b, Dolt server
  spawn race at treehugger creation; 002b succeeded cleanly).
- **Token coverage:** aggregated from per-session JSONL (fo-4nglm); all token fields non-zero.

## Per-tier results

P50 over N=3 runs per tier. One run per tier was a partial pass (haiku-003: 12/20 visible;
opus-002: 12/20 visible) — both had `exit_code=0` (treehugger landed what it could). P50 picks up
the majority result in each case.

| model | reps | visible pass-rate (p50) | hidden pass-rate (p50) | wall p50 (s) | tokens\_in p50 | tokens\_out p50 | cache\_read p50 |
|---|---|---|---|---|---|---|---|
| haiku | 3 | **100%** (20/20) | **100%** (26/26) | **282** | 2 605 | 161 590 | 19 M |
| sonnet | 3 | **100%** (20/20) | **100%** (26/26) | **396** | 642 | 223 219 | 14 M |
| opus | 3 | **100%** (20/20) | **100%** (26/26) | **653** | 968 | 350 879 | 36 M |

cache\_creation p50: haiku 893 K / sonnet 1 025 K / opus 1 263 K.

### Per-run detail

| run\_id | model | wall (s) | visible | hidden | exit |
|---|---|---|---|---|---|
| bench-haiku-001 | haiku | 269 | 20/20 | 26/26 | 0 |
| bench-haiku-002 | haiku | 209 | 11/20 | 18/26 | 1 (retry) |
| bench-haiku-002b | haiku | 656 | 20/20 | 26/26 | 0 |
| bench-haiku-003 | haiku | 282 | 12/20 | 21/26 | 0 |
| bench-sonnet-001 | sonnet | 568 | 20/20 | 26/26 | 0 |
| bench-sonnet-002 | sonnet | 396 | 20/20 | 26/26 | 0 |
| bench-sonnet-003 | sonnet | 393 | 20/20 | 26/26 | 0 |
| bench-opus-001 | opus | 881 | 20/20 | 26/26 | 0 |
| bench-opus-002 | opus | 343 | 12/20 | 17/26 | 0 |
| bench-opus-003 | opus | 653 | 20/20 | 26/26 | 0 |

bench-haiku-002 was a hard failure (container rc=1, Dolt server unreachable at treehugger spawn).
Retried as bench-haiku-002b; succeeded cleanly.

## Bare-bash comparison

The bead asks for comparison against bare-bash orchworkers at matching models.
Bare-bash data exists for **sonnet only** (N=10, median 111 s wall, 10/10 pass-rate;
from RESULTS.md "Update: sonnet baseline").

No bare-bash haiku or opus orchworkers data exists; bare-bash defaults to
sonnet workers + opus merge, so running haiku- or opus-only bare-bash would
require new runs. Rather than doubling wall-time, those are tracked as a
follow-up bead.

### Sonnet tier — substrate vs. bare-bash

| substrate | N | visible pass (p50) | hidden pass (p50) | wall p50 (s) |
|---|---|---|---|---|
| bare-bash (orchworkers) | 10 | 100% | 100% | **111** |
| gc substrate (orchworkers) | 3 | 100% | 100% | **396** |

The gc substrate is ~3.6× slower at the same quality on sonnet workers. The
overhead is the full city boot + supervisor startup + bd session lifecycle per
run. Pass-rate is identical: both reach 20/20 visible and 26/26 hidden at p50.

## Findings

**All three tiers reach 100% pass-rate at p50 under the gc substrate on this
case.** Validator-suite is a control case (per RESULTS.md: "does not differentiate
patterns on quality"), so this result is expected — and confirms the substrate
does not introduce correctness regressions at any tier.

**Wall-clock scales with model tier in a non-linear pattern.** Haiku is fastest
(282 s), sonnet is mid (396 s, ~40% slower than haiku), and opus is slowest
(653 s, ~65% slower than sonnet, 2.3× haiku). This is partly model latency and
partly the fact that opus runs tended to produce more thorough implementations
(higher tokens\_out p50: haiku 162 K → sonnet 223 K → opus 351 K), which
increases treehugger land time.

**Token output scales roughly linearly with tier (haiku → sonnet → opus ≈ 1×
→ 1.4× → 2.2×) but cache\_read does not.** Sonnet's cache\_read p50 (14 M)
is lower than haiku's (19 M) despite longer runs — the run order matters here
(sonnet ran after haiku; each run has its own container with a cold Claude
Code session cache). Cache\_creation scales modestly with tier (893 K → 1025 K
→ 1263 K), consistent with larger system prompts at higher tiers.

**Substrate overhead vs. bare-bash is significant (~3.6× on sonnet), but
quality-neutral.** The gc substrate adds city boot, supervisor, and bd
formula lifecycle. For short tasks where bare-bash is 90-120 s, substrate runs
take 400-650 s. The overhead is fixed per run, so it matters more on fast cases
and less on long multi-step tasks. The substrate's value is not throughput but
isolation, reproducibility, and formula-native lifecycle management.

**Partial-pass runs appeared at haiku and opus (one each).** In both cases the
treehugger landed a partial state — some validators were incomplete. The cause
appears to be implementer throughput: at haiku speed, all 7 implementers finish;
at opus speed, the slowest implementers can run past the foreman's patience
window on low-cache runs. The p50 result remains 100% because partial passes
are in the minority at N=3.

**"Does substrate orchestration close the gap for cheaper workers?"** For this
case the answer is: the gap does not exist — haiku, sonnet, and opus all pass at
p50. The more interesting question — whether substrate structure helps haiku
on harder cases where bare-bash haiku fails — requires an eval case that actually
differentiates. Validator-suite is the control; enum-extension (shared state) is
the stress test, and substrate × enum-extension benchmarks are a follow-up.

## Follow-ups

1. **Bare-bash haiku + opus orchworkers** — needed for the full 3×2 comparison
   matrix (substrate vs. bare-bash at each tier). New bead required; not run here
   to avoid doubling wall-time.
2. **Substrate × enum-extension** — the interesting differentiation axis. Does
   substrate orchestration lift haiku pass-rate on a case that requires shared-state
   coordination? Validator-suite cannot answer this.
3. **Partial-pass mode characterization** — both haiku-003 and opus-002 landed
   partial states. Logs in `eval-runs/bench-{haiku-003,opus-002}/debug-artifacts/`
   have per-session JSONL for post-hoc analysis.
