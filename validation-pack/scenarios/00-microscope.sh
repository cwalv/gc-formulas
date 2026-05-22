#!/usr/bin/env bash
# scenarios/00-microscope.sh
#
# Driver for scenario 00: microscope (rig validation, single bead).
#
# Invoked by run-scenario.sh, which exports:
#   SCENARIO_ID — "00-microscope"
#   PACK_ROOT   — "/home/agent/validation-pack"
#
# What this driver does:
#   1. Substrate prep — formula symlink, ~/.beads discovery symlink, git identity.
#   2. Wisp the microscope formula (single bead: probe).
#   3. Route probe to the implementer pool via direct assignee write.
#   4. Write the expected predicate fixture BEFORE spawning the agent.
#      Includes a comments_contain assertion.
#   5. Spawn one implementer session via shim_spawn.
#   6. Await probe closed via shim_await.
#   7. Exit 0 on success; on failure/timeout dump diagnostics and exit 1.
#
# Purpose: NOT an Anthropic catalog pattern exercise. This is the smallest
# possible end-to-end rig check — validates shim / persona / Dockerfile /
# bd substrate. If this passes but a catalog scenario fails, the bug is in
# the scenario complexity, not the rig. Target runtime: ~30s.

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Prerequisites
# ---------------------------------------------------------------------------

: "${PACK_ROOT:?PACK_ROOT must be set by run-scenario.sh}"
: "${SCENARIO_ID:?SCENARIO_ID must be set by run-scenario.sh}"

cd "${PACK_ROOT}"

# Source checkpoint helper (DEBUG_PAUSE_AT support).
# shellcheck source=scripts/checkpoint.sh
source "${PACK_ROOT}/scripts/checkpoint.sh"

# Source the orchestrator shim (defaults to gc).
SHIM="${SHIM:-gc}"
SHIM_FILE="${PACK_ROOT}/shims/${SHIM}.sh"
if [[ ! -f "${SHIM_FILE}" ]]; then
    echo "[${SCENARIO_ID}] ERROR: shim not found: ${SHIM_FILE}" >&2
    exit 1
fi
# shellcheck source=shims/gc.sh
source "${SHIM_FILE}"

# ---------------------------------------------------------------------------
# 1. Substrate prep
# ---------------------------------------------------------------------------

# Formula search path: bd looks in .beads/formulas/ — symlink our formula in.
mkdir -p .beads/formulas
if [[ ! -e .beads/formulas/microscope.formula.toml ]]; then
    ln -s "${PACK_ROOT}/formulas/microscope.formula.toml" \
          .beads/formulas/microscope.formula.toml
fi

# bd discovery from /home/agent (the container WORKDIR): bd walks up from cwd
# to find .beads/. The verifier runs from /home/agent, not PACK_ROOT. Symlink
# /home/agent/.beads → PACK_ROOT/.beads so both cwd contexts resolve the same
# substrate.
if [[ ! -e "${HOME}/.beads" ]]; then
    ln -sf "${PACK_ROOT}/.beads" "${HOME}/.beads"
fi

# bd embedded Dolt needs a git user.name for audit commits. Scope to local
# config (this repo) so host global config is unaffected.
git config --local user.name  "agent" 2>/dev/null || true
git config --local user.email "agent@validation-pack.local" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Wisp the formula (bd mol wisp → ephemeral bead, minimal overhead)
# ---------------------------------------------------------------------------
# Uses bd mol wisp (ephemeral) rather than bd mol pour (persistent) because
# this scenario is purely a rig probe; no blocker/dependency chain needed.
# The microscope formula has a single step (probe); no dep chain to manage.

echo "[${SCENARIO_ID}] wisping formula microscope..."

WISP_JSON="$(bd mol wisp microscope \
    --var assignee=implementer \
    --json)"

echo "[${SCENARIO_ID}] wisp output: ${WISP_JSON}"

# ---------------------------------------------------------------------------
# 3. Parse bead IDs from wisp output (raw_decode pattern)
# ---------------------------------------------------------------------------
# bd may emit auto-import lines on stdout before the JSON object.
# raw_decode: locate the first '{' and parse from there — robust against
# leading noise ("auto-importing N bytes...", "auto-imported N issues...").

_parse_bead() {
    local key="$1"
    printf '%s' "${WISP_JSON}" | python3 -c "
import json, sys
text = sys.stdin.read()
idx = text.index('{')
d = json.loads(text[idx:])
print(d['id_mapping']['microscope.${key}'])
"
}

