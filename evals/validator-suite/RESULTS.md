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
| Naive fanout (broken impl) | **25.7** | 4850 | **0/10** | only ~11 of 20 visible tests collected per run — workers corrupted shared imports |
| **Orchworkers** | **99.5** | 12222 | **10/10** | **2× faster than ralph at same quality** |
| Ralph (goal-check loop) | 197.6 | 12485 | 10/10 | one-shot at iter 1 in all runs; slowest, correct |

## Headline finding

**Orchestrator-workers wins decisively on this case.** Half ralph's wall-clock for identical quality (100% pass). The merge step adds negligible token cost (12.2K vs 12.5K mean tokens out) but cuts wall-clock in half by parallelizing the implementation phase.

Naive fanout's 0/10 result needs honest framing: it's not "the fanout pattern fails" — my `eval-fanout.sh` is a broken-by-design implementation that does concurrent unsynchronized writes to a shared worktree, with no isolation and no merge. It happened to work on cancel-method (where pieces are truly file-isolated and there's no shared state to corrupt) but fails on validator-suite (where workers modify shared `base.py`, `registry.py`, and the `Reason` enum without coordination). The result demonstrates *what happens with shared-state concurrent writes*, not *what the Anthropic "sectioning" pattern does* (which requires either isolation OR merge).

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

## Reproducing

```sh
cd github/cwalv/gc-formulas
mkdir -p /tmp/eval-runs/vs-repro
python3 scripts/eval-driver.py --case validator-suite --pattern ralph       --n 10 --output-dir /tmp/eval-runs/vs-repro
python3 scripts/eval-driver.py --case validator-suite --pattern fanout      --n 10 --output-dir /tmp/eval-runs/vs-repro
python3 scripts/eval-driver.py --case validator-suite --pattern orchworkers --n 10 --output-dir /tmp/eval-runs/vs-repro
```

Approximately 35 min wall-clock for ralph N=10, 5 min for fanout, 18 min for orchworkers (or ~35 min total if run in parallel — ralph dominates). Token budget ~$20-25 at opus pricing.
