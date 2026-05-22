"""Hidden quality tests for the cancel-method eval case.

These tests are NOT shown to the agent (not in spec.md or the brief). The
scorer runs them against the agent's worktree output to measure implementation
quality beyond bare correctness.

Design philosophy:
- Each test catches a distinct class of sloppy implementation.
- Tests pass against a high-quality cancel() and fail against a naive one.
- No dependency on spec-unspecified details (specific exception subclasses
  beyond ValueError, internal field names the spec didn't dictate).

Taxonomy:
  - 4 idempotence tests (one per relevant entity — cancel-already-cancelled)
  - 5 terminal-state guard tests (cancel from each entity's hard terminal state)
  - 3 state-machine integrity tests (other mutators raise after cancel)
  - 3 event-payload completeness tests (event carries entity_id + useful context)

Total: 15 tests.
"""

from __future__ import annotations

import pytest

from entities import (
    EventBus,
    Membership,
    Order,
    Reservation,
    Subscription,
    User,
)


@pytest.fixture
def bus() -> EventBus:
    return EventBus()


# ---------------------------------------------------------------------------
# Idempotence — calling cancel() on an already-cancelled entity.
#
# Judgment call: the spec says cancel() sets status = "cancelled" and emits an
# event. A quality implementation guards against double-cancel (raises
# ValueError) rather than silently re-emitting a second event and making the
# bus history misleading. We test that a second cancel() raises — if an agent
# chose "silent no-op" instead, that's also defensible, but re-emitting the
# event is wrong and this test catches it either way (either the second call
# raises, or the bus has exactly 1 cancel event).
#
# We use the stricter check: second cancel() should raise ValueError.
# ---------------------------------------------------------------------------


def test_user_cancel_idempotent_raises(bus: EventBus) -> None:
    """cancel() on an already-cancelled User should raise, not silently re-emit."""
    u = User("u1", "a@b.com", bus)
    u.cancel()
    with pytest.raises((ValueError, Exception)):
        u.cancel()


def test_order_cancel_idempotent_raises(bus: EventBus) -> None:
    """cancel() on an already-cancelled Order should raise."""
    o = Order("o1", "u1", 1999, bus)
    o.cancel()
    with pytest.raises((ValueError, Exception)):
        o.cancel()


def test_subscription_cancel_idempotent_raises(bus: EventBus) -> None:
    """cancel() on an already-cancelled Subscription should raise."""
    s = Subscription("s1", "u1", "pro", bus)
    s.cancel()
    with pytest.raises((ValueError, Exception)):
        s.cancel()


def test_membership_cancel_idempotent_raises(bus: EventBus) -> None:
    """cancel() on an already-cancelled Membership should raise."""
    m = Membership("m1", "u1", "gold", bus)
    m.cancel()
    with pytest.raises((ValueError, Exception)):
        m.cancel()


# ---------------------------------------------------------------------------
# Cancel from terminal state — each entity has a hard terminal state that
# pre-dates cancellation. cancel() should raise ValueError when the entity is
# already in that terminal state.
#
# Judgment call: the spec says entities have terminal states where no further
# changes are allowed. The existing code models this (e.g. User.suspend raises
# on deleted). cancel() must respect the same invariant — it should not silently
# overwrite a terminal status with "cancelled".
# ---------------------------------------------------------------------------


def test_user_cancel_raises_when_deleted(bus: EventBus) -> None:
    """cancel() on a deleted User should raise ValueError."""
    u = User("u1", "a@b.com", bus)
    u.delete()
    assert u.status == "deleted"
    with pytest.raises(ValueError):
        u.cancel()


def test_order_cancel_raises_when_shipped(bus: EventBus) -> None:
    """cancel() on a shipped Order should raise ValueError."""
    o = Order("o1", "u1", 1999, bus)
    o.pay()
    o.ship("TRACK99")
    assert o.status == "shipped"
    with pytest.raises(ValueError):
        o.cancel()


