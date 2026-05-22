# NTM multi-agent workflow tutorial — manual walkthrough

A hand-walked version of a mol-weave-work-shaped workflow using NTM primitives.
The goal is to *exercise the framework* on a trivial change, to validate that
the workflow shape (isolate → preflight → implement → review → merge → cleanup)
can be expressed with NTM's substrate and to surface the rough edges before
investing in any test-harness automation.

The tutorial is operator-driven: a human walks through it by hand. Where a step
would normally dispatch to an LLM agent, the operator can either send a real
prompt via `ntm send` (and wait for the agent to act) or just perform the work
themselves and continue — the primitives being exercised are the same either
way.

Commands below were verified against the NTM source at
`github/cwalv/ntm` (current tip). Anything unexpected during a run should be
captured in the *Observations* section.

## Goal

Append the line `hello` to `fixture/hello.txt` in the tutorial target repo,
land it on `main`, and tear down all session state. End in a clean state ready
to repeat.

## Prerequisites

- `ntm` on PATH (built from `cwalv/ntm` fork)
- `git`, `tmux` on PATH
- `jq` on PATH (used for parsing JSON output)

NTM's `projects_base` resolves to `~/ntm_Dev/` on Linux by default. Set
`NTM_PROJECTS_BASE` or `ntm config set projects_base <path>` to change it.

## Setup — create the target repo

You can either run `ntm quick test` (which scaffolds `~/ntm_Dev/test/` with
`.gitignore`, `.vscode/`, `.claude/`, and an empty git repo) and then seed
the fixture by hand, or you can do the whole thing explicitly:

```
mkdir -p ~/ntm_Dev/test/fixture
cd ~/ntm_Dev/test
git init -b main

# minimal .gitignore is fine for the tutorial; skip if you don't care
echo '.DS_Store' > .gitignore

# seed the fixture
printf 'one\ntwo\nthree\n' > fixture/hello.txt

cat > README.md <<'EOF'
# ntm-tutorial-target

Scratch repo for the foundations NTM tutorial. The canonical fake change is
"append `hello` to `fixture/hello.txt`."
EOF

git add fixture/hello.txt README.md .gitignore
git -c user.email=$(git config --global user.email 2>/dev/null || echo you@example.com) \
    -c user.name=$(git config --global user.name 2>/dev/null || echo you) \
    commit -m "init: tutorial target with fixture/hello.txt baseline"
git tag seed
```

`ntm spawn` does NOT require a git repo — it just opens a tmux session in
the project directory. But `ntm worktree provision` (Step 2 below) runs
`git worktree add`, so for the worktree-based workflow this tutorial walks
through, git is functionally required.

**Success means**:

```
cd ~/ntm_Dev/test
git log --oneline -1        # init: tutorial target ... at seed
git rev-parse seed          # short SHA of the seed commit
cat fixture/hello.txt       # one, two, three
```

## Target description

| Item | Value |
|---|---|
| NTM project dir | `~/ntm_Dev/test/` |
| NTM session name | `test--tutorial` (project `test`, label `tutorial`) |
| Base branch | `main` (at tag `seed` for fresh runs) |
| Work branch | Auto-named by NTM: `ntm/test--tutorial/cc_1` |
| Agent pane | `cc_1` (first Claude pane; pane index `1`, since pane `0` is reserved for the user) |
| File to modify | `fixture/hello.txt` |
| Change | Append the literal line `hello` |
| Expected post-state | `one`, `two`, `three`, `hello` (4 lines) |
| Commit message | `tutorial: append hello to fixture` |

## Steps

### Step 1: Spawn an NTM session

```
ntm spawn test --label tutorial --cc=1
```

- `test` is the project name; NTM cd's into `~/ntm_Dev/test/`.
- `--label tutorial` gives a session name `test--tutorial`, leaving the plain
  `test` session available for unrelated work.
- `--cc=1` creates one Claude agent pane (pane index `1`). The user pane (index
  `0`) is reserved by default.

**Observe**:

