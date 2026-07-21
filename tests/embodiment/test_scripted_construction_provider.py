from __future__ import annotations

import hashlib
from pathlib import Path

import pytest
from genesis_arena.embodiment.construction_task_provider import ConstructionTaskProvider
from genesis_arena.embodiment.protocol import (
    EmbodimentProtocolPackage,
    canonical_json_bytes,
    strict_json_loads,
)
from genesis_arena.embodiment.providers.contracts import ProviderRequest
from genesis_arena.embodiment.scripted_construction_demo import (
    DEMO_BUILD_START_TICK,
    SCRIPTED_CONSTRUCTION_MODEL,
    ScriptedConstructionDemoProvider,
    demo_task_timeout_ticks,
)

ROOT = Path(__file__).resolve().parents[2]


def _request(
    *,
    sequence: int,
    tick: int,
    inventory: list[dict] | None = None,
    resource_state: str = "available",
    pad_state: str = "needs_materials",
) -> ProviderRequest:
    frame = (
        b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"
        + (1280).to_bytes(4, "big")
        + (720).to_bytes(4, "big")
    )
    observation = {
        "episode_id": "ep_scripted_demo",
        "observation_seq": sequence,
        "tick": tick,
        "profile": "hybrid-visible-v1",
        "frame": {
            "sensor_id": "operator-follow-v1",
            "mime_type": "image/png",
            "width": 1280,
            "height": 720,
            "sha256": hashlib.sha256(frame).hexdigest(),
            "transport_ref": f"frame:participant_0.{sequence}",
        },
        "self": {"inventory": inventory or []},
        "visible_entities": [
            {"id": "v_resource_1", "state": resource_state},
            {"id": "v_relay_1", "state": "materials_ready"},
            {"id": "v_build_pad_1", "state": pad_state},
        ],
        "previous_receipt": None,
        "terminal": {"ended": False},
    }
    return ProviderRequest(
        episode_id="ep_scripted_demo",
        participant_id="participant_0",
        observation_seq=sequence,
        deadline_monotonic_ns=1,
        model=SCRIPTED_CONSTRUCTION_MODEL,
        system_prompt="deterministic test",
        observation_json=canonical_json_bytes(observation),
        action_schema_json=b"{}",
        frame_png=frame,
    )


@pytest.mark.asyncio
async def test_scripted_demo_uses_the_strict_task_plan_boundary() -> None:
    provider = ScriptedConstructionDemoProvider(showcase=True)
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    cases = (
        (_request(sequence=0, tick=0), "gather_materials"),
        (
            _request(
                sequence=1,
                tick=10,
                inventory=[{"kind": "material", "count": 2, "selected": True}],
            ),
            "deliver_materials",
        ),
        (
            _request(
                sequence=2,
                tick=DEMO_BUILD_START_TICK - 1,
                resource_state="depleted",
                pad_state="ready",
            ),
            "wait",
        ),
        (
            _request(
                sequence=3,
                tick=DEMO_BUILD_START_TICK,
                resource_state="depleted",
                pad_state="ready",
            ),
            "build_barricade",
        ),
    )

    for request, expected_task in cases:
        result = await provider.request(request)
        assert result.failure is None
        assert result.raw_output is not None
        plan = strict_json_loads(result.raw_output)
        package.validate("construction-task-plan", plan)
        assert plan["task_id"] == expected_task
        assert plan["episode_id"] == request.episode_id
        assert plan["observation_seq"] == request.observation_seq


@pytest.mark.asyncio
async def test_scripted_demo_wait_is_replayed_locally_until_the_late_build_phase() -> None:
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    adapter = ConstructionTaskProvider(
        ScriptedConstructionDemoProvider(showcase=True),
        package,
        task_timeout_ticks=demo_task_timeout_ticks,
    )
    initial_tick = DEMO_BUILD_START_TICK - 25
    first = await adapter.request(
        _request(
            sequence=0,
            tick=initial_tick,
            resource_state="depleted",
            pad_state="ready",
        )
    )
    replayed = await adapter.request(
        _request(
            sequence=1,
            tick=initial_tick + 1,
            resource_state="depleted",
            pad_state="ready",
        )
    )
    assert first.raw_output is not None
    assert replayed.raw_output is not None
    assert strict_json_loads(first.raw_output)["control"]["autonomous_task"] == "wait"
    assert strict_json_loads(replayed.raw_output)["control"]["autonomous_task"] == "wait"
    assert demo_task_timeout_ticks(
        "wait", {"tick": initial_tick}
    ) == DEMO_BUILD_START_TICK - initial_tick


@pytest.mark.asyncio
async def test_ordinary_construction_builds_immediately_without_showcase_staging() -> None:
    result = await ScriptedConstructionDemoProvider().request(
        _request(
            sequence=0,
            tick=100,
            resource_state="depleted",
            pad_state="ready",
        )
    )
    assert result.raw_output is not None
    assert strict_json_loads(result.raw_output)["task_id"] == "build_barricade"
