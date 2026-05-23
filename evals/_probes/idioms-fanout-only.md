# Choreography Idioms (Bead-Graph Templates) — fanout-only variant

(Probe variant of `docs/choreography-idioms.md` that exposes only the
fire-and-forget fan-out idiom to the planner. Used to test whether
sonnet's "add a coordinator" bias on validator-suite is taught by the
full library's hierarchical examples, or intrinsic to the model.)

## The Core Idiom (Template)

### 1. The "Fire-and-Forget Fan-Out" (The Map)
* **The Shape:** $N$ independent leaf beads.
* **The Use Case:** Independent, non-colliding work. Each leaf operates
  on its own file or own slice of state.
* **Why it works:** It scales linearly without complex merge logic. There
  is no parent bead, no coordinator bead, no synthesis bead. The leaves
  are the entire graph.

## Avoiding the DSL Trap

* No `try/catch/finally`, no `while` loops, no runtime state machine.
* The orchestrator is a dumb database enforcing `Depends On`. The
  intelligence of *when* to move forward is handled by the agents.
