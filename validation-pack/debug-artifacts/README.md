# debug-artifacts

On scenario failure, `scripts/run-scenario.sh` writes a timestamped
subdirectory here containing:

- `claude-projects/` — Claude Code's per-session JSONL transcripts (the
  agent's full tool-use history for that run).
- `tmux/<session>.txt` — pane scrollback for each tmux session that was
  active (ntm shim uses tmux per persona).
- `beads/issues.jsonl` — the bd JSONL on disk at exit.
- `beads/bd-export.jsonl` — a fresh `bd export` (live dolt state).
- `<scenario-id>-expected.json` — the predicate fixture the verifier
  was asserting against.
- `summary.txt` — exit codes + timestamp.

Successful runs do not write here.

Override the host path with `DEBUG_ARTIFACTS=/some/other/path docker compose ...`.
