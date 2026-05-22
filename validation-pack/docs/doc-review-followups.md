# Doc-review follow-ups

Punch list of items surfaced by a doc-review pass on the validation-pack docs.
Each item has a file/line citation and a suggested action. Strike through or
remove entries once landed.

When adding to this file: new reviews append a section with their date and the
items they surfaced. Don't rewrite older sections — that's history.

## 2026-05-21 — initial review (sonnet subagent)

Reviewer scope: `validation-pack-design.md`, `validation-pack-decisions.md`,
`agent-orchestration-architecture.md`, `scenario-01-call-chain.md`, plus the
three context docs (`gascity-focus-areas.md`, `ntm-multi-agent-tutorial.md`,
`orchestration-conversation.md`).

### Conflicts (high priority — false claims in current docs)

- [x] **A. Design doc's shim table cites `gc events --watch`; we use polling.**
  `validation-pack-design.md:44`. Replace the `gc events --watch --filter ...`
  cell with the actual polling approach, or add a "↳ see decisions doc"
  pointer.

- [x] **B. Design doc's "What works" cites `bd mol pour`; we switched to
  `bd mol wisp` + `pour=true`.** `validation-pack-design.md:192`. Strike or
  date-stamp the "What works" pour bullet; wisp is the live decision.

- [x] **C. Decisions doc "Observation update" re-asserts write-loss AFTER
  the "Correction" overturned it.** `validation-pack-decisions.md:246-252`.
  Add a "Superseded by Correction above" marker, or delete the obsolete
  passage.

- [x] **D. Final coverage matrix attributes scenario 02 failures to "JSONL
  race"; real cause is bd#4082 + the `.children` vs `.dependents` field-
  name bug.** `validation-pack-decisions.md:299`. Update the scenario 02
  root-cause cell.

### Missing context

- [x] **E. Bare bead IDs used as labels without a one-phrase gloss.**
  `validation-pack-design.md:15-16,160-161,171-172` (e.g. `fo-h8o87.1.8`,
  `fo-8fdbk`). Inline a one-phrase description, or add a "Referenced beads"
  subsection.

- [x] **F. `gc prime`, `gc hook`, `gc runtime drain-ack` used in the
  architecture doc without definition.** `agent-orchestration-architecture.md:115,127,139`.
  Add a one-line gloss per verb in the coordination-flow section, or a
  "gc CLI verbs used" aside.

- [x] **G. `sme2 mail gc-wisp-bj2` cited as source for scenario 8 input.**
  `validation-pack-design.md:169`. Mail IDs are opaque + ephemeral —
  inline the gist (one sentence).

### Claims lacking evidence

- [x] **H. "mol-weave-work didn't complete in 10 minutes" presented as
  structural evidence of workflow-runtime decay.**
  `agent-orchestration-architecture.md:62`. Single run; qualify with the
  conditions / mark as anecdotal rather than load-bearing.

- [x] **I. Hypothesis that gc's supervisor "re-primes the session" is
  stated as the mechanism without verification.**
  `validation-pack-decisions.md:224`. Mark explicitly as hypothesis, not
  fact.

### Superfluous / redundant detail

- [x] **J. Validation-pack-design.md "Validation findings" section has
  three overlapping accounts of scenario 01.** `validation-pack-design.md:177-318`.
  "What works", "ALL 7 scenarios PASS", "scenario 01 PASSES cleanly on
  v1.0.3" are sequential diary entries, not synthesized findings. Collapse
  to a current-status subsection; demote the bd v1.0.4 regression
  analysis to a sub-bullet.

### Stale cross-references

- [x] **K. Architecture doc links use `projects/foundations/docs/` paths.**
  `agent-orchestration-architecture.md:18-21`. The three context docs were
  moved into this same directory; the `../../../projects/foundations/docs/`
  prefixes are broken. Update to `./<name>.md`.
