import json
from copy import deepcopy
from pathlib import Path

import pytest
from genesis_arena.embodiment.evaluation import (
    EVALUATION_SCHEMA_VERSION,
    evaluate_paired_duel_replays,
    evaluate_solo_replay,
)
from genesis_arena.embodiment.protocol import (
    EmbodimentProtocolPackage,
    canonical_json_bytes,
)
from genesis_arena.embodiment.providers.contracts import (
    ProviderAuditRecord,
    ProviderCallResult,
    ProviderRequest,
    ProviderTelemetry,
)
from genesis_arena.embodiment.replay import ReplayLedger, verify_replay_bytes

ROOT = Path(__file__).resolve().parents[2]


def _golden_replay(name: str):
    transcript = json.loads(
        (ROOT / f"game/embodiment_protocol/golden/{name}.json").read_text()
    )
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    ledger = ReplayLedger(
        transcript["config"], transcript["config_sha256"], package.package_sha256
    )
    ledger.record_initial(
        observations=transcript["initial_boundary"]["observations"],
        state_hash=transcript["initial_boundary"]["state_hash"],
    )
    for step in transcript["steps"]:
        ledger.record_step(
            decision_window=step["decision_window"], result=step["result"]
        )
    payload = ledger.seal(
        final_terminal=transcript["terminal_boundary"]["terminal"],
        final_state_hash=transcript["terminal_boundary"]["state_hash"],
    )
    return verify_replay_bytes(payload, package=package)


def _multi_action_replay() -> dict:
    participant_id = "participant_0"
    event_kinds = (
        "resource_gathered",
        "material_deposited",
        "barricade_completed",
        "episode_succeeded",
    )
    end_ticks = (200, 500, 800, 900)
    steps = []
    for index, (event_kind, end_tick) in enumerate(zip(event_kinds, end_ticks)):
        effects = []
        control = {"look_x": 0, "look_y": 0, "move_x": 0, "move_y": 0, "buttons": {}}
        if index == 0:
            effects = [
                {"kind": "heading_steps", "value": 1},
                {"kind": "distance_moved_mt", "value": 1_000},
            ]
            control.update({"look_x": 1_000, "move_y": 1_000})
        steps.append(
            {
                "decision_window": {
                    "decisions": {
                        participant_id: {"action": {"control": control}}
                    }
                },
                "result": {
                    "receipts": {
                        participant_id: {
                            "accepted": True,
                            "applied_ticks": end_tick - (end_ticks[index - 1] if index else 0),
                            "codes": ["applied"],
                            "effects": effects,
                            "end_tick": end_tick,
                        }
                    },
                    "public_events": [{"kind": event_kind, "tick": end_tick}],
                },
            }
        )
    return {
        "config": {"participant_ids": [participant_id]},
        "final_terminal": {"ended": True, "outcome": "success", "reason": "barricade_built"},
        "steps": steps,
    }


def test_stage_c_golden_evaluation_is_authority_derived_and_integer_only() -> None:
    replay = _golden_replay("stage-c-construction-v1")
    evaluation = evaluate_solo_replay(
        replay,
        (
            {
                "latency_ms": 7,
                "input_tokens": 100,
                "output_tokens": 10,
                "cached_input_tokens": 20,
            },
            {
                "latency_ms": 9,
                "input_tokens": 120,
                "output_tokens": 12,
                "cached_input_tokens": 0,
            },
        ),
        replay_verified=True,
    )

    assert evaluation["schema_version"] == EVALUATION_SCHEMA_VERSION
    assert evaluation["scope"] == "solo"
    metrics = evaluation["metrics"]
    assert metrics["task_success"] == {"status": "supported", "value": True}
    assert metrics["completion_tick"]["value"] == replay["steps"][-1]["result"][
        "receipts"
    ]["participant_0"]["end_tick"]
    assert metrics["valid_action_rate"]["value"] == {
        "basis_points": 10_000,
        "denominator": len(replay["steps"]),
        "numerator": len(replay["steps"]),
    }
    assert metrics["interaction_alignment_failures"]["value"] == 1
    assert metrics["unnecessary_collisions"]["value"] == 0
    assert metrics["progress_checkpoints_reached"]["value"]["event_kinds"] == [
        "resource_gathered",
        "resource_gathered",
        "material_deposited",
        "barricade_completed",
    ]
    assert metrics["provider_token_efficiency"]["value"] == {
        "calls": 2,
        "cached_input_tokens": 20,
        "input_tokens": 220,
        "output_tokens": 22,
    }
    assert metrics["provider_latency_efficiency"]["value"] == {
        "calls": 2,
        "maximum_ms": 9,
        "mean_ms": 8,
        "total_ms": 16,
    }
    assert metrics["path_efficiency"] == {
        "reason": "shortest_legal_route_not_recorded",
        "status": "unsupported",
    }
    assert metrics["memory_consistency"]["reason"] == (
        "runner_memory_not_in_authority_replay"
    )
    canonical_json_bytes(evaluation)


