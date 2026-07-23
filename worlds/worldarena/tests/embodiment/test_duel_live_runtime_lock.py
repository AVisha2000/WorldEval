from __future__ import annotations

from dataclasses import replace
from pathlib import Path

import pytest
from genesis_arena.embodiment.duel import DuelEntrant
from genesis_arena.embodiment.duel.live_runtime import build_paired_duel_plan
from genesis_arena.embodiment.duel.service import DuelSeriesSpec
from genesis_arena.embodiment.protocol import EmbodimentProtocolPackage

ROOT = Path(__file__).resolve().parents[2]


def _plan():
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    spec = DuelSeriesSpec(
        series_id="series_fairness_lock",
        entrants=(
            DuelEntrant("entrant_a", "openai", "model-a"),
            DuelEntrant("entrant_b", "anthropic", "model-b"),
        ),
        seed=23,
        schedule_nonce="schedule-lock-0",
    )
    return build_paired_duel_plan(
        spec=spec,
        repository_root=ROOT,
        godot_project_path=ROOT / "godot",
        protocol_package=package,
        provider_timeout_s=30.0,
    )


def test_production_plan_binds_complete_equal_two_leg_fairness_lock() -> None:
    plan = _plan()
    lock = plan.fairness_lock
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
    assert set(material["entrants"][0]) == {
        "adapter_sha256",
        "entrant_id",
        "model",
        "provider",
        "reasoning",
    }
    assert [entrant.reasoning for entrant in lock.entrants] == ["low", "disabled"]
    assert all(len(entrant.adapter_sha256) == 64 for entrant in lock.entrants)
    assert lock.entrants[0].adapter_sha256 != lock.entrants[1].adapter_sha256
    assert lock.deadline_ms == plan.settings.timeout_ms == 30_000
    assert lock.max_input_bytes == plan.settings.max_input_bytes == 8_388_608
    assert lock.max_output_bytes == plan.settings.max_output_bytes == 4_096

    first, second = plan.legs
    assert first.fairness_lock_sha256 == second.fairness_lock_sha256 == lock.lock_sha256
    by_first = {assignment.entrant_id: assignment for assignment in first.assignments}
    by_second = {assignment.entrant_id: assignment for assignment in second.assignments}
    for entrant_id in by_first:
        assert by_first[entrant_id].participant_id != by_second[entrant_id].participant_id
        assert by_first[entrant_id].spawn_side != by_second[entrant_id].spawn_side
        assert by_first[entrant_id].dispatch_precedence != by_second[entrant_id].dispatch_precedence


def test_every_variable_fairness_input_changes_the_production_plan_hash() -> None:
    plan = _plan()
    original = plan.plan_sha256
    lock = plan.fairness_lock

    for field in (
        "protocol_sha256",
        "rules_sha256",
        "map_sha256",
        "body_sha256",
        "controller_sha256",
        "projector_sha256",
        "evaluator_sha256",
    ):
        changed = replace(lock, **{field: "f" * 64})
        changed_plan = replace(plan, fairness_lock=changed)
        assert changed_plan.plan_sha256 != original
        assert changed_plan.legs[0].plan_sha256 != plan.legs[0].plan_sha256
        assert changed_plan.legs[1].plan_sha256 != plan.legs[1].plan_sha256

    first = lock.entrants[0]
    for changed_entrant in (
        replace(first, adapter_sha256="e" * 64),
        replace(first, reasoning="high"),
    ):
        changed = replace(lock, entrants=(changed_entrant, lock.entrants[1]))
        assert replace(plan, fairness_lock=changed).plan_sha256 != original

    changed_model_lock = replace(first, model="model-a-v2")
    changed_model = replace(
        plan,
        entrants=(DuelEntrant("entrant_a", "openai", "model-a-v2"), plan.entrants[1]),
        fairness_lock=replace(lock, entrants=(changed_model_lock, lock.entrants[1])),
    )
    assert changed_model.plan_sha256 != original

    for lock_field, setting_field, value in (
        ("max_input_bytes", "max_input_bytes", lock.max_input_bytes - 1),
        ("max_output_bytes", "max_output_bytes", lock.max_output_bytes - 1),
        ("deadline_ms", "timeout_ms", lock.deadline_ms - 1),
    ):
        changed = replace(lock, **{lock_field: value})
        settings = replace(plan.settings, **{setting_field: value})
        assert replace(plan, fairness_lock=changed, settings=settings).plan_sha256 != original

    changed_seed = replace(lock, seed=lock.seed + 1)
    assert replace(plan, seed=plan.seed + 1, fairness_lock=changed_seed).plan_sha256 != original
    changed_nonce = replace(lock, schedule_nonce="schedule-lock-1")
    assert (
        replace(
            plan,
            schedule_nonce="schedule-lock-1",
            fairness_lock=changed_nonce,
        ).plan_sha256
        != original
    )
    changed_budget = replace(
        plan,
        max_live_provider_calls=plan.max_live_provider_calls - 1,
    )
    assert changed_budget.plan_sha256 != original


def test_fixed_profile_timing_and_cross_contract_mismatches_fail_closed() -> None:
    plan = _plan()
    lock = plan.fairness_lock

    with pytest.raises(ValueError, match="hybrid-visible-v1"):
        replace(lock, observation_profile="text-visible-v1")
    with pytest.raises(ValueError, match="step-locked-v1"):
        replace(lock, timing_track="wall-clock-v1")
    with pytest.raises(ValueError, match="input ceiling"):
        replace(plan, settings=replace(plan.settings, max_input_bytes=1024))
    with pytest.raises(ValueError, match="entrants"):
        replace(
            plan,
            entrants=(DuelEntrant("entrant_a", "openai", "different-model"), plan.entrants[1]),
        )


def test_scripted_plan_locks_canonical_policy_tier_and_mode() -> None:
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    spec = DuelSeriesSpec(
        series_id="series_scripted_lock",
        entrants=(
            DuelEntrant("entrant_a", "openai", "model-a"),
            DuelEntrant("entrant_b", "scripted", "balanced-v1"),
        ),
        seed=23,
        schedule_nonce="scripted-lock-0",
    )
    plan = build_paired_duel_plan(
        spec=spec,
        repository_root=ROOT,
        godot_project_path=ROOT / "godot",
        protocol_package=package,
        provider_timeout_s=30.0,
    )

    assert plan.mode == "scripted-duel-v0"
    assert all(leg.mode == "scripted-duel-v0" for leg in plan.legs)
    scripted = plan.fairness_lock.entrants[1]
    assert (scripted.provider, scripted.model, scripted.reasoning) == (
        "scripted",
        "balanced-v1",
        "deterministic",
    )
    assert len(scripted.adapter_sha256) == 64
