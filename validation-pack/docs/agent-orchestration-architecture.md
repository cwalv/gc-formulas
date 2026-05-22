# Agent orchestration architecture (foundations position, 2026-05-20)

Where foundations has landed on multi-agent orchestration architecture after exploring gascity's graph.v2, NTM's pipeline + worktree + Agent Mail, and the Flywheel cohort. Captures the conclusion, the supporting evidence, the proposed experiment, and pre-registered expectations so the experiment is falsifiable.

## TL;DR

- **Workflow runtimes age badly** (graph.v2 in gascity, pipeline in NTM, TOML formula DSLs broadly) — the **simple-agent-loop principle** inverts on them: better models do worse with prescriptive workflow contracts than without. (See Anthropic's [Building Effective Agents](https://www.anthropic.com/research/building-effective-agents) for the canonical framing; lineage includes ReAct, Cherny's Claude Code design, and others.)
- **Empirical**: mol-weave-work didn't complete a 3-step trivial scenario in 10 minutes wall-clock, even after substrate optimizations (auto-export disabled, etc.). Per-step gaps were ~2m 25s of pure substrate overhead.
- **Target architecture**: **model-as-orchestrator with substrate-coordinated personas**. No workflow runtime. Foreman + treehugger + implementer roles, coordinating via the bead graph (Agent Mail peripheral/optional).
- **What gets dropped from gascity**: formula compiler, TOML DSL (`gc.kind`, `gc.continuation_group`, `gc.session_affinity`, `gc.output_json_schema`), control-bead processing (retry-eval, scope-check, workflow-finalize), separate Mayor/Deacon escalation layer.
- **What gets kept**: bead graph + workweaves + gc sling + named pools + supervisor + refinery + Agent Mail (as one optional coordination channel; not load-bearing).
- **Next step**: small empirical experiment on the canonical fake change (append `hello` to `fixture/hello.txt`), with pre-registered expectations below.

## gc CLI verbs used in this doc

