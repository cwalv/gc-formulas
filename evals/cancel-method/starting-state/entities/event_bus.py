"""Tiny in-memory event bus shared by the entities.

Production replacement would be a real pub/sub (Redis, Kafka, etc.); this
class only needs to record emitted events so tests can assert against them.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class Event:
    type: str
    entity_type: str
    entity_id: str
    payload: dict[str, Any] = field(default_factory=dict)


class EventBus:
    """Records all emitted events. Tests inspect `bus.events`."""

    def __init__(self) -> None:
        self.events: list[Event] = []

    def emit(
        self,
        event_type: str,
        entity_type: str,
        entity_id: str,
        **payload: Any,
    ) -> None:
        self.events.append(
            Event(
                type=event_type,
                entity_type=entity_type,
                entity_id=entity_id,
                payload=payload,
            )
        )

    def events_of_type(self, event_type: str) -> list[Event]:
        return [e for e in self.events if e.type == event_type]
