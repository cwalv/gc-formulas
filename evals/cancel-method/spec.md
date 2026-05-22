# Task

Add a `cancel()` method to each of the 5 entity classes in `entities/`.

## Entities

The directory `entities/` contains five Python classes that each manage their own state and emit events via a shared `EventBus`:

- `entities/user.py` — `User`
- `entities/order.py` — `Order`
- `entities/subscription.py` — `Subscription`
- `entities/reservation.py` — `Reservation`
- `entities/membership.py` — `Membership`

Each has different lifecycle states but follows the same pattern: state-mutating methods update `self.status` and call `self.event_bus.emit(...)`.

## Required behavior for the new `cancel()` method

For each of the five entities:

1. Calling `cancel()` sets `self.status` to `"cancelled"`.
2. Calling `cancel()` emits an event via the entity's `event_bus`. The event's `type` field must be `"cancelled"` and its `entity_type` field must match the class name (lower-case: `"user"`, `"order"`, etc.).
3. The existing tests in `tests/` must continue to pass — `cancel()` is an addition, not a refactor; don't alter existing methods unless necessary to support cancellation.

## Constraints

- Stay strictly within `entities/`. Don't modify the `EventBus` itself or any tests.
- Match the existing code style (type hints, docstring conventions, event payload shape).
- The 5 entities share the *shape* of `cancel()` but not necessarily the *implementation* — each entity has its own preconditions and side effects (e.g. an `Order` that's already shipped probably can't be cancelled).

## Success criteria

When `pytest tests/ visible-tests/` is run from the worktree root, all tests pass.
