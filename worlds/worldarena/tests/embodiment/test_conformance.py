from __future__ import annotations

import copy
import json

import pytest
from genesis_arena.embodiment import (
    ControllerAction,
    ControllerButtons,
    ControllerState,
    DecisionWindow,
    EmbodimentProtocolPackage,
    EpisodeConfig,
    ProtocolValidationError,
)
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
CORPUS_PATH = (
    ROOT / "game" / "embodiment_protocol" / "conformance" / "protocol-conformance.v1.json"
)


@pytest.fixture(scope="module")
def package() -> EmbodimentProtocolPackage:
    return EmbodimentProtocolPackage.from_repository(ROOT)


@pytest.fixture(scope="module")
def corpus() -> dict:
    return json.loads(CORPUS_PATH.read_text(encoding="utf-8"))


def _materialize(case: dict) -> dict:
    input_value = case["input"]
    value = copy.deepcopy(input_value["instance"])
    repeat = input_value.get("utf8_repeat")
    if repeat is not None:
        assert repeat["pointer"] == "/memory_update"
        value["memory_update"] = repeat["text"] * repeat["count"]
    return value


def _action(value: dict) -> ControllerAction:
    control = value["control"]
    return ControllerAction(
        episode_id=value["episode_id"],
        observation_seq=value["observation_seq"],
        action_id=value["action_id"],
        control=ControllerState(
            move_x=control["move_x"],
            move_y=control["move_y"],
            look_x=control["look_x"],
            look_y=control["look_y"],
            duration_ticks=control["duration_ticks"],
            buttons=ControllerButtons(**control["buttons"]),
        ),
        intent_label=value["intent_label"],
        memory_update=value["memory_update"],
        protocol_version=value["protocol_version"],
    )


def test_shared_action_corpus_matches_python_runtime(
    package: EmbodimentProtocolPackage, corpus: dict
) -> None:
    for case in corpus["action_cases"]:
        expected = case["expected"]
        parsed = None
        try:
            if "raw_json" in case["input"]:
                parsed = package.parse_and_validate(
                    "controller-action", case["input"]["raw_json"].encode("utf-8"), byte_limit=4096
                )
            else:
                parsed = _materialize(case)
                package.validate("controller-action", parsed)
            wire_valid = True
        except (ProtocolValidationError, TypeError, ValueError):
            wire_valid = False
        assert wire_valid is expected["wire_valid"], case["id"]

        context = case["context"]
        participant_ids = (
            ("participant_0",)
            if context["mode"] == "solo-curriculum-v0"
            else ("participant_0", "participant_1")
        )
        candidate = None
        if wire_valid:
            try:
                candidate = _action(parsed)
            except (TypeError, ValueError):
                candidate = None
        window = DecisionWindow.finalize(
            episode_id=context["episode_id"],
            observation_seq=context["observation_seq"],
            mode=context["mode"],
            start_tick=30,
            participant_ids=participant_ids,
            actions={"participant_0": candidate} if candidate is not None else {},
            failure_reasons={"participant_0": "invalid"} if not wire_valid else None,
            duration_ticks=context["window_ticks"],
        )
        decision = window.decisions["participant_0"]
        assert decision.disposition == expected["disposition"], case["id"]
        assert decision.no_input_reason == expected["reason"], case["id"]
        assert window.duration_ticks == expected["advance_ticks"], case["id"]


def test_shared_observation_and_window_schema_cases(
    package: EmbodimentProtocolPackage, corpus: dict
) -> None:
    for group, schema_name in (
        ("observation_cases", "observation"),
        ("decision_window_cases", "decision-window"),
    ):
        for case in corpus[group]:
            try:
                package.validate(schema_name, case["instance"])
                valid = True
            except ProtocolValidationError:
                valid = False
            assert valid is case["expected_schema_valid"], case["id"]


def test_shared_reset_capability_cases_fail_before_reset(corpus: dict) -> None:
    for case in corpus["reset_capability_cases"]:
        participants = (
            ("participant_0",)
            if case["mode"] == "solo-curriculum-v0"
            else ("participant_0", "participant_1")
        )
        try:
            EpisodeConfig(
                episode_id="ep_conformance",
                mode=case["mode"],
                task_id=case["task_id"],
                seed=7,
                observation_profile=case["profile"],
                participant_ids=participants,
            )
            accepted = True
        except (TypeError, ValueError):
            accepted = False
        assert accepted is case["expected_accepted"], case["id"]