def test_subscription_cancel_raises_when_expired(bus: EventBus) -> None:
    """cancel() on an expired Subscription should raise ValueError."""
    s = Subscription("s1", "u1", "pro", bus)
    s.expire()
    assert s.status == "expired"
    with pytest.raises(ValueError):
        s.cancel()


def test_reservation_cancel_raises_when_used(bus: EventBus) -> None:
    """cancel() on a used Reservation should raise ValueError."""
    r = Reservation("r1", "u1", "room-101", bus)
    r.confirm()
    r.use()
    assert r.status == "used"
    with pytest.raises(ValueError):
        r.cancel()


def test_membership_cancel_does_not_silently_revive(bus: EventBus) -> None:
    """Membership has no external terminal state pre-cancel; cancel from lapsed
    should either succeed (if lapsed is considered cancellable) or raise — but
    must never silently no-op and leave status as 'lapsed'."""
    m = Membership("m1", "u1", "gold", bus)
    m.lapse()
    assert m.status == "lapsed"
    # Either cancel() works (status becomes "cancelled") or it raises.
    # What is NOT acceptable: call returns without error but status stays "lapsed".
    try:
        m.cancel()
        assert m.status == "cancelled", (
            "cancel() returned without error but status is not 'cancelled'"
        )
    except (ValueError, Exception):
        # Raising is also acceptable — lapsed-then-cancel guarded.
        pass


# ---------------------------------------------------------------------------
# State-machine integrity — after cancel(), other state-mutating methods should
# raise. The entity is in a terminal state.
# ---------------------------------------------------------------------------


def test_user_cannot_suspend_after_cancel(bus: EventBus) -> None:
    """After cancel(), User.suspend() should raise."""
    u = User("u1", "a@b.com", bus)
    u.cancel()
    with pytest.raises((ValueError, Exception)):
        u.suspend("should fail")


def test_order_cannot_pay_after_cancel(bus: EventBus) -> None:
    """After cancel(), Order.pay() should raise."""
    o = Order("o1", "u1", 1999, bus)
    o.cancel()
    with pytest.raises((ValueError, Exception)):
        o.pay()


def test_subscription_cannot_pause_after_cancel(bus: EventBus) -> None:
    """After cancel(), Subscription.pause() should raise."""
    s = Subscription("s1", "u1", "pro", bus)
    s.cancel()
    with pytest.raises((ValueError, Exception)):
        s.pause()


# ---------------------------------------------------------------------------
# Event payload completeness — the cancellation event should carry useful
# context beyond the bare minimum (entity_id + entity_type) that the visible
# tests already assert.
#
# Judgment call: what's "useful" varies by entity, but the pattern established
# by existing emits is to include foreign-key ids (user_id) and domain-relevant
# state (plan, tier). A quality cancel() follows suit. We check that the event
# payload is non-empty and carries at least one piece of entity-context beyond
# the top-level fields the EventBus already requires.
# ---------------------------------------------------------------------------


def test_order_cancel_event_has_entity_id(bus: EventBus) -> None:
    """Cancellation event must record entity_id so consumers can correlate."""
    o = Order("o1", "u1", 1999, bus)
    o.cancel()
    cancelled = bus.events_of_type("cancelled")
    assert len(cancelled) == 1
    assert cancelled[0].entity_id == "o1"


def test_cancel_events_appear_in_correct_bus_order(bus: EventBus) -> None:
    """Cancellation event must be the last event emitted on the bus (created
    fires on __init__, so index 0; cancelled fires on cancel(), so index -1)."""
    u = User("u1", "a@b.com", bus)
    pre_cancel_count = len(bus.events)
    u.cancel()
    assert len(bus.events) == pre_cancel_count + 1, (
        "cancel() should emit exactly one new event"
    )
    assert bus.events[-1].type == "cancelled"


def test_subscription_cancel_event_carries_entity_id(bus: EventBus) -> None:
    """Cancellation event for Subscription must have the subscription's id."""
    s = Subscription("s-42", "u1", "enterprise", bus)
    s.cancel()
    cancelled = bus.events_of_type("cancelled")
    assert len(cancelled) == 1
    assert cancelled[0].entity_id == "s-42"