```
ntm list                                       # shows test--tutorial: 1 windows
ntm health test--tutorial                      # one Claude agent reported ok
ntm list --json | jq '.sessions[] | select(.name == "test--tutorial")'
```

**Success means**: session exists, pane `cc_1` is alive.

### Step 2: Provision an isolated worktree

```
ntm worktree provision cc_1 test--tutorial
```

- Positional args: agent name first, session name second.
- NTM picks the branch name (`ntm/test--tutorial/cc_1`) and worktree path; you
  don't choose them.

**Observe**:

```
ntm worktree list test--tutorial
ntm worktree list test--tutorial --json | jq '.[0].path'   # capture path
```

Set `WT="$(ntm worktree list test--tutorial --json | jq -r '.[0].path')"` for
the rest of the tutorial.

**Success means**:

```
git -C "$WT" branch --show-current        # ntm/test--tutorial/cc_1
git -C "$WT" status --short               # empty (clean tree)
cat "$WT/fixture/hello.txt"               # one, two, three
```

This is NTM's analog of the per-bead workweave in mol-weave-work — isolation
for the work so the main checkout stays clean.

### Step 3: Preflight — verify base state

```
cd "$WT"
git status                                # clean
git log --oneline -1                      # at seed commit
cat fixture/hello.txt                     # 3 lines
wc -l fixture/hello.txt                   # 3
```

**Success means**: file has 3 content lines, branch is clean, log shows the
seed commit at HEAD.

In mol-weave-work this was the preflight step that runs lint/build/test. For
this trivial change the analog is "the file is in the expected starting
state."

### Step 4: Implement the change

Two paths; the workflow shape is the same either way.

**Option A — operator does the work directly** (preferred for the manual
tutorial; minimum LLM cost):

```
cd "$WT"
echo hello >> fixture/hello.txt
git add fixture/hello.txt
git commit -m "tutorial: append hello to fixture"
```

**Option B — dispatch to the agent in pane `cc_1`** (optional, exercises
`ntm send`):

```
ntm send test--tutorial --pane=1 \
  "Working directory: $WT. Append the literal line 'hello' to fixture/hello.txt there. \
   Then git add the file and git commit with message 'tutorial: append hello to fixture'. \
   Reply 'done' when finished."

# stream the pane to watch the agent work
ntm watch test--tutorial --cc
# Ctrl-C out of watch once the commit lands.
```

**Observe**:

```
git -C "$WT" log --oneline -2          # tutorial commit + seed
cat "$WT/fixture/hello.txt"            # 4 lines, last is `hello`
git -C ~/ntm_Dev/test log --oneline -1 # main is still at seed
```

**Success means**: file has 4 lines ending in `hello`; commit is on the
feature branch only; main has not advanced.

### Step 5: Self-review — verify the change

```
cd "$WT"
git diff main..HEAD -- fixture/hello.txt
git log --oneline main..HEAD
```

**Success means**: diff shows exactly one added line `hello`; commit list
shows one new commit with the expected message; no unrelated edits.

In mol-weave-work this was the self-review step routed to a (potentially
different) agent. For the tutorial the operator does it directly. To
exercise the agent route, send a review prompt to a second pane (would need
to spawn with `--cc=2` to have one).

### Step 6: Merge with advisory lock check

NTM's file locks are advisory and aren't load-bearing for correctness, but
the tutorial should at least show what checking them looks like.

```
ntm locks check fixture/hello.txt --session test--tutorial
```

**Observe**: JSON envelope with `state: "free"` (no agent currently holds a
reservation on this path).

**Success means**: `state` is `free` — nothing is blocking.

Then merge in the main checkout (not the worktree):

```
cd ~/ntm_Dev/test
git merge --ff-only ntm/test--tutorial/cc_1
git log --oneline -2
cat fixture/hello.txt                       # 4 lines, hello at end
```

**Success means**: `main` now points at the same commit as the work branch;
`fixture/hello.txt` has 4 lines on main.

