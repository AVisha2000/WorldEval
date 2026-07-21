from __future__ import annotations

import hashlib
from dataclasses import FrozenInstanceError, replace

import pytest
from genesis_arena.embodiment.demo_scenarios import (
    DEMO_SCENARIOS,
    DemoScenarioDefinition,
    demo_scenario,
    demo_scenario_fixture_bytes,
    demo_scenario_fixture_sha256,
)
from genesis_arena.embodiment.protocol import canonical_json_bytes, strict_json_loads
from genesis_arena.embodiment.scripted_solo_demo import SCRIPTED_SOLO_MODELS


def test_catalog_preserves_current_solo_identity_and_adds_control_games() -> None:
    assert tuple(DEMO_SCENARIOS) == (
        "orientation-v0",
        "interaction-v0",
        "construction-v0",
        "neutral-encounter-v0",
        "multi-action-demo-v0",
        "movement-maze-v0",
        "operator-action-course-v0",
    )
    for task_id, model in SCRIPTED_SOLO_MODELS.items():
        scenario = demo_scenario(task_id)
        assert scenario.authority_task_id == task_id
        assert scenario.policy_id == model
        assert scenario.provider_model == model

    showcase = demo_scenario("multi-action-demo-v0")
    assert showcase.authority_task_id == "construction-v0"
    assert showcase.scenario_id != showcase.authority_task_id
    assert showcase.provider_model == SCRIPTED_SOLO_MODELS["construction-v0"]
    assert showcase.policy_id != showcase.provider_model
    assert (showcase.terminal_tick_minimum, showcase.terminal_tick_maximum) == (900, 1_200)
    assert showcase.episode_tick_budget == 1_300
    assert demo_scenario("movement-maze-v0").protocol_version == "llm-controller/0.2.0"
    assert (
        demo_scenario("operator-action-course-v0").protocol_version
        == "llm-controller/0.2.0"
    )


def test_existing_scripted_replay_labels_remain_byte_exact() -> None:
    legacy_labels = {
        scenario_id: definition.replay_label
        for scenario_id, definition in DEMO_SCENARIOS.items()
        if scenario_id
        in {
            "orientation-v0",
            "interaction-v0",
            "construction-v0",
            "neutral-encounter-v0",
        }
    }
    assert legacy_labels == {
        "orientation-v0": "Orientation v0 scripted demo",
        "interaction-v0": "Interaction v0 scripted demo",
        "construction-v0": "Construction v0 scripted demo",
        "neutral-encounter-v0": "Neutral Encounter v0 scripted demo",
    }


def test_catalog_and_definitions_are_immutable() -> None:
    with pytest.raises(TypeError):
        DEMO_SCENARIOS["new-v0"] = demo_scenario("orientation-v0")  # type: ignore[index]
    with pytest.raises(FrozenInstanceError):
        demo_scenario("orientation-v0").display_label = "changed"  # type: ignore[misc]


def test_fixture_is_canonical_reproducible_and_binds_every_public_identity() -> None:
    digests = {"scripted-construction-demo-v1": "a" * 64}
    first = demo_scenario_fixture_bytes("multi-action-demo-v0", policy_source_sha256=digests)
    second = demo_scenario_fixture_bytes("multi-action-demo-v0", policy_source_sha256=dict(digests))
    value = strict_json_loads(first)
    assert first == second == canonical_json_bytes(value)
    assert value == {
        "authority_task_id": "construction-v0",
        "display_label": "Multi-action solo showcase",
        "episode_tick_budget": 1_300,
        "evaluation_profile_id": "solo-multi-action-showcase-v1",
        "fixture_version": "worldarena-demo-scenario/1.0.0",
        "output_contract": "construction-task-plan",
        "policy_id": "multi-action-construction-demo-v1",
        "policy_sources": [{"sha256": "a" * 64, "source_id": "scripted-construction-demo-v1"}],
        "provider_model": "construction-demo-v1",
        "replay_label": "Multi-action solo showcase",
        "scenario_id": "multi-action-demo-v0",
        "terminal_tick_maximum": 1_200,
        "terminal_tick_minimum": 900,
        "total_decision_budget": 1_300,
    }
    assert (
        demo_scenario_fixture_sha256("multi-action-demo-v0", policy_source_sha256=digests)
        == hashlib.sha256(first).hexdigest()
    )


