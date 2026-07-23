import json
from dataclasses import FrozenInstanceError

import pytest
from genesis_arena.embodiment.baselines import BaselineLock, baseline_intent, decide_baseline
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT


def _entity(*, kind, bearing="front", distance="near", affordances=()):
    return {
        "id": f"visible_{kind}",
        "kind": kind,
        "bearing": bearing,
        "distance": distance,
        "state": "active",
        "affordances": list(affordances),
    }


def _observation(**overrides):
    values = {
        "observation_seq": 6,
        "self": {"health_percent": 100},
        "visible_entities": [
            _entity(kind="operator", affordances=("hostile",)),
            _entity(kind="relay", distance="medium", affordances=("interactable",)),
        ],
    }
    values.update(overrides)
    return values


def test_baseline_tiers_match_godot_visible_policy_and_fixed_horizon() -> None:
    observation = _observation()
    scout = decide_baseline(BaselineLock("scout-v1"), observation)
    balanced = decide_baseline(BaselineLock("balanced-v1"), observation)
    challenger = decide_baseline(BaselineLock("challenger-v1"), observation)

    assert scout == decide_baseline(BaselineLock("scout-v1"), observation)
    assert scout.duration_ticks == balanced.duration_ticks == challenger.duration_ticks == 10
    assert scout.move_y == 600
    assert balanced.buttons.primary
    assert challenger.buttons.primary


def test_balanced_guards_at_low_health_and_challenger_dashes_at_range() -> None:
    low_health = _observation(self={"health_percent": 35})
    guarded = decide_baseline(BaselineLock("balanced-v1"), low_health)
    distant = _observation(
        visible_entities=[
            _entity(
                kind="operator",
                bearing="back_right",
                distance="far",
                affordances=("hostile",),
            ),
            _entity(kind="relay", distance="medium"),
        ]
    )
    challenger = decide_baseline(BaselineLock("challenger-v1"), distant)

    assert guarded.buttons.guard and guarded.move_y < 0
    assert challenger.buttons.dash
    assert challenger.move_x > 0 and challenger.move_y < 0


def test_policy_is_side_neutral_and_ignores_non_visible_material() -> None:
    visible = _observation()
    with_extra = {**visible, "spectator_only": {"global_position": [1, 2]}}
    lock = BaselineLock("challenger-v1")
    assert decide_baseline(lock, visible) == decide_baseline(lock, with_extra)


def test_baseline_lock_is_immutable_strict_and_canonically_hashed() -> None:
    lock = BaselineLock("balanced-v1")
    assert len(lock.lock_sha256) == 64
    assert lock.lock_sha256 == BaselineLock("balanced-v1").lock_sha256
    with pytest.raises(FrozenInstanceError):
        lock.tier = "scout-v1"
    with pytest.raises(ValueError):
        BaselineLock("unknown")
    with pytest.raises(ValueError):
        BaselineLock("balanced-v1", decision_ticks=True)
    with pytest.raises(ValueError):
        decide_baseline(lock, _observation(observation_seq=True))


def test_shared_python_godot_baseline_conformance_fixture() -> None:
    path = ROOT / "game/embodiment_protocol/conformance/duel-baseline-conformance.v1.json"
    fixture = json.loads(path.read_text(encoding="utf-8"))
    assert fixture["format"] == "llm-controller/duel-baseline-conformance/1.0.0"
    for case in fixture["cases"]:
        control = decide_baseline(BaselineLock(case["tier"]), case["observation"])
        expected = dict(case["expected"])
        intent = expected.pop("intent_label")
        assert control.as_dict() == expected, case["id"]
        assert baseline_intent(control) == intent, case["id"]
