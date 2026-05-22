"""Baseline tests covering existing behavior. Must keep passing after the
agents add `cancel()`."""

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


# --- User -------------------------------------------------------------------


def test_user_created_emits_event(bus: EventBus) -> None:
    User("u1", "a@b.com", bus)
    created = bus.events_of_type("created")
    assert len(created) == 1
    assert created[0].entity_type == "user"
    assert created[0].entity_id == "u1"


def test_user_suspend_then_reactivate(bus: EventBus) -> None:
    u = User("u1", "a@b.com", bus)
    u.suspend("policy violation")
    assert u.status == "suspended"
    u.reactivate()
    assert u.status == "active"


def test_user_cannot_suspend_deleted(bus: EventBus) -> None:
    u = User("u1", "a@b.com", bus)
    u.delete()
    with pytest.raises(ValueError):
        u.suspend("oops")


# --- Order ------------------------------------------------------------------


def test_order_pay_then_ship(bus: EventBus) -> None:
    o = Order("o1", "u1", 1999, bus)
    o.pay()
    o.ship("TRACK123")
    assert o.status == "shipped"


def test_order_cannot_ship_unpaid(bus: EventBus) -> None:
    o = Order("o1", "u1", 1999, bus)
    with pytest.raises(ValueError):
        o.ship("TRACK123")


# --- Subscription -----------------------------------------------------------


def test_subscription_pause_resume(bus: EventBus) -> None:
    s = Subscription("s1", "u1", "pro", bus)
    s.pause()
    assert s.status == "paused"
    s.resume()
    assert s.status == "active"


def test_subscription_expire_terminal(bus: EventBus) -> None:
    s = Subscription("s1", "u1", "pro", bus)
    s.expire()
    with pytest.raises(ValueError):
        s.expire()


# --- Reservation ------------------------------------------------------------


def test_reservation_confirm_then_use(bus: EventBus) -> None:
    r = Reservation("r1", "u1", "room-101", bus)
    r.confirm()
    r.use()
    assert r.status == "used"


def test_reservation_cannot_use_unconfirmed(bus: EventBus) -> None:
    r = Reservation("r1", "u1", "room-101", bus)
    with pytest.raises(ValueError):
        r.use()


# --- Membership -------------------------------------------------------------


def test_membership_lapse_reactivate(bus: EventBus) -> None:
    m = Membership("m1", "u1", "gold", bus)
    m.lapse()
    assert m.status == "lapsed"
    m.reactivate()
    assert m.status == "active"
