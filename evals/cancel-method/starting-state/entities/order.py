"""Order entity: tracks pending / paid / shipped lifecycle."""

from __future__ import annotations

from .event_bus import EventBus


class Order:
    """A customer order.

    Lifecycle: `pending` → `paid` → `shipped`. Once shipped, terminal.
    """

    def __init__(
        self, order_id: str, user_id: str, amount_cents: int, event_bus: EventBus
    ) -> None:
        self.id = order_id
        self.user_id = user_id
        self.amount_cents = amount_cents
        self.status = "pending"
        self.event_bus = event_bus
        self.event_bus.emit(
            "created",
            entity_type="order",
            entity_id=self.id,
            user_id=user_id,
            amount_cents=amount_cents,
        )

    def pay(self) -> None:
        if self.status != "pending":
            raise ValueError(
                f"Order {self.id} must be pending to pay (is {self.status})"
            )
        self.status = "paid"
        self.event_bus.emit("paid", entity_type="order", entity_id=self.id)

    def ship(self, tracking_number: str) -> None:
        if self.status != "paid":
            raise ValueError(
                f"Order {self.id} must be paid to ship (is {self.status})"
            )
        self.status = "shipped"
        self.event_bus.emit(
            "shipped",
            entity_type="order",
            entity_id=self.id,
            tracking_number=tracking_number,
        )
