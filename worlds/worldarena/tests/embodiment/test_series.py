from dataclasses import FrozenInstanceError

import pytest
from genesis_arena.embodiment.series import (
    ModelLock,
    SeriesLock,
    VerifiedLeg,
    aggregate_pair,
    rerun_lock,
    schedule_pair,
)

HASH = "a" * 64


def _lock(seed: int = 7, nonce: str = "schedule-0") -> SeriesLock:
    return SeriesLock(
        protocol_version="llm-controller/0.1.0",
        protocol_sha256="1" * 64,
        rules_sha256="2" * 64,
        map_sha256="3" * 64,
        body_sha256="4" * 64,
        controller_sha256="5" * 64,
        projector_sha256="6" * 64,
        evaluator_sha256="7" * 64,
        entrants=(
            ModelLock("entrant_a", "openai", "8" * 64, "model-a", "medium"),
            ModelLock("entrant_b", "anthropic", "9" * 64, "model-b", "enabled"),
        ),
        max_input_bytes=8_388_608,
        max_output_bytes=8192,
        deadline_ms=30_000,
        observation_profile="hybrid-visible-v1",
        timing_track="step-locked-v1",
        seed=seed,
        schedule_nonce=nonce,
    )


def _leg(schedule_sha256, outcome="draw", winner=None, **overrides):
    values = {
        "schedule_sha256": schedule_sha256,
        "replay_sha256": HASH,
        "terminal_state_sha256": "b" * 64,
        "outcome": outcome,
        "winner_entrant_id": winner,
        "complete": True,
        "independently_verified": True,
    }
    values.update(overrides)
    return VerifiedLeg(**values)


def test_lock_contains_all_fairness_inputs_and_has_stable_canonical_hash() -> None:
    lock = _lock()
    material = lock.as_dict()
    assert set(material) == {
        "body_sha256",
        "controller_sha256",
        "deadline_ms",
        "entrants",
        "evaluator_sha256",
        "map_sha256",
        "max_input_bytes",
        "max_output_bytes",
        "observation_profile",
        "projector_sha256",
        "protocol_sha256",
        "protocol_version",
        "rules_sha256",
        "schedule_nonce",
        "seed",
        "timing_track",
    }
    assert material["entrants"][0] == {
        "adapter_sha256": "8" * 64,
        "entrant_id": "entrant_a",
        "model": "model-a",
        "provider": "openai",
        "reasoning": "medium",
    }
    assert lock.lock_sha256 == _lock().lock_sha256
    assert lock.lock_sha256 != _lock(seed=8).lock_sha256
    with pytest.raises(FrozenInstanceError):
        lock.seed = 8


def test_second_leg_swaps_seat_spawn_side_and_dispatch_precedence() -> None:
    first, second = schedule_pair(_lock())
    by_entrant_first = {value.entrant_id: value for value in first.assignments}
    by_entrant_second = {value.entrant_id: value for value in second.assignments}
    for entrant_id in by_entrant_first:
        left = by_entrant_first[entrant_id]
        right = by_entrant_second[entrant_id]
        assert left.participant_id != right.participant_id
        assert left.spawn_side != right.spawn_side
        assert left.dispatch_precedence != right.dispatch_precedence
    assert first.decision_ticks == second.decision_ticks == 10
    assert first.scratchpad_epoch != second.scratchpad_epoch
    assert first.fresh_scratchpads() == second.fresh_scratchpads() == (b"", b"")


def test_ten_seed_schedules_are_deterministic_and_side_balanced() -> None:
    hashes = set()
    for seed in range(10):
        lock = _lock(seed=seed, nonce=f"seed-{seed}")
        first = schedule_pair(lock)
        second = schedule_pair(lock)
        assert first == second
        hashes.add(tuple(leg.schedule_sha256 for leg in first))
        for entrant in lock.entrants:
            sides = {
                assignment.spawn_side
                for leg in first
                for assignment in leg.assignments
                if assignment.entrant_id == entrant.entrant_id
            }
            assert sides == {"south", "north"}
    assert len(hashes) == 10


def test_only_complete_independently_verified_matching_legs_aggregate() -> None:
    lock = _lock()
    schedules = schedule_pair(lock)
    complete = (
        _leg(schedules[0].schedule_sha256, "win", "entrant_a"),
        _leg(schedules[1].schedule_sha256, "win", "entrant_b"),
    )
    result = aggregate_pair(lock, complete)
    assert result.status == "complete"
    assert result.leg_wins == (1, 1)
    assert result.winner_entrant_id is None
    assert not result.rerun_required
    assert len(result.result_sha256) == 64

    with pytest.raises(ValueError, match="complete independently verified"):
        aggregate_pair(
            lock,
            (complete[0], _leg(schedules[1].schedule_sha256, complete=False)),
        )
    with pytest.raises(ValueError, match="complete independently verified"):
        aggregate_pair(
            lock,
            (complete[0], _leg(schedules[1].schedule_sha256, independently_verified=False)),
        )
    with pytest.raises(ValueError, match="expected schedule"):
        aggregate_pair(lock, (complete[0], _leg("c" * 64)))


def test_void_invalidates_pair_and_rerun_requires_explicit_new_nonce() -> None:
    lock = _lock()
    schedules = schedule_pair(lock)
    result = aggregate_pair(
        lock,
        (
            _leg(schedules[0].schedule_sha256, "void"),
            _leg(schedules[1].schedule_sha256),
        ),
    )
    assert result.status == "invalid"
    assert result.rerun_required
    assert result.leg_wins == (0, 0)

    with pytest.raises(ValueError, match="must differ"):
        rerun_lock(lock, schedule_nonce=lock.schedule_nonce)
    rerun = rerun_lock(lock, schedule_nonce="schedule-1")
    assert rerun.schedule_nonce == "schedule-1"
    assert rerun.lock_sha256 != lock.lock_sha256
    assert schedule_pair(rerun)[0].schedule_sha256 != schedules[0].schedule_sha256


def test_series_contracts_reject_bool_integers_bad_hashes_and_mutable_sequences() -> None:
    with pytest.raises(ValueError):
        _lock(seed=True)
    with pytest.raises(ValueError):
        SeriesLock(
            **{
                **_lock().__dict__,
                "observation_profile": "text-visible-v1",
            }
        )
    values = _lock().__dict__.copy()
    values["protocol_sha256"] = "A" * 64
    with pytest.raises(ValueError):
        SeriesLock(**values)
    values = _lock().__dict__.copy()
    values["entrants"] = list(_lock().entrants)
    with pytest.raises(TypeError):
        SeriesLock(**values)
