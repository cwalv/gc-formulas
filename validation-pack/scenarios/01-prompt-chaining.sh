#!/usr/bin/env bash
# scenarios/01-prompt-chaining.sh
#
# Driver for scenario 01: prompt-chaining.
#
# Invoked by run-scenario.sh, which exports:
#   SCENARIO_ID — "01-prompt-chaining"
#   PACK_ROOT   — "/home/agent/validation-pack"
#
# What this driver does:
#   1. Initialise the bd substrate (formula symlink, git identity)
#   2. Pour the prompt-chaining formula with small deterministic tasks
#   3. Sling all 3 step beads to the implementer persona
#   4. Write the expected predicate fixture BEFORE spawning the agent
#   5. Spawn one implementer agent (claude --print) to execute the chain
#   6. Poll for all 3 beads closed; timeout after 1500s
#   7. Exit 0 on success, 1 on timeout (with diagnostics on stderr)
#
# The agent processes beads in substrate-enforced order (deps ensure A→B→C).
# No external polling loop is needed during agent execution because we run
# claude synchronously; the poll loop below is a belt-and-suspenders guard
# for timeouts or unexpected agent behaviour.

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Prerequisites check
# ---------------------------------------------------------------------------

: "${PACK_ROOT:?PACK_ROOT must be set by run-scenario.sh}"
: "${SCENARIO_ID:?SCENARIO_ID must be set by run-scenario.sh}"

cd "${PACK_ROOT}"

# ---------------------------------------------------------------------------
# 1. Substrate initialisation
# ---------------------------------------------------------------------------

# Formula search path: bd looks in .beads/formulas/ — symlink our formula in.
mkdir -p .beads/formulas
if [[ ! -e .beads/formulas/prompt-chaining.formula.toml ]]; then
    ln -s "${PACK_ROOT}/formulas/prompt-chaining.formula.toml" \
          .beads/formulas/prompt-chaining.formula.toml
fi

# bd discovery fix: run-scenario.sh and verify_bead_state.py run from /home/agent
# (the container WORKDIR), not from PACK_ROOT. bd auto-discovers .beads/ by
# walking up from cwd. Symlink /home/agent/.beads → PACK_ROOT/.beads so that
# `bd` invocations from /home/agent also find the substrate — specifically the
# verifier's subprocess calls after the driver exits.
if [[ ! -e "${HOME}/.beads" ]]; then
    ln -sf "${PACK_ROOT}/.beads" "${HOME}/.beads"
fi

# Git identity — bd's embedded Dolt needs a user.name to commit audit rows.
# Use noop-scoped local config so we don't pollute the global git config.
git config --local user.name  "agent" 2>/dev/null || true
git config --local user.email "agent@validation-pack.local" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Pour the formula — creates root + 3 step beads
# ---------------------------------------------------------------------------

echo "[01-prompt-chaining] pouring formula..."

POUR_JSON="$(bd mol pour prompt-chaining \
    --var task_a="Output exactly three comma-separated single-word descriptors of the color blue (lowercase, no extra words)." \
    --var task_b="Read step-a's notes. For each word in the list, write a single sentence describing that word's connotation. Output one sentence per line." \
    --var task_c="Read step-b's notes. Combine the sentences into a single coherent paragraph of 3-5 sentences." \
    --var assignee=implementer \
    --json 2>&1)"

echo "[01-prompt-chaining] pour output: ${POUR_JSON}"

BD_STEP_A="$(printf '%s' "${POUR_JSON}" | python3 -c \
    'import json,sys; d=json.load(sys.stdin); print(d["id_mapping"]["prompt-chaining.step-a"])')"
BD_STEP_B="$(printf '%s' "${POUR_JSON}" | python3 -c \
    'import json,sys; d=json.load(sys.stdin); print(d["id_mapping"]["prompt-chaining.step-b"])')"
BD_STEP_C="$(printf '%s' "${POUR_JSON}" | python3 -c \
    'import json,sys; d=json.load(sys.stdin); print(d["id_mapping"]["prompt-chaining.step-c"])')"

echo "[01-prompt-chaining] step-a=${BD_STEP_A} step-b=${BD_STEP_B} step-c=${BD_STEP_C}"

# ---------------------------------------------------------------------------
# 3. Route all three step beads to the implementer persona
# ---------------------------------------------------------------------------

echo "[01-prompt-chaining] slinging beads to implementer..."

# gc sling may emit a warning about convoy creation failing (bd version mismatch
# on the 'convoy' issue type). The sling itself still succeeds; suppress only
# the convoy error to keep logs clean.
_sling() {
    gc sling implementer "$1" --city "${PACK_ROOT}" 2>&1 \
        | grep -v "invalid issue type: convoy" >&2 || true
}

_sling "${BD_STEP_A}"
_sling "${BD_STEP_B}"
_sling "${BD_STEP_C}"

echo "[01-prompt-chaining] routing complete"

# ---------------------------------------------------------------------------
# 4. Write the expected predicate BEFORE spawning the agent
# ---------------------------------------------------------------------------

