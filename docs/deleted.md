# Deleted (archive class)

Per the 2026-07-25 gc-formulas triage, "archive" no longer means
"frozen in the tree" — it means deleted, with git history as the
archive. Recovery: `git show pre-reorg-2026-07-25:<path>`. Full
per-file rationale is in the triage JSON, imported into the aop
project history at
`projects/foundations/docs/gc-formulas-triage-2026-07-25.json`
(`git -C projects/foundations show '5e68605^:docs/gc-formulas-triage-2026-07-25.json'`).

Abandon-class items (22, pure dead-runtime plumbing and process
residue with no evidentiary value) are not indexed here — they're
covered by the tag and the triage JSON alone.

One line per archive-class path deleted in this reorg:

- `docs/throughput-mode.md` — superseded plan for claims 2-5 via the
  dead validation-pack rig; the choreograph practice validated those
  claims in the field instead.
- `docs/per-orchestrator-runners.md` — design fragment for routing
  eval cases through the formula substrate; provenance for the
  ~3.6x substrate-overhead finding in `evals/validator-suite/SUBSTRATE-RESULTS.md`.
- `docs/debugging.md` — operational runbook for the validation-pack
  container rig.
- `docs/archive/README.md` — index of the (now-deleted) archive dir.
- `docs/archive/agent-orchestration-architecture.md` — long-form
  original of `position.md`.
- `docs/archive/gascity-focus-areas.md` — where "content over
  runtime" and the other principles were first coined, before
  distillation into `principles.md`.
- `docs/archive/orchestration-conversation.md` — raw landscape-mapping
  conversation (gascity, NTM, Flywheel, Intent, Swamp); the
  terminology's birthplace.
- `docs/archive/ntm-multi-agent-tutorial.md` — cross-project evidence
  for "workflow runtimes age badly."
- `docs/archive/validation-pack-design.md` — methodology for the eval
  rig that produced the claim-1 evidence.
- `docs/archive/validation-pack-decisions.md` — lab notebook behind
  the eval results, including corrections of earlier wrong
  conjectures; `state.md` carries the corrected story.
- `evals/validator-suite/SUBSTRATE-RESULTS.md` — the gc-substrate
  (formula runtime) bench vs bare-bash: same quality, ~3.6x slower.
  Helped justify abandoning the runtime.
- `scripts/eval-gc.sh`, `scripts/eval-ntm.sh` — C.2 substrate bench
  drivers; provenance for `SUBSTRATE-RESULTS.md` (they ran the case
  through a real gc/ntm supervisor executing the
  `eval-orchestrator-workers` formula — the condition itself is the
  abandoned runtime).
- `validation-pack/` (everything except the 6 tools moved to
  top-level `personas/` and `tools/` ahead of this deletion — see
  those directories) — the container rig that produced the claim-1
  evidence (`docs/state.md`: 7/7 patterns under two shims). Frozen
  rig config, nine scenario drivers and nine formula TOMLs bound to
  `bd mol wisp`, and the two shim implementations (`shims/gc.sh`,
  `shims/ntm.sh` — these two were runtime-independent, kept archive
  rather than abandon as part of the coherent rig record).

`eval-runs/` (gitignored run artifacts: the bench-* series, smoke
runs, SUBSTRATE-RESULTS provenance) is also archive-class per the
triage, but did not exist as tracked content in this checkout — it's
untracked/gitignored and was already absent before this reorg. No
deletion action was possible or needed here; see the divergence note
on bead aop-je6oy9 for detail. The same applies to
`validation-pack/debug-artifacts/`'s raw session evidence (the
directory's tracked `README.md` is listed above; the ~4.8MB of
gitignored JSONLs/scrollback/logs never existed in this checkout).
