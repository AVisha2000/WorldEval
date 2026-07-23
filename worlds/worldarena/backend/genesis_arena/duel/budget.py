from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping

from .models import (
    ActionBatch,
    ActorGroupCommand,
    BuildCommand,
    Command,
    DefineSquadCommand,
    DisbandSquadCommand,
    LoadTransportCommand,
    OrderSquadCommand,
    ProduceCommand,
    PurchaseOfferCommand,
    SetTacticsCommand,
    UnloadTransportCommand,
    UpdateSquadCommand,
    WorkerGroupCommand,
)

MAX_COMMAND_OBJECTS = 16
MAX_ATOMIC_ORDER_COST = 64


class ActionBudgetError(ValueError):
    """A batch cannot be assigned an exact atomic-order cost or exceeds its limit."""


@dataclass(frozen=True)
class ActionBudget:
    command_objects: int
    atomic_orders: int


def command_atomic_cost(
    command: Command,
    *,
    squad_sizes: Mapping[str, int],
    transport_passenger_counts: Mapping[str, int],
) -> int:
    if isinstance(command, WorkerGroupCommand):
        return len(command.worker_ids)
    if isinstance(command, BuildCommand):
        return len(command.builder_ids)
    if isinstance(command, (ProduceCommand, PurchaseOfferCommand)):
        return command.quantity
    if isinstance(command, LoadTransportCommand):
        return len(command.passenger_ids)
    if isinstance(command, UnloadTransportCommand):
        if command.passengers == "all":
            return _known_count(command.transport_id, transport_passenger_counts, "transport")
        return len(command.passengers)
    if isinstance(command, OrderSquadCommand):
        return _known_count(command.squad_id, squad_sizes, "squad")
    if isinstance(command, SetTacticsCommand):
        if command.subject.kind == "actors":
            return len(command.subject.actor_ids)
        return _known_count(command.subject.squad_id, squad_sizes, "squad")
    if isinstance(command, ActorGroupCommand):
        return len(command.actor_ids)
    if isinstance(command, (DefineSquadCommand, UpdateSquadCommand, DisbandSquadCommand)):
        return 1
    return 1


def action_batch_budget(
    batch: ActionBatch,
    *,
    squad_sizes: Mapping[str, int] | None = None,
    transport_passenger_counts: Mapping[str, int] | None = None,
) -> ActionBudget:
    if len(batch.commands) > MAX_COMMAND_OBJECTS:
        raise ActionBudgetError(f"batch exceeds {MAX_COMMAND_OBJECTS} command objects")
    squads = squad_sizes or {}
    transports = transport_passenger_counts or {}
    running_cost = 0
    for index, command in enumerate(batch.commands):
        running_cost += command_atomic_cost(
            command,
            squad_sizes=squads,
            transport_passenger_counts=transports,
        )
        if running_cost > MAX_ATOMIC_ORDER_COST:
            raise ActionBudgetError(
                f"command {index} ({command.command_id}) exceeds the "
                f"{MAX_ATOMIC_ORDER_COST}-order atomic budget"
            )
    return ActionBudget(command_objects=len(batch.commands), atomic_orders=running_cost)


def _known_count(identifier: str, values: Mapping[str, int], kind: str) -> int:
    if identifier not in values:
        raise ActionBudgetError(f"cannot price unknown {kind}: {identifier}")
    count = values[identifier]
    if not 0 <= count <= 24:
        raise ActionBudgetError(f"invalid {kind} size for {identifier}: {count}")
    return count
