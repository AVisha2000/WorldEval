from __future__ import annotations

from pathlib import Path

import pytest
from genesis_arena.embodiment.protocol import (
    EmbodimentProtocolPackage,
    canonical_json_bytes,
    strict_json_loads,
)
from genesis_arena.embodiment.providers.contracts import ProviderFailureKind, ProviderRequest
from genesis_arena.embodiment.scripted_solo_demo import (
    SCRIPTED_DIRECT_TASKS,
    ScriptedSoloDemoProvider,
    scripted_demo_model,
)

ROOT = Path(__file__).resolve().parents[2]


def _request(task_id: str, observation: dict) -> ProviderRequest:
    return ProviderRequest(
        episode_id="ep_scripted_solo",
        participant_id="participant_0",
        observation_seq=0,
        deadline_monotonic_ns=1,
        model=scripted_demo_model(task_id),
        system_prompt="deterministic scripted demo",
        observation_json=canonical_json_bytes(observation),
        action_schema_json=b"{}",
    )


def _observation(
    *,
    entities: list[dict],
    inventory: list[dict] | None = None,
    status: list[str] | None = None,
) -> dict:
    return {
        "episode_id": "ep_scripted_solo",
        "observation_seq": 0,
        "tick": 0,
        "profile": "text-visible-v1",
        "self": {"inventory": inventory or [], "status": status or []},
        "visible_entities": entities,
        "terminal": {"ended": False},
    }


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("task_id", "observation", "expected"),
    (
        (
            "orientation-v0",
            _observation(
                entities=[
                    {
                        "id": "v_beacon_1",
                        "bearing": "front",
                        "distance": "far",
                        "state": "active",
                    }
                ]
            ),
            {"move_y": 1000, "interact": False, "primary": False},
        ),
        (
            "interaction-v0",
            _observation(
                entities=[
                    {
                        "id": "v_resource_1",
                        "bearing": "front",
                        "distance": "touching",
                        "state": "available",
                    },
                    {
                        "id": "v_relay_1",
                        "bearing": "back",
                        "distance": "far",
                        "state": "empty",
                    },
                ]
            ),
            {"move_y": 0, "interact": True, "primary": False},
        ),
        (
            "neutral-encounter-v0",
            _observation(
                entities=[
                    {
                        "id": "v_neutral_1",
                        "bearing": "front",
                        "distance": "touching",
                        "state": "chase_healthy",
                    },
                    {
                        "id": "v_relay_1",
                        "bearing": "front",
                        "distance": "far",
                        "state": "defended",
                    },
                ]
            ),
            {"move_y": 0, "interact": False, "primary": True},
        ),
    ),
)
async def test_scripted_direct_demos_emit_only_valid_visible_controller_actions(
    task_id: str, observation: dict, expected: dict
) -> None:
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    result = await ScriptedSoloDemoProvider(task_id).request(_request(task_id, observation))

    assert result.failure is None
    assert result.raw_output is not None
    action = strict_json_loads(result.raw_output)
    package.validate("controller-action", action)
    assert action["control"]["duration_ticks"] == 1
    assert action["control"]["move_y"] == expected["move_y"]
    assert action["control"]["buttons"]["interact"] is expected["interact"]
    assert action["control"]["buttons"]["primary"] is expected["primary"]
    assert b"position" not in result.raw_output
    assert b"prompt" not in result.raw_output


@pytest.mark.asyncio
async def test_scripted_direct_demo_rejects_missing_visible_target() -> None:
    task_id = "orientation-v0"
    result = await ScriptedSoloDemoProvider(task_id).request(
        _request(task_id, _observation(entities=[]))
    )

    assert result.raw_output is None
    assert result.failure == ProviderFailureKind.INVALID_RESPONSE


def test_scripted_direct_demo_excludes_construction_task_plan_stage() -> None:
    assert "construction-v0" not in SCRIPTED_DIRECT_TASKS
    with pytest.raises(ValueError, match="unsupported"):
        ScriptedSoloDemoProvider("construction-v0")
