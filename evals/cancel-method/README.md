# Eval case: cancel-method

A small Python project with 5 entity classes that each manage their own state via shared event-bus emissions. The task is to add a `cancel()` method to each entity. Designed as the **first eval case** for the plan-evals framework (`docs/plan-evals.md` M1).

## Why this case

- **Structurally parallelisable.** 5 independent files; fan-out should win on wall-clock vs ralph serializing.
- **Spec is clear.** "Add `cancel()`" is unambiguous; visible-tests pin exact behavior.
- **Mechanically scoreable.** pytest pass/fail.
- **Calibration honest.** This case will be ~30s-2min for opus-ralph — too easy to differentiate patterns at opus tier. It's primarily here to **validate the eval runner infrastructure**, not to prove orchestration wins. Real pattern signal comes from larger cases per `docs/plan-evals.md` M2.

## Contents

```
cancel-method/
├── README.md                           (this file)
├── spec.md                             (the task as given to the planner/agents)
├── starting-state/                     (fixture; copied to a worktree at run-start)
│   ├── entities/
│   │   ├── event_bus.py
│   │   ├── user.py
│   │   ├── order.py
│   │   ├── subscription.py
│   │   ├── reservation.py
│   │   └── membership.py
│   └── tests/
│       └── test_existing.py            (regression coverage; must continue to pass)
└── visible-tests/
    └── test_cancel.py                  (success target; agents make these pass)
```

## Scoring

- **Visible:** `pytest visible-tests/ starting-state/tests/` — both pass = correctness floor met.
- **Hidden:** *not yet authored.* This case is for runner validation only. Hidden tests can be added later if we want quality-axis signal from this case.

## How the runner uses this

1. Copy `starting-state/` into a fresh worktree per run.
2. Show `spec.md` to the agent(s).
3. Let the agent(s) work in the worktree.
4. Run `pytest visible-tests/ tests/` against the worktree.
5. Capture wall-clock + token cost + pass/total.

Repeat 10× to get distributions; aggregate.
