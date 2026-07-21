from __future__ import annotations

import pytest

from backend.genesis_arena.embodiment.trio_games.common import TRIO_PARTICIPANT_IDS
from backend.genesis_arena.embodiment.trio_games.scheduling import (
    TRIO_DEMO_ENTRANTS,
    TRIO_SPAWN_SLOTS,
    TrioLegPlan,
    TrioSeatAssignment,
    build_cyclic_trio_plan,
)


@pytest.mark.parametrize("task_id", ["trio-relay-v0", "trio-free-for-all-v0"])
def test_cyclic_plan_is_deterministic_and_each_entrant_uses_every_seat(task_id: str) -> None:
    first = build_cyclic_trio_plan(
        series_id="series_demo", task_id=task_id, seed=77, schedule_nonce="nonce_a"
    )
    second = build_cyclic_trio_plan(
        series_id="series_demo", task_id=task_id, seed=77, schedule_nonce="nonce_a"
    )
    assert first == second
    assert first.plan_sha256 == second.plan_sha256
    assert len(first.legs) == 3
    for entrant in TRIO_DEMO_ENTRANTS:
        assignments = [
            assignment
            for leg in first.legs
            for assignment in leg.assignments
            if assignment.entrant_id == entrant.entrant_id
        ]
        assert {value.participant_id for value in assignments} == set(TRIO_PARTICIPANT_IDS)
        assert {value.spawn_slot for value in assignments} == set(TRIO_SPAWN_SLOTS)
        assert len(assignments) == 3
    for leg in first.legs:
        assert leg.decision_ticks == 10
        assert {value.dispatch_precedence for value in leg.assignments} == {0, 1, 2}


def test_leg_contract_rejects_missing_or_duplicate_third_participant() -> None:
    assignment = TrioSeatAssignment("sol", "participant_0", "south", 0)
    with pytest.raises((TypeError, ValueError), match="three-item|exactly once"):
        TrioLegPlan(
            series_id="series_demo",
            episode_id="ep_series_demo_leg",
            task_id="trio-relay-v0",
            leg_index=0,
            seed=1,
            schedule_nonce="nonce",
            assignments=(assignment, assignment, assignment),
        )


def test_named_demo_identities_are_explicit_and_never_claim_live_models() -> None:
    assert [(value.display_name, value.provider) for value in TRIO_DEMO_ENTRANTS] == [
        ("Sol", "demo"),
        ("Luna", "demo"),
        ("Terra", "demo"),
    ]
    assert all(value.model.startswith("demo-") for value in TRIO_DEMO_ENTRANTS)