_parse_root() {
    printf '%s' "${WISP_JSON}" | python3 -c "
import json, sys
text = sys.stdin.read()
idx = text.index('{')
d = json.loads(text[idx:])
# root_id is the molecule root; some bd versions use 'root_id', others 'id'
print(d.get('root_id') or d.get('id', ''))
"
}

BD_PROBE="$(_parse_bead probe)"
BD_ROOT="$(_parse_root)"

echo "[${SCENARIO_ID}] root=${BD_ROOT} probe=${BD_PROBE}"

# Checkpoint: after wisp is poured, before routing.
checkpoint pour

# ---------------------------------------------------------------------------
# 4. Route probe to the implementer pool (direct assignee write)
# ---------------------------------------------------------------------------
# Use bd update --assignee rather than gc sling — sidesteps gc sling's
# auto-convoy bead creation (not needed for single-bead scenarios).
# The assignee slot doubles as a pool name: validation/<persona>.
# The implementer persona's pool query reads --assignee=validation/implementer.

echo "[${SCENARIO_ID}] routing probe to implementer..."

bd update "${BD_PROBE}" --assignee=validation/implementer
echo "[${SCENARIO_ID}]   routed ${BD_PROBE}"

# ---------------------------------------------------------------------------
# 5. Write expected predicate fixture BEFORE spawning the agent
# ---------------------------------------------------------------------------
# Predicate kinds used:
#   closed_in_order  — probe must close with reason=completed
#   comments_contain — probe comments must contain "hostname"

mkdir -p "${PACK_ROOT}/fixtures"
cat > "${PACK_ROOT}/fixtures/${SCENARIO_ID}-expected.json" <<EOF
{
  "closed_in_order": [
    {"bead_id": "${BD_PROBE}", "reason": "completed"}
  ],
  "comments_contain": [
    {"bead_id": "${BD_PROBE}", "value": "hostname"}
  ]
}
EOF

echo "[${SCENARIO_ID}] predicate written to fixtures/${SCENARIO_ID}-expected.json"

# Checkpoint: after routing, before shim_spawn.
checkpoint route

# ---------------------------------------------------------------------------
# 6. Spawn the implementer agent (via gc shim)
# ---------------------------------------------------------------------------

echo "[${SCENARIO_ID}] spawning implementer agent..."
shim_spawn implementer 1

# Checkpoint: after shim_spawn, before shim_await.
checkpoint spawn

# ---------------------------------------------------------------------------
# 7. Await terminal state via shim_await
# ---------------------------------------------------------------------------
# Wait for probe to close. Single trivial bead — generous but tight ceiling.
# 300s (5 min) is 5–10x the expected runtime; allows for slow model starts.

echo "[${SCENARIO_ID}] awaiting probe (${BD_PROBE}) close..."

AWAIT_RC=0
shim_await "${BD_PROBE}" 300 || AWAIT_RC=$?

# Checkpoint: after shim_await detects close, before exit.
checkpoint close

# ---------------------------------------------------------------------------
# 8. Outcome
# ---------------------------------------------------------------------------

if [[ "${AWAIT_RC}" -eq 0 ]]; then
    echo "[${SCENARIO_ID}] probe closed — SUCCESS"
    exit 0
fi

# Timeout / failure path: dump diagnostics so the treehugger can triage.
echo "[${SCENARIO_ID}] FAILED (await exit ${AWAIT_RC})" >&2
echo "--- open beads in this run ---" >&2
bd list --status=open --json 2>/dev/null \
    | jq -r "[.[] | select(.id==\"${BD_PROBE}\" or .id==\"${BD_ROOT}\")] | .[] | [.id, .status, .title] | @tsv" \
    2>&1 || true
echo "--- hooked beads in this run ---" >&2
bd list --status=hooked --json 2>/dev/null \
    | jq -r "[.[] | select(.id==\"${BD_PROBE}\" or .id==\"${BD_ROOT}\")] | .[] | [.id, .status, .title] | @tsv" \
    2>&1 || true
echo "--- bd ready (implementer pool) ---" >&2
bd ready --include-ephemeral --assignee=validation/implementer --json --limit 1 2>&1 || true
echo "--- gc session list ---" >&2
gc session list --city "${PACK_ROOT}" 2>&1 || true
exit 1
