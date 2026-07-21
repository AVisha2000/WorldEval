from __future__ import annotations

import asyncio
from pathlib import Path
from types import SimpleNamespace

import pytest
from genesis_arena.embodiment.contracts import ControllerState
from genesis_arena.embodiment.protocol_registry import EmbodimentProtocolRegistry
from genesis_arena.embodiment.trio_games.common import (
    TrioControllerAction,
    TrioResolvedDecision,
)
from genesis_arena.embodiment.trio_games.scheduler import TrioSeriesScheduler
from genesis_arena.embodiment.trio_games.scheduling import build_cyclic_trio_plan

ROOT = Path(__file__).resolve().parents[2]


class _NoFrameSession:
    async def render(self, *_args):
        raise AssertionError("text-only test must not request a frame")


class _Controller:
    def __init__(self, disposition: str, started: list[str], participant_id: str) -> None:
        self.policy_lock = SimpleNamespace(model=f"demo-{participant_id}")
        self._disposition = disposition
        self._started = started
        self._participant_id = participant_id

    async def decide(self, request, *, eliminated=False):
        assert not eliminated
        self._started.append(self._participant_id)
        if self._disposition == "raise":
            raise RuntimeError("isolated provider fault")
        if self._disposition == "slow":
            await asyncio.sleep(10)
        action = TrioControllerAction(
            episode_id=request.episode_id,
            observation_seq=request.observation_seq,
            action_id=f"accepted_{self._participant_id}",
            control=ControllerState(0, 1000, 0, 0, 10),
        )
        return TrioResolvedDecision(action, "accepted", "accepted", True)


@pytest.mark.asyncio
async def test_shared_deadline_keeps_completed_decision_when_other_seats_fail() -> None:
    plan = build_cyclic_trio_plan(
        series_id="series_scheduler_isolation",
        task_id="trio-relay-v0",
        seed=17,
        schedule_nonce="isolation_nonce",
    )
    package = EmbodimentProtocolRegistry.from_repository(ROOT).package(
        "llm-controller/0.3.0"
    )

    async def unused_factory(_value):
        raise AssertionError("direct window test does not construct sessions")

    scheduler = TrioSeriesScheduler(
        plan=plan,
        session_factory=unused_factory,
        controller_factory=unused_factory,
        protocol_package=package,
        provider_timeout_s=0.02,
    )
    started: list[str] = []
    controllers = {
        "participant_0": _Controller("accepted", started, "participant_0"),
        "participant_1": _Controller("raise", started, "participant_1"),
        "participant_2": _Controller("slow", started, "participant_2"),
    }
    episode_id = plan.legs[0].episode_id
    observations = {
        participant_id: {
            "episode_id": episode_id,
            "observation_seq": 0,
            "tick": 0,
            "profile": "text-visible-v1",
            "self": {"status": []},
            "terminal": {"ended": False},
            "visible_entities": [],
        }
        for participant_id in controllers
    }

    window = await scheduler._window(
        plan.legs[0], _NoFrameSession(), controllers, observations, 0, 0
    )

    assert set(started) == set(controllers)
    assert window.duration_ticks == 10
    assert window.decisions["participant_0"].disposition == "accepted"
    assert window.decisions["participant_1"].disposition == "no_input"
    assert window.decisions["participant_2"].disposition == "no_input"
    assert window.decisions["participant_1"].no_input_reason == "timeout"
    assert window.decisions["participant_2"].no_input_reason == "timeout"
