# beads-ui handbook docs-refresh runbook

Procedure for refreshing the beads-ui handbook docs at
`github/cwalv/beads-ui-prototype/docs/` against the current tips of
beads + gastown + gascity (per `rwv.lock`). Runtime-independent — this
used to be `formulas/mol-docs-refresh.formula.toml`; the formula
packaging (wisp/pour, `gc sling --formula`) is gone, but the procedure
itself has no scope/wisp machinery and ports directly to a manual or
subagent-driven run.

Each run produces:
- Mechanical citation-drift fixes (`file:line` that moved, fixed in place).
- Semantic rewrites where schema / CLI / formula behaviour changed.
- Flagged gaps (new concepts, not auto-written) — recorded in the entry
  and optionally as follow-up beads.
- A dated changelog entry under `docs/docs-changelog/` (inside the
  beads-ui-prototype repo) whose **Tips** section doubles as the
  "where we left off" bookmark for the next run. The latest entry IS
  the state — there is no separate state file.

## Scope

Three repos, each with its own path allowlist (commits outside the
allowlist are auto-classified as "no material doc impact"):

- **beads** — `github/gastownhall/beads/`
  - `internal/types/` (schema)
  - `cmd/bd/` (CLI surface)
  - `internal/storage/schema/migrations/`
  - `internal/formula/`, `internal/molecules/`, `internal/hooks/`
  - `internal/recipes/`, `internal/tracker/`
  - top-level `beads*.go`

- **gastown** — `github/gastownhall/gastown/`
  - `internal/beads/` (wrapper layer)
  - `internal/formula/`, `internal/molecule/`, `internal/convoy/`
  - `internal/mail/`, `internal/nudge/`, `internal/hooks/`
  - `internal/agent/`, `internal/crew/`, `internal/mayor/`
  - `internal/deacon/`, `internal/dog/`, `internal/polecat/`
  - `internal/witness/`, `internal/refinery/`
  - `cmd/gt/`

- **gascity** — `github/gastownhall/gascity/`
  - `internal/beads/` (Store abstraction)
  - `internal/formula/`, `internal/molecule/`, `internal/convoy/`
  - `internal/orders/`, `internal/sourceworkflow/`, `internal/graphroute/`
  - `internal/mail/`, `internal/nudgequeue/`, `internal/convergence/`
  - `internal/supervisor/`, `internal/session/`, `internal/runtime/`
  - `internal/worker/`, `internal/dispatch/`
  - `cmd/gc/`

## Tips / state model

The previous run's tips live in the **latest** changelog entry's
`## Tips` section (no separate state file). Step 1 reads
`github/cwalv/beads-ui-prototype/docs/docs-changelog/` for the latest
entry, extracts tips, and diffs against the current tips read from
`projects/foundations/rwv.lock` (or the successor manifest's lock
file). If the directory is empty (first run), fall back to "no prior
tips" — the operator seeds an initial entry manually.

Triage aims to classify commits via diff-stat + path list in most
cases; full-diff reads only when the stat is ambiguous.

## Output locations

- Entry: `github/cwalv/beads-ui-prototype/docs/docs-changelog/YYYY-MM-DD-{label}.md`
- Index: `github/cwalv/beads-ui-prototype/docs/docs-changelog/README.md`

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `label` | `refresh` | Filename suffix (e.g. `2026-05-15-refresh.md`). Set to a short kebab-case tag for notable runs. |
| `max_commits` | `200` | Upper bound on triaged commits per run. If exceeded, bail out and ask the operator to advance the lock in smaller steps. |
| `force_classify_all` | `false` | If true, send every commit to triage (skip the path-allowlist filter). Use when investigating whether the allowlist is too aggressive. |

## Step 1: plan — collect + path-filter commits per repo since the last entry

1. Resolve the weave root and read the previous tips from the latest
   changelog entry (`^- <repo> @ <sha>` lines inside the first
   `## Tips` block). If no entry exists yet, this is the first run —
   short-circuit to a bootstrap entry.
2. Read the current per-repo tips from the lock file.
3. For each repo, `git log <prev>..<curr>` over the range.
4. Path-allowlist filter (unless `force_classify_all`): for each
   commit, `git show --stat --name-only <sha>` and drop commits where
   no touched file matches the repo's allowlist above. Keep both the
   kept set and the dropped count — the entry reports both.
