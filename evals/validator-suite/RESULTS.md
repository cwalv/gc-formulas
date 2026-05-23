# validator-suite N=1 smoke results

Second plan-eval data point. Designed at the worker model's edge (opus-4-7). 7 sibling validators (Email, Phone, CreditCard, IBAN, ISBN, Semver, URL) sharing a `Validator` ABC and `Reason` enum, glued together by a `registry.py`. 20 visible tests + 26 hidden tests + 19 baseline tests.

## Setup

- **Case:** `evals/validator-suite/`. Authored by opus to be at opus's capability edge. Each validator has its own algorithm (Luhn, mod-97, mod-11, semver grammar, URL parsing) — pieces are NOT identical templates.
- **Worker model:** `claude-opus-4-7[1m]` (captured from the runner's `worker_model` field).
- **Patterns evaluated:** ralph (single-agent loop), naive fanout (8 parallel agents, no merge).
- **N:** 1 each (smoke level — N=10 is the next step pending orchworkers landing).

## Results (N=1)

| Pattern | Wall-clock | Tokens out | Visible | Existing | Notes |
|---|---|---|---|---|---|
| **Ralph** | 212.3s | 10515 | **20/20** | 19/19 | one-shot success at iter 1 |
| **Naive fanout** | 32.4s | 7481 | **0/11** | 19/19 | only 11 of 20 visible tests collected — cross-piece imports broken |

## Headline finding

**The wrong pattern for the task produces broken results, not just slow results.**

Fan-out was 6.5× faster but produced output where only 11 of 20 visible tests could even be collected — workers modified shared modules (`base.py`, `registry.py`, the `Reason` enum) in incompatible ways that nobody reconciled. Ralph was slower but correct: 20/20 visible passing.

This is the empirical case for two related claims in `docs/position.md` and `docs/principles.md`:

- **Patterns aren't interchangeable.** Fan-out's wall-clock win on cancel-method (2.9× speedup, 100% quality) is *task-specific*. On validator-suite, fan-out's wall-clock win comes with a quality collapse.
- **A merge / reconciliation step is what makes orch-workers different from naive fanout.** Workers can't see each other's outputs; cross-cutting concerns need a final LLM call to reconcile. Our `eval-fanout.sh` is the degenerate "no merge" version. The validation-pack's scenario 05 has it right via the treehugger persona.

## Implication for the planner

Per `docs/position.md`'s claim about model-as-orchestrator: the planner has to *recognize when fan-out fits the task* before dispatching. Inputs to that decision:

- Are the pieces truly independent? (Looking at the starting-state structure — does the dir have shared modules like a registry or an ABC?)
- If pieces share state, does the task need orch-workers (with merge) instead of naive fanout?
- Or could the task structurally be inappropriate for fan-out at all, in which case ralph or eval-optimizer wins?

Hardcoding the pattern (as plan-evals M1 currently does) bypasses this decision. The natural next milestone is **pattern selection as an eval axis** — the planner is given the task + a menu of patterns and picks one; we score the choice.

## Pattern-task fit matrix (preliminary, based on these two cases)

| Pattern | cancel-method | validator-suite |
|---|---|---|
| Ralph | wins on quality (one-shot) | wins on quality (one-shot, slow) |
| Naive fanout | wins on wall-clock + quality tie | wins on wall-clock, **loses on quality** |
| Orchestrator-workers (TBD) | should match fanout (no merge needed) | should match ralph on quality, beat ralph on wall-clock |

## Follow-ups surfaced

1. **Naive fanout's failure mode is structural, not a bug.** Workers blind to each other can't maintain cross-cutting invariants. This is a property of the pattern, not the validator-suite case.
2. **Need `scripts/eval-orchworkers.sh`** with a merge step. In progress.
3. **`registry.py` should be excluded from validator-suite/fanout.json's worker list.** It's infrastructure, not a validator. Cosmetic fix; the empirical signal stands without it (the underlying mismatch is `base.py` + `Reason` enum).
4. **Pattern selection as a third eval axis.** Not just "given pattern X, how does it score?" but "given the task, which pattern should the planner choose?" — see Implication section.
5. **Hidden tests not scored yet.** The scorer doesn't run `hidden-tests/`. Once it does, we'd see whether ralph's one-shot misses hidden-test edge cases that orch-workers (with thoughtful per-worker context) might catch.

## Pending: N=10 + orchworkers

Once `eval-orchworkers.sh` lands, the full comparison run on validator-suite is:
- N=10 ralph (already validated; ~35 min wall-clock total)
- N=10 naive fanout (already validated; ~5 min)
- N=10 orchworkers (pending)

Token budget estimate: ~$20-25 total in opus tokens.

## Reproducing this smoke

```sh
cd github/cwalv/gc-formulas
mkdir -p /tmp/eval-runs/vs-repro
bash scripts/eval-ralph.sh   validator-suite --output-dir /tmp/eval-runs/vs-repro --run-id smoke-ralph
bash scripts/eval-fanout.sh  validator-suite --output-dir /tmp/eval-runs/vs-repro --run-id smoke-fanout
```

Approximately 4 min wall-clock for ralph + 1 min for fanout (or 4 min in parallel).
