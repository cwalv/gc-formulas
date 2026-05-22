"""Reservation entity: holds a resource until confirmed or released."""

from __future__ import annotations

from .event_bus import EventBus


class Reservation:
    """A resource reservation.

    Lifecycle: `pending` → `confirmed` → `used`. `used` is terminal.
    """

    def __init__(
        self,
        reservation_id: str,
        user_id: str,
        resource_id: str,
        event_bus: EventBus,
    ) -> None:
        self.id = reservation_id
        self.user_id = user_id
        self.resource_id = resource_id
        self.status = "pending"
        self.event_bus = event_bus
        self.event_bus.emit(
            "created",
            entity_type="reservation",
            entity_id=self.id,
            user_id=user_id,
            resource_id=resource_id,
        )

    def confirm(self) -> None:
        if self.status != "pending":
            raise ValueError(
                f"Reservation {self.id} must be pending to confirm "
                f"(is {self.status})"
            )
        self.status = "confirmed"
        self.event_bus.emit(
            "confirmed", entity_type="reservation", entity_id=self.id
        )

    def use(self) -> None:
        if self.status != "confirmed":
            raise ValueError(
                f"Reservation {self.id} must be confirmed to use "
                f"(is {self.status})"
            )
        self.status = "used"
        self.event_bus.emit(
            "used", entity_type="reservation", entity_id=self.id
        )
