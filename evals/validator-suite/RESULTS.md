# validator-suite N=10 results

Second plan-eval data point. Three patterns compared on a case designed at the worker model's edge (opus-4-7). 7 sibling validators (Email, Phone, CreditCard, IBAN, ISBN, Semver, URL) sharing a `Validator` ABC and `Reason` enum, glued together by `registry.py`. 20 visible tests + 26 hidden tests + 19 baseline tests.

## Setup

- **Case:** `evals/validator-suite/`. Authored by opus to be at opus's capability edge. Each validator has its own algorithm (Luhn, mod-97, mod-11, semver grammar, URL parsing) — pieces are NOT identical templates.
- **Worker model:** `claude-opus-4-7[1m]` (captured from the runner's `worker_model` field).
- **Patterns evaluated (N=10 each):** ralph (single-agent loop), naive fanout (7 parallel agents, no merge, no isolation), orchworkers (7 parallel agents + LLM merge step).
- **Orchestration substrate:** bare bash + direct `claude -p` calls (no gc, no ntm, no bd formulas in the loop). The current runners are baselines; per-orchestrator runners are a future axis (see `docs/plan-evals.md`).

## Results (N=10)

| Pattern | Median wall (s) | Mean tokens out | All-passed | Notes |
|---|---|---|---|---|
| Naive fanout (after brief fix, plan-evals A) | **72.2** | 13341 | **10/10** | brief bug was the entire previous failure; see below |
| Naive fanout (original 2026-05-12 run, broken brief) | 25.7 | 4850 | 0/10 | superseded — workers were told "add a cancel() method" on validator files |
| **Orchworkers** | **99.5** | 12222 | **10/10** | from the original 2026-05-12 run; not re-run under plan-evals A |
| Ralph (goal-check loop) | 197.6 | 12485 | 10/10 | one-shot at iter 1 in all runs; slowest, correct |

## Headline finding

**The 0/10 naive-fanout result was a brief bug, not a structural failure of the pattern.**
After the plan-evals A fix (`scripts/eval-fanout.sh` brief now reads from `spec.md` instead of hard-coding "add a cancel() method to ${ENTITY_REL}" plus an `event_bus.py` reference borrowed from the cancel-method case), N=10 naive fanout passes 10/10 visible AND 10/10 hidden AND 10/10 existing-tests on validator-suite. The previous "workers corrupted shared imports" narrative is overturned — none of the 10 reruns touched `base.py`; every worker stayed strictly within its assigned file. The structural-collapse story was real for the *broken brief* (workers given a nonsense task improvised in cross-cutting ways), but **does not hold under a coherent task-scoped brief**.

Wall-clock went from a (worthless) 25.7s median to a real 72.2s median, because workers are now actually doing the validator work. Token output went from 4850 → 13341 for the same reason. The honest comparison:

- **Naive fanout (fixed) vs orchworkers:** 72.2s vs 99.5s — naive fanout is ~27% faster on this case. The earlier "orch-workers wins decisively" claim was relative to a broken baseline and needs to be re-run with the new fanout numbers before drawing conclusions about merge-step value.
- **Naive fanout (fixed) vs ralph:** 72.2s vs 197.6s — fanout is 2.7× faster at identical quality (10/10).

## Implication for the planner

This still says **pattern choice matters**, but the matrix is different from what the 2026-05-12 run suggested. Naive fanout actually *can* solve a multi-file task with shared infrastructure (ABC, registry, enum) *as long as workers are told to stay in their assigned file*. The shared `base.py` and `Reason` enum are not implicitly corrupted by parallel workers; they're only corrupted if the brief invites improvisation.

What we don't yet know:
- Does naive fanout's win hold across other multi-file shared-state tasks, or is validator-suite "easy" because each validator's algorithm is genuinely independent (Luhn, mod-97, etc.) once the contract is in place?
- Does the orchworkers merge step add measurable value here, or is it overhead (extra 27s wall-clock, ~minus 1K tokens) for no quality gain?
- What's the boundary case where coordination *is* required and naive fanout fails for a structural reason rather than a brief reason?

These are the questions the next set of cases (plan-evals B/C/D) needs to surface.

## Pattern-task fit matrix (updated post plan-evals A)

| Pattern | cancel-method | validator-suite |
|---|---|---|
| Ralph | wins on quality (one-shot) | wins on quality (one-shot, slow) |
| Naive fanout | wins on wall-clock + quality tie | **wins on wall-clock + quality tie** (after brief fix) |
| Orchestrator-workers | should match fanout (no merge needed) | matches on quality; **adds ~27s vs naive fanout** for unclear gain on this case |

## Follow-ups surfaced (post plan-evals A)

1. **Re-run orchworkers with the same brief fix** to get an apples-to-apples comparison. The orchworkers brief is now task-generic (commit ae01123), but its N=10 numbers above are from the prior run. Worth verifying nothing changed at orchworkers's quality/wall-clock with the new brief.
2. **Validator-suite may no longer be the right "shared-state stress test."** It empirically doesn't stress shared state under a correct brief. plan-evals's pattern-fit ladder needs a case that *actually* requires worker coordination (cross-cutting interface changes that can't be done with per-file scope), or the matrix above is misleading.
3. **Hidden tests are now scored** (commit c2e7c7f) and naive fanout passes 26/26 in all 10 runs — same as visible. The pattern doesn't lose quality at the edges either.
4. **Per-worker token tracking added** (plan-evals A): each result JSON now includes a `workers: [{file, tokens_in, tokens_out}, ...]` array. Lets us verify claim 3 in `docs/position.md` (short worker contracts) by observing per-file input-token counts. The numbers from this re-run hold: per-worker `tokens_in` was 8-16 tokens across all workers (the spec text is what dominates; the wrapper brief is small).

## Representative per-worker tokens

One representative `workers` array from a passing run
(`results-fanout-validator-suite-20260522-183859-10.json`):

```json
[
  {"file": "credit_card.py", "tokens_in":  8, "tokens_out":  639},
  {"file": "email.py",       "tokens_in": 15, "tokens_out": 3084},
  {"file": "iban.py",        "tokens_in":  8, "tokens_out": 1271},
  {"file": "isbn.py",        "tokens_in":  8, "tokens_out": 1097},
  {"file": "phone.py",       "tokens_in":  8, "tokens_out": 1185},
  {"file": "semver.py",      "tokens_in":  8, "tokens_out": 1790},
  {"file": "url.py",         "tokens_in": 16, "tokens_out": 3827}
]
```

`tokens_in` here is the prompt cost *for the current model turn*, not including cache hits or the spec text bundled into the system prompt — so it's not a measure of contract length, just of incremental turn cost. The wider per-worker visibility is the additive value: we can now see per-file output-token spend and reason about which files are doing the most work.

**Update (fo-vgam1, 2026-05-23):** worker records now also include `cache_creation_input_tokens` + `cache_read_input_tokens`. Those numbers reflect the **full contract length** the worker actually saw (brief + cached system prompt + tool defs). On the sister `enum-extension` case under fanout/sonnet, per-worker `cache_creation` ranged 11K-29K tokens — vs per-turn `tokens_in` of 5-22. The per-turn field underrepresents the real contract by ~1000×. For `position.md` claim 3 ("worker contracts stay short"), the cache fields are the load-bearing measurement; the per-turn fields measure billing, not context volume.

## Reproducing

```sh
cd github/cwalv/gc-formulas
mkdir -p /tmp/eval-runs/vs-repro
python3 scripts/eval-driver.py --case validator-suite --pattern ralph       --n 10 --output-dir /tmp/eval-runs/vs-repro
python3 scripts/eval-driver.py --case validator-suite --pattern fanout      --n 10 --output-dir /tmp/eval-runs/vs-repro
python3 scripts/eval-driver.py --case validator-suite --pattern orchworkers --n 10 --output-dir /tmp/eval-runs/vs-repro
```

Approximately 35 min wall-clock for ralph N=10, 12 min for fanout (post-fix; was 5 min on the broken brief), 18 min for orchworkers (or ~35 min total if run in parallel — ralph dominates). Token budget ~$20-25 at opus pricing.

---

## Update: sonnet baseline (post worker-model switch)

After plan-evals A confirmed that the original 0/10 was a brief bug, the bench switched worker models from opus to sonnet (see `docs/plan-evals.md` "Calibration: why sonnet workers"). All four patterns were re-run on validator-suite with sonnet workers + opus planner/merge:

| Pattern | N | All-pass | Median wall (s) | Mean tokens out |
|---|---|---|---|---|
| Ralph | 3 (killed at N=3 to save quota) | 3/3 | ~382s | — |
| Naive fanout | 10 | 10/10 | 83.4s | 11364 |
| Sectioning | 10 | 10/10 | 83.0s | 11533 |
| Orchworkers | 10 | 10/10 | 111.3s | 13011 |

Reproducing the broader-bench finding: **validator-suite does not differentiate patterns** under sonnet either. All patterns reach 10/10; differentiation is on wall-clock only, and orchworkers' merge step is pure overhead (~34% slower than fanout, no quality benefit). Sectioning ≈ fanout because the case doesn't actually force shared-state extension (the `Reason` enum is pre-stocked).

This is **the right behavior for a control case**. Differentiation lives on `enum-extension` (see `../enum-extension/RESULTS.md`), which forces workers to extend shared `ErrorCode` + `ERROR_REGISTRY` that are not pre-stocked.

### What validator-suite is good for now

- Smoke / regression test that the runners + scorer work end-to-end.
- Wall-clock baseline: orchworkers' merge-step overhead is measurable here (~28s vs fanout).
- Calibration sanity: sonnet ≈ opus on this case (within 15%), so worker switch didn't break anything.

### What validator-suite is NOT good for

- Differentiating patterns on quality. (Use `enum-extension`.)
- Testing the orchworkers merge-step value. (The merge does no real reconciliation work here.)
- Stress-testing the planner's pattern selection. (All patterns succeed; "wrong" choice is just slow, not broken.)

