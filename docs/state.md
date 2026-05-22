# Current state of validation

## Substrate fix story

bd v1.0.3 has an auto-import-from-JSONL guard that fires on every bd invocation against an empty database. With auto-export on, the JSONL on disk accumulates; concurrent bd processes import the stale state into fresh dolt instances and overwrite in-dolt writes. Earlier sessions attributed this to a "supervisor-load race" and tried to disable via `ENV BEADS_EXPORT_AUTO=false` — that env var doesn't exist in bd v1.0.3 (no-op). The real config key is `export.auto` in `.beads/config.yaml`. The validation-pack now sets `bd config set export.auto false` + deletes `.beads/issues.jsonl` at image build time (commit `805a19e`); the auto-import guard then trips on `info.Size() == 0` and skips entirely. Single source of truth: embedded dolt.

## Validation matrix at the claim level

| Claim ([`position.md`](position.md)) | Status |
|---|---|
| 1: patterns work without runtime | ✅ — 7/7 under gc and ntm |
| 2: patterns compose without runtime | ✗ — mechanic exists in bd; no scenario exercises it |
| 3: worker contracts stay short | ✗ — not tracked over time |
| 4: it scales | ✗ — current rig is one-workflow-per-container |
| 5: better models do worse with cages | ✗ — no counter-experiment |

## Pattern coverage (claim 1)

LLM mode. Post-substrate-fix + three rig-side fixes (scenario 06 marker → `bd comment`, verifier `closed_in_order` uses `bd show` fallback, ntm personas poll-with-retry).

| Scenario | gc | ntm |
|---|---|---|
| 00 microscope | PASS | PASS |
| 01 prompt-chaining | PASS | PASS |
| 02 routing | PASS | PASS |
| 03 sectioning | PASS | PASS |
| 04 voting | PASS | PASS |
| 05 orchestrator-workers | PASS | PASS |
| 06 evaluator-optimizer | PASS | PASS |
| 07 agent-loop | PASS | PASS |

Caveats: gc requires serial or ≤3-parallel docker runs — supervisor boot is dolt-sql-server-bound under parallel load (P2 `storage_degraded→durable`: 21s solo, 65s avg at N=7). Operational ceiling, not a substrate bug. ntm parallelizes freely.

## Fake-worker lane (no-LLM)

All 7 scenarios also pass in fake-worker mode (`SCENARIO_MODE=fake`). Deterministic bd ops driven by scenario scripts, no LLM call. ~24s total wall-clock for all 7 in parallel under ntm. Used for substrate/shim/persona regression without LLM cost. See [`debugging.md`](debugging.md).

## Known nuances surfaced this session

- **gc supervisor parallel startup is dolt-bound.** ntm scales flat under the same N (gc N=1 → 94s, gc N=7 → 242s; ntm N=1 → 47s, ntm N=7 → 46s). Host has 24 cores + 28% idle + 0.5% IO wait, so it's not host resource exhaustion — it's dolt sql-server boot under contention.
- **ntm has no reconciler.** Personas must use poll-with-retry to survive ping-pong handoffs (e.g. evaluator-optimizer). gc's `min_active_sessions = 1` handles this automatically; ntm fix lives in the persona prompt.
- **Roles are encoded in persona files** (foreman, implementer, evaluator, treehugger × 2 shims = 8 files). The position's principles say roles should live in beads, not personas. We violate the principle ourselves; captured as an improvement.
- **The 7 patterns aren't orthogonal.** 02/03/04/05 are variations of one fan-out shape parameterized by `(decompose?, N, aggregation)`. Tolerable as unit-test fixtures; redundant for higher-level validation.

## Open follow-ups

- `fo-pb0ye` — consolidate ntm `projects_base` (blocked on ntm upstream — `ntm spawn --project-dir` flag doesn't exist; Claude trust is per-directory, not prefix).
- `fo-jlv6k` — decisions log (intentionally kept open as running record).
- Composition + claims 2-5 — see [`throughput-mode.md`](throughput-mode.md).
