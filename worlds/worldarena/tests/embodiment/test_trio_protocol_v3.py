from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest
from genesis_arena.embodiment.contracts import (
    CapabilityStatus,
    ControllerAction,
    ControllerState,
    DecisionWindow,
    EpisodeConfig,
    ParticipantDecision,
    TrioParticipantOutcome,
    TrioPlacementGroup,
    TrioResult,
)
from genesis_arena.embodiment.managed_process import (
    V3_MANAGED_AUTHORITY_SCRIPT,
    _authority_script,
)
from genesis_arena.embodiment.presentation.preview_ingress import derive_trio_preview_ticket
from genesis_arena.embodiment.protocol import ProtocolValidationError, strict_json_loads
from genesis_arena.embodiment.protocol_registry import EmbodimentProtocolRegistry
from genesis_arena.embodiment.replay import verify_replay_bytes
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
V1_SHA256 = "ddfc8998dfe33c0bb68aff31f78118a227792f4d568bd438d732c3d3abe0c34d"
V2_SHA256 = "edbd41865f3ed7186b02f6d370dd6e655910bcfebe66c330bafa42d5e533fff5"
V3 = "llm-controller/0.3.0"
FIXTURE = (
    ROOT
    / "game"
    / "embodiment_protocol_packages"
    / "llm-controller-0.3.0"
    / "fixtures"
    / "trio-conformance.v1.json"
)
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")


@pytest.fixture(scope="module")
def registry() -> EmbodimentProtocolRegistry:
    return EmbodimentProtocolRegistry.from_repository(ROOT)


def trio_capabilities() -> CapabilityStatus:
    return CapabilityStatus(
        implemented_modes=("trio-game-v0",),
        implemented_observation_profiles=("text-visible-v1", "hybrid-visible-v1"),
        implemented_tasks=("trio-relay-v0", "trio-free-for-all-v0"),
    )


def test_v3_is_additive_and_older_protocol_hashes_are_byte_stable(
    registry: EmbodimentProtocolRegistry,
) -> None:
    assert registry.available_versions == (
        "llm-controller/0.1.0",
        "llm-controller/0.2.0",
        V3,
    )
    assert registry.package("llm-controller/0.1.0").package_sha256 == V1_SHA256
    assert registry.package("llm-controller/0.2.0").package_sha256 == V2_SHA256
    assert registry.package(V3).package_sha256 == (
        "49435d7099c6a28a45f1e08dd8640a4f5e786c6dc2fed8bf4eede862c6da984a"
    )
    assert "trio-result" in registry.package(V3).SCHEMA_FILES
    assert _authority_script(V3) == V3_MANAGED_AUTHORITY_SCRIPT


@pytest.mark.parametrize("task_id", ["trio-relay-v0", "trio-free-for-all-v0"])
@pytest.mark.parametrize("seat_rotation", [0, 1, 2])
def test_v3_episode_contract_requires_exact_three_and_fixed_rotation(
    registry: EmbodimentProtocolRegistry, task_id: str, seat_rotation: int
) -> None:
    config = EpisodeConfig(
        episode_id="ep_v3_contract",
        mode="trio-game-v0",
        task_id=task_id,
        seed=17,
        participant_ids=("participant_0", "participant_1", "participant_2"),
        maximum_episode_ticks=1200,
        capability_status=trio_capabilities(),
        protocol_version=V3,
        seat_rotation=seat_rotation,
    )
    registry.validate(V3, "episode-config", config.as_dict())
    with pytest.raises(ProtocolValidationError):
        registry.validate(
            "llm-controller/0.2.0",
            "episode-config",
            {**config.as_dict(), "protocol_version": "llm-controller/0.2.0"},
        )


def test_v3_contract_window_has_three_fixed_decisions_and_eliminated_disposition() -> None:
    action = ControllerAction(
        episode_id="ep_v3_window",
        observation_seq=0,
        action_id="forward",
        control=ControllerState(0, 1000, 0, 0, 10),
        protocol_version=V3,
    )
    window = DecisionWindow.finalize(
        episode_id=action.episode_id,
        observation_seq=0,
        mode="trio-game-v0",
        start_tick=0,
        participant_ids=("participant_0", "participant_1", "participant_2"),
        actions={"participant_0": action},
        failure_reasons={"participant_2": "eliminated"},
    )
    assert window.duration_ticks == 10
    assert window.decisions["participant_0"].disposition == "accepted"
    assert window.decisions["participant_1"].disposition == "no_input"
    assert window.decisions["participant_2"] == ParticipantDecision.eliminated()


def test_typed_trio_result_requires_ordered_complete_tie_groups() -> None:
    result = TrioResult(
        task_id="trio-free-for-all-v0",
        outcome="win",
        reason="last_standing",
        winner_id="participant_0",
        placements=(
            TrioPlacementGroup(1, ("participant_0",), False, "last_standing"),
            TrioPlacementGroup(
                2, ("participant_1", "participant_2"), True, "elimination_order"
            ),
        ),
        participant_outcomes={
            "participant_0": TrioParticipantOutcome(
                "participant_0", "win", 1, False
            ),
            "participant_1": TrioParticipantOutcome(
                "participant_1", "eliminated", 2, True, 80
            ),
            "participant_2": TrioParticipantOutcome(
                "participant_2", "eliminated", 2, True, 80
            ),
        },
    )
    assert result.as_dict()["placements"][1]["tie"] is True
    with pytest.raises(ValueError, match="cover"):
        TrioResult(
            task_id="trio-relay-v0",
            outcome="draw",
            reason="time_limit_tie",
            winner_id=None,
            placements=(
                TrioPlacementGroup(1, ("participant_0", "participant_1"), True, "tie"),
            ),
            participant_outcomes=result.participant_outcomes,
        )


