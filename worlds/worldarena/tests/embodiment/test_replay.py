from __future__ import annotations

import json

import pytest
from genesis_arena.embodiment.protocol import (
    EmbodimentProtocolPackage,
    canonical_json_bytes,
    canonical_sha256,
)
from genesis_arena.embodiment.protocol_registry import EmbodimentProtocolRegistry
from genesis_arena.embodiment.replay import ReplayLedger, ReplayValidationError, verify_replay_bytes
from worldarena.paths import WORLDARENA_GODOT_ROOT, WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT


def _observation() -> dict:
    corpus = json.loads(
        (ROOT / "game/embodiment_protocol/conformance/protocol-conformance.v1.json").read_text()
    )
    return next(
        case["instance"] for case in corpus["observation_cases"] if case["expected_schema_valid"]
    )


def _valid_replay() -> tuple[bytes, EmbodimentProtocolPackage]:
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    observation = _observation()
    config = {
        "protocol_version": "llm-controller/0.1.0",
        "episode_id": "ep_conformance",
        "mode": "solo-curriculum-v0",
        "task_id": "orientation-v0",
        "seed": 1,
        "observation_profile": "text-visible-v1",
        "timing_track": "step-locked-v1",
        "maximum_episode_ticks": 100,
        "participant_ids": ["participant_0"],
    }
    state_hash = "b" * 64
    receipt = {
        "action_id": "no_input_0",
        "observation_seq": 0,
        "accepted": False,
        "disposition": "no_input",
        "fallback": "neutral",
        "no_input_reason": "missing",
        "start_tick": 0,
        "end_tick": 10,
        "applied_ticks": 10,
        "codes": [],
        "effects": [],
    }
    terminal = {"ended": True, "outcome": "success", "reason": "beacon_held"}
    terminal_observation = {
        **observation,
        "observation_seq": 1,
        "tick": 10,
        "previous_receipt": receipt,
        "terminal": terminal,
    }
    result = {
        "observations": {"participant_0": terminal_observation},
        "receipts": {"participant_0": receipt},
        "public_events": [],
        "state_hash": state_hash,
        "terminal": terminal,
    }
    window = {
        "episode_id": "ep_conformance",
        "observation_seq": 0,
        "mode": "solo-curriculum-v0",
        "start_tick": 0,
        "duration_ticks": 10,
        "decisions": {
            "participant_0": {
                "disposition": "no_input",
                "action": None,
                "fallback": "neutral",
                "no_input_reason": "missing",
            }
        },
    }
    ledger = ReplayLedger(
        config=config,
        config_sha256=canonical_sha256(config),
        protocol_package_sha256=package.package_sha256,
    )
    ledger.record_initial(observations={"participant_0": observation}, state_hash="a" * 64)
    ledger.record_step(decision_window=window, result=result)
    payload = ledger.seal(final_terminal=result["terminal"], final_state_hash=state_hash)
    return payload, package


def _reseal(value: dict) -> bytes:
    body = {key: child for key, child in value.items() if key != "ledger_sha256"}
    value["ledger_sha256"] = canonical_sha256(body)
    return canonical_json_bytes(value)


def _rts_replay_with_task_plan_evidence() -> bytes:
    """Make a schema-valid task-plan-evidence variant of the checked-in RTS replay.

    The source replay is deliberately an older ordinary-controller ledger, so this fixture
    changes only the generated receipt action IDs required by the new task executor audit.
    It lets Python verify the extension without depending on a local Godot binary or /tmp.
    """

    value = json.loads(
        (
            WORLDARENA_GODOT_ROOT
            / "showcases/rts_skirmish/rts-skirmish-demo.replay.json"
        ).read_bytes()
    )
    evidence: list[dict] = []
    for index, step in enumerate(value["steps"]):
        ordinary = step["decision_window"]
        plans = {
            "participant_0": {
                "protocol": "rts-task-plan-v1",
                "episode_id": ordinary["episode_id"],
                "observation_seq": index,
                "intent_label": "Harvest Blue Tree 0",
                "memory_update": "deterministic fixture",
                "assignments": [
                    {"unit_id": "blue_0", "task": "gather", "target_id": "blue_tree_0"}
                ],
            },
            "participant_1": {
                "protocol": "rts-task-plan-v1",
                "episode_id": ordinary["episode_id"],
                "observation_seq": index,
                "intent_label": "Harvest Red Tree 0",
                "memory_update": "deterministic fixture",
                "assignments": [
                    {"unit_id": "red_0", "task": "gather", "target_id": "red_tree_0"}
                ],
            },
        }
        evidence.append(
            {
                field: ordinary[field]
                for field in (
                    "episode_id",
                    "observation_seq",
                    "mode",
                    "start_tick",
                    "duration_ticks",
                )
            }
            | {"plans": plans}
        )
        for participant_id in ("participant_0", "participant_1"):
            action_id = f"task_plan_{participant_id}_{index}"
            step["result"]["receipts"][participant_id]["action_id"] = action_id
            step["result"]["observations"][participant_id]["previous_receipt"][
                "action_id"
            ] = action_id
    value["rts_task_plan_evidence"] = evidence
    return _reseal(value)