(Non-FF merge with an approval gate would be a variant — `git merge --no-ff`
plus `ntm safety policy` blocking until approved. Skip for v1.)

### Step 7: Cleanup

```
ntm worktree clean-session test--tutorial   # removes provisioned worktrees + branches
ntm kill test--tutorial --force             # tear down the tmux session
```

**Observe**:

```
ntm list                                    # no test--tutorial
ntm worktree list test--tutorial            # empty (or session-not-found)
git -C ~/ntm_Dev/test worktree list         # only the main worktree
git -C ~/ntm_Dev/test branch                # ntm/test--tutorial/cc_1 should be gone
```

**Success means**: no NTM state remains for the session; the target repo is
on `main` with the tutorial commit.

## Reset for the next run

The tutorial commits land on `main`. To go back to seed for the next run:

```
cd ~/ntm_Dev/test
git checkout main
git reset --hard seed
git branch -D ntm/test--tutorial/cc_1 2>/dev/null || true
git worktree prune                          # drop any stale worktree metadata
```

After this, `fixture/hello.txt` is 3 lines again and `main` is at the seed
commit.

## Observations

From the first walkthrough (2026-05-19):

**Things that worked as documented:**
- `ntm spawn test --label tutorial --cc=1` — session created cleanly, Claude
  agent launched in pane 1.
- `ntm health test--tutorial` — surfaced one warning worth knowing (see
  below).
- Preflight (Step 3) — pure git commands, no surprises.
- Implement Option A (Step 4) — pure git, worked as written.
- Self-review (Step 5) — pure git diff/log, worked as written.
- `git merge --ff-only` into main (Step 6b) — straightforward.
- `ntm kill test--tutorial --force` (Step 7) — killed the tmux session.

**Things that needed a different command than written:**

- **Step 2 must be run from inside the project directory.** Running
  `ntm worktree provision cc_1 test--tutorial` from outside `~/ntm_Dev/test/`
  fails with "failed to determine project directory: not in a git
  repository". The session arg is *not* used to resolve the project — CWD is.
  Tutorial should `cd ~/ntm_Dev/test` before Step 2.

- **Auto-named branch is `agent/cc_1/test--tutorial`**, not
  `ntm/test--tutorial/cc_1` as I predicted. The actual format is
  `agent/<agent>/<session>`. Tutorial table needs updating.

- **Worktree path includes numeric IDs**:
  `/home/cwa/ntm_Dev/agent-4-cc_1-session-14-test--tutorial`. Peer to the
  project dir, not inside `.git/worktrees/`. The numeric IDs (`agent-4`,
  `session-14`) come from NTM's internal sequence; you can't predict the
  path, you have to capture it from `ntm worktree list` output.

- **`ntm worktree list --json` does NOT emit JSON.** It prints the same
  table format regardless of `--json`. Capturing the path via
  `jq -r '.[0].path'` won't work. Use awk on the table output, or hard-code
  the path after running the provision step.

**Things NTM didn't have a clean primitive for:**

- **`ntm worktree clean-session` does not actually clean.** It reports
  "Session worktrees cleaned up successfully!" but `git worktree list` still
  shows the worktree and `git branch -a` still shows the branch. Manual
  cleanup is required:

  ```
  git worktree remove <worktree-path>
  git branch -D agent/<agent>/<session>
  ```

  This is a real gap, not a UX nit — the documented cleanup primitive is a
  no-op. Either a bug or scope mismatch (perhaps it only cleans an internal
  NTM record, not the git state).

**Friction points where the operator had to think:**

- **`ntm locks check` requires Agent Mail to be running.** Without it
  (default install on a fresh box), the call fails with
  `Error: agent mail server unavailable`. The merge step doesn't actually
  need locks to be working — it's advisory — but the *check* fails noisily
  rather than gracefully. For a workflow that doesn't intend to use locks,
  just skip the check.

- **Pane 0 (user) reports ✗ ERROR in `ntm health`.** Because nothing is
  running in the user pane (no human attached). Not load-bearing, but the
  overall health summary says "1 healthy, 0 warning, 1 error" which is
  alarming-looking for an actually-fine session.

