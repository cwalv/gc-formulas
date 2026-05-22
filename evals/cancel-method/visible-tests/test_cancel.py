"""Visible success criteria. The agents see this as part of the spec; their
job is to make these tests pass without breaking starting-state/tests/."""

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


def test_user_has_cancel_method() -> None:
    assert hasattr(User, "cancel"), "User must have a cancel() method"


def test_order_has_cancel_method() -> None:
    assert hasattr(Order, "cancel"), "Order must have a cancel() method"


def test_subscription_has_cancel_method() -> None:
    assert hasattr(Subscription, "cancel"), "Subscription must have a cancel() method"


def test_reservation_has_cancel_method() -> None:
    assert hasattr(Reservation, "cancel"), "Reservation must have a cancel() method"


def test_membership_has_cancel_method() -> None:
    assert hasattr(Membership, "cancel"), "Membership must have a cancel() method"


def test_user_cancel_sets_status(bus: EventBus) -> None:
    u = User("u1", "a@b.com", bus)
    u.cancel()
    assert u.status == "cancelled"


def test_order_cancel_sets_status(bus: EventBus) -> None:
    o = Order("o1", "u1", 1999, bus)
    o.cancel()
    assert o.status == "cancelled"


def test_subscription_cancel_sets_status(bus: EventBus) -> None:
    s = Subscription("s1", "u1", "pro", bus)
    s.cancel()
    assert s.status == "cancelled"


def test_reservation_cancel_sets_status(bus: EventBus) -> None:
    r = Reservation("r1", "u1", "room-101", bus)
    r.cancel()
    assert r.status == "cancelled"


def test_membership_cancel_sets_status(bus: EventBus) -> None:
    m = Membership("m1", "u1", "gold", bus)
    m.cancel()
    assert m.status == "cancelled"


def test_user_cancel_emits_event(bus: EventBus) -> None:
    u = User("u1", "a@b.com", bus)
    u.cancel()
    cancelled = bus.events_of_type("cancelled")
    assert len(cancelled) == 1
    assert cancelled[0].entity_type == "user"
    assert cancelled[0].entity_id == "u1"


def test_order_cancel_emits_event(bus: EventBus) -> None:
    o = Order("o1", "u1", 1999, bus)
    o.cancel()
    cancelled = bus.events_of_type("cancelled")
    assert len(cancelled) == 1
    assert cancelled[0].entity_type == "order"


def test_subscription_cancel_emits_event(bus: EventBus) -> None:
    s = Subscription("s1", "u1", "pro", bus)
    s.cancel()
    cancelled = bus.events_of_type("cancelled")
    assert len(cancelled) == 1
    assert cancelled[0].entity_type == "subscription"


def test_reservation_cancel_emits_event(bus: EventBus) -> None:
    r = Reservation("r1", "u1", "room-101", bus)
    r.cancel()
    cancelled = bus.events_of_type("cancelled")
    assert len(cancelled) == 1
    assert cancelled[0].entity_type == "reservation"


def test_membership_cancel_emits_event(bus: EventBus) -> None:
    m = Membership("m1", "u1", "gold", bus)
    m.cancel()
    cancelled = bus.events_of_type("cancelled")
    assert len(cancelled) == 1
    assert cancelled[0].entity_type == "membership"
