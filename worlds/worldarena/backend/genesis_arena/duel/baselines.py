"""Deterministic provider-free benchmark controls for WorldArena Duel.

Baselines consume the same immutable ``ProviderRequest`` and return the same raw ``action_batch``
bytes as a hosted model.  They receive no authority shortcut and are therefore useful calibration
opponents for scored model evaluations and local smoke matches.
"""

from __future__ import annotations

# ruff: noqa: UP045 -- Keep annotations importable on the project's Python 3.9 floor.
import hashlib
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence

from .canonical import canonical_json_bytes, strict_json_loads
from .protocol import DUEL_PROTOCOL_VERSION
from .provider_adapters import (
    EndpointOwnership,
    ProviderCallResult,
    ProviderRequest,
)


class BaselineInputError(ValueError):
    """The organizer supplied a malformed or mismatched provider-visible boundary."""


class NoOpDuelProviderAdapter:
    """Return a valid empty command list at every opportunity."""

    endpoint_ownership = EndpointOwnership.ORGANIZER_HOSTED

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        observation = _observation(request)
        return ProviderCallResult.success(
            canonical_json_bytes(_batch_envelope(request, observation, commands=[]))
        )


class SeededRandomDuelProviderAdapter:
    """Issue one deterministic, structurally valid low-level unit command.

    This is intentionally not an omniscient legal-action oracle.  It selects only IDs present in
    ``owned_entities`` and emits one of ``stop``, ``hold_position``, or ``set_stance``.  Godot still
    performs application-time legality checks, exactly as it does for model output.
    """

    endpoint_ownership = EndpointOwnership.ORGANIZER_HOSTED

    def __init__(self, *, seed: int) -> None:
        if (
            not isinstance(seed, int)
            or isinstance(seed, bool)
            or not 0 <= seed <= 9_007_199_254_740_991
        ):
            raise ValueError("seed must be a non-negative safe integer")
        self._seed = seed

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        observation = _observation(request)
        actor_ids = _owned_actor_ids(observation)
        commands: List[Dict[str, Any]] = []
        if actor_ids:
            digest = _decision_digest(self._seed, request, request.observation_json)
            count = 1 + digest[1] % min(len(actor_ids), 4)
            selected = _rotated_prefix(actor_ids, digest[2] % len(actor_ids), count)
            choice = digest[0] % 3
            command: Dict[str, Any] = {
                "actor_ids": selected,
                "command_id": _command_id("random", request, 0),
            }
            if choice == 0:
                command["op"] = "stop"
            elif choice == 1:
                command["op"] = "hold_position"
            else:
                command["op"] = "set_stance"
                command["stance"] = ("aggressive", "defensive", "hold_fire")[digest[3] % 3]
            commands.append(command)
        return ProviderCallResult.success(
            canonical_json_bytes(_batch_envelope(request, observation, commands=commands))
        )


class RushHeuristicDuelProviderAdapter:
    """Transparent combat baseline: focus visible opponents, otherwise advance on their home."""

    endpoint_ownership = EndpointOwnership.ORGANIZER_HOSTED

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        observation = _observation(request)
        actors = _combat_actor_ids(observation)[:24]
        commands: List[Dict[str, Any]] = []
        if actors:
            visible_opponents = sorted(
                entity_id
                for entity_id in _entity_ids(
                    observation.get("visible_contacts", ()),
                    owner_category="opponent",
                )
            )
            if visible_opponents:
                commands.append(
                    {
                        "actor_ids": actors,
                        "command_id": _command_id("rush", request, 0),
                        "op": "attack_entity",
                        "queue": "replace",
                        "target": {"entity_id": visible_opponents[0], "kind": "entity"},
                    }
                )
            else:
                commands.append(
                    {
                        "actor_ids": actors,
                        "command_id": _command_id("rush", request, 0),
                        "op": "attack_move",
                        "queue": "replace",
                        "target": {
                            "kind": "region_slot",
                            "region_id": "r_opponent_home",
                            "slot_id": "center",
                        },
                    }
                )
        return ProviderCallResult.success(
            canonical_json_bytes(_batch_envelope(request, observation, commands=commands))
        )


