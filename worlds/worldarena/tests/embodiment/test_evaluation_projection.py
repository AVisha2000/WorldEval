from __future__ import annotations

from dataclasses import FrozenInstanceError

import pytest
from genesis_arena.embodiment.evaluation import EVALUATION_SCHEMA_VERSION
from genesis_arena.embodiment.evaluation_projection import (
    EVALUATION_PROJECTION_VERSION,
    EvaluationProjectionError,
    build_paired_duel_leg_evaluation_projection,
    build_solo_evaluation_projection,
    build_unavailable_evaluation_projection,
)
from genesis_arena.embodiment.protocol import canonical_sha256

HASH = "a" * 64


def _run() -> dict[str, object]:
    return {
        "episode_id": "ep_evaluation_projection",
        "task_id": "construction-v0",
        "run_class": "demo",
        "certification_eligible": False,
        "scenario_id": "multi-action-demo-v0",
        "evaluation_profile_id": "solo-multi-action-showcase-v1",
    }


def _terminal() -> dict[str, object]:
    return {"ended": True, "outcome": "success", "reason": "barricade_built"}


def _summary() -> dict[str, object]:
    return {
        "episode_id": "ep_evaluation_projection",
        "final_state_hash": HASH,
        "frozen_configuration": {
            "config_sha256": HASH,
            "model_sha256": HASH,
            "protocol_package_sha256": HASH,
            "provider_sha256": HASH,
            "settings_sha256": HASH,
        },
        "terminal": _terminal(),
    }


def _result() -> dict[str, object]:
    return {
        "episode_id": "ep_evaluation_projection",
        "final_state_hash": HASH,
        "provider_failures": 0,
        "terminal": _terminal(),
        "windows": 4,
    }


def _supported(value: object) -> dict[str, object]:
    return {"status": "supported", "value": value}


def _unavailable(reason: str) -> dict[str, object]:
    return {"reason": reason, "status": "unsupported"}


def _evaluation() -> dict[str, object]:
    ratio = {"basis_points": 10_000, "denominator": 4, "numerator": 4}
    return {
        "schema_version": EVALUATION_SCHEMA_VERSION,
        "scope": "solo",
        "scenario_id": "multi-action-demo-v0",
        "evaluation_profile_id": "solo-multi-action-showcase-v1",
        "metrics": {
            "task_success": _supported(True),
            "completion_tick": _supported(900),
            "progress_checkpoints_reached": _supported(
                {
                    "count": 3,
                    "event_kinds": [
                        "resource_gathered",
                        "material_deposited",
                        "barricade_completed",
                    ],
                }
            ),
            "valid_action_rate": _supported(ratio),
            "controller_changes": _supported(3),
            "total_held_ticks": _supported(900),
            "path_efficiency": _unavailable("shortest_legal_route_not_recorded"),
            "unnecessary_collisions": _supported(0),
            "interaction_alignment_failures": _supported(0),
            "damage_taken": _supported(0),
            "recovery_quality": _unavailable("normative_recovery_baseline_not_recorded"),
            "repeated_ineffective_windows": _supported(
                {"longest_run": 0, "windows_in_repeated_runs": 0}
            ),
            "memory_consistency": _unavailable("runner_memory_not_in_authority_replay"),
            "provider_token_efficiency": _unavailable("provider_telemetry_not_recorded"),
            "provider_latency_efficiency": _unavailable("provider_telemetry_not_recorded"),
            "deterministic_replay_verification": _supported(True),
        },
    }


def _build(**changes):
    values = {
        "evaluation": _evaluation(),
        "replay_summary": _summary(),
        "run_spec": _run(),
        "result": _result(),
        "receipts": (
            {
                "observation_seq": 0,
                "participants": {
                    "participant_0": {
                        "action_id": "task_0",
                        "prompt": "must-not-cross-projection",
                        "raw_output": "must-not-cross-projection",
                    }
                },
            },
        ),
        "public_events": (
            {
                "kind": "resource_gathered",
                "tick": 200,
                "data": {"hidden_position": [1, 2, 3]},
            },
            {"kind": "private_debug_event", "tick": 201, "spectator": True},
        ),
    }
    values.update(changes)
    return build_solo_evaluation_projection(**values)


def test_solo_projection_is_canonical_hash_bound_and_contains_only_safe_references() -> None:
    projection = _build()
    value = projection.as_dict()
    digest = value.pop("projection_sha256")

    assert value["schema_version"] == EVALUATION_PROJECTION_VERSION
    assert value["state"] == "supported"
    assert value["scope"] == "solo"
    assert digest == canonical_sha256(value) == projection.projection_sha256
    assert value["references"] == {
        "events": [{"kind": "resource_gathered", "tick": 200}],
        "receipts": [
            {
                "action_id": "task_0",
                "observation_seq": 0,
                "participant_id": "participant_0",
            }
        ],
    }
    encoded = projection.canonical_bytes
    for forbidden in (
        b"prompt",
        b"raw_output",
        b"hidden_position",
        b"spectator",
        b"private_debug_event",
    ):
        assert forbidden not in encoded
    assert value["evaluation"]["metrics"]["path_efficiency"] == {
        "reason": "shortest_legal_route_not_recorded",
        "state": "unavailable",
    }


