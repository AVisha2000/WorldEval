"""Stable episode object identities with explicit lifecycle semantics."""

from __future__ import annotations

from typing import Dict, Iterable

from worldeval.contracts.models import ObjectInstance, Position


class ObjectIdentityError(ValueError):
    """An object identity was reused, rebound, or addressed ambiguously."""


class ObjectRegistry:
    """Stores live objects while permanently reserving every spawned ID.

    Despawning an object does not free its ID.  A replacement must receive a
    new object ID, so an old plan can never silently bind to a new entity.
    """

    def __init__(self, objects: Iterable[ObjectInstance] = ()) -> None:
        self._active: Dict[str, ObjectInstance] = {}
        self._used_ids: set[str] = set()
        for value in objects:
            self.spawn(value)

    def spawn(self, value: ObjectInstance) -> ObjectInstance:
        if value.object_id in self._used_ids:
            raise ObjectIdentityError(f"object ID cannot be reused: {value.object_id}")
        self._used_ids.add(value.object_id)
        self._active[value.object_id] = value
        return value

    def resolve(self, object_id: str, *, generation: int | None = None) -> ObjectInstance:
        value = self._active.get(object_id)
        if value is None:
            raise ObjectIdentityError(f"object is not active: {object_id}")
        if generation is not None and value.generation != generation:
            raise ObjectIdentityError(
                f"generation mismatch for {object_id}: expected {generation}, "
                f"got {value.generation}"
            )
        return value

    def update(
        self,
        object_id: str,
        *,
        position: Position | None = None,
        state: dict | None = None,
        affordances: list[str] | None = None,
    ) -> ObjectInstance:
        current = self.resolve(object_id)
        value = ObjectInstance.model_validate(
            {
                **current.model_dump(mode="json"),
                "position": (position or current.position).model_dump(mode="json"),
                "state": current.state if state is None else state,
                "affordances": current.affordances if affordances is None else affordances,
            }
        )
        self._active[object_id] = value
        return value

    def despawn(self, object_id: str, *, generation: int | None = None) -> ObjectInstance:
        value = self.resolve(object_id, generation=generation)
        del self._active[object_id]
        return value

    def contains(self, object_id: str) -> bool:
        return object_id in self._active

    def values(self) -> list[ObjectInstance]:
        return [self._active[key] for key in sorted(self._active)]