**Steps that felt like ceremony for this trivial change:**

- Spawning a Claude agent pane (Step 1) is heavy if all you're going to do
  is Option A (operator does the work). For exercising the workflow
  primitives only, you could skip `ntm spawn` entirely — provision a
  worktree, do the work, clean up. The spawn is required only if you intend
  to use Option B (LLM dispatch) in Step 4.

**Steps that were too thin and would matter on a real change:**

- Preflight is just "is the file there?" Real preflight runs build/lint/test
  and would surface NTM's lack of a structured way to express
  "run-these-checks-and-block-on-failure" — likely needs a script or
  `ntm safety policy` rules. Worth a follow-up walk.

- Self-review is just `git diff`. Real self-review needs a second agent
  with a review-shaped prompt and a structured response. That's where
  multi-agent setups and the orchestration-conversation's "independent
  signal" idea would actually be exercised.

**Net read after the run:**

NTM gives you usable scaffolding for the parts that matter (session
isolation via worktrees, observable state via tmux, kill + cleanup) but
several rough edges leak into the tutorial flow. The two with the highest
"cost relative to surface area" are:

1. `worktree clean-session` not actually cleaning (a misleading primitive
   is worse than a missing one)
2. `worktree list --json` not respecting `--json` (breaks the natural
   automation path)

Both are fixable with small PRs upstream, and the workflow shape itself
went through end-to-end on the first manual attempt with only the
adjustments above.

## Candidate upstream bug reports