def test_projection_is_immutable_and_as_dict_returns_an_independent_copy() -> None:
    projection = _build()
    with pytest.raises(FrozenInstanceError):
        projection.projection_sha256 = HASH  # type: ignore[misc]
    first = projection.as_dict()
    first["run"]["task_id"] = "tampered"
    assert projection.as_dict()["run"]["task_id"] == "construction-v0"


@pytest.mark.parametrize(
    ("source", "field"),
    (
        ("run_spec", "credential"),
        ("replay_summary", "observations"),
        ("result", "raw_model_output"),
        ("evaluation", "prompts"),
    ),
)
def test_projection_rejects_unknown_or_protected_top_level_fields(
    source: str, field: str
) -> None:
    values = {
        "run_spec": _run(),
        "replay_summary": _summary(),
        "result": _result(),
        "evaluation": _evaluation(),
    }
    values[source][field] = "must-not-reflect"
    with pytest.raises(EvaluationProjectionError, match="fields differ"):
        _build(**{source: values[source]})


def test_projection_rejects_metric_payloads_outside_the_exact_allow_list() -> None:
    evaluation = _evaluation()
    evaluation["metrics"]["progress_checkpoints_reached"]["value"][
        "hidden_coordinates"
    ] = [1, 2]
    with pytest.raises(EvaluationProjectionError, match="fields differ"):
        _build(evaluation=evaluation)


def test_projection_requires_result_and_replay_summary_to_match() -> None:
    result = _result()
    result["final_state_hash"] = "b" * 64
    with pytest.raises(EvaluationProjectionError, match="differs"):
        _build(result=result)


@pytest.mark.parametrize("scope", ("solo", "paired_duel"))
def test_unavailable_projection_has_stable_solo_and_paired_duel_shape(scope: str) -> None:
    first = build_unavailable_evaluation_projection(
        run_spec=_run(), scope=scope, reason="evidence_not_ready"
    )
    second = build_unavailable_evaluation_projection(
        run_spec=_run(), scope=scope, reason="evidence_not_ready"
    )
    assert first.canonical_bytes == second.canonical_bytes
    assert first.as_dict() == {
        "reason": "evidence_not_ready",
        "run": _run(),
        "schema_version": EVALUATION_PROJECTION_VERSION,
        "scope": scope,
        "state": "unavailable",
        "projection_sha256": first.projection_sha256,
    }


def test_unavailable_projection_does_not_reflect_arbitrary_failure_text() -> None:
    with pytest.raises(EvaluationProjectionError, match="availability identity"):
        build_unavailable_evaluation_projection(
            run_spec=_run(), scope="paired_duel", reason="provider said secret prompt"
        )


def test_paired_duel_leg_projection_has_a_strict_side_normalized_shape() -> None:
    unavailable = _unavailable("provider_telemetry_not_recorded")
    ratio = {"basis_points": 10_000, "denominator": 2, "numerator": 2}
    entrant = {
        "participant_id": "participant_0",
        "objective_control_ticks": 10,
        "damage_dealt": 125,
        "damage_taken": 0,
        "guard_efficiency": ratio,
        "valid_actions": 2,
        "total_actions": 2,
        "action_validity": ratio,
        "idle_ticks": 0,
        "oscillation": 0,
        "provider_token_efficiency": unavailable,
        "provider_latency_efficiency": unavailable,
    }
    aggregate = {
        "wins": 1,
        "draws": 0,
        "losses": 1,
        "objective_control_ticks": 10,
        "damage_dealt": 125,
        "damage_taken": 0,
        "idle_ticks": 0,
        "valid_action_rate": ratio,
    }
    evaluation = {
        "schema_version": EVALUATION_SCHEMA_VERSION,
        "scope": "paired_duel_leg",
        "leg_index": 0,
        "metrics": {
            "positional_advantage": _unavailable("exact_positions_not_in_public_replay"),
            "disengagement_success": _unavailable("disengagement_outcome_not_typed"),
            "adaptation_after_losing_exchange": _unavailable(
                "exchange_loss_boundary_not_typed"
            ),
            "deterministic_replay_verification": _supported(True),
        },
        "entrants": {
            "entrant_a": entrant,
            "entrant_b": {**entrant, "participant_id": "participant_1"},
        },
        "pair_metrics": {
            "series_result": _supported(
                {
                    "draws": 0,
                    "entrant_wins": {"entrant_a": 1, "entrant_b": 1},
                    "winner_entrant_id": None,
                }
            ),
            "side_normalized_performance": _supported(
                {"entrant_a": aggregate, "entrant_b": aggregate}
            ),
            "deterministic_replay_verification": _supported(True),
        },
    }
    run = _run()
    run.pop("scenario_id")
    run.pop("evaluation_profile_id")

    projection = build_paired_duel_leg_evaluation_projection(
        evaluation=evaluation,
        replay_summary=_summary(),
        run_spec=run,
        result=_result(),
    )
    value = projection.as_dict()
    assert value["scope"] == "paired_duel_leg"
    assert value["evaluation"]["entrants"]["entrant_b"]["participant_id"] == (
        "participant_1"
    )
    assert value["evaluation"]["pair_metrics"]["series_result"]["value"] == {
        "draws": 0,
        "entrant_wins": {"entrant_a": 1, "entrant_b": 1},
        "winner_entrant_id": None,
    }
