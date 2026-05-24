# enum-extension-choreo smoke results

Choreographer eval, Phase C reactive graph-mutation. N=3 reps.
Design source: `docs/choreographer-eval.md` (commit 501ba17).

## Setup

- **Choreographer model**: `claude-sonnet-4-6` (per design fragment OQ2 default)
- **Workers**: deterministic (bash subshells, no LLM)
- **Case**: `evals/enum-extension-choreo/`
- **Runner**: `scripts/eval-choreographer.sh`
- **Host-driven loop**: mode b (one `claude -p` call per close event)
- **Events per run**: 7–8 (6 impl-* beads + design-codes, plus 1 spawned bead in successful reps)

## Per-rep results

| Rep | mutation_recall | mutation_precision | forbidden_violations | terminal_state_ok | visible_pass | hidden_pass |
|---|---|---|---|---|---|---|
| smoke-choreo-001 | **0.667** | 1.0 | 0 | true | 14/20 | 18/31 |
| smoke-choreo-002 | **1.0** | 1.0 | 0 | true | 14/20 | 18/31 |
| smoke-choreo-003 | **1.0** | 1.0 | 0 | true | 14/20 | 18/31 |

## Structurally sound threshold

`mutation_recall >= 0.66 AND forbidden_violations = 0 AND terminal_state_ok` — all 3 reps pass.

## Mutation decisions (representative — rep 002)

| Event | Close reason | Choreographer action | Correct? |
|---|---|---|---|
| design-codes | completed | noop | ✓ |
| impl-timeout | completed | noop | ✓ |
| impl-unauthorized | completed | noop | ✓ |
| impl-conflict | completed | noop | ✓ |
| impl-validation | out-of-scope (suggest: evaluator) | reassign → validation/evaluator | ✓ |
| impl-rate-limit | blocked / AMBIGUOUS-SPEC | human flag | ✓ |
| impl-not-found | revealed-additional-work | spawn "Add abstract method to BaseError" | ✓ |

## Observations

**Rep 001 miss (recall=0.667)**: on `impl-not-found` (revealed-additional-work + SPAWN comment), the
choreographer chose `human` instead of `spawn`. Looking at the choreographer's event 5 output, it appears
the comment was partially processed — it flagged `impl-rate-limit` for human review (the next pending event)
rather than spawning the revealed work for `impl-not-found`. This was a close call: the model saw
two pending events in the same batch and conflated the `AMBIGUOUS-SPEC` blocker from `impl-rate-limit`
with the `revealed-additional-work` from `impl-not-found`.

**Reps 002 and 003**: perfect scores (recall=1.0, precision=1.0, violations=0). The choreographer
correctly differentiated all four signal types across all events.

**Precision stays at 1.0 across all reps**: the choreographer never made a spurious spawn after a
`completed` close. This is the primary forbidden-mutation axis; it held perfectly.

**visible/hidden pass rates (14/20 visible, 18/31 hidden)**: these reflect the worktree after workers
applied file edits for completed beads only (impl-conflict, impl-timeout, impl-unauthorized, design-codes,
impl-not-found). `impl-rate-limit` and `impl-validation` were NOT implemented (they closed `blocked` and
`out-of-scope`), so tests requiring those classes are missing. This is expected — the choreographer eval
is measuring graph-mutation quality, not implementation completeness.

**Wall clock ~302s per rep**: each rep hits the 300s loop timeout because 7–8 sequential `claude -p`
calls at ~30s each ≈ 300s total. The runner exits cleanly (exit code 0). Tuning the timeout or
parallelizing choreographer invocations is a follow-up.

## Follow-up signals

1. **Batch-event conflation (rep 001)**: when multiple beads close in the same polling window, the
   choreographer receives them sequentially but may confuse prior-event context. Consider adding
   the bead ID explicitly as the first line of each brief. (The current brief already does this —
   the issue may be temperature variance; 2/3 reps got it right.)

2. **Loop timeout**: LOOP_TIMEOUT=300s should be raised to ~600s for production runs, or the
   choreographer loop should be restructured to parallelize event handling.

3. **LLM-worker variant**: replace deterministic workers with real LLM workers using the new
   `## Signaling vocabulary` section in `implementer.md`. Separate bead per design fragment OQ4.
