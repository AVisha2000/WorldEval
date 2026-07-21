from __future__ import annotations

import asyncio
from collections import deque

import pytest
from genesis_arena.embodiment.labyrinth_run import HEADINGS, _cell_graph, _start_exit
from genesis_arena.embodiment.live_labyrinth import (
    LIVE_TASK_ID,
    LiveLabyrinthError,
    LiveLabyrinthService,
    LiveMazeEntrant,
    public_live_evaluation,
    run_live_labyrinth_race,
    verify_live_replay,
)
from genesis_arena.embodiment.protocol import canonical_json_bytes, strict_json_loads
from genesis_arena.embodiment.providers.contracts import (
    ProviderCallResult,
    ProviderRequest,
    ProviderTelemetry,
)


class ScriptedMazeProvider:
    provider_name = "fake"

    def __init__(self, choices: list[str], *, stale: bool = False) -> None:
        self._choices = iter(choices)
        self._stale = stale
        self.requests: list[ProviderRequest] = []

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        self.requests.append(request)
        observation = strict_json_loads(request.observation_json)
        choice = next(self._choices, "wait")
        payload = {
            "protocol_version": "maze-task-plan-v1",
            "episode_id": request.episode_id,
            "observation_id": "obs_participant_0_0000"
            if self._stale
            else observation["observation_id"],
            "participant_id": request.participant_id,
            "passage_choice": choice,
            "scratchpad_update": "private route note",
        }
        return ProviderCallResult.success(
            canonical_json_bytes(payload), ProviderTelemetry(latency_ms=0)
        )


def _shortest_choices() -> list[str]:
    graph = _cell_graph()
    start, exit_cell = _start_exit()
    previous = {start: None}
    queue = deque([start])
    while queue:
        current = queue.popleft()
        if current == exit_cell:
            break
        for candidate in graph[current]:
            if candidate not in previous:
                previous[candidate] = current
                queue.append(candidate)
    path = []
    current = exit_cell
    while current != start:
        path.append(current)
        current = previous[current]
    path.append(start)
    path.reverse()
    heading = 0
    choices = []
    names = ("forward", "right", "back", "left")
    for source, target in zip(path, path[1:]):
        absolute = HEADINGS.index((target[0] - source[0], target[1] - source[1]))
        choices.append(names[(absolute - heading) % 4])
        heading = absolute
    return choices


def _entrants() -> tuple[LiveMazeEntrant, ...]:
    return (
        LiveMazeEntrant("participant_0", "sol", "Sol", "fake", "fake-sol", "#fbbf24"),
        LiveMazeEntrant("participant_1", "terra", "Terra", "fake", "fake-terra", "#34d399"),
        LiveMazeEntrant("participant_2", "luna", "Luna", "fake", "fake-luna", "#a78bfa"),
    )


@pytest.mark.asyncio
async def test_live_race_runs_three_private_provider_calls_and_seals_public_replay() -> None:
    choices = _shortest_choices()
    providers = {
        participant_id: ScriptedMazeProvider(choices)
        for participant_id in ("participant_0", "participant_1", "participant_2")
    }
    execution = await run_live_labyrinth_race(
        episode_id="ep_live_labyrinth_test",
        entrants=_entrants(),
        providers=providers,
        max_provider_calls=180,
    )

    assert execution.replay["task_id"] == LIVE_TASK_ID
    assert execution.replay["result"]["finish_order"] == [
        "participant_0",
        "participant_1",
        "participant_2",
    ]
    assert execution.replay["provider_calls"] == 180
    assert all(len(provider.requests) == 60 for provider in providers.values())
    for provider in providers.values():
        observation = strict_json_loads(provider.requests[0].observation_json)
        assert set(observation) == {
            "episode_id",
            "observation_id",
            "observation_seq",
            "participant_id",
            "protocol_version",
            "profile",
            "tick",
            "visible_passages",
            "landmark",
            "at_exit",
        }
        assert "participant_0" not in provider.requests[0].system_prompt
    serialized = repr(execution.replay).casefold()
    assert all(term not in serialized for term in ("scratchpad", "raw_output", "private route"))
    assert any(
        item.raw_output and b"private route" in item.raw_output
        for item in execution.protected_decisions
    )
    verify_live_replay(execution.replay)
    assert public_live_evaluation(execution.replay)["verification"]["state"] == "verified"


@pytest.mark.asyncio
async def test_stale_plan_is_only_an_invalid_wait_for_its_racer() -> None:
    choices = _shortest_choices()
    providers = {
        "participant_0": ScriptedMazeProvider(choices, stale=True),
        "participant_1": ScriptedMazeProvider(choices),
        "participant_2": ScriptedMazeProvider(choices),
    }
    execution = await run_live_labyrinth_race(
        episode_id="ep_live_labyrinth_stale",
        entrants=_entrants(),
        providers=providers,
        max_provider_calls=180,
    )
    racers = {value["participant_id"]: value for value in execution.replay["racers"]}
    # The fixture's first stale id happens to match sequence zero; subsequent windows fail closed.
    assert racers["participant_0"]["invalid_decisions"] == (
        len(providers["participant_0"].requests) - 1
    )
    assert racers["participant_0"]["finished"] is False
    assert racers["participant_1"]["finished"] is True
    assert racers["participant_2"]["finished"] is True


@pytest.mark.asyncio
async def test_service_returns_public_entrants_and_runs_cleanup_once() -> None:
    choices = _shortest_choices()
    providers = {
        participant_id: ScriptedMazeProvider(choices)
        for participant_id in ("participant_0", "participant_1", "participant_2")
    }
    cleaned = 0

    async def cleanup() -> None:
        nonlocal cleaned
        cleaned += 1

    service = LiveLabyrinthService()
    created = await service.create(
        entrants=_entrants(), providers=providers, max_provider_calls=180, cleanup=cleanup
    )
    for _ in range(200):
        status = await service.status(created["episode_id"])
        if status["state"] != "queued" and status["state"] != "running":
            break
        await asyncio.sleep(0)
    assert status["state"] == "completed"
    assert [value["display_name"] for value in status["entrants"]] == ["Sol", "Terra", "Luna"]
    assert cleaned == 1


def test_verifier_rejects_public_protected_material() -> None:
    replay = {
        "schema_version": "worldarena/live-labyrinth-run-replay/1",
        "task_id": LIVE_TASK_ID,
        "protocol_version": "maze-task-plan-v1",
        "map": {"rows": []},
        "final_state_sha256": "not-a-valid-hash",
        "scratchpad": "do not publish",
    }
    with pytest.raises(LiveLabyrinthError):
        verify_live_replay(replay)
