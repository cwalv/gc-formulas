"""Membership entity: active or lapsed."""

from __future__ import annotations

from .event_bus import EventBus


class Membership:
    """A membership.

    Lifecycle: `active` ↔ `lapsed`. Lapsed can be reactivated.
    """

    def __init__(
        self,
        membership_id: str,
        user_id: str,
        tier: str,
        event_bus: EventBus,
    ) -> None:
        self.id = membership_id
        self.user_id = user_id
        self.tier = tier
        self.status = "active"
        self.event_bus = event_bus
        self.event_bus.emit(
            "created",
            entity_type="membership",
            entity_id=self.id,
            user_id=user_id,
            tier=tier,
        )

    def lapse(self) -> None:
        if self.status != "active":
            raise ValueError(
                f"Membership {self.id} must be active to lapse "
                f"(is {self.status})"
            )
        self.status = "lapsed"
        self.event_bus.emit("lapsed", entity_type="membership", entity_id=self.id)

    def reactivate(self) -> None:
        if self.status != "lapsed":
            raise ValueError(
                f"Membership {self.id} must be lapsed to reactivate "
                f"(is {self.status})"
            )
        self.status = "active"
        self.event_bus.emit(
            "reactivated", entity_type="membership", entity_id=self.id
        )