mkdir -p "${PACK_ROOT}/fixtures"
cat > "${PACK_ROOT}/fixtures/${SCENARIO_ID}-expected.json" <<EOF
{
  "closed_in_order": [
    {"bead_id": "${BD_STEP_A}", "reason": "completed"},
    {"bead_id": "${BD_STEP_B}", "reason": "completed"},
    {"bead_id": "${BD_STEP_C}", "reason": "completed"}
  ]
}
EOF

echo "[01-prompt-chaining] predicate written to fixtures/${SCENARIO_ID}-expected.json"

# ---------------------------------------------------------------------------
# 5. Spawn the implementer agent
# ---------------------------------------------------------------------------
# The implementer persona (gc prime implementer) instructs the agent to:
#   - Find work via `bd ready --metadata-field gc.routed_to=implementer --unassigned`
#   - Claim, execute, close, repeat
#   - Call `gc runtime drain-ack` when no more work is found
#
# We run claude in --print mode so it blocks until done. --dangerously-skip-permissions
# lets bd/gc CLI tools run without interactive confirmation inside the container.
#
# GC_AGENT is set so `gc hook` and `gc runtime` can identify the session.

IMPLEMENTER_PROMPT="$(gc prime implementer --city "${PACK_ROOT}" 2>&1)"

echo "[01-prompt-chaining] spawning implementer agent..."

AGENT_EXIT=0
# Note: --add-dir takes multiple <directories...> and will greedily consume
# positional arguments unless we use -- to end option parsing before the prompt.
GC_AGENT=implementer \
GC_SESSION_NAME=implementer-01 \
    claude \
        --print \
        --dangerously-skip-permissions \
        --add-dir "${PACK_ROOT}" \
        --system-prompt "${IMPLEMENTER_PROMPT}" \
        -- \
        "You are an implementer agent. Process all available work in the validation-pack bd substrate.

Your work queue is filtered to beads routed to you:
  bd ready --metadata-field gc.routed_to=implementer --unassigned

Loop until the queue is empty:
1. Run: bd ready --metadata-field gc.routed_to=implementer --unassigned --json
2. If empty, you are done — stop.
3. Take the first bead. Claim it: bd update <id> --claim
4. Read the full bead description: bd show <id>
5. Execute the task described in the bead's 'Your assignment:' section.
6. Record your result: bd update <id> --append-notes 'Result: <your output>'
7. Close the bead: bd close <id> --reason=completed
8. Repeat from step 1.

For step B and C: retrieve prior step output via:
  bd show <this-bead-id> --json  (check .dependencies for the upstream bead id)
  bd show <upstream-bead-id> --json  (read .notes for the result)

Work directory: ${PACK_ROOT}
Bead IDs in this run: step-a=${BD_STEP_A} step-b=${BD_STEP_B} step-c=${BD_STEP_C}

When no more work is available, output 'DRAIN_COMPLETE' and stop." \
    2>&1 || AGENT_EXIT=$?

echo "[01-prompt-chaining] agent exited with code ${AGENT_EXIT}"

# ---------------------------------------------------------------------------
# 6. Poll for terminal state — belt-and-suspenders guard
# ---------------------------------------------------------------------------
# The agent ran synchronously above. If it succeeded, all 3 beads are already
# closed. We still poll briefly so a partially-completed run surfaces quickly
# rather than timing out the full 1500s.

TIMEOUT_SECS=1500
POLL_INTERVAL=10
START_TS="$(date +%s)"

echo "[01-prompt-chaining] polling for all 3 beads closed..."

while true; do
    CLOSED="$(bd list --status=closed --json 2>/dev/null \
        | jq "[.[] | select(.id==\"${BD_STEP_A}\" or .id==\"${BD_STEP_B}\" or .id==\"${BD_STEP_C}\")] | length" \
        2>/dev/null || echo 0)"

    echo "[01-prompt-chaining] closed: ${CLOSED}/3"

    if [[ "${CLOSED}" -eq 3 ]]; then
        echo "[01-prompt-chaining] all 3 beads closed — SUCCESS"
        exit 0
    fi

    NOW="$(date +%s)"
    ELAPSED=$(( NOW - START_TS ))
    if [[ "${ELAPSED}" -ge "${TIMEOUT_SECS}" ]]; then
        echo "[01-prompt-chaining] TIMEOUT after ${ELAPSED}s" >&2
        echo "--- still-open beads ---" >&2
        bd list --status=open --json 2>&1 \
            | jq "[.[] | select(.id==\"${BD_STEP_A}\" or .id==\"${BD_STEP_B}\" or .id==\"${BD_STEP_C}\")]" \
            2>&1 >&2 || true
        echo "--- hooked beads ---" >&2
        bd list --status=hooked --json 2>&1 \
            | jq "[.[] | select(.id==\"${BD_STEP_A}\" or .id==\"${BD_STEP_B}\" or .id==\"${BD_STEP_C}\")]" \
            2>&1 >&2 || true
        echo "--- bd ready (implementer) ---" >&2
        bd ready --metadata-field gc.routed_to=implementer 2>&1 >&2 || true
        exit 1
    fi

    sleep "${POLL_INTERVAL}"
done