5. Cap at `max_commits`; if exceeded, stop and ask the operator to
   advance the lock in smaller steps.

## Step 2: triage — classify each surviving commit

For each commit, look at the subject line, the stat, the path list,
and — only if the stat alone is ambiguous — the full diff. Keep diff
reads proportional to signal.

| Category | Meaning | Action |
|---|---|---|
| `citation-drift` | Rename / refactor that moved lines without changing semantics. | Mechanical: grep the new location for the cited text, update `path:line`. |
| `schema-cli` | Added / removed / renamed a schema column, CLI flag, type constant, or formula schema field. | Semantic: re-read the relevant handbook section, rewrite. |
| `new-concept` | A new concept the handbook doesn't cover. | Flag only; create a follow-up bead. Do not auto-write. |
| `no-op` | Test fixtures, formatting, CI, dependency bumps, unrelated refactors. | Skip; record in the entry summary. |

For each classified commit, identify which handbook docs reference the
affected code (grep the handbook index / handbook tree for the
relevant file or symbol).

## Step 3: apply — fix drift, rewrite semantics, flag gaps

- **citation-drift**: for each affected doc, locate the new line for
  the cited text at the current tip and replace `path:line` in the
  doc. If the diff isn't a clean rename/move, escalate to `schema-cli`
  handling instead.
- **schema-cli**: read the affected doc section (nearest H2/H3), read
  the changed code at the current tip, rewrite the section to match,
  preserve citations pointing at the new code. Be conservative — if
  unsure what the change means, leave the section as-is, add a
  `<!-- TODO: refresh after GH#XXXX -->` marker, and record as a gap
  rather than guessing.
- **new-concept**: record a one-paragraph brief and file a follow-up
  bead (`docs: cover <new concept> (<sha>)`, type task, P3) citing the
  commit sha and repo. Record the bead id against the gap.

## Step 4: entry — write the changelog entry and update the index

Write the dated entry under
`github/cwalv/beads-ui-prototype/docs/docs-changelog/YYYY-MM-DD-{label}.md`.
Template (fixed shape so the next run's plan step can parse the Tips
section):

```markdown
# YYYY-MM-DD {label}

## Tips (at end of run)

- beads @ <curr-sha>
- gastown @ <curr-sha>
- gascity @ <curr-sha>

## Summary

- beads: {N} material, {M} no-op ({reason})
- gastown: {N} material, {M} no-op
- gascity: {N} material, {M} no-op

## Changes applied

### handbook/reference/bead-schema.md
- beads (sha): one-line description of the change → affected sections

## Gaps flagged (not auto-applied)

- beads (sha): brief one-paragraph. Follow-up bead: <id>.

## Drift fixes

- N `path:line` citations updated across M files (mechanical).
```

First-run case: the entry body is "bootstrap entry, no changes
applied" plus the Tips reflecting the current lock state.

Update `docs/docs-changelog/README.md` — it lists entries in
reverse-chronological order as a `| Date | Label | Summary |` table.
Prepend the new row; keep the same Markdown shape so it stays
parseable.

## Step 5: commit

Stage only `docs/` changes in the beads-ui-prototype repo (`git add
docs/`) so nothing unrelated gets bundled, then commit with a
pathspec-scoped message reporting drift fixes / semantic updates /
gaps and the new tips:

```
docs(beads-ui): docs-refresh {label} YYYY-MM-DD

N drift fixes, M semantic updates, K gaps flagged.
Tips: beads @ <sha> · gastown @ <sha> · gascity @ <sha>.

See docs/docs-changelog/YYYY-MM-DD-{label}.md for the full entry.
```

Leave publishing to the operator — this procedure doesn't push or
sync on its own. The next run's plan step reads this entry's Tips as
the "where we left off" bookmark.

## Usage

Run manually or hand this file to a subagent as the task brief, e.g.:

```
Follow docs/beads-ui-docs-refresh-runbook.md against the current
beads-ui-prototype tree. label=post-gates-work
```

Prefer a stronger model when a run looks likely to hit heavy semantic
rewrites (a big schema change); the mechanical steps (plan, drift
fixes) tolerate a lighter one.