def test_fixture_contains_no_hidden_geometry_or_source_path() -> None:
    fixture = demo_scenario_fixture_bytes("multi-action-demo-v0")
    lowered = fixture.lower()
    for forbidden in (
        b"coordinate",
        b"position",
        b"transform",
        b"spectator",
        b"hidden_state",
        b"scripted_construction_demo.py",
        b"/users/",
    ):
        assert forbidden not in lowered


@pytest.mark.parametrize(
    ("source_digests", "message"),
    (
        ({}, "identities"),
        ({"scripted-construction-demo-v1": "a" * 64, "extra": "b" * 64}, "identities"),
        ({"scripted-construction-demo-v1": "A" * 64}, "lowercase SHA-256"),
        ({"scripted-construction-demo-v1": "a" * 63}, "lowercase SHA-256"),
    ),
)
def test_fixture_source_set_and_digests_fail_closed(
    source_digests: dict[str, str], message: str
) -> None:
    with pytest.raises(ValueError, match=message):
        demo_scenario_fixture_bytes("multi-action-demo-v0", policy_source_sha256=source_digests)


def test_policy_source_change_changes_fixture_and_lock_digest() -> None:
    first = {"scripted-solo-demo-v1": "1" * 64}
    second = {"scripted-solo-demo-v1": "2" * 64}
    assert demo_scenario_fixture_bytes(
        "orientation-v0", policy_source_sha256=first
    ) != demo_scenario_fixture_bytes("orientation-v0", policy_source_sha256=second)
    assert demo_scenario_fixture_sha256(
        "orientation-v0", policy_source_sha256=first
    ) != demo_scenario_fixture_sha256("orientation-v0", policy_source_sha256=second)


@pytest.mark.parametrize("bad", (None, 1, "construction", "CONSTRUCTION-V0"))
def test_unknown_or_aliased_scenario_fails_closed(bad: object) -> None:
    error = TypeError if not isinstance(bad, str) else ValueError
    with pytest.raises(error):
        demo_scenario(bad)  # type: ignore[arg-type]


@pytest.mark.parametrize(
    ("changes", "message"),
    (
        ({"scenario_id": "bad id"}, "scenario_id"),
        ({"authority_task_id": "unknown-task-v0"}, "authority_task_id"),
        ({"output_contract": "controller-action"}, "output_contract"),
        ({"terminal_tick_minimum": True}, "terminal_tick_minimum"),
        ({"terminal_tick_minimum": 1_201}, "horizon"),
        ({"episode_tick_budget": 18_001}, "horizon"),
        ({"total_decision_budget": 1_301}, "total_decision_budget"),
        ({"policy_source_ids": []}, "policy_source_ids"),
        ({"policy_source_ids": ("same", "same")}, "policy_source_ids"),
        ({"display_label": " leading"}, "display_label"),
    ),
)
def test_definition_validation_is_strict(changes: dict[str, object], message: str) -> None:
    base = demo_scenario("multi-action-demo-v0")
    with pytest.raises(ValueError, match=message):
        replace(base, **changes)


def test_definition_rejects_non_tuple_policy_source_collection() -> None:
    base = demo_scenario("orientation-v0")
    values = {field: getattr(base, field) for field in base.__dataclass_fields__}
    values["policy_source_ids"] = ["scripted-solo-demo-v1"]
    with pytest.raises(ValueError, match="policy_source_ids"):
        DemoScenarioDefinition(**values)  # type: ignore[arg-type]
