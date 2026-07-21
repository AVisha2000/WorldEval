"""Typed helpers for WorldArena's seven public conquest verbs.

Agents may construct :class:`PhysicalOrder` directly.  These helpers keep common
field combinations terse and document the only supported v0.4 vocabulary.  The
authoritative Godot simulation still validates every returned order and emits the
receipt; SDK construction never implies success.
"""

from __future__ import annotations

from typing import Iterable, Optional

from .models import PhysicalAction, PhysicalOrder, ResourceKind


class ArenaAgentSDK:
    @staticmethod
    def move(
        action_id: str,
        actors: Iterable[str],
        destination_id: str,
        *,
        mode: str = "advance",
    ) -> PhysicalOrder:
        return PhysicalOrder(
            order_id=action_id,
            action=PhysicalAction.MOVE,
            actor_ids=list(actors),
            target_id=destination_id,
            mode=mode,
        )

    @staticmethod
    def gather(
        action_id: str,
        workers: Iterable[str],
        district_id: str,
        resource: ResourceKind,
        *,
        node_id: Optional[str] = None,
    ) -> PhysicalOrder:
        attributes = {"resource_node_id": node_id} if node_id is not None else {}
        return PhysicalOrder(
            order_id=action_id,
            action=PhysicalAction.GATHER,
            actor_ids=list(workers),
            target_id=district_id,
            resource=resource,
            attributes=attributes,
        )

    @staticmethod
    def build(
        action_id: str,
        actors: Iterable[str],
        target_id: str,
        kind: str,
        *,
        mode: str = "construct",
    ) -> PhysicalOrder:
        return PhysicalOrder(
            order_id=action_id,
            action=PhysicalAction.BUILD,
            actor_ids=list(actors),
            target_id=target_id,
            option=kind,
            mode=mode,
        )

    @staticmethod
    def attack(
        action_id: str,
        actors: Iterable[str],
        target_id: str,
        *,
        mode: str = "assault",
    ) -> PhysicalOrder:
        return PhysicalOrder(
            order_id=action_id,
            action=PhysicalAction.ATTACK,
            actor_ids=list(actors),
            target_id=target_id,
            stance="assault" if mode == "assault" else "raid",
            mode=mode,
        )

    @staticmethod
    def research(
        action_id: str,
        researchers: Iterable[str],
        district_id: str,
        technology_id: str,
    ) -> PhysicalOrder:
        return PhysicalOrder(
            order_id=action_id,
            action=PhysicalAction.RESEARCH,
            actor_ids=list(researchers),
            target_id=district_id,
            option=technology_id,
        )

    @staticmethod
    def negotiate(action_id: str, *, note: str = "communication_plan") -> PhysicalOrder:
        return PhysicalOrder(
            order_id=action_id,
            action=PhysicalAction.NEGOTIATE,
            mode="offer",
            option=note,
        )

    @staticmethod
    def think(action_id: str, *, note: str = "deliberate") -> PhysicalOrder:
        return PhysicalOrder(
            order_id=action_id,
            action=PhysicalAction.THINK,
            mode="deliberate",
            option=note,
        )


def canonical_engine_order(order: PhysicalOrder) -> dict:
    """Project a typed SDK order into the compact Godot v0.4 action dictionary."""

    action = order.canonical_action
    payload = {
        "id": order.order_id,
        "kind": action.value,
        "actor_ids": list(order.actor_ids),
        "unit_ids": list(order.actor_ids),
        "target_id": order.target_id or "",
        "mode": order.mode or "",
    }
    if action == PhysicalAction.MOVE:
        payload["target"] = order.target_id or ""
    elif action == PhysicalAction.GATHER:
        node = order.attributes.get("resource_node_id")
        default_nodes = {
            ResourceKind.FOOD: "animals",
            ResourceKind.WOOD: "forest",
            ResourceKind.STONE: "stone",
            ResourceKind.IRON: "iron",
            ResourceKind.CRYSTAL: "crystal",
        }
        payload.update(
            {
                "district": order.target_id or "",
                "node": node or default_nodes.get(order.resource, ""),
                "worker_ids": list(order.actor_ids),
            }
        )
    elif action == PhysicalAction.BUILD:
        if order.mode == "train":
            payload.update({"kind": "train", "unit": order.option or ""})
        elif order.mode == "repair":
            payload.update({"worker_ids": list(order.actor_ids)})
        else:
            payload.update(
                {
                    "structure": order.option or "",
                    "district": order.target_id or "",
                    "worker_ids": list(order.actor_ids),
                }
            )
    elif action == PhysicalAction.RESEARCH:
        payload.update(
            {
                "district": order.target_id or "",
                "technology_id": order.option or "",
                "worker_ids": list(order.actor_ids),
            }
        )
    return payload