def test_replay_is_canonical_schema_valid_and_tamper_evident() -> None:
    payload, package = _valid_replay()
    verify_replay_bytes(payload, package=package)
    changed = json.loads(payload)
    changed["final_state_hash"] = "c" * 64
    with pytest.raises(ReplayValidationError, match="seal"):
        verify_replay_bytes(canonical_json_bytes(changed), package=package)


def test_replay_rejects_cross_episode_window_even_when_resealed() -> None:
    payload, _ = _valid_replay()
    changed = json.loads(payload)
    changed["steps"][0]["decision_window"]["episode_id"] = "ep_other"
    with pytest.raises(ReplayValidationError, match="decision boundary"):
        verify_replay_bytes(_reseal(changed))


def test_replay_rejects_participant_mismatch_even_when_resealed() -> None:
    payload, _ = _valid_replay()
    changed = json.loads(payload)
    changed["initial_observations"]["participant_other"] = changed["initial_observations"].pop(
        "participant_0"
    )
    with pytest.raises(ReplayValidationError, match="initial boundary"):
        verify_replay_bytes(_reseal(changed))


def test_replay_rejects_tick_gap_even_when_resealed() -> None:
    payload, _ = _valid_replay()
    changed = json.loads(payload)
    changed["steps"][0]["decision_window"]["start_tick"] = 1
    with pytest.raises(ReplayValidationError, match="decision boundary"):
        verify_replay_bytes(_reseal(changed))


def test_replay_rejects_receipt_mismatch_even_when_resealed() -> None:
    payload, _ = _valid_replay()
    changed = json.loads(payload)
    changed["steps"][0]["result"]["receipts"]["participant_0"]["observation_seq"] = 1
    changed["steps"][0]["result"]["observations"]["participant_0"]["previous_receipt"][
        "observation_seq"
    ] = 1
    with pytest.raises(ReplayValidationError, match="receipt boundary"):
        verify_replay_bytes(_reseal(changed))


def test_rts_task_plan_evidence_accepts_aligned_task_windows() -> None:
    verified = verify_replay_bytes(
        _rts_replay_with_task_plan_evidence(),
        registry=EmbodimentProtocolRegistry.from_repository(ROOT),
    )
    assert verified["config"]["task_id"] == "rts-skirmish-v0"
    assert len(verified["rts_task_plan_evidence"]) == len(verified["steps"])


def test_rts_task_plan_evidence_rejects_malformed_or_misaligned_windows() -> None:
    value = json.loads(_rts_replay_with_task_plan_evidence())
    value["rts_task_plan_evidence"][0]["plans"]["participant_0"]["assignments"][0][
        "coordinate"
    ] = 1
    with pytest.raises(ReplayValidationError, match="assignment fields"):
        verify_replay_bytes(
            _reseal(value), registry=EmbodimentProtocolRegistry.from_repository(ROOT)
        )

    value = json.loads(_rts_replay_with_task_plan_evidence())
    value["rts_task_plan_evidence"][1]["start_tick"] += 1
    with pytest.raises(ReplayValidationError, match="does not align"):
        verify_replay_bytes(
            _reseal(value), registry=EmbodimentProtocolRegistry.from_repository(ROOT)
        )


def test_rts_task_plan_evidence_is_rejected_for_non_rts_replay() -> None:
    payload, _ = _valid_replay()
    value = json.loads(payload)
    value["rts_task_plan_evidence"] = []
    with pytest.raises(ReplayValidationError, match="not permitted"):
        verify_replay_bytes(_reseal(value))
