from __future__ import annotations

import pytest
from genesis_arena.duel.baselines import (
    BaselineInputError,
    NoOpDuelProviderAdapter,
    RushHeuristicDuelProviderAdapter,
    SeededRandomDuelProviderAdapter,
)
from genesis_arena.duel.canonical import canonical_json_bytes, strict_json_loads
from genesis_arena.duel.protocol import ProtocolPackage
from genesis_arena.duel.provider_adapters import (
    EndpointOwnership,
    ProviderCallResult,
    ProviderRequest,
)
from genesis_arena.duel.schema_validation import DuelSchemaValidator
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
PACKAGE = ProtocolPackage(ROOT / "game" / "duel_protocol")
VALIDATOR = DuelSchemaValidator(PACKAGE)


def _request(*, observation_override: dict | None = None) -> ProviderRequest:
    observation = PACKAGE.read_json("fixtures/observation.maximal.valid.json")
    assert isinstance(observation, dict)
    if observation_override:
        observation.update(observation_override)
    return ProviderRequest(
        match_id=str(observation["match_id"]),
        opportunity_id=f"opp_{int(observation['observation_seq']):08d}",
        player_slot=0,
        observation_seq=int(observation["observation_seq"]),
        boundary_tick=int(observation["tick"]),
        deadline_monotonic_ns=10_000_000_000,
        system_prompt="frozen baseline prompt",
        match_init_json=canonical_json_bytes(
            PACKAGE.read_json("fixtures/match-init.valid.json")
        ),
        observation_json=canonical_json_bytes(observation),
        action_schema_json=canonical_json_bytes(
            PACKAGE.read_schema("action-batch.v1.schema.json")
        ),
    )


def _decoded(result: ProviderCallResult) -> dict:
    raw_output = result.raw_output
    value = strict_json_loads(raw_output)
    assert isinstance(value, dict)
    VALIDATOR.validate("action-batch.v1.schema.json", value)
    return value


async def test_noop_baseline_uses_the_exact_observation_boundary() -> None:
    adapter = NoOpDuelProviderAdapter()
    request = _request()

    batch = _decoded(await adapter.request(request))

    observation = strict_json_loads(request.observation_json)
    assert adapter.endpoint_ownership is EndpointOwnership.ORGANIZER_HOSTED
    assert batch["commands"] == []
    assert batch["match_id"] == request.match_id
    assert batch["observation_seq"] == request.observation_seq
    assert batch["based_on_observation_hash"] == observation["observation_hash"]
    assert batch["valid_until_tick"] == observation["decision"]["valid_until_tick"]


async def test_seeded_random_baseline_is_reproducible_and_uses_owned_ids_only() -> None:
    request = _request()
    first = _decoded(await SeededRandomDuelProviderAdapter(seed=73).request(request))
    second = _decoded(await SeededRandomDuelProviderAdapter(seed=73).request(request))
    owned = {
        value["entity_id"]
        for value in strict_json_loads(request.observation_json)["owned_entities"]
    }

    assert first == second
    assert len(first["commands"]) == 1
    command = first["commands"][0]
    assert command["op"] in {"stop", "hold_position", "set_stance"}
    assert set(command["actor_ids"]) <= owned
    assert 1 <= len(command["actor_ids"]) <= 4


async def test_rush_heuristic_focuses_only_a_visible_opponent() -> None:
    request = _request()

    batch = _decoded(await RushHeuristicDuelProviderAdapter().request(request))

    assert batch["commands"] == [
        {
            "actor_ids": ["e_hero1"],
            "command_id": "rush_0_18_0",
            "op": "attack_entity",
            "queue": "replace",
            "target": {"entity_id": "e_enemy7", "kind": "entity"},
        }
    ]


async def test_rush_heuristic_advances_to_public_opponent_home_when_no_contact_visible() -> None:
    request = _request(observation_override={"visible_contacts": []})

    batch = _decoded(await RushHeuristicDuelProviderAdapter().request(request))

    assert batch["commands"][0]["op"] == "attack_move"
    assert batch["commands"][0]["target"] == {
        "kind": "region_slot",
        "region_id": "r_opponent_home",
        "slot_id": "center",
    }


async def test_baselines_fail_closed_on_request_observation_mismatch() -> None:
    request = _request()
    mismatched = ProviderRequest(
        **{
            **request.__dict__,
            "observation_seq": request.observation_seq + 1,
        }
    )

    with pytest.raises(BaselineInputError, match="sequence"):
        await NoOpDuelProviderAdapter().request(mismatched)


def test_random_baseline_rejects_unsafe_seed() -> None:
    with pytest.raises(ValueError, match="safe integer"):
        SeededRandomDuelProviderAdapter(seed=9_007_199_254_740_992)