Notes for filing against `cwalv/ntm` (and possibly forward to
`Dicklesworthstone/ntm` since the cwalv fork hasn't diverged).

### Bug 1: `worktree provision` and `worktree clean-session` use incompatible branch naming, so manual provisions can't be cleaned

**Summary**: Worktrees created by `ntm worktree provision <agent> <session>`
are silently ignored by `ntm worktree clean-session <session>`. Only the
worktrees created by `auto-provision` get cleaned.

**Code paths**:

- Manual `provision` (`internal/git/worktree.go:247`,
  `internal/cli/worktree.go:177`): passes the raw `<session-id>` arg
  through to `ProvisionWorktree`, producing branch
  `agent/<agentKey>/<sessionKey>` where `sessionKey == <session-id>` (raw).
- `auto-provision` (`internal/git/service.go:131`): builds the sessionID
  via `buildSessionWorktreeID(sessionName, agentType, agentNum)` = 
  `<session>-<agent>-<paneNum>`, producing branch
  `agent/<agentKey>/<session>-<agent>-<paneNum>`.
- `clean-session` (`internal/git/service.go:172`) matches via
  `sessionMatchesWorktree` (line 266), which requires the sessionID
  portion to be `<sessionName>-<agentType>-<digits>`. The manual-provision
  format has no such suffix and is rejected.

**Reproducer**:

```
ntm spawn test --label tutorial --cc=1
cd ~/ntm_Dev/test
ntm worktree provision cc_1 test--tutorial
# Worktree created: branch agent/cc_1/test--tutorial,
# path .../agent-4-cc_1-session-14-test--tutorial
ntm worktree clean-session test--tutorial
# Prints: "✓ Session worktrees cleaned up successfully!"
git worktree list           # worktree still present
git branch -a               # agent/cc_1/test--tutorial still present
```

**Suggested fix**: have `clean-session` accept either format. Easiest
path is to relax `sessionMatchesWorktree` to ALSO match
`sessionID == canonicalSessionKey(sessionName)` (the manual format). Or
have manual `provision` route through `buildSessionWorktreeID` so it
produces the canonical form — but that changes the public CLI surface
(branch names would change). Either fix is small.

### Bug 2: `worktree clean-session` reports success even when nothing matched

**Summary**: `runWorktreeCleanSession` (`internal/cli/worktree.go:515`)
prints `"✓ Session worktrees cleaned up successfully!"` even when zero
worktrees matched the session. There's no indication that the operation
was a no-op.

**Why this compounds Bug 1**: without the misleading success message, the
user would notice that clean-session didn't actually clean and would
investigate. The success message hides the naming mismatch and makes Bug 1
silent.

**Suggested fix**: have `CleanupSessionWorktrees` return a count (or list)
of cleaned paths. CLI prints `"Cleaned 2 worktrees"` on success or
`"No worktrees found for session 'X'"` on zero matches. Returning a count
also makes the operation testable.

### Bug 3 (smaller): `worktree list --json` does not emit JSON

**Summary**: `ntm worktree list <session> --json` prints the same
human-readable table as without `--json`. Breaks the natural automation
path (e.g., `jq -r '.[0].path'`).

**Suggested fix**: respect the global `--json` flag in the `worktree list`
command. The data is already structured; only the renderer needs a
branch.

### Bug 4: `ntm assign` has no project-level default for the dispatch prompt template

**Summary**: The default prompt template used by `ntm assign` /
`bulk_assign` ("Read AGENTS.md, register with Agent Mail. Work on:
{bead_id} - {bead_title}. ...") is a Go `const`
(`internal/robot/bulk_assign.go:19`). Per-invocation overrides exist
(`--prompt` literal, `--template-file` path), but there is no
project-level or user-level config-driven default. To use a customized
dispatch contract project-wide, you'd have to wrap every `ntm assign`
call with `--template-file=...` or build a shell wrapper that injects it.

**Why this matters**: `AGENTS.md` already gives a project-as-source-of-
truth story for the *agent-side* contract (what the agent reads on
startup). The *dispatch-side* contract — what NTM tells the agent to do
when assigning new work — is the symmetric concern, and today it lives
in source code only. Customizing the agent's reading of work (`Read
AGENTS.md` → `Read SKILL.md`, or `Mark in_progress` → `Set gc.outcome on
the bead when done`) requires either a fork-and-rebuild of NTM, or a
wrapper around every `ntm assign` invocation.

**Code path**: `internal/robot/bulk_assign.go:770-779`,
`loadBulkAssignTemplate`:

```go
func loadBulkAssignTemplate(opts BulkAssignOptions, deps BulkAssignDependencies) (string, error) {
    if opts.PromptTemplatePath == "" {
        return defaultBulkAssignTemplate, nil
    }
    data, err := deps.ReadFile(opts.PromptTemplatePath)
    if err != nil {
        return "", fmt.Errorf("failed to read prompt template: %w", err)
    }
    return string(data), nil
}
```

**Suggested fix**: have `loadBulkAssignTemplate` consult a project-level
override before falling back to the const. Resolution order matching the
existing `ntm template` precedence would be natural:

1. `--template-file` (explicit per-invocation)
2. `.ntm/templates/bulk-assign.md` (project)
3. `~/.config/ntm/templates/bulk-assign.md` (user)
4. `defaultBulkAssignTemplate` (built-in fallback)

The placeholder syntax (`{bead_id}`, `{bead_title}`, etc., per
`expandBulkAssignTemplate` at `bulk_assign.go:781-795`) already handles
substitution; only the lookup path needs changing.

## What this tells us

Once executed end-to-end, this tutorial gives three things:

1. **A tested doc.** Future readers (human or agent) can follow it.
2. **A list of NTM primitive gaps** — where the framework needed manual
   workarounds. These inform whether a script later would be straightforward
   or need new helpers.
3. **The concrete shape** of what a `scenario_01`-equivalent would test if we
   later decide to automate.

It does *not* yet tell us:

- Whether NTM's agent dispatch (Step 4 Option B) is reliable enough for an
  automated scenario
- Whether multi-agent setups (e.g., implementer + reviewer in different
  panes) add value commensurate with the operator-side complexity
- Whether the multi-repo case (rwv workweave shape) can be expressed at all
  with NTM's single-repo worktree primitive

Each of those is a follow-on bead's worth of investigation, decided after
this walkthrough lands.
