from pathlib import Path

import pytest
from genesis_arena.embodiment.duel.scripted_provider import ScriptedBaselineAdapter
from genesis_arena.embodiment.protocol import (
    EmbodimentProtocolPackage,
    canonical_json_bytes,
    strict_json_loads,
)
from genesis_arena.embodiment.providers.contracts import ProviderRequest

ROOT = Path(__file__).resolve().parents[2]


def _request(observation):
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    return ProviderRequest(
        episode_id=observation["episode_id"],
        participant_id="participant_0",
        observation_seq=observation["observation_seq"],
        deadline_monotonic_ns=1,
        model="balanced-v1",
        system_prompt="Return one action.",
        observation_json=canonical_json_bytes(observation),
        action_schema_json=canonical_json_bytes(package.schema("controller-action")),
        frame_png=None,
    )


@pytest.mark.asyncio
async def test_scripted_adapter_returns_canonical_visible_only_action() -> None:
    observation = {
        "protocol_version": "llm-controller/0.1.0",
        "episode_id": "ep_scripted_adapter",
        "observation_seq": 2,
        "tick": 20,
        "profile": "text-visible-v1",
        "goal": "Hold the relay.",
        "remaining_ticks": 1780,
        "self": {"health_percent": 100},
        "visible_entities": [
            {
                "id": "v_relay",
                "kind": "relay",
                "bearing": "front",
                "distance": "touching",
                "state": "neutral",
                "affordances": ["interactable"],
            }
        ],
        "recent_events": [],
        "previous_receipt": None,
        "memory": "ignored",
        "terminal": {"ended": False, "outcome": "running", "reason": "running"},
    }
    adapter = ScriptedBaselineAdapter("balanced-v1")
    result = await adapter.request(_request(observation))
    action = strict_json_loads(result.raw_output)

    assert result.raw_output == canonical_json_bytes(action)
    assert action["control"]["duration_ticks"] == 10
    assert action["control"]["buttons"]["interact"] is True
    assert action["memory_update"] == ""
    assert "spectator" not in result.raw_output.decode()
    assert result.telemetry.latency_ms == 0