def test_python_and_godot_accept_reject_the_same_checked_in_fixtures(
    registry: EmbodimentProtocolRegistry,
) -> None:
    fixture = strict_json_loads(FIXTURE.read_bytes())
    package = registry.package(V3)
    python_results: dict[str, bool] = {}
    for case in fixture["config_cases"]:
        try:
            package.validate("episode-config", case["payload"])
        except ProtocolValidationError:
            python_results[case["id"]] = False
        else:
            python_results[case["id"]] = True
    for case in fixture["action_cases"]:
        try:
            package.validate("controller-action", case["payload"])
        except ProtocolValidationError:
            python_results[case["id"]] = False
        else:
            python_results[case["id"]] = True
    for case in fixture["decision_window_cases"]:
        try:
            package.validate("decision-window", case["payload"])
        except ProtocolValidationError:
            python_results[case["id"]] = False
        else:
            python_results[case["id"]] = True
    expected = {
        case["id"]: case["accepted"]
        for group in ("config_cases", "action_cases", "decision_window_cases")
        for case in fixture[group]
    }
    assert python_results == expected

    if not GODOT.is_file():
        pytest.skip("pinned local Godot executable is unavailable")
    completed = subprocess.run(
        [
            str(GODOT),
            "--headless",
            "--path",
            str(ROOT / "godot"),
            "--script",
            "res://tests/embodiment/trio_conformance_v3_headless_runner.gd",
            "--",
            f"--fixture={FIXTURE}",
        ],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert completed.returncode == 0, completed.stdout + completed.stderr
    result_line = next(
        line for line in reversed(completed.stdout.splitlines()) if line.startswith('{"results"')
    )
    assert json.loads(result_line)["results"] == expected


def test_v3_managed_transport_replay_and_determinism_runner() -> None:
    if not GODOT.is_file():
        pytest.skip("pinned local Godot executable is unavailable")
    completed = subprocess.run(
        [
            str(GODOT),
            "--headless",
            "--path",
            str(ROOT / "godot"),
            "--script",
            "res://tests/embodiment/trio_protocol_v3_headless_runner.gd",
        ],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert completed.returncode == 0, completed.stdout + completed.stderr
    assert "TRIO_PROTOCOL_V3_OK" in completed.stdout


def test_python_and_godot_derive_three_distinct_preview_tickets() -> None:
    expected = {
        "participant_0": "TmhwIY2zI-nRGxyAAcxwPgVJvTdf1ovJsoA5Sejplxc",
        "participant_1": "XQNdKG9cIDj9mHUJi0dacZoZ4J7g2Q8VbrLCOOePfag",
        "participant_2": "RzD5lISjmqwDa83RTIvmS6Je7c5yIam9STM-7yQ7Huk",
    }
    actual = {
        participant_id: derive_trio_preview_ticket(
            bytes(range(32)), attachment_ticket="A" * 43, participant_id=participant_id
        )
        for participant_id in expected
    }
    assert actual == expected
    assert len(set(actual.values())) == 3
    if not GODOT.is_file():
        pytest.skip("pinned local Godot executable is unavailable")
    completed = subprocess.run(
        [
            str(GODOT), "--headless", "--path", str(ROOT / "godot"), "--script",
            "res://tests/embodiment/trio_preview_ticket_v3_headless_runner.gd",
        ],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert completed.returncode == 0, completed.stdout + completed.stderr
    assert "TRIO_PREVIEW_TICKET_V3_OK" in completed.stdout


def test_real_godot_replay_matches_python_v3_schema_and_semantics(
    tmp_path: Path, registry: EmbodimentProtocolRegistry
) -> None:
    if not GODOT.is_file():
        pytest.skip("pinned local Godot executable is unavailable")
    replay_path = tmp_path / "trio-v3-replay.json"
    completed = subprocess.run(
        [
            str(GODOT), "--headless", "--path", str(ROOT / "godot"), "--script",
            "res://tests/embodiment/trio_protocol_v3_headless_runner.gd", "--",
            f"--replay-output={replay_path}",
        ],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert completed.returncode == 0, completed.stdout + completed.stderr
    payload = replay_path.read_bytes()
    package = registry.package(V3)
    replay = strict_json_loads(payload)
    package.validate("episode-replay", replay)
    verified = verify_replay_bytes(payload, registry=registry)
    assert verified["final_result"] == replay["final_result"]


def test_v3_movie_archive_selects_participant_scoped_renderer(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from genesis_arena.embodiment import replay_archive as module

    replay_path = tmp_path / "authority.replay.json"
    replay_path.write_bytes(b"{}")
    output_path = tmp_path / "participant-2.mp4"
    commands: list[tuple[str, ...]] = []

    def run(command: tuple[str, ...], **_kwargs: object) -> None:
        commands.append(command)
        if "--write-movie" in command:
            Path(command[command.index("--write-movie") + 1]).write_bytes(b"A" * 2048)
        elif command[-1] == str(output_path):
            output_path.write_bytes(b"\x00\x00\x00\x18ftypmp42moovmdat" + b"P" * 64)

    monkeypatch.setattr(module, "_run", run)
    module._render_participant_mp4(
        replay_path=replay_path,
        output_path=output_path,
        godot_executable=Path("/usr/bin/true"),
        godot_project_path=ROOT / "godot",
        ffmpeg_executable=Path("/usr/bin/true"),
        protocol_version=V3,
        participant_id="participant_2",
    )
    assert any(
        "res://scripts/embodiment/v3/replay/embodiment_movie_maker_cli_v3.gd" in command
        for command in commands
    )