- `gc prime <persona>` — emit the persona's system prompt to stdout
- `gc hook` — worker-side primitive for receiving routed work (called inside the worker's loop to pull the next dispatched bead)
- `gc runtime drain-ack` — worker signals "no more work in my pool; safe to retire"

## Context

Background reading, in approximate chronological order:

- `./orchestration-conversation.md` — the OOB conversation that mapped the agent-orchestration landscape (Flywheel, Intent, NTM, gascity, Swamp), introduced the form-matches-consumer framing, and surfaced the "two projects built workflow runtimes is weaker than two confirmations" reading.
- `./gascity-focus-areas.md` — the four focus areas (worker-contract crystallization, schema enforcement, reverse derivation, protocol evals) and their implied direction.
- `./ntm-multi-agent-tutorial.md` — manual NTM walkthrough with observations and 4 candidate upstream bug reports.
- This session: the deep-dive into NTM internals (pipeline, worktree, Agent Mail, personas), the persona decomposition synthesis, and the architectural-vs-implementation cost analysis.

Related foundations beads:
- `fo-ybvmi` (retry materialization drops body metadata) — symptom of the workflow-runtime contract surface.
- `fo-session-affinity-not-enforced` — contract declared in worker prompt, not enforced by substrate.
- `fo-rgccn` (phase 3 testrig cleanup) — the mol-weave-work test harness that surfaced the failure modes.

## Conclusion

**Model-as-orchestrator with substrate-coordinated personas.** The bead graph is the durable coordination state. Three named agent roles (foreman, treehugger, implementer) operate over the substrate via typed CLI verbs and prose contracts. No workflow runtime sits between them.

Layered picture:

| Layer | Provided by | Consumer |
|---|---|---|
| Substrate (durable state) | bead graph (bd or br), workweaves | Everyone reads/writes via typed CLI |
| Coordination channel | bead-graph mutations (claim, close, set `gc.routed_to`) | Anything that polls `bd ready` |
| Agent contract | AGENTS.md + persona system prompts | Each agent on first turn |
| Workflow shape | Prose in skill + agents' personas | The foreman, who orchestrates |
| Escalation | Same primitive as dispatch (foreman) | Same LLM that handled happy path |
| Mail | Agent Mail (optional, peripheral) | Ad-hoc coordination / human overseer |
| Refinery | named pool (gascity) or treehugger persona (NTM-shape) | Landing gate |

Nothing here is workflow-runtime-shaped. The foreman is an LLM agent reading the bead graph and dispatching; not a Go function walking a state machine.

## Why this and not workflow-runtime

### Architectural argument (the simple-agent-loop principle applied to runtime)

- **Content over runtime**: agent→agent = prose, agent→deterministic-runtime = typed config. Workflow YAML/TOML is typed config, but the runtime that consumes it has to interpret it AND coordinate with agents whose output is prose. Two boundaries to keep aligned; both leak.
- **Better models do worse with cages**: a workflow runtime constrains the agent to a pre-decided decomposition. As model capability grows, the most valuable thing the model can do is exactly the part the runtime takes away (problem decomposition, ordering, retry judgment). The simple-agent-loop principle (Anthropic's *Building Effective Agents*; Cherny's Claude Code design; ReAct lineage) survives on prompt-as-protocol; it inverts on runtime-as-orchestrator.
- **Form should match consumer** — the sharper formulation lives in [`gascity-focus-areas.md`](./gascity-focus-areas.md): **"opinionated UI for humans, content for agents."** AGENTS.md is read by an agent (prose works). Per-step `gc.outcome` metadata is read by the substrate (typed works). Pipeline scrollback regex is parsed by the runtime against an LLM's prose response (form mismatch — fragile). See "Mail's place" in v2 refinements for an application of this principle to comms.

### Empirical argument (mol-weave-work failure)

We ran mol-weave-work on the canonical fake-change scenario this session. Failure modes observed:

- **bd write amplification** (~4s/write with auto-export on, ~650ms with it off) — accumulates fast across many control beads.
- **Substrate control-bead processing** taking ~75s per retry-eval — the dispatcher walks too much state per decision.
- **Session-spawn cost per step** (~30-60s each Claude Code session startup) — the architecture spawns a fresh worker per step.
- **Per-step gap of ~2m 25s** observed; body of the work was a few seconds; the substrate overhead between steps was the wall clock.
- **Result**: 22 minutes for what should have been 2-3 minutes; on the specific run described here, mol-weave-work didn't complete in 10 minutes even with auto-export off — single data point, not a controlled measurement.

These aren't tuning bugs — they're structural to the "encode workflow as bead graph the runtime walks" model. Many beads → many writes → many session spawns. Cost compounds with workflow size.

### The "two projects built it" signal is weaker than it looks

- Both gascity and NTM built workflow runtimes (graph.v2; pipeline).
- Investigation of NTM (CONTRIBUTING.md + 2765-issue jsonl): all pipeline-related issues filed by maintainer's own ubuntu/agents, no external contributors. No demand signal from users — pipeline reflects the maintainer's call.
- Both maintainers are sophisticated individuals influenced by similar prior art (Temporal, CI/CD, LangGraph). Convergence likely reflects shared intellectual heritage, not validation by demand.

### What's left to drop or stop building

- Formula compiler (gascity's parallel one at `internal/formula/`)
- The TOML DSL surface: `[steps.retry]`, `[steps.on_complete]`, `gc.kind`, `gc.session_affinity`, `gc.continuation_group`, `gc.output_json_schema`, etc.
- Control-bead processing in `internal/dispatch/` (retry-eval, scope-check, workflow-finalize, fanout)
- `DecorateGraphWorkflowRecipe` and per-step routing decoration
- Wisp lifecycle TTL tied to `gc.continuation_group` semantics
- Schema enforcement infrastructure for workflow contracts
- The separate Mayor/Deacon escalation layer — one LLM (the foreman) handles happy and unhappy paths

## The persona decomposition

Three roles. Each is an LLM agent. Coordination is via the substrate (bead mutations); mail is optional/peripheral.

### Implementer

- **Job**: do the actual work — write code, edit files, run tests, commit changes.
- **Persona**: existing NTM personas work (architect, implementer, reviewer, tester, documenter — `internal/persona/persona.go:524-613`) or custom personas per project.
- **Contract surface**: AGENTS.md (workflow conventions) + persona system prompt (role lens).
- **Substrate interaction**:
  - `br update --claim` to claim a bead
  - work in isolation (worktree if needed)
  - `br close <id> --reason="..."` when done — typed close as the "I'm done" signal
- **No workflow contract**: doesn't need to know about retry-eval, continuation groups, or `gc.outcome`. Just claim, work, close.

### Treehugger (refinery / merge gate)

- **Job**: handle landing — observe beads closed by implementers, attempt merge/integration, ship on success or reject back.
- **Persona**: custom (no built-in NTM persona maps cleanly; create one).
- **Contract surface**: AGENTS.md + persona system prompt focused on merge safety, conflict resolution, refinery discipline (mutex pattern, atomic land semantics).
- **Substrate interaction**:
  - poll `br ready` filtered to `gc.routed_to=refinery` (or equivalent pool)
  - take the rig-merge-mutex bead
  - run merge; on conflict, reject by re-opening the work bead with a `notes` update; on success, close the merge bead
- **Scope**: deliberately late-binding. Doesn't watch edits; only acts at land time. Worktree isolation handles edit-time separation.

### Foreman (dispatcher + escalation)

- **Job**: read the bead graph, decide what should happen next, dispatch work, evaluate failures, escalate to operator when judgment is exhausted.
- **Persona**: custom (no built-in). System prompt focused on bead-graph reading, dispatch decisions, retry policy as judgment (not as rule), unhappy-path remediation.
- **Contract surface**: AGENTS.md + persona system prompt + skill prose describing the workflow shape (NOT YAML).
- **Substrate interaction**:
  - poll `br ready` for unblocked work
  - sling beads to implementer pool via `gc sling` (or set `gc.routed_to` directly)
  - watch for closes; on close, evaluate result (read commit, read notes, look at git diff) and decide if scope is satisfied
  - on failure: read context, decide retry / reroute / abandon / escalate
- **No separate retry-eval / scope-check beads**: the foreman is the retry-evaluator and scope-checker. Same LLM that dispatched is the one that evaluates.
- **Could be code-with-LLM-escalation**: for routine cases (load balancing, sequencing), deterministic logic; LLM judgment only when assignment is non-obvious or remediation is required. Hybrid mode is probably the right place to land cost-wise.

### Coordination flow (happy path)

1. Operator creates a feature bead with `bd create`
2. Foreman polling sees it, decides which implementer (by persona, by load, by file-touch prediction)
3. Foreman sets `gc.routed_to` on the bead
4. Implementer claims via `br update --claim`, works in worktree, commits
5. Implementer closes work bead with `br close --reason="merged-ready"` and sets `gc.routed_to=refinery` on a follow-up landing bead
6. Treehugger sees the landing bead, takes mutex, attempts merge
7. On success: treehugger closes landing bead with `reason="landed"`; foreman sees scope satisfied
8. On conflict: treehugger re-opens or annotates the work bead with notes; foreman sees and decides what to do

### Coordination flow (unhappy path)

1. Implementer encounters a failure (test fails, can't proceed)
2. Implementer closes bead with structured notes (typed side effect) describing what happened
3. Foreman reads the closed bead's notes and the diff
4. Foreman decides: retry-with-modification, reroute to different implementer (persona mismatch?), break work into smaller pieces, escalate to operator
5. Operator escalation: mail to HumanOverseer (or any structured channel)

The unhappy path uses the SAME primitive as the happy path: an LLM (the foreman) reading bead state and making decisions. No separate Mayor/Deacon, no retry-eval bead, no scope-check semantics. The foreman is the workflow runtime, in prose.

## What gets kept and what gets dropped

| Component | Kept? | Notes |
|---|---|---|
| `bd` / `br` bead graph | ✓ | Substrate; durable; coordination channel |
| `bd pour` (formula instantiation) | ✓ for templates that just create bead subgraphs | Use minimally — beads-graph generator only, no workflow runtime |
| Formulas with `[steps.retry]`, `[steps.parallel]`, etc. | ✗ | Workflow-runtime semantics; replace with foreman judgment |
| `gc.kind` (body/scope/cleanup/retry-eval) | ✗ | Encode in prose, not metadata |
| `gc.continuation_group` | ✗ | Session affinity via foreman dispatch decisions |
| `gc.session_affinity` | ✗ | Same |
| `gc.output_json_schema` | ✗ | Typed side effects via CLI commands (`br update --metadata`), not declared-and-unenforced schema |
| `gc.routed_to` (per-bead) | ✓ | Mechanical routing; content-driven; observable from work-query script |
| Named pools in city.toml | ✓ | Provider-abstract addressing; supervisor sizing |
| `gc sling` | ✓ | Routing primitive |
| Supervisor + auto-restart | ✓ | Platform-level reconciler; long-lived agent sessions |
| Refinery (named pool) / treehugger (persona) | ✓ | Landing gate; the merge mutex pattern |
| Workweaves (rwv) | ✓ | Multi-repo isolation; per-bead worktrees when needed |
| Agent Mail | ✓ optional | Peripheral coordination channel; not load-bearing for workflow |
| NTM personas (architect, implementer, reviewer, ...) | ✓ | Role definitions with system prompts |
| NTM profiles (backend-team, full-stack, ...) | ✓ | Reusable spawn shapes |
| NTM pipeline (workflow runtime) | ✗ | Same category as graph.v2 — workflow-as-runtime ages badly |
| NTM `assign --watch` | ✓ | Substrate-driven dispatch loop; aligns with model-as-orchestrator |
| Mayor / Deacon (separate escalation agents) | ✗ | Foreman handles happy AND unhappy paths |
| Control-bead processing in dispatcher | ✗ | No control beads materialized |
| Schema enforcement infrastructure | ✗ | Typed CLI verbs replace declared schemas |
| Workflow contract in prompts (gc.outcome, etc.) | ✗ | Use typed side effects (br close --reason, br update --metadata) instead |

## The experiment

### Target

Append the literal line `hello` to `fixture/hello.txt` in `~/ntm_Dev/test/` (or another fresh single-repo target). Same canonical fake change used by scenario_01 and the NTM tutorial. Repeatable; observable; small enough to run end-to-end in a session.

### Setup

- Pre-register one custom persona for `foreman` and one for `treehugger`. Implementer can use built-in NTM `implementer` persona.
- AGENTS.md customized for this workflow: the workflow shape is described in prose, including the substrate verbs each role uses (`br ready`, `br update --claim`, `br close --reason`, etc.).
- Substrate: foundations rig's bd (or a fresh bd instance for the test repo).
- Agent Mail running, but only used for HumanOverseer escalation if needed — NOT for workflow coordination.

### Workflow

1. Operator creates a single work bead: "Append 'hello' to fixture/hello.txt"
2. Foreman session polls, sees the bead, dispatches to implementer (sets `gc.routed_to=implementer` or slings to the implementer pool)
3. Implementer claims, makes the change (echo hello >> ..., git add, git commit), closes with structured notes
4. Foreman sees close, evaluates (reads diff, confirms expected file state), creates a follow-up landing bead routed to treehugger
5. Treehugger merges to main, closes the landing bead
6. Foreman closes the scope; operator sees the chain landed

### What we measure

- **Wall-clock**: full run from operator-creates-bead to landed-on-main
- **Substrate writes**: count of `bd` mutations (creates, updates, closes) across the run
- **Session spawns**: count of fresh agent CLI launches
- **LLM calls per role**: foreman invocations, implementer invocations, treehugger invocations
- **Operator interventions**: how many times the operator had to step in
- **Observability**: can we reconstruct the workflow from `bd show` outputs alone?

### Comparison baseline

Same target run via:
- (already done) mol-weave-work / graph.v2 — did not complete in 10 min
- (optional) `ntm pipeline run` against a hand-authored workflow YAML — interesting if we want to compare runtime-shaped against substrate-shaped

The mol-weave-work data is the primary baseline since we already have it.

## Expectations (pre-registered)

These are what we expect IF the architecture is right. Falsifiable.

### Performance

- **Wall-clock**: under 3 minutes end-to-end for the trivial change. Compares against mol-weave-work's failure to complete in 10 minutes.
- **Substrate writes**: under 20 (one per state transition: bead create, claim, close, status changes). Compares against mol-weave-work's hundreds of writes for control-bead processing.
- **Session spawns**: 3 or fewer (one per persona, assuming warm sessions). Compares against mol-weave-work's ~6 (one per step).
- **No per-step gaps of minutes**. Gaps should be seconds (LLM latency) not minutes (substrate overhead).

### Behavior

- The workflow shape is in **prose** (AGENTS.md + persona prompts + skill). Nowhere is there a TOML file declaring steps or dependencies for the runtime.
- The bead graph at any point should be **trivially observable**: `bd show <work-bead>` shows status, assignee, recent updates. No materialized control beads to interpret.
- Failures should be handled by the foreman without a separate escalation primitive. If the implementer's commit doesn't pass review, the foreman re-routes — same LLM, same primitive.
- The operator should be able to **reconstruct the workflow** from bead state alone after the fact.

### What we'd consider a failure of the ARCHITECTURE (not the implementation)

- The agents getting confused about coordination without an explicit workflow contract — i.e., they don't know what to do next based on bead state alone
- The foreman making consistently wrong dispatch decisions — i.e., LLM judgment isn't actually sufficient for the dispatch role
- Bead-graph polling causing race conditions or coordination drift that a workflow runtime would have caught
- Costs unexpectedly compounding (we said this wouldn't happen per the cost analysis; if it does, the analysis was wrong)
- Inability to recover from a killed foreman — i.e., the substrate doesn't actually contain enough state to resume

### What we'd consider a failure of the IMPLEMENTATION (architecture might still be right)

- Specific NTM/gascity primitives missing the affordances we need (write a bug, work around)
- Persona prompts not focused enough (iterate on the prompts)
- AGENTS.md missing critical context (add it)
- Agent Mail downtime affecting things we thought were peripheral (move them off mail)

### What we're NOT trying to validate in v1

- Multi-repo workflows (rwv-workweave-shaped changes spanning multiple repos)
- Vendor diversity (different reviewer model vs implementer model)
- The conflict-aware-scheduling layer (foreman predicting file conflicts from bead descriptions and adding depends_on edges)
- High-throughput concurrent work (multiple implementers on overlapping beads)
- Long-running pipelines (days/weeks)

These are extensions worth exploring after v1 lands.

## Open questions

- **Foreman as code-with-escalation vs pure-LLM**: hybrid mode might be much cheaper. When is the LLM judgment actually needed vs when does deterministic logic suffice?
- **Treehugger as code-with-escalation**: same question. Merge math is mostly mechanical; LLM judgment for the gray-zone (semantic conflicts) only.
- **How much of AGENTS.md should be project-customized vs persona-customized**: project conventions live in AGENTS.md; role-specific behavior in personas. Unclear where to draw the line for things like "how to commit" — is that a project convention or a persona behavior?
- **What happens when multiple foremen exist** (e.g., one per project, all reading the same rig's bd): coordination via substrate works in theory; need to think through whether they need an explicit "I'm in charge of these beads" claim mechanism.
- **Conflict-aware-scheduling layer**: worth building? Probably not in v1; the worktree-isolation-plus-late-merge model handles most cases. Revisit if conflicts at merge time become a frequent failure mode.
- **gascity's keep list vs NTM's keep list**: both have useful primitives (gascity's named-pool abstraction, NTM's personas + supervisor + Agent Mail). Mixing them is possible but adds operational complexity. v1 should pick one and run; v2 might federate.

## v1 results (2026-05-20)

The experiment ran. Spawned three sessions (`test--foreman`, `test--treehugger`, `test--implementer`), each with a persona-defined Claude pane. Operator created a feature bead (`tt-j7i` — append `hello` to `fixture/hello.txt`) and nudged the foreman to start its loop.

### What worked

- **End-to-end substrate-coordinated workflow ran**: bead created → foreman polled and dispatched → implementer claimed and worked → bead closed with typed `reason=completed` + structured notes. The foreman observed the closure on its next poll cycle.
- **LLM judgment filled persona gaps**: the foreman discovered on its own that mail delivery isn't sufficient to wake an idle implementer — the model decided to use `ntm send` (tmux send-keys) as the wake mechanism, even though that wasn't in its persona prompt. This is exactly the gap-filling the architecture is designed to exploit.
- **Foreman correctly skipped a redundant follow-up**: the implementer recognized that `fixture/hello.txt` already had the expected 4 lines (from an earlier manual tutorial run that left commit `77df718` on `main`) and closed the bead with that explanation. The foreman read the close-reason notes, cross-referenced with `git log`, and decided **not to create a landing bead for the treehugger** because there was nothing to merge. A workflow runtime would have mechanically dispatched the landing step. The model exercising judgment skipped redundant work.
- **CLI flag drift was handled by reading help**: both agents hit minor CLI surprises (`bd update --metadata` vs `--set-metadata`; `bd close --notes` vs `-r`) and recovered by reading `--help`. No fragile parsing layer needed.
- **Substrate as durable workflow state**: every meaningful step was a typed substrate mutation (`bd update --set-metadata gc.routed_to=...`, `bd close --reason "..."`). No parallel state store. The bead graph IS the workflow state.

### What surprised us

- **MCP push does NOT wake idle Claude Code sessions** (empirically confirmed): sent a message from OliveDuck (foreman identity) to SandyDove (implementer identity); the message was delivered server-side (visible in SandyDove's inbox), but the implementer pane stayed idle. Claude Code does not surface MCP-server notifications as next-turn input. **The architectural implication is significant**: mail can't be the wake-up channel; agents need to be poked via something Claude Code DOES treat as input (tmux send-keys, or the next-turn-after-tool-call).
- **`bd` has a native `--watch` flag on `list` and `show`** (fsnotify-based, per `cmd/bd/show_watch_test.go`). We didn't know this when we wrote `foreman-poll.py`. The script's polling-with-backoff could potentially be replaced by `bd list --watch --metadata-field gc.routed_to=<role>` for true event-driven wake-up. Worth testing for v2.
- **NTM's supervisor fights non-NTM-managed mail servers**: NTM has a supervisor (`internal/supervisor/supervisor.go:707-713`) that auto-spawns `am serve-http --no-auth` on port 8765 if it doesn't see "its" server. This collided with our `mcp-agent-mail` running with the localhost-unauth bypass we needed. Resolution: `~/.config/ntm/config.toml` with `[agent_mail] supervisor_enabled = false`.
- **`mcp-agent-mail` (upstream Dicklesworthstone) requires `HTTP_ALLOW_LOCALHOST_UNAUTHENTICATED=true` for mutating tools** — RBAC defaults anonymous callers to `reader`; `ensure_project` and `register_agent` require `writer`. Bearer-token-only doesn't grant a role; the localhost bypass does. Also: the name-validation ("must be adjective+noun") rejects the canonical `HumanOverseer` identity, breaking NTM's overseer flow.
- **MCP server adds overhead with no compensating value** in this configuration: with push not waking agents, the MCP server is just a daemon process maintaining RBAC + auth + connection state for operations a CLI subprocess could handle directly. Beads' design (no daemon, just CLI → SQLite/Dolt) is structurally simpler.

### Refinements committed during the run

- `foreman-poll.py` — exponential backoff (60s → 120s → 240s → 480s → 900s cap), state in `.ntm/foreman-backoff`, reset to floor on event return. Fixed a bug where it tried to use `bd list --since` (doesn't exist) — now filters by `closed_at` client-side.
- Persona update (`personas.toml`) — explains the polling tool can run long (set generous Bash tool timeout), adds an "idle-survey" instruction for empty/`_note` returns.
- `bd init --force --prefix=tt` in `~/ntm_Dev/test/` — isolated test bd substrate so agents don't accidentally see foundations beads.
- NTM mail-supervisor opt-out — `~/.config/ntm/config.toml` with `[agent_mail] supervisor_enabled = false`.

### Architectural framing corrections

- **"Local / single-user" was doing no real work in the cost argument** — the real distinction is stateful-daemon-with-persistent-MCP-connection vs stateless-CLI-invocations. CLIs can do HTTP, cross-machine, anything; the architectural commitment is whether the agent maintains a persistent connection to a stateful server.
- **"Yegge argument" was sloppy attribution** — the principle we keep citing is the simple-agent-loop argument, articulated more directly by Anthropic's *Building Effective Agents*, Cherny's Claude Code design, and the ReAct paper lineage. References cleaned up throughout this doc.

### Verdict

The v1 architecture (substrate-coordinated personas, foreman as model-as-orchestrator, no workflow runtime) works as designed. The model genuinely fills gaps in the prose contract — not as a heroic save, but as ordinary judgment. The substrate carries durable state; CLI invocations carry mutations; LLM judgment carries decisions.

Where the test was a softball (idempotent state already present, single bead, single deviation handled gracefully), we should still take the lesson seriously: the architecture asks the model to do exactly what models are good at, and the substrate to do exactly what substrates are good at. Both sides held up.

## v2 design sketch: formulas as workflow-shape templates

A natural next step that survives the simple-agent-loop critique (we think): use formulas not as workflow runtimes, but as **bead-graph generators** that pre-materialize phase beads at pour time. The foreman shrinks to a supervisor, not a dispatcher.

### The shape

A formula declares phase beads with `depends_on` edges and `gc.routed_to` metadata. Pour materializes them:

- `work-implement` — `gc.routed_to=implementer`, body = the task description
- `work-land` — `depends_on=work-implement`, `gc.routed_to=treehugger`, body = the merge task
- `work-scope` — `depends_on=work-land`, `gc.routed_to=foreman`, body = "close the scope when all phases land"

Then **nothing dispatches**. Each role's poll script picks up its `gc.routed_to=<role>` beads as they become ready (i.e., as their `depends_on` predecessors close). Phase ordering happens via the dependency graph; `br ready` naturally respects it.

### The foreman's role shrinks

- (Optionally) pour the formula when an epic is created (or operator/upstream pours; foreman doesn't have to)
- Handle the scope-close bead at the end
- Handle exceptions when phases fail (a phase closes with `blocked` / `merge-conflict` → foreman judgment: re-pour with revised approach, add a corrective bead, escalate to operator)

That's **foreman-as-supervisor**, not foreman-as-dispatcher. Most of the dispatching is replaced by the substrate's natural `br ready` filtering. The foreman wakes only when something needs judgment.

### Layered context (corrected from v1)

| Layer | Content | Generates / triggers | Read by |
|---|---|---|---|
| `AGENTS.md` | project conventions (commit style, banned ops) | nothing — read at session start | all agents |
| persona prompt | role expertise (treehugger ↔ repoweave + git semantics; implementer ↔ language patterns; foreman ↔ workflow vocabulary) | nothing — read at session start | the role's CLI |
| formula (markdown / TOML) | phase shape + routing metadata | beads with `depends_on` + `gc.routed_to` on pour | foreman (when routing); operator (when authoring) |
| poured beads | task descriptions per phase | claimed by role workers via `br ready` filter | the claiming agent |
| bead description | instance-specific work (files, branches, constraints) | the agent's actual work | the claiming agent |

**Role context is durable expertise; bead context is the assignment.** Treehugger doesn't need to learn repoweave from each merge bead — that lives in its persona. The bead carries only what's specific to this merge (files, branches, target).

### Litmus test: does a formula violate the simple-agent-loop principle?

> **Is the bead's body a *task description* (what to do, what success looks like), or is it *protocol instructions* (how to be a state machine the runtime is walking)?**

- **Task** ✓ — "Append `hello` to fixture/hello.txt. Branch: feat/hello. Done when committed." The agent reads it like any other bead.
- **Protocol** ✗ — "Phase 2 of mol-weave-work. Check the gc.outcome of upstream bead bd-123. If pass and gc.kind=body, route per continuation_group..."

The first is what a competent operator would write by hand. The second is contract-as-cage.

**Corollary**: `depends_on` edges are *ordering guidance*, not *runtime policy*. The model can:
- Close a phase as `superseded` if the work was already done elsewhere (foreman judgment)
- Add an unplanned bead (operator/foreman judgment)
- Decide a phase doesn't apply this time (close with `skipped`, notes explain why)

The substrate doesn't enforce the order beyond "deps must be satisfied for `br ready` to surface a bead." That's mechanical and fine — it's how the bead substrate already works for any DAG of work.

### What the formula must NOT do

If you find yourself wanting any of these in a formula, you've crossed back to runtime-as-orchestrator territory:

- Retry policy ("retry phase 2 up to 3 times")
- Schema for inter-phase output ("phase 1 must produce JSON with key `branch_name`")
- Runtime gates ("phase 3 blocks until phase 2 emits `gc.outcome=pass`")
- Conditionals interpreted by a runtime ("if `${steps.review.output}` contains 'NEEDS_REVISION'...")

Those belong (if anywhere) in the *foreman's persona* — where judgment lives — not in the formula, where the model is supposed to be unconstrained.

### Scheduler vs supervisor: a distinction worth being explicit about

Two concepts that look similar but are architecturally different:

- **Scheduler** (workflow engine) — walks a DAG, decides what runs when, holds state for "which step is next." This is the runtime-as-orchestrator piece. Our principle rejects this *as a separate component* (see "Honest framing" below for the more precise statement — the foreman performs scheduling-shaped work, but as an LLM agent over the substrate, not as a parallel control-plane runtime). The bead DAG + `br ready` filter already does dependency-aware dispatch mechanically; adding a scheduler on top is graph.v2 creep.
- **Supervisor** (platform watchdog) — monitors agents for liveness, stuck detection, doom-loop escalation, autoscaling pool sizes. NOT walking a control graph; just keeping the platform healthy. This is fine — it's the same role NTM's session-monitor or gascity's supervisor plays. Keep it.

Reference comparison: ORC (a similar single-developer agent-orchestration project — see `safethecode/orc`) has both a Scheduler and a Supervisor as separate components. Our principle would keep the Supervisor (and the Decomposer, Router, QA agents — all useful) and drop the Scheduler.

The bead substrate already provides what a Scheduler would: deps satisfied → bead becomes ready → worker's poll picks it up. The graph-walking is mechanical and lives in `br ready`, not in a runtime layer.

### What this buys

- Reusable workflow shapes (formula is named + versioned + auditable)
- Foreman per-feature LLM cost drops (doesn't re-derive the routing graph each time)
- Workflow types are first-class artifacts in the repo (markdown / TOML files), independent of bd's runtime ambition
- No runtime to maintain (no control beads, no executor, no contract surface for workers)

### What this is essentially

This is `bd pour` used without graph.v2's runtime ambition. The pour generates a bead subgraph; that subgraph becomes the workflow state; workers and foreman exercise judgment on it. The whole "compile a formula into a control-bead-laden state machine the dispatcher walks" layer disappears. What remains is the simple, useful version of formulas.

### Open v2 design questions

- **Who pours**: foreman? operator? upstream system that creates the epic? Probably "whoever creates the parent bead with `gc.formula=feature_work` metadata"; foreman pours if needed. Cleanly: the foreman *can* pour on observation, but doesn't *have to*.
- **Formula format**: existing TOML (`mol-docs-refresh.formula.toml`-style)? Pure markdown? Both? Markdown is more model-friendly (model reads as context); TOML is more pour-machine-friendly (`bd pour` parses it). Hybrid (TOML pour-spec with markdown phase descriptions) is probably right.
- **Pour mechanism**: existing `bd pour` works. Question is whether we want a gascity-flavored pour (with metadata stamping) or just plain bd pour. For v2, plain bd pour + post-pour `bd update --set-metadata` to add `gc.routed_to` is the simplest path.
- **Per-role poll scripts**: each role gets its own `<role>-poll.py` (or unified script with `--role` flag), so implementer/treehugger pick up their work on the same wake-up mechanism the foreman uses. v1 only had the foreman poll; v2 generalizes.

## v2 design refinements (continued 2026-05-20)

Subsequent conversation pushed several earlier framings to be more precise. The subsections below refine the v2 sketch above.

### Foreman role distillation

The foreman's job reduces to exactly two responsibilities:

1. **`bd mol wisp` maker** — pick the right formula (i.e., the checklist, which also determines the persona(s)) for incoming work, and wisp it. Never executes beads.
2. **Observer** — watch for off-the-rails: stuck beads, unexpected close reasons, repeated-failure patterns. Intervene by judgment.

That's the whole job. No happy-path dispatch, no per-bead routing, no graph-walking. Everything routine — including known loops — lives elsewhere (formula edges, persona prompts, substrate ticks).

### Two routing modes

| Mode | Mechanism | When |
|---|---|---|
| **Substrate dispatch** (default) | Formula wisps beads with `gc.routed_to=<persona>` baked in + deps; agents poll `bd ready --metadata gc.routed_to=<self>` (or `--watch`); atomic `bd update --claim` handles contention | Formula's happy path |
| **Foreman dispatch** | Foreman reads close events, wisps + routes manually | Exception path, ad-hoc work, cross-formula handoff |

Determinant: **does the routing depend on outcome (foreman) or just on phase (substrate)?** Outcome-conditional routing is the tell for a scheduler creeping into the formula.

The v1 ntm test had no formula so the foreman drove every step — that was the degenerate case, not the steady state. With substrate dispatch, the foreman is uninvolved on the happy path; mail demotes to a communication overlay (clarification, escalation), not the dispatch primitive.

### Mail's place

The principle that governs mail vs bead-ops is one we already have, from [`gascity-focus-areas.md`](./gascity-focus-areas.md):

> **Opinionated UI for humans, content for agents.** Where the artifact is consumed by a human, opinionated UI is great because humans benefit from compression and structure. Where the artifact is consumed by a model, prefer content because the model is more fluent in prose than any DSL. The boundary line is "who's reading this thing."

Applied to comms in this architecture:

- **Mail = opinionated UI over the bead substrate** — inbox, threads, subjects, To/From, web client. Affordances humans benefit from.
- **Direct bead ops (`bd` CLI, agent tools) = content over the same substrate** — typed verbs (`update --claim`, `close --reason`), free-form notes, metadata. The substrate's native vocabulary.

Same data layer (mail in gc is implemented on top of beads); different UX layers.

**Consumer mix → UX layer:**

| Sender → Recipient | Category | UX |
|---|---|---|
| Human → Human | Human comms | Mail |
| Human → Agent | Human-involved | Mail (human side dictates the form) |
| Agent → Human | Human-involved | Mail (human side dictates the form) |
| Agent → Agent | Pure agent coordination | Substrate (bead ops directly) |

The agent-to-agent rule isn't because mail is missing infrastructure — it's because mail is the wrong UX layer when both endpoints are agents. If agent A writes mail to agent B, the message gets encoded in mail vocab and B has to decode back to substrate action. That's a form mismatch — the message could have been direct bead operations.

The phase dimension (pre-plan / execution / troubleshooting) is **orthogonal** to the consumer-mix dimension. A mid-flight operator nudge is still human-involved (mail-appropriate); an end-of-execution agent-to-agent close-signal is still pure agent (substrate-appropriate). The flavor of human involvement (in-the-loop continuous oversight vs escalation at a boundary) doesn't change the UX recommendation — either way there's a human endpoint, so mail.

**Testable invariant**: a mail outage during execution should not break anything. If it does, mail has leaked into a place where the consumers were both agents — wrong-layer for the form. The substrate is sufficient for pure-agent coordination; mail is not on the critical path of execution.

### Formula = multi-agent checklist

Clean distillation: a **skill** is a checklist for one agent (lives in their prompt). A **formula** is the same thing when steps cross agent boundaries — and the bead graph becomes the IPC mechanism because that's how agents share state.

- Single agent end-to-end → skill
- Multiple agents with handoff → formula, materialized as a bead graph

Phases exist precisely where handoff crosses an agent boundary. The formula isn't a workflow DSL; it's a multi-agent checklist. The ambition stops there.

### Formula format, location, versioning

bd already has a formula scheme; we use the vanilla version. From [`beads-ui-prototype/docs/formulas.md`](../../github/cwalv/beads-ui-prototype/docs/formulas.md):

- **Format**: TOML (preferred) or JSON
- **Schema**: `formula`, `description`, `version` (integer), `type` ("workflow"), `[vars.*]`, `[[steps]]` with `id` / `title` / `needs` (step deps)
- **Location precedence**: `.beads/formulas/` (project-level) → `~/.beads/formulas/` (user-level)
- **Versioning**: `version` field in the file

Gascity's implementation is a **superset** — it adds runtime-shaped extensions (`gc.kind`, `gc.continuation_group`, `gc.session_affinity`, `gc.output_json_schema`). Those are exactly what we committed to dropping ("What gets kept and what gets dropped" table above). Gastown's gastownhall-* formulas use gascity's extended surface; we don't.

This resolves several items from "Open v2 design questions" above: format/location/versioning is bd-vanilla; pour mechanism is plain `bd mol wisp` + post-wisp metadata.

Where we still need our own conventions:

- **Routing metadata on poured beads** — vanilla bd has no routing concept; `gc.routed_to` is a gascity invention. Two options:
  - (a) post-wisp `bd update --set-metadata gc.routed_to=<persona>` wrapped in the persona/operator action that pours
  - (b) add a per-step routing field that the wisp stamps automatically

  (a) is simpler and doesn't extend the format. (b) is more declarative (routing co-located with step definition) but requires custom pour logic. Lean (a) for v2 unless (b) earns its keep later.

- **Step-to-bead granularity** — `[[steps]]` becomes beads on wisp. Pick the unit thoughtfully per the multi-agent-checklist principle: a step exists where handoff crosses an agent boundary; otherwise it could be a skill in someone's prompt instead.

- **Who pours** — convention TBD. Candidates: operator on epic creation; foreman as fallback if an epic appears without a pour; upstream automation when defined. The principle is "whoever has the right context for matching epic → formula." Leave as foreman-with-operator-override for v2; refine via experiments.

### Anthropic catalog: pattern coverage

Anthropic's *Building Effective Agents* catalogs five workflow patterns plus the agent loop. Mapping each:

| Pattern | Mapping | Expressible? |
|---|---|---|
| **Prompt chaining** | Formula = bead sequence with deps; gates = typed close-reasons | Yes — core fit |
| **Routing** | Foreman classifies, sets `gc.routed_to`, mails | Yes |
| **Parallelization (sectioning)** | Foreman wisps N independent beads; workers atomic-claim; join bead `--depends-on` all | Yes |
| **Parallelization (voting)** | N beads with same description; foreman tallies outcomes | Yes |
| **Orchestrator-workers** | Foreman + implementer + treehugger | Yes — primary pattern |
| **Evaluator-optimizer** | One bead, hooked↔open lifecycle, routing flips between roles | Yes (see iteration model below) |
| **Agent (dynamic loop)** | What every persona already is | Yes — building block |

None inexpressible. Our architecture is **prompt-chaining + orchestrator-workers composed**, with the bead substrate as shared state and the foreman as the "agent" piece. Two of the essay's recommended patterns; not a bespoke design.

### Intra-phase iteration: same-bead ping-pong with hooked lifecycle

For loops where one logical contract requires back-and-forth between roles (evaluator-optimizer is the canonical case), don't materialize a new bead per iteration — that bloats the DAG and abuses `closed`'s terminal semantics. Use the bead lifecycle directly.

bd's state vocabulary (per `beads-ui-prototype/docs/03-concepts.md`): `open` / `hooked` (actively claimed by a worker) / `closed`.

The pattern:

1. Bead created: `status=open`, `gc.routed_to=implementer`
2. Implementer's ready poll surfaces it → `bd update --claim` → `hooked`
3. Implementer works, releases with notes + routing flip:
   `bd update --status=open --metadata gc.routed_to=evaluator --notes="iter 1: did X"`
4. Evaluator's ready poll surfaces it → claim → `hooked`
5. Evaluator decides:
   - **Approved** → `bd close --reason=approved` (terminal)
   - **Needs revision** → `bd update --status=open --metadata gc.routed_to=implementer --notes="iter 1 review: fix A"`
6. Repeat from 2 until evaluator closes terminally.

Lifecycle: `open(routed-X) → hooked → open(routed-Y) → hooked → … → closed`. Same bead, all iterations in its notes, no DAG bloat.

Sharpened verb semantics:

| Verb | Means | When |
|---|---|---|
| `bd close --reason=...` | Terminal exit from this bead | Final outcome of the contract |
| `bd update --status=open` + routing flip | Hand off to next role within the contract | Intra-bead iteration |
| `bd update --claim` (→ `hooked`) | I'm working on this now | Take ownership |

So:
- **Cross-phase handoff** (impl → land) → separate beads, deps, close-with-reason → substrate dispatch
- **Intra-phase iteration** (impl ↔ eval) → single bead, open↔hooked cycling, routing flip → also substrate dispatch

The close-reason vocabulary (`completed-needs-review`, `landed`, `merge-conflict`, …) is for **terminal phase exits between separate beads**. For iterative work within one bead's contract, it's status-flip + routing-flip; no close until done.

Corollary: **bead count = work count, not iteration count.** Iterations are notes on the bead; the bead is the contract.

### Where loops live

| Loop type | Lives in |
|---|---|
| **Inherent** (eval-optimizer, retry-acquire-mutex, post-merge-checks-failed-revert) | Persona prompt at the loop boundary |
| **Predetermined sequence** | Formula edges (substrate-driven via deps) |
| **Novel exception** (blocked on clarification, ambiguous merge intent, cross-formula deadlock) | Foreman judgment |

Inherent loops belong inside the persona that knows the loop. Evaluator's prompt encodes the approved-or-revise decision; foreman never sees iterations, only the terminal close (or an exception evaluator chooses to escalate).

### Honest framing: the foreman IS a scheduler

The earlier "we reject the scheduler" framing was rhetorically sloppy. On the happy path the foreman walks the bead graph, dispatches ready work, observes outcomes, advances state — that's scheduling. The actual principle:

| | Workflow-engine scheduler | Foreman |
|---|---|---|
| Program | Code / declarative DAG | Prose (persona + AGENTS.md + formula) |
| Decisions | Deterministic | LLM judgment |
| Unexpected input | Halts / errors | Improvises |
| Exception path | Separate component | Same engine, same loop |
| State location | **Parallel control-plane structure** | **The substrate itself** |

What we reject is not scheduling but **a parallel control-plane data structure**. ORC has a Scheduler component holding its DAG; graph.v2 / mol-weave-work were heading the same way. We say: don't build that. The bead graph + `bd ready` + foreman judgment already constitute the workflow runtime; bolting on a separate scheduler state object duplicates what the substrate already has.

Tighter: **the foreman is the scheduler, implemented as an LLM agent reading the substrate, with no parallel control-plane state.** Same engine handles routine dispatch *and* exceptions — that's the structural payoff, not the absence of scheduling.

Note that with substrate dispatch (above), most of the "scheduling" inside a formula is done by the substrate itself, not the foreman. The foreman's scheduler-shaped work is narrow: wisp the right formula on incoming work, handle exceptions.

### Terminology: `bd mol wisp` vs `bd mol pour`

Both primitives instantiate a formula into beads. They differ in **persistence**, not weight:

- **`bd mol wisp`** — beads are ephemeral (`Ephemeral=true`, not synced via git, eligible for `bd mol wisp gc` cleanup). Right for run-and-done work where the audit trail has no long-term value: a phase's worth of single-feature work, validation scenarios, operational cycles.
- **`bd mol pour`** — beads are persistent (synced via git, full audit). Right for work the substrate should remember: releases, multi-session feature work, anything you'd want to point back to later.

For v2's ephemeral use cases, `wisp` is the semantic fit. References in this v2 refinements section use `wisp`; v1 prose retains `pour` as historical record.

**Important: formulas need `pour = true` for multi-bead materialization under wisp.** Per bd PR #2187 (commit `c459812e`, 2026-03-02), `bd mol wisp` defaults to **root-only** — only the root issue is created, and the formula's `[[steps]]` are NOT materialized as child beads. To get the full bead DAG under wisp, the formula must declare `pour = true` at the top level. `bd mol pour` always materializes children regardless of this field. Any v2 formula that means "wisp this and produce my checklist of step beads" must include `pour = true`. See [`scenario-01-call-chain.md`](./scenario-01-call-chain.md) for the empirical verification and `beads-ui-prototype/docs/formulas.md` for the canonical field reference.

## Anti-patterns (what to avoid)

Concrete lessons from v1 + sme2 feedback. Each is a pattern we observed or hit during this design pass; surfacing them here so we don't repeat them when implementing.

### File reservations as advisory locks

**Pattern**: layering file-level reservations (paths, with TTL expiry, pre-commit guards) over a substrate that already provides atomic per-bead claim.

**Why bad**: `bd update --claim` is a hard primitive (atomic, substrate-enforced). Wrapping it with soft file-level locks recreates a hard primitive as a soft system. The soft system can disagree with the hard primitive (TTL expires while claim is still valid; pre-commit guard passes while claim was already released) — the disagreements ARE the new failure modes.

**Do instead**: use `bd update --claim` directly. If you need cross-process exclusion at a finer-than-bead granularity, derive it from substrate state, don't layer a parallel coordination mechanism.

**Reference**: Flywheel's Agent Mail ships file reservations; sme2 in `gc-wisp-bj2`.

### CDN-hosted JS in operator UI

**Pattern**: operator-facing web UI that pulls 20+ external scripts (jsdelivr, unpkg, cloudflare, googleapis, ...) at page load.

**Why bad**: works in the typical setup; hostile in air-gapped, corporate-proxy, or slow-network environments. Operator surfaces are exactly the contexts where degraded-network behavior matters — operators may be on VPN, on conference wifi, or actively troubleshooting an outage.

**Do instead**: self-host or vendor critical JS. Treat the operator UI as needing-to-work-when-the-network-is-the-problem.

**Reference**: Agent Mail web UI; sme2 in `gc-wisp-bj2`.

### Template-string-only tests for client-side behavior

**Pattern**: assertions check that rendered template output contains certain function-call substrings (e.g., `expect(html).toContain("window.foo(...)")`).

**Why bad**: assertions pass even when the referenced function isn't defined anywhere — the UI is inert at runtime (TypeError on event handlers) but the test suite is green. Templates render strings; runtime behavior is a different thing.

**Do instead**: client-side behavior needs runtime-evaluating tests (JSDOM, headless browser, or actual browser-driving). String-match on rendered output verifies template structure, not behavior.

**Reference**: Dicklesworthstone/mcp_agent_mail_rust #129 — `window.agentMailAppendAuth(...)` referenced in templates but never defined; tests passed.

### Auto-generated bearer tokens that don't grant the needed role

**Pattern**: a daemon auto-provisions a bearer token at first start (e.g., into `~/.config/<app>/config.env`), implicit framing being "use this and things work."

**Why bad**: authentication and authorization are distinct. Auto-provisioning auth without provisioning the role means the token authenticates (you're identifiable as a caller) but doesn't authorize (RBAC defaults you to `reader`; mutating tools 403). Worse than no auto-provisioning — the operator thinks it's wired up, hits the failure later, and has to debug authorization separately.

**Do instead**: auto-provisioning should grant the needed role explicitly, OR fail loudly on the first use that requires a role beyond default, OR not auto-provision at all (force a deliberate step that includes role choice).

**Reference**: mcp-agent-mail (upstream Dicklesworthstone) bearer-token + RBAC interaction. We hit this in v1 — see "What surprised us" in v1 results.

## Followups

Items surfaced during the v2 refinements conversation that warrant beads or a follow-up session. Captured here rather than woven into the design narrative because either (a) we haven't resolved them, (b) they need empirical work, or (c) they're a separate design pass.

### Open implementation-blocking questions

- **`hooked` lifecycle on session death** — if a worker claims a bead and disconnects, who/what unhooks? Affects recovery semantics and the observer's "stuck bead" signal.
- **`bd ready --watch` validation** — proposed as event-driven replacement for `foreman-poll.py`. Untested.
- **Routing metadata convention** — post-wisp `bd update --set-metadata` (simpler) vs. per-step routing field stamped at wisp (more declarative). Leaning the former; not committed.
- **Step-to-bead granularity heuristics** — when does a `[[steps]]` entry justify a separate bead vs. being collapsed? The multi-agent-checklist principle says "where handoff crosses an agent boundary"; concrete examples wanted.
- **Who pours** — convention TBD (operator on epic creation; foreman as fallback; upstream automation when defined).

### Open conceptual questions

- **"Off-the-rails" signal specification** — foreman observer role is underspecified. Concrete signals needed (bead-hooked-too-long; repeated-failure patterns; etc.).
- **Sectioning routing default** — N independent beads → N distinct instances (specialization) or shared pool with atomic-claim (load balancing)?
- **Cross-formula coordination** — when one formula's output feeds another's input, parent bead with cross-subgraph deps, or another mechanism?

### Validation stack (primary next priority)

Per sme2 input via mail `gc-wisp-bj2`: validation has two complementary axes, not one.

- **Post-impl evaluator-optimizer** (BEA): same-vendor; "did the output match the spec?" — the agent loop variant.
- **Pre-impl multi-vendor gate** (Flywheel methodology): different-vendor; "is the plan sound before we burn tokens?" — pre-merge.

Concrete eval scaffold worth piloting:
- Every PR runs N independent vendor passes
- Structured verdicts logged to a bead (gc.outcome-style)
- Metrics: catch rate per vendor; inter-vendor agreement; post-merge defect rate per vendor's verdict
- Evidence base for vendor weighting + quorum-vs-agreement gating

The e2e validation stack should also exercise one scenario per Anthropic pattern (prompt chaining / routing / sectioning / voting / orchestrator-workers / evaluator-optimizer / agent loop) — observable from bead state alone. Bead-worthy as an epic.

### Orchestrator-mapping recipes

- **Gascity**: deeper recipe (pools / refinery / supervisor / sling already partially mapped in this doc).
- **safethecode/orc**: comparative reference for scheduler-vs-supervisor framing (referenced already; no full recipe).
- **Flywheel**: slim recipe (per sme2 in `gc-wisp-bj2`) — ~1/3 the depth of gascity. Three primitives worth a slot:
  1. **AGENTS.md as canonical content-for-agents primitive** — now an industry convention (Codex, Anthropic, Google all aligning); pair with foreman-as-wisp-maker. Reference: Dicklesworthstone/ntm #153 (project-level dispatch templates, v1.17.0).
  2. **Frontier-vendor diversity for independent signal** — Claude + Codex + Gemini cross-vendor review; structurally different from same-vendor evaluator-optimizer.
  3. **Planning-as-load-bearing methodology** — "85% planning / check N times implement once." Methodology not primitive; works for greenfield concentrated sessions, less clearly right for ongoing maintenance.

  Skip: substrate (covered by gascity); mail-as-mail (one-line aside); bv graph metrics (defer).

### Idea → plan flow

Genuinely upstream of everything in this doc (which assumes beads exist). Separate design pass; prior art in [`orchestration-conversation.md`](./orchestration-conversation.md) and the intent docs. Bead-worthy as its own follow-up session.

## Status

This document captures foundations' position as of 2026-05-20. The v1 experiment ran; results are above. v2 design (formulas as templates) is sketched but not implemented. Update as further runs land.