def test_multi_action_evaluation_requires_and_seals_authority_identity() -> None:
    replay = _multi_action_replay()
    evaluation = evaluate_solo_replay(
        replay,
        replay_verified=True,
        scenario_id="multi-action-demo-v0",
        evaluation_profile_id="solo-multi-action-showcase-v1",
    )
    assert evaluation["scenario_id"] == "multi-action-demo-v0"
    assert evaluation["evaluation_profile_id"] == "solo-multi-action-showcase-v1"
    assert evaluation["metrics"]["completion_tick"]["value"] == 900


def test_multi_action_accepts_authoritative_completion_and_success_on_same_step() -> None:
    replay = _multi_action_replay()
    barricade = replay["steps"][2]["result"]["public_events"].pop()
    replay["steps"][3]["result"]["public_events"].insert(0, barricade)
    evaluation = evaluate_solo_replay(
        replay,
        replay_verified=True,
        scenario_id="multi-action-demo-v0",
        evaluation_profile_id="solo-multi-action-showcase-v1",
    )
    assert evaluation["metrics"]["completion_tick"]["value"] == 900


@pytest.mark.parametrize(
    "mutation",
    ("too_short", "too_long", "no_turn", "no_walk", "missing_deposit", "wrong_order", "failure"),
)
def test_multi_action_evaluation_rejects_invalid_showcase_claims(mutation: str) -> None:
    replay = deepcopy(_multi_action_replay())
    participant_id = "participant_0"
    if mutation == "too_short":
        replay["steps"][-1]["result"]["receipts"][participant_id]["end_tick"] = 899
    elif mutation == "too_long":
        replay["steps"][-1]["result"]["receipts"][participant_id]["end_tick"] = 1_201
    elif mutation == "no_turn":
        replay["steps"][0]["result"]["receipts"][participant_id]["effects"][0]["value"] = 0
        replay["steps"][0]["decision_window"]["decisions"][participant_id]["action"][
            "control"
        ]["look_x"] = 0
    elif mutation == "no_walk":
        replay["steps"][0]["result"]["receipts"][participant_id]["effects"][1]["value"] = 0
        replay["steps"][0]["decision_window"]["decisions"][participant_id]["action"][
            "control"
        ]["move_y"] = 0
    elif mutation == "missing_deposit":
        replay["steps"][1]["result"]["public_events"] = []
    elif mutation == "wrong_order":
        replay["steps"][0]["result"]["public_events"], replay["steps"][1]["result"][
            "public_events"
        ] = (
            replay["steps"][1]["result"]["public_events"],
            replay["steps"][0]["result"]["public_events"],
        )
    else:
        replay["final_terminal"]["outcome"] = "failure"

    with pytest.raises(ValueError, match="multi-action"):
        evaluate_solo_replay(
            replay,
            replay_verified=True,
            scenario_id="multi-action-demo-v0",
            evaluation_profile_id="solo-multi-action-showcase-v1",
        )


def test_paired_duel_evaluation_is_side_normalized_and_marks_missing_metrics() -> None:
    leg_a = _duel_replay("ep_eval_leg_a")
    leg_b = _duel_replay("ep_eval_leg_b")
    mappings = (
        {"participant_0": "entrant_a", "participant_1": "entrant_b"},
        {"participant_0": "entrant_b", "participant_1": "entrant_a"},
    )
    evaluations = evaluate_paired_duel_replays(
        replays=(leg_a, leg_b),
        provider_audits=(
            _audits("ep_eval_leg_a", (3, 5)),
            _audits("ep_eval_leg_b", (7, 11)),
        ),
        participant_to_entrant=mappings,
        entrant_ids=("entrant_a", "entrant_b"),
        entrant_wins=(1, 1),
        draws=0,
        winner_entrant_id=None,
        replay_verified=(True, True),
    )

    first = evaluations[0]
    assert first["entrants"]["entrant_a"]["objective_control_ticks"] == 10
    assert first["entrants"]["entrant_a"]["damage_dealt"] == 125
    assert first["entrants"]["entrant_b"]["damage_taken"] == 125
    assert first["entrants"]["entrant_b"]["guard_efficiency"] == {
        "basis_points": 5_000,
        "denominator": 250,
        "numerator": 125,
    }
    assert first["entrants"]["entrant_a"]["oscillation"] == 1
    assert first["entrants"]["entrant_b"]["action_validity"] == {
        "basis_points": 6_666,
        "denominator": 3,
        "numerator": 2,
    }
    assert first["entrants"]["entrant_b"]["idle_ticks"] == 20
    assert first["metrics"]["positional_advantage"] == {
        "reason": "exact_positions_not_in_public_replay",
        "status": "unsupported",
    }
    pair = first["pair_metrics"]
    assert pair == evaluations[1]["pair_metrics"]
    assert pair["series_result"]["value"] == {
        "draws": 0,
        "entrant_wins": {"entrant_a": 1, "entrant_b": 1},
        "winner_entrant_id": None,
    }
    assert pair["side_normalized_performance"]["value"]["entrant_a"] == {
        "wins": 1,
        "draws": 0,
        "losses": 1,
        "objective_control_ticks": 10,
        "damage_dealt": 125,
        "damage_taken": 125,
        "idle_ticks": 30,
        "valid_action_rate": {
            "basis_points": 8_333,
            "denominator": 6,
            "numerator": 5,
        },
    }
    assert pair["deterministic_replay_verification"]["value"] is True
    canonical_json_bytes(first)


