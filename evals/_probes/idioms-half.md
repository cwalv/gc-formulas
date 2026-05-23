# Choreography Idioms (Bead-Graph Templates) — half-library variant

(Probe variant of `docs/choreography-idioms.md` that exposes only the
two idioms relevant to the current bench: fire-and-forget fan-out and
synthesis-pipeline. Used to test whether curated libraries enable
correct per-case routing by the architect — bias-bearing idioms like
two-phase-commit, critique-loop, gatekeeper are excluded.)

## The Core Idioms (Templates)

### 1. The "Fire-and-Forget Fan-Out" (The Map)
* **The Shape:** $N$ independent leaf beads, no parent or coordinator.
* **The Use Case:** Independent, non-colliding work where each leaf
  operates on its own file or own slice of state. No shared write
  targets across leaves.
* **Why it works:** It scales linearly without complex merge logic. The
  leaves are the entire graph.

### 2. The "Synthesis Pipeline" (Map-then-Reduce)
* **The Shape:** $N$ independent Child beads → 1 Synthesis bead.
* **The Use Case:** Parallel work that requires a unified final step,
  typically because the children share a write target (a single registry,
  a single enum, a single index file) that needs to be reconciled after
  the leaves finish.
* **Why it works:** The leaves stay independent; the synthesis bead
  centralizes shared-state writes so the leaves don't race.

## Avoiding the DSL Trap

* No `try/catch/finally`, no `while` loops, no runtime state machine.
* The orchestrator is a dumb database enforcing `Depends On`.
