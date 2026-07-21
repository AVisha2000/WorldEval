from __future__ import annotations

from typing import Any

import pytest
from genesis_arena.embodiment.labyrinth_run import TICKS_PER_CELL
from genesis_arena.embodiment.live_labyrinth import LiveMazeEntrant, run_live_labyrinth_race
from genesis_arena.embodiment.live_labyrinth_media import (
    project_live_labyrinth_broadcast_replay,
)
from genesis_arena.embodiment.protocol import canonical_json_bytes, strict_json_loads
from genesis_arena.embodiment.providers.contracts import (
    ProviderCallResult,
    ProviderRequest,
    ProviderTelemetry,
)


class _PublicTrackProvider:
    provider_name = "fake"

    def __init__(self) -> None:
        self._calls = 0

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        observation = strict_json_loads(request.observation_json)
        # The first currently visible move is valid at the fixed maze start.  All following calls
        # wait, exercising both moving and stationary public keyframes without exposing plan text.
        choice = observation["visible_passages"][0] if self._calls == 0 else "wait"
        self._calls += 1
        plan: dict[str, Any] = {
            "protocol_version": "maze-task-plan-v1",
            "episode_id": request.episode_id,
            "observation_id": observation["observation_id"],
            "participant_id": request.participant_id,
            "passage_choice": choice,
            "scratchpad_update": "private route note",
        }
        return ProviderCallResult.success(
            canonical_json_bytes(plan), ProviderTelemetry(latency_ms=0)
        )


def _entrants() -> tuple[LiveMazeEntrant, ...]:
    return (
        LiveMazeEntrant("participant_0", "sol", "Sol", "fake", "fake-sol", "#fbbf24"),
        LiveMazeEntrant("participant_1", "terra", "Terra", "fake", "fake-terra", "#34d399"),
        LiveMazeEntrant("participant_2", "luna", "Luna", "fake", "fake-luna", "#a78bfa"),
    )


@pytest.mark.asyncio
async def test_public_live_replay_projects_to_existing_broadcast_shape() -> None:
    execution = await run_live_labyrinth_race(
        episode_id="ep_live_labyrinth_media",
        entrants=_entrants(),
        providers={
            participant_id: _PublicTrackProvider()
            for participant_id in ("participant_0", "participant_1", "participant_2")
        },
        max_provider_calls=180,
    )

    projected = project_live_labyrinth_broadcast_replay(execution.replay)

    assert projected["task_id"] == "trio-maze-race-v0"
    assert projected["protocol_version"] == "maze-task-plan-v1"
    assert projected["source"] == {
        "task_id": "trio-maze-race-v1",
        "final_state_sha256": execution.replay["final_state_sha256"],
    }
    assert [racer["participant_id"] for racer in projected["racers"]] == [
        "participant_0",
        "participant_1",
        "participant_2",
    ]
    for racer in projected["racers"]:
        assert racer["keyframes"][0] == {
            "tick": 0,
            "cell": [7, 13],
            "heading": 0,
            "state": "thinking",
            "task": "exploring",
        }
        assert racer["keyframes"][1]["tick"] == TICKS_PER_CELL
        assert racer["keyframes"][1]["state"] == "walk"
        assert racer["keyframes"][2]["cell"] == racer["keyframes"][1]["cell"]
        assert racer["keyframes"][2]["task"] == "waiting"
    assert {event["label"] for event in projected["events"]} == {
        "Advancing through maze",
        "Waiting at passage",
    }
    public_text = repr(projected).casefold()
    assert "scratchpad" not in public_text
    assert "private route" not in public_text
    assert "raw_output" not in public_text
