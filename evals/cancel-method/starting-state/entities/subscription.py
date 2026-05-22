"""Subscription entity: recurring billing with active / paused / expired states."""

from __future__ import annotations

from .event_bus import EventBus


class Subscription:
    """A recurring subscription.

    Lifecycle: `active` ↔ `paused`; either can transition to `expired`
    (terminal).
    """

    def __init__(
        self,
        subscription_id: str,
        user_id: str,
        plan: str,
        event_bus: EventBus,
    ) -> None:
        self.id = subscription_id
        self.user_id = user_id
        self.plan = plan
        self.status = "active"
        self.event_bus = event_bus
        self.event_bus.emit(
            "created",
            entity_type="subscription",
            entity_id=self.id,
            user_id=user_id,
            plan=plan,
        )

    def pause(self) -> None:
        if self.status != "active":
            raise ValueError(
                f"Subscription {self.id} must be active to pause "
                f"(is {self.status})"
            )
        self.status = "paused"
        self.event_bus.emit(
            "paused", entity_type="subscription", entity_id=self.id
        )

    def resume(self) -> None:
        if self.status != "paused":
            raise ValueError(
                f"Subscription {self.id} must be paused to resume "
                f"(is {self.status})"
            )
        self.status = "active"
        self.event_bus.emit(
            "resumed", entity_type="subscription", entity_id=self.id
        )

    def expire(self) -> None:
        if self.status == "expired":
            raise ValueError(f"Subscription {self.id} is already expired")
        self.status = "expired"
        self.event_bus.emit(
            "expired", entity_type="subscription", entity_id=self.id
        )
