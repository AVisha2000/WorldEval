from __future__ import annotations

import pytest
from genesis_arena.arena.models import (
    ActionAvailability,
    ArenaEvent,
    CognitionView,
    FactionObservation,
    ResourceDelta,
    RewardVector,
    RewardVectorMetadata,
    RoundDelta,
    RoundReceipt,
    TaskReceipt,
    TerminationMetadata,
    TruncationMetadata,
    VisionObservation,
)
from genesis_arena.arena_api import ArenaMatchConfigure
from pydantic import ValidationError


def _scores() -> list[dict[str, object]]:
    return [
        {
            "faction_id": faction,
            "core_health": 1_000,
            "supplied_land": 1,
            "territory_time": 0,
        }
        for faction in ("sol", "terra", "luna")
    ]


def _observation(**overrides: object) -> FactionObservation:
    payload: dict[str, object] = {
        "match_id": "match-v03",
        "round": 1,
        "faction_id": "sol",
        "snapshot_hash": "a" * 64,
        "inventory": {},
        "public_scores": _scores(),
        "cognition": CognitionView(remaining_units=20),
        "available_actions": ["scout"],
        "action_mask": [{"action": "scout", "enabled": True}],
    }
    payload.update(overrides)
    return FactionObservation.model_validate(payload)


def test_v03_observation_masks_and_vision_modes_are_strict() -> None:
    observation = _observation(
        observation_mode="hybrid",
        vision=VisionObservation(
            frame_id="frame-1",
            content_hash="b" * 64,
            width=1280,
            height=720,
            frame_uri="replay://match-v03/frame-1.png",
        ),
    )
    assert observation.action_mask[0].action.value == "scout"

    with pytest.raises(ValidationError, match="exactly match"):
        _observation(
            action_mask=[ActionAvailability(action="scout", enabled=False, reason="no scout unit")]
        )
    with pytest.raises(ValidationError, match="vision frame"):
        _observation(observation_mode="vision", available_actions=[], action_mask=[])


def test_v03_receipts_are_canonical_and_keep_rewards_separate() -> None:
    event = ArenaEvent(
        event_id="event-1",
        match_id="match-v03",
        sequence=0,
        round=1,
        tick=10,
        kind="task_impact",
        visibility="faction",
        visible_to=["sol"],
        summary="Worker gathers wood.",
        payload={"resource_delta": 12, "task_id": "task-1"},
    )
    receipt = RoundReceipt(
        protocol="world-arena/0.3",
        match_id="match-v03",
        round=1,
        previous_state_hash="a" * 64,
        state_hash="b" * 64,
        delta=RoundDelta(
            base_state_hash="a" * 64,
            canonical_events=[event],
            resource_deltas={"sol": ResourceDelta(wood=12)},
        ),
        task_receipts=[
            TaskReceipt(
                task_id="task-1",
                faction_id="sol",
                task_kind="gather",
                status="impact",
                required_work=10,
                completed_work=0,
                resource_delta=ResourceDelta(wood=12),
                event_id="event-1",
            )
        ],
        reward_vector=RewardVectorMetadata(
            vectors=[
                RewardVector(faction_id=faction, components={"economy_delta": 1.0})
                for faction in ("sol", "terra", "luna")
            ]
        ),
        termination=TerminationMetadata(terminated=False),
        truncation=TruncationMetadata(truncated=False),
    )
    assert receipt.reward_vector is not None
    assert receipt.reward_vector.exposed_to_agent is False

    with pytest.raises(ValidationError, match="base_state_hash"):
        RoundReceipt.model_validate(
            {
                **receipt.model_dump(mode="json"),
                "delta": {**receipt.delta.model_dump(mode="json"), "base_state_hash": "c" * 64},
            }
        )


def test_configuration_accepts_v03_advisor_count_without_breaking_legacy_limit() -> None:
    config = ArenaMatchConfigure.model_validate(
        {
            "type": "configure_match",
            "protocol": "world-arena/0.3",
            "observation_mode": "semantic",
            "agents": [
                {"agent_id": faction, "model": "demo", "advisor_count": 2}
                for faction in ("sol", "terra", "luna")
            ],
        }
    )
    assert [agent.specialist_limit for agent in config.agents] == [2, 2, 2]
