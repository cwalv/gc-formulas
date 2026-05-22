"""User entity: tracks active / suspended / deleted lifecycle."""

from __future__ import annotations

from .event_bus import EventBus


class User:
    """A user account.

    Lifecycle: `active` → `suspended` → `deleted`. Once deleted, no further
    state changes are allowed.
    """

    def __init__(self, user_id: str, email: str, event_bus: EventBus) -> None:
        self.id = user_id
        self.email = email
        self.status = "active"
        self.event_bus = event_bus
        self.event_bus.emit(
            "created", entity_type="user", entity_id=self.id, email=email
        )

    def suspend(self, reason: str) -> None:
        if self.status == "deleted":
            raise ValueError(f"User {self.id} is deleted; cannot suspend")
        self.status = "suspended"
        self.event_bus.emit(
            "suspended", entity_type="user", entity_id=self.id, reason=reason
        )

    def reactivate(self) -> None:
        if self.status != "suspended":
            raise ValueError(
                f"User {self.id} must be suspended to reactivate (is {self.status})"
            )
        self.status = "active"
        self.event_bus.emit("reactivated", entity_type="user", entity_id=self.id)

    def delete(self) -> None:
        self.status = "deleted"
        self.event_bus.emit("deleted", entity_type="user", entity_id=self.id)
