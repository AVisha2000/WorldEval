from __future__ import annotations

import pytest
from genesis_arena.duel import (
    ActionBatch,
    CommitRevealError,
    FailureClassification,
    FailureOwner,
    FixedCommitRevealWindow,
    ModelFailureCounter,
    action_batch_commit_hash,
    batch_is_fresh,
    continuous_application_tick,
    controller_valid_until_tick,
    verify_action_batch_commit,
)


def _empty_batch(match_id: str, sequence: int, slot: int) -> ActionBatch:
    return ActionBatch(
        match_id=match_id,
        observation_seq=sequence,
        based_on_observation_hash=("a" if slot == 0 else "b") * 64,
        client_batch_id=f"batch_{sequence}_{slot}",
        valid_until_tick=sequence * 100 + 1,
        commands=[],
    )


def test_commit_reveal_cannot_disclose_first_batch_before_both_commits() -> None:
    window = FixedCommitRevealWindow("m_match_1", 4)
    batch_zero = _empty_batch("m_match_1", 4, 0)
    batch_one = _empty_batch("m_match_1", 4, 1)
    salt_zero = "00" * 32
    salt_one = "11" * 32

    commit_zero = window.add_private_batch(0, batch_zero, salt_zero)
    assert verify_action_batch_commit(batch_zero, salt_zero, commit_zero)
    with pytest.raises(CommitRevealError, match="all slots"):
        window.lock_commits()
    with pytest.raises(CommitRevealError, match="only after"):
        window.reveal_all()

    commit_one = window.add_private_batch(1, batch_one, salt_one)
    assert commit_one == action_batch_commit_hash(batch_one, salt_one)
    assert window.lock_commits() == {0: commit_zero, 1: commit_one}
    reveals = window.reveal_all()
    assert reveals[0].batch == batch_zero
    assert reveals[1].batch == batch_one


def test_action_batch_commit_matches_godot_wire_vector() -> None:
    batch = ActionBatch(
        match_id="m_commit-vector",
        observation_seq=0,
        based_on_observation_hash="0" * 64,
        client_batch_id="vector.batch",
        valid_until_tick=1,
        working_memory="vector",
        commands=[],
    )
    assert action_batch_commit_hash(
        batch,
        "000102030405060708090a0b0c0d0e0f"
        "101112131415161718191a1b1c1d1e1f",
    ) == "afb111cea7e182183a0f805362dda469a361e471ac6b40c5b5472d9a33318dcc"


def test_continuous_gate_uses_strictly_later_tick_at_exact_boundary() -> None:
    start = 5_000_000_000
    assert continuous_application_tick(
        match_start_monotonic_ns=start,
        ready_time_ns=start,
        current_completed_tick=-1,
    ) == 1
    assert continuous_application_tick(
        match_start_monotonic_ns=start,
        ready_time_ns=start + 99_999_999,
        current_completed_tick=0,
    ) == 1
    assert continuous_application_tick(
        match_start_monotonic_ns=start,
        ready_time_ns=start + 100_000_000,
        current_completed_tick=1,
    ) == 2
    assert continuous_application_tick(
        match_start_monotonic_ns=start,
        ready_time_ns=start + 100_000_001,
        current_completed_tick=3,
    ) == 4

    assert controller_valid_until_tick(500, "fixed_simultaneous") == 501
    assert controller_valid_until_tick(500, "continuous_realtime") == 600
    assert batch_is_fresh(600, 600)
    assert not batch_is_fresh(601, 600)


def test_failure_counter_resets_consecutive_but_not_cumulative() -> None:
    counter = ModelFailureCounter()
    hard = FailureClassification("provider_timeout", FailureOwner.MODEL, True)
    valid = FailureClassification("valid_envelope", FailureOwner.MODEL, False)
    organizer = FailureClassification(
        "shared_gateway_crash", FailureOwner.ORGANIZER_INFRASTRUCTURE, False
    )

    assert not counter.record(hard)
    assert not counter.record(hard)
    assert (counter.consecutive, counter.cumulative) == (2, 2)
    assert not counter.record(valid)
    assert (counter.consecutive, counter.cumulative) == (0, 2)
    assert not counter.record(organizer)
    assert (counter.consecutive, counter.cumulative) == (0, 2)
    assert not counter.record(hard)
    assert not counter.record(hard)
    assert counter.record(hard)
