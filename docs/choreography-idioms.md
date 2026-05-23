# Choreography Idioms (Bead-Graph Templates)

In a "Beads" choreography architecture, we abandon rigid workflow runtimes (TOML/YAML state machines) in favor of simple graph primitives (`Spawn`, `Depend`, `Claim`, `Annotate`, `Close`). 

To prevent the Tech Lead (TL) agent from having to reinvent graph structures for every task, we rely on **Idioms** (Bead-Graph Templates). These are not rigid DSLs with `try/finally` loops; they are purely structural shapes that leverage the graph to coordinate work.

## The Lifecycle Phases

The architecture separates the *What* from the *How* to ensure expensive, high-context models aren't wasted on boilerplate, and fast, narrow models aren't making architectural decisions.

### Phase A: Goal Alignment (The "What/Why")
- **The Medium:** Markdown design documents, Architecture Decision Records (ADRs). No beads exist yet.
- **The Persona (Architect/Human):** High-context models (Opus/o1) or human operators. They debate value, probe edge cases, and write the spec.
- **The Handoff:** A finalized, approved design document.

### Phase B: Decomposition (The "How")
- **The Medium:** Translating the prose design doc into a bespoke dependency graph of Epics and Tasks (Beads).
- **The Persona (Tech Lead / Foreman):** Medium-context models (Sonnet) focused on systems engineering.
- **The Handoff:** A fully populated, dependency-linked graph of `Open` or `Ready` beads representing the project plan.

### Phase C: Execution & "Pouring" (The "Do")
- **The Medium:** Autonomous execution of individual beads, using "Pouring" to instantiate standard sub-graphs.
- **The Persona (Universal Worker):** Fast, narrow models (Sonnet/Haiku). They only see their specific bead.
- **The Escalation Path:** If a Worker hits ambiguity, they do not block or guess. They ask the TL. The TL acts as a firewall: it resolves minor technical choices locally, and only escalates back to Phase A if a discovery violates the "50% Rework Rule" (i.e., painting the system into a corner).

## The Core Idioms (Templates)

When a TL or Worker needs to execute a standard operating procedure in Phase C, they "Pour" one of these idioms. Pouring simply means executing the `bd create` and `bd dep add` commands to construct these shapes.

### 1. The "Fire-and-Forget Fan-Out" (The Map)
* **The Shape:** A single Parent bead depends on $N$ independent Child beads.
* **The Use Case:** Independent, non-colliding work. "Add license headers to these 100 files."
* **Why it works:** It scales linearly without complex merge logic. The TL dynamically decides $N$. If one of the 100 files requires special handling, the worker handling it coordinates with the TL without blocking the other 99.

### 2. The "Synthesis Pipeline" (The Map-Reduce)
* **The Shape:** $N$ independent Child beads $\rightarrow$ 1 Synthesis bead.
* **The Use Case:** Parallel research or generation that requires a unified final output. "Read these 4 different logs and write a unified post-mortem."
* **Why it works:** It circumvents attention decay and context-window physics. You let $N$ workers read 100k tokens each and output a 1k token summary. The Synthesis worker only reads $N \times 1k$ tokens to make a decision.

### 3. The "Critique Loop" (The Evaluator-Optimizer)
* **The Shape:** `Implement` $\rightarrow$ `Critique`. 
* **The Loop Mechanism:** The loop happens via the *agent's instructions*, not a runtime DSL. The Critique agent's prompt says: *"If the implementation fails, do not write the fix yourself. Create a new `Implement` bead with your feedback, make yourself depend on it, and close your current lock."*
* **The Use Case:** High-complexity tasks where the first attempt is likely wrong (e.g., "Fix this race condition").
* **Why it works:** It forces a fresh context window to evaluate the code, breaking the model out of tunnel vision. It avoids rigid `retry=3` constraints because the agent determines when the loop is satisfied.

### 4. The "Two-Phase Commit" (Spec-Driven / TDD)
* **The Shape:** `Define Contract` $\rightarrow$ `Implement against Contract`. 
* **The Use Case:** API design, Test-Driven Development, or any scenario where the "What" must be locked before the "How".
* **Why it works:** It enforces cognitive discipline through graph constraints. Worker A writes the unit tests and closes the bead. Worker B claims the implementation bead and is physically blocked from changing the tests; it must make them pass.

### 5. The "Gatekeeper" (Consensus / Voting)
* **The Shape:** `Implement` $\rightarrow$ [`Review A`, `Review B`] $\rightarrow$ `Merge`. (Merge depends on both reviews).
* **The Use Case:** High-risk actions (modifying security policies, dropping tables).
* **Why it works:** It provides statistical confidence. You are explicitly paying for redundant compute (running two independent reviews in parallel) to ensure a single model hallucination doesn't break production.

## Avoiding the DSL Trap

These idioms deliberately omit features found in workflow runtimes:
* **No `try/catch/finally`:** If a bead fails, the TL agent (or the worker) observes the failure and uses reasoning to decide the next graph mutation.
* **No explicit `while` loops:** Loops are generated organically by agents spawning new beads, extending the graph dynamically rather than looping over a static node.
* **No runtime state machine:** The orchestrator is a dumb database enforcing `Depends On`. The intelligence of *when* to move forward is handled by the agents.