def _duel_replay(episode_id: str):
    participants = ["participant_0", "participant_1"]
    steps = []
    for seq in range(3):
        participant_0_move = 1000 if seq == 0 else -1000 if seq == 1 else 0
        decisions = {
            "participant_0": _decision(
                episode_id, "participant_0", seq, participant_0_move
            ),
            "participant_1": (
                _decision(episode_id, "participant_1", seq, 0)
                if seq != 1
                else {
                    "disposition": "no_input",
                    "fallback": "neutral",
                    "no_input_reason": "invalid",
                    "action": None,
                }
            ),
        }
        receipts = {
            "participant_0": _receipt(seq, True, ()),
            "participant_1": _receipt(
                seq,
                seq != 1,
                (
                    ("guard_active", "guard_reduced_damage", "damage_taken")
                    if seq == 0
                    else ("no_input",) if seq == 1 else ()
                ),
                health_delta=-125 if seq == 0 else 0,
            ),
        }
        events = []
        if seq == 0:
            events = [
                {
                    "event_id": "evt_0_0",
                    "tick": 0,
                    "kind": "relay_control_changed",
                    "summary": "Relay control changed.",
                    "participant_ids": participants,
                    "data": {"controller": "participant_0"},
                },
                {
                    "event_id": "evt_0_1",
                    "tick": 0,
                    "kind": "primary_hit",
                    "summary": "Primary hit.",
                    "participant_ids": participants,
                    "data": {
                        "attacker": "participant_0",
                        "target": "participant_1",
                        "damage": 250,
                    },
                },
                {
                    "event_id": "evt_0_2",
                    "tick": 0,
                    "kind": "operator_damaged",
                    "summary": "Operator damaged.",
                    "participant_ids": ["participant_1"],
                    "data": {"participant_id": "participant_1", "damage": 125},
                },
            ]
        elif seq == 1:
            events = [
                {
                    "event_id": "evt_10_3",
                    "tick": 10,
                    "kind": "relay_hold_reset",
                    "summary": "Relay hold reset.",
                    "participant_ids": participants,
                    "data": {},
                }
            ]
        steps.append(
            {
                "decision_window": {"decisions": decisions},
                "result": {"receipts": receipts, "public_events": events},
            }
        )
    return {
        "config": {"episode_id": episode_id, "participant_ids": participants},
        "steps": steps,
        "final_terminal": {"ended": True, "outcome": "win", "reason": "relay_hold"},
    }


def _decision(episode_id: str, participant_id: str, seq: int, move_y: int):
    return {
        "disposition": "accepted",
        "fallback": "none",
        "no_input_reason": None,
        "action": {
            "episode_id": episode_id,
            "observation_seq": seq,
            "action_id": f"action_{participant_id}_{seq}",
            "control": {
                "move_x": 0,
                "move_y": move_y,
                "look_x": 0,
                "look_y": 0,
                "duration_ticks": 10,
                "buttons": {
                    "interact": False,
                    "primary": seq == 0 and participant_id == "participant_0",
                    "guard": seq == 0 and participant_id == "participant_1",
                    "dash": False,
                    "ability_1": False,
                    "ability_2": False,
                    "cycle_item": False,
                    "cancel": False,
                },
            },
        },
    }


def _receipt(seq: int, accepted: bool, codes, *, health_delta: int = 0):
    return {
        "accepted": accepted,
        "applied_ticks": 10,
        "end_tick": (seq + 1) * 10,
        "codes": list(codes),
        "effects": [
            {"kind": "health_delta", "value": health_delta},
            {"kind": "energy_delta", "value": 0},
        ],
    }


def _audits(episode_id: str, latencies: tuple[int, int]):
    records = []
    for index, participant_id in enumerate(("participant_0", "participant_1")):
        observation = {
            "episode_id": episode_id,
            "observation_seq": 0,
            "profile": "text-visible-v1",
        }
        request = ProviderRequest(
            episode_id=episode_id,
            participant_id=participant_id,
            observation_seq=0,
            deadline_monotonic_ns=100,
            model=f"model-{index}",
            system_prompt="Return an action.",
            observation_json=canonical_json_bytes(observation),
            action_schema_json=b"{}",
        )
        result = ProviderCallResult.success(
            b"{}",
            ProviderTelemetry(
                latency_ms=latencies[index],
                input_tokens=10 * (index + 1),
                output_tokens=2 * (index + 1),
                cached_input_tokens=0,
            ),
        )
        records.append(
            ProviderAuditRecord(
                provider="scripted",
                request=request,
                result=result,
                started_monotonic_ns=0,
                completed_monotonic_ns=latencies[index] * 1_000_000,
            )
        )
    return tuple(records)
