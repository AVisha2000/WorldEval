from __future__ import annotations

import hashlib

import pytest
from genesis_arena.embodiment.demo_provider import DemoPolicyLock
from genesis_arena.embodiment.demo_scenarios import demo_scenario
from genesis_arena.embodiment.episode_service import EpisodeRunSpec, demo_fixture_bytes
from genesis_arena.embodiment.live_runtime import _demo_provider
from genesis_arena.embodiment.protocol import (
    EmbodimentProtocolPackage,
    canonical_json_bytes,
    strict_json_loads,
)
from genesis_arena.embodiment.providers import provider_capabilities
from genesis_arena.embodiment.providers.contracts import ProviderRequest
from genesis_arena.embodiment.scripted_solo_demo import SCRIPTED_SOLO_MODELS
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT


def _visible_entity(entity_id: str, *, state: str) -> dict[str, object]:
    return {
        "affordances": ["interact"],
        "bearing": "front",
        "distance": "touching",
        "id": entity_id,
        "kind": "fixture",
        "state": state,
    }


def _observation(episode_id: str, task_id: str) -> dict[str, object]:
    entities = {
        "orientation-v0": [_visible_entity("v_beacon_1", state="active")],
        "interaction-v0": [_visible_entity("v_resource_1", state="available")],
        "construction-v0": [_visible_entity("v_resource_1", state="available")],
        "neutral-encounter-v0": [
            _visible_entity("v_neutral_1", state="idle"),
            _visible_entity("v_relay_1", state="inactive"),
        ],
    }[task_id]
    return {
        "episode_id": episode_id,
        "observation_seq": 0,
        "tick": 0,
        "profile": "text-visible-v1",
        "self": {"inventory": [], "status": []},
        "visible_entities": entities,
        "terminal": {"ended": False, "outcome": "running", "reason": "running"},
    }


@pytest.mark.asyncio
@pytest.mark.parametrize("task_id", tuple(SCRIPTED_SOLO_MODELS))
async def test_production_demo_factory_drives_each_current_solo_contract(task_id: str) -> None:
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    model = SCRIPTED_SOLO_MODELS[task_id]
    scenario = demo_scenario(task_id)
    fixture = demo_fixture_bytes(model=model, task_id=task_id)
    lock = DemoPolicyLock(
        scenario_id=task_id,
        policy_id=model,
        fixture_sha256=hashlib.sha256(fixture).hexdigest(),
        seed=31,
        participant_id="participant_0",
        model=model,
        total_decision_budget=scenario.total_decision_budget,
    )
    spec = EpisodeRunSpec(
        episode_id=f"ep_demo_runtime_{task_id}",
        provider="demo",
        model=model,
        task_id=task_id,
        seed=31,
        maximum_episode_ticks=scenario.episode_tick_budget,
        observation_profile="hybrid-visible-v1",
        demo_policy_lock=lock,
    )
    observation = _observation(spec.episode_id, task_id)
    schema_name = "construction-task-plan" if task_id == "construction-v0" else "controller-action"
    provider = _demo_provider(spec)

    result = await provider.request(
        ProviderRequest(
            episode_id=spec.episode_id,
            participant_id="participant_0",
            observation_seq=0,
            deadline_monotonic_ns=1,
            model=model,
            system_prompt="Return strict JSON.",
            observation_json=canonical_json_bytes(observation),
            action_schema_json=canonical_json_bytes(package.schema(schema_name)),
        )
    )

    assert result.failure is None
    assert result.raw_output is not None
    value = strict_json_loads(result.raw_output)
    package.validate(schema_name, value)
    assert value["episode_id"] == spec.episode_id
    assert value["observation_seq"] == 0
    assert provider.policy_lock == lock
    assert provider.decision_count == 1
    assert provider_capabilities(provider.provider_name).as_dict() == {
        "provider_name": "demo",
        "requires_credential": False,
        "is_networked": False,
    }


@pytest.mark.asyncio
async def test_production_factory_selects_late_build_policy_only_for_showcase() -> None:
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    scenario = demo_scenario("multi-action-demo-v0")
    fixture = demo_fixture_bytes(
        model=scenario.provider_model,
        task_id=scenario.authority_task_id,
        scenario_id=scenario.scenario_id,
    )
    lock = DemoPolicyLock(
        scenario_id=scenario.scenario_id,
        policy_id=scenario.policy_id,
        fixture_sha256=hashlib.sha256(fixture).hexdigest(),
        seed=31,
        participant_id="participant_0",
        model=scenario.provider_model,
        total_decision_budget=scenario.total_decision_budget,
    )
    spec = EpisodeRunSpec(
        episode_id="ep_demo_runtime_multi_action",
        provider="demo",
        model=scenario.provider_model,
        task_id=scenario.authority_task_id,
        scenario_id=scenario.scenario_id,
        seed=31,
        maximum_episode_ticks=scenario.episode_tick_budget,
        demo_policy_lock=lock,
    )
    observation = _observation(spec.episode_id, spec.task_id)
    observation["tick"] = 100
    observation["visible_entities"] = [
        _visible_entity("v_resource_1", state="depleted"),
        _visible_entity("v_build_pad_1", state="ready"),
    ]
    result = await _demo_provider(spec).request(
        ProviderRequest(
            episode_id=spec.episode_id,
            participant_id="participant_0",
            observation_seq=0,
            deadline_monotonic_ns=1,
            model=spec.model,
            system_prompt="Return strict JSON.",
            observation_json=canonical_json_bytes(observation),
            action_schema_json=canonical_json_bytes(package.schema("construction-task-plan")),
        )
    )
    assert result.raw_output is not None
    assert strict_json_loads(result.raw_output)["task_id"] == "wait"
