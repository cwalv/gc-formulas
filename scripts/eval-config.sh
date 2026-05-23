#!/usr/bin/env bash
# eval-config.sh — shared model constants for plan-evals runners.
#
# Sourced by every eval-*.sh script. Override via env var on a per-invocation
# basis if needed:
#
#   WORKER_MODEL=opus bash scripts/eval-fanout.sh validator-suite
#   PLANNER_MODEL=sonnet bash scripts/eval-planner.sh cancel-method
#
# Workers do concrete file edits; planner does pattern selection and
# orchworkers' merge-step reconciliation. Defaults: sonnet for workers,
# opus for planner. Rationale lives in docs/plan-evals.md "Model calibration".

: "${WORKER_MODEL:=claude-sonnet-4-6}"
: "${PLANNER_MODEL:=claude-opus-4-7}"

export WORKER_MODEL PLANNER_MODEL
