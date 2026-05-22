#!/usr/bin/env bash
# scripts/inspect.sh — one-shot in-container snapshot for debugging.
#
# Usage:
#   docker exec <container> /home/agent/validation-pack/scripts/inspect.sh
#
# Prints to stdout:
#   1. All bd wisps — id, status, close_reason, assignee, comment_count.
#      Falls back to bd show <id> for any fixture-referenced beads not in list.
#   2. gc supervisor + sessions (if gc supervisor status returns 0).
#   3. tmux sessions — pane count + last 5 lines of each pane.
#   4. JSONL vs dolt state — line count of .beads/issues.jsonl, TRUE/FALSE match.
#
# Idempotent (read-only). Target runtime < 2 seconds.

set -euo pipefail

PACK_ROOT="${PACK_ROOT:-/home/agent/validation-pack}"

hr() { printf '%.0s-' {1..72}; printf '\n'; }

# ---------------------------------------------------------------------------
# 1. bd wisps
# ---------------------------------------------------------------------------
hr
echo "=== BD WISPS ==="
hr

# Collect all bead IDs mentioned in any fixture file (for fallback show).
fixture_ids=()
for fx in "${PACK_ROOT}"/fixtures/*-expected.json; do
    [[ -f "${fx}" ]] || continue
    while IFS= read -r id; do
        fixture_ids+=("${id}")
    done < <(python3 -c "
import json, sys
try:
    fx = json.load(open('${fx}'))
    seen = set()
    for entries in fx.values():
        if not isinstance(entries, list): continue
        for e in entries:
            bid = e.get('bead_id')
            if bid and bid not in seen:
                seen.add(bid)
                print(bid)
except Exception as exc:
    print(f'# parse error: {exc}', file=sys.stderr)
" 2>/dev/null || true)
done

# Primary: bd list --json (may omit ephemeral beads).
python3 - <<'PYEOF'
import json, subprocess, sys

result = subprocess.run(['bd', 'list', '--json'], capture_output=True, text=True)
if result.returncode != 0:
    print(f'[inspect] bd list failed: {result.stderr.strip()}')
    sys.exit(0)

text = result.stdout
try:
    idx = text.index('[')
    beads = json.loads(text[idx:])
except Exception as exc:
    print(f'[inspect] bd list parse error: {exc}')
    sys.exit(0)

if not beads:
    print('[inspect] bd list: no beads found')
    sys.exit(0)

fmt = '  {:<20} {:<10} {:<15} {:<25} {:>5}'
print(fmt.format('ID', 'STATUS', 'CLOSE_REASON', 'ASSIGNEE', '#CMTS'))
print('  ' + '-'*70)
for b in beads:
    bid     = str(b.get('id', ''))[:20]
    status  = str(b.get('status', ''))[:10]
    reason  = str(b.get('close_reason') or '')[:15]
    assign  = str(b.get('assignee') or '')[:25]
    cmts    = len(b.get('comments', []))
    print(fmt.format(bid, status, reason, assign, cmts))
PYEOF

# Fallback: bd show for fixture-referenced IDs not covered by list.
if [[ "${#fixture_ids[@]}" -gt 0 ]]; then
    echo ""
    echo "  [fixture-referenced beads via bd show]"
    for bid in "${fixture_ids[@]}"; do
        python3 - "${bid}" <<'PYEOF'
import json, subprocess, sys

bid = sys.argv[1]
result = subprocess.run(['bd', 'show', bid, '--json'], capture_output=True, text=True)
if result.returncode != 0:
    print(f'    {bid}: bd show failed')
    sys.exit(0)
try:
    text = result.stdout
    idx = text.index('[')
    beads = json.loads(text[idx:])
    b = beads[0]
except Exception as exc:
    print(f'    {bid}: parse error: {exc}')
    sys.exit(0)

status  = b.get('status', '')
reason  = b.get('close_reason') or ''
assign  = b.get('assignee') or ''
cmts    = len(b.get('comments', []))
print(f'    {bid:<20}  status={status:<10}  reason={reason:<15}  assignee={assign:<25}  comments={cmts}')
PYEOF
    done
fi

# ---------------------------------------------------------------------------
# 2. gc supervisor + sessions
# ---------------------------------------------------------------------------
hr
echo "=== GC SUPERVISOR ==="
hr

if gc supervisor status --city "${PACK_ROOT}" >/dev/null 2>&1; then
    echo "  supervisor: RUNNING"
    echo ""
    echo "  [active sessions]"
    gc session list --city "${PACK_ROOT}" 2>/dev/null \
        | sed 's/^/  /' \
        || echo "  (gc session list failed)"
else
    echo "  supervisor: NOT RUNNING (gc supervisor status returned non-zero)"
fi

# ---------------------------------------------------------------------------
# 3. tmux sessions
# ---------------------------------------------------------------------------
hr
echo "=== TMUX SESSIONS ==="
hr

if ! command -v tmux >/dev/null 2>&1; then
    echo "  tmux: not in PATH"
else
    sessions="$(tmux list-sessions -F '#{session_name} panes=#{session_windows} windows' 2>/dev/null || true)"
    if [[ -z "${sessions}" ]]; then
        echo "  (no tmux sessions)"
    else
        while IFS= read -r line; do
            session_name="${line%% *}"
            echo "  session: ${line}"
            echo "  [last 5 lines of pane]"
            tmux capture-pane -t "${session_name}" -p 2>/dev/null \
                | tail -5 \
                | sed 's/^/    /' \
                || echo "    (capture failed)"
            echo ""
        done <<< "${sessions}"
    fi
fi

# ---------------------------------------------------------------------------
# 4. JSONL vs dolt state
# ---------------------------------------------------------------------------
hr
echo "=== JSONL VS DOLT STATE ==="
hr

jsonl_path="${PACK_ROOT}/.beads/issues.jsonl"

if [[ -f "${jsonl_path}" ]]; then
    jsonl_lines="$(wc -l < "${jsonl_path}")"
    echo "  issues.jsonl: ${jsonl_lines} lines"
else
    echo "  issues.jsonl: NOT FOUND at ${jsonl_path}"
    jsonl_lines=0
fi

# Compare: export current dolt state and diff against JSONL.
# TRUE if every dolt-exported bead's id+status+close_reason matches JSONL.
python3 - "${jsonl_path}" <<'PYEOF'
import json, subprocess, sys

jsonl_path = sys.argv[1]

# Load JSONL (may be stale/pre-import state).
jsonl_beads = {}
try:
    with open(jsonl_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            b = json.loads(line)
            jsonl_beads[b['id']] = b
except FileNotFoundError:
    print('  JSONL match: FALSE (file not found)')
    sys.exit(0)
except Exception as exc:
    print(f'  JSONL match: FALSE (parse error: {exc})')
    sys.exit(0)

# Export from dolt.
r = subprocess.run(['bd', 'export'], capture_output=True, text=True)
if r.returncode != 0:
    print(f'  JSONL match: FALSE (bd export failed: {r.stderr.strip()[:80]})')
    sys.exit(0)

dolt_beads = {}
for line in r.stdout.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        b = json.loads(line)
        dolt_beads[b['id']] = b
    except Exception:
        pass

dolt_count = len(dolt_beads)
print(f'  bd export:   {dolt_count} beads')

# Compare key fields.
mismatches = []
for bid, db in dolt_beads.items():
    jb = jsonl_beads.get(bid)
    if jb is None:
        mismatches.append(f'{bid}: missing from JSONL')
        continue
    for field in ('status', 'close_reason', 'assignee'):
        dv = db.get(field)
        jv = jb.get(field)
        if dv != jv:
            mismatches.append(f'{bid}.{field}: dolt={dv!r} jsonl={jv!r}')

match = len(mismatches) == 0
print(f'  JSONL match: {"TRUE" if match else "FALSE"}')
if mismatches:
    for m in mismatches[:10]:
        print(f'    ! {m}')
    if len(mismatches) > 10:
        print(f'    ... and {len(mismatches) - 10} more')
PYEOF

hr