def _observation(request: ProviderRequest) -> Mapping[str, Any]:
    try:
        value = strict_json_loads(request.observation_json)
    except Exception:
        raise BaselineInputError("observation is not strict canonical JSON") from None
    if not isinstance(value, dict):
        raise BaselineInputError("observation must be a JSON object")
    if canonical_json_bytes(value) != request.observation_json:
        raise BaselineInputError("observation must use canonical bytes")
    if value.get("message_type") != "observation":
        raise BaselineInputError("provider request does not contain an observation")
    if value.get("match_id") != request.match_id:
        raise BaselineInputError("observation match does not match provider request")
    if value.get("observation_seq") != request.observation_seq:
        raise BaselineInputError("observation sequence does not match provider request")
    tick = value.get("tick")
    if tick != request.boundary_tick:
        raise BaselineInputError("observation tick does not match provider request")
    observation_hash = value.get("observation_hash")
    if (
        not isinstance(observation_hash, str)
        or len(observation_hash) != 64
        or any(character not in "0123456789abcdef" for character in observation_hash)
    ):
        raise BaselineInputError("observation hash is invalid")
    decision = value.get("decision")
    if not isinstance(decision, dict):
        raise BaselineInputError("observation decision metadata is missing")
    valid_until_tick = decision.get("valid_until_tick")
    if (
        not isinstance(valid_until_tick, int)
        or isinstance(valid_until_tick, bool)
        or valid_until_tick < 1
    ):
        raise BaselineInputError("observation validity window is invalid")
    return value


def _batch_envelope(
    request: ProviderRequest,
    observation: Mapping[str, Any],
    *,
    commands: Sequence[Mapping[str, Any]],
) -> Dict[str, Any]:
    decision = observation["decision"]
    assert isinstance(decision, dict)
    observation_hash = observation["observation_hash"]
    assert isinstance(observation_hash, str)
    return {
        "based_on_observation_hash": observation_hash,
        "client_batch_id": _batch_id(request),
        "commands": [dict(command) for command in commands],
        "match_id": request.match_id,
        "message_type": "action_batch",
        "observation_seq": request.observation_seq,
        "protocol_version": DUEL_PROTOCOL_VERSION,
        "valid_until_tick": decision["valid_until_tick"],
    }


def _batch_id(request: ProviderRequest) -> str:
    digest = hashlib.sha256(
        (
            "worldeval-rts/baseline-batch/v1\x00"
            f"{request.match_id}\x00{request.opportunity_id}\x00{request.player_slot}"
        ).encode()
    ).hexdigest()[:20]
    return f"baseline_{request.player_slot}_{request.observation_seq}_{digest}"


def _command_id(kind: str, request: ProviderRequest, index: int) -> str:
    return f"{kind}_{request.player_slot}_{request.observation_seq}_{index}"


def _decision_digest(seed: int, request: ProviderRequest, observation_json: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(b"worldeval-rts/random-baseline/v1\x00")
    hasher.update(seed.to_bytes(16, byteorder="big", signed=False))
    hasher.update(request.match_id.encode("utf-8"))
    hasher.update(b"\x00")
    hasher.update(request.opportunity_id.encode("utf-8"))
    hasher.update(b"\x00")
    hasher.update(str(request.player_slot).encode("ascii"))
    hasher.update(b"\x00")
    hasher.update(observation_json)
    return hasher.digest()


def _owned_actor_ids(observation: Mapping[str, Any]) -> List[str]:
    return sorted(_entity_ids(observation.get("owned_entities", ())))


def _combat_actor_ids(observation: Mapping[str, Any]) -> List[str]:
    result: List[str] = []
    for collection_name in ("owned_entities", "heroes"):
        collection = observation.get(collection_name, ())
        if not isinstance(collection, list):
            continue
        for value in collection:
            if not isinstance(value, dict):
                continue
            entity_id = value.get("entity_id")
            tags = value.get("tags", ())
            hp = value.get("hp", 1)
            if (
                isinstance(entity_id, str)
                and isinstance(tags, list)
                and "worker" not in tags
                and "structure" not in tags
                and isinstance(hp, int)
                and hp > 0
            ):
                result.append(entity_id)
    return sorted(set(result))


def _entity_ids(
    values: Any,
    *,
    owner_category: Optional[str] = None,
) -> Iterable[str]:
    if not isinstance(values, list):
        return ()
    result: List[str] = []
    for value in values:
        if not isinstance(value, dict):
            continue
        if owner_category is not None and value.get("owner_category") != owner_category:
            continue
        entity_id = value.get("entity_id")
        if isinstance(entity_id, str):
            result.append(entity_id)
    return result


def _rotated_prefix(values: Sequence[str], offset: int, count: int) -> List[str]:
    rotated = [*values[offset:], *values[:offset]]
    return sorted(rotated[:count])
