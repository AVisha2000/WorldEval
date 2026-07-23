#!/usr/bin/env python3
"""Build sealed Mini RTS evaluation and public-story metadata from a verified replay.

This is intentionally a pre-packaging step.  It reads only the fixed RTS public event vocabulary,
never provider requests, prompts, observations, memories, or raw outputs.  Feed its two outputs
to ``package_rts_showcase.py`` together with the same replay and final native MP4.
"""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
from typing import Any, Mapping, Sequence

from genesis_arena.embodiment.protocol import canonical_json_bytes
from genesis_arena.embodiment.protocol_registry import EmbodimentProtocolRegistry
from genesis_arena.embodiment.replay import verify_replay_bytes
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
SHOWCASE_ID = "rts-skirmish-v0"
REPLAY_NAME = "rts-skirmish-demo.replay.json"
VIDEO_NAME = "rts-skirmish-broadcast.mp4"
EXPECTED_COMPLETION_TICK = 1200
EXPECTED_CASUALTIES = (
    ("blue_0", "Blue", 850),
    ("red_0", "Red", 880),
    ("red_1", "Red", 900),
    ("red_2", "Red", 1020),
)
_PARTICIPANTS = ("participant_0", "participant_1")
# Internal unit IDs deliberately retain their Blue/Red world-team prefixes for replay
# verification.  The sealed public story instead identifies the two deterministic demo
# agents by their showcase names.
_PUBLIC_TEAM_NAMES = {"Blue": "Terra", "Red": "Luna"}
_PUBLIC_UNIT_PREFIXES = {"blue": "terra", "red": "luna"}
_SUMMARY_FIELDS = frozenset(
    {
        "barracks_built",
        "central_hold_ticks",
        "completion_tick",
        "decision_windows",
        "deposits",
        "fallback_windows",
        "hits_landed",
        "hits_received",
        "knockouts",
        "materials_gathered",
        "outcome",
        "participant_id",
        "task_id",
        "terminal_outcome",
        "terminal_reason",
        "towers_built",
        "town_hall_damage_dealt",
        "town_hall_damage_received",
        "units_trained",
    }
)
_EVENT_KINDS = frozenset(
    {
        "rts_construction_started",
        "rts_material_deposited",
        "rts_material_gathered",
        "rts_skirmish_completed",
        "rts_skirmish_participant_summary",
        "rts_structure_built",
        "rts_structure_damaged",
        "rts_structure_destroyed",
        "rts_unit_armed",
        "rts_unit_hit",
        "rts_unit_lost",
        "rts_unit_spawned",
    }
)


class RtsShowcaseBuildError(RuntimeError):
    """The supplied replay does not prove the locked showcase story."""


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replay", type=Path, required=True)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--evaluation-output", type=Path, required=True)
    parser.add_argument("--metadata-output", type=Path, required=True)
    parser.add_argument("--repository-root", type=Path, default=ROOT)
    return parser


def build_rts_showcase_artifacts(
    *,
    repository_root: Path,
    replay_path: Path,
    video_path: Path,
    evaluation_output: Path,
    metadata_output: Path,
) -> tuple[Path, Path]:
    """Verify a final replay and emit canonical evaluator/public metadata artifacts."""

    root = Path(repository_root).resolve()
    replay_path = _readable_file(replay_path, "replay")
    video_path = _readable_file(video_path, "video")
    evaluation_output = _output_path(evaluation_output, "evaluation output")
    metadata_output = _output_path(metadata_output, "metadata output")
    if evaluation_output == metadata_output:
        raise RtsShowcaseBuildError("evaluation and metadata outputs must differ")
    replay_bytes = replay_path.read_bytes()
    video_bytes = video_path.read_bytes()
    if len(video_bytes) <= 16 or b"ftyp" not in video_bytes[:32]:
        raise RtsShowcaseBuildError("final video is not an MP4")
    try:
        replay = verify_replay_bytes(
            replay_bytes, registry=EmbodimentProtocolRegistry.from_repository(root)
        )
    except Exception as error:
        raise RtsShowcaseBuildError("authority replay failed independent verification") from error
    config = _mapping(replay.get("config"), "replay configuration")
    if (
        config.get("task_id") != SHOWCASE_ID
        or config.get("maximum_episode_ticks") != EXPECTED_COMPLETION_TICK
        or config.get("participant_ids") != list(_PARTICIPANTS)
    ):
        raise RtsShowcaseBuildError("replay does not use the locked 1200-tick RTS configuration")

    story = _parse_story(replay)
    replay_sha256 = _sha256(replay_bytes)
    video_sha256 = _sha256(video_bytes)
    evaluation = _evaluation(
        story, replay_sha256, video_sha256, _required_hash(replay.get("final_state_hash"))
    )
    metadata = _metadata(story)
    _write_canonical(evaluation_output, evaluation)
    _write_canonical(metadata_output, metadata)
    return evaluation_output, metadata_output


def _parse_story(replay: Mapping[str, Any]) -> Mapping[str, Any]:
    events = _public_rts_events(replay)
    completion: Mapping[str, Any] | None = None
    summaries: dict[str, Mapping[str, Any]] = {}
    casualties: list[tuple[str, str, int]] = []
    deposits = {participant: 0 for participant in _PARTICIPANTS}
    gathered = {participant: 0 for participant in _PARTICIPANTS}
    builds = {participant: {"barracks": 0, "tower": 0} for participant in _PARTICIPANTS}
    construction_starts = {
        participant: {"barracks": 0, "tower": 0} for participant in _PARTICIPANTS
    }
    damage_events = 0
    destroyed: list[str] = []
    for event in events:
        kind = event["kind"]
        data = event["data"]
        participants = event["participant_ids"]
        tick = event["tick"]
        if kind == "rts_skirmish_completed":
            if completion is not None or set(data) != {
                "completion_tick",
                "task_id",
                "terminal_outcome",
                "terminal_reason",
                "winner_id",
            }:
                raise RtsShowcaseBuildError("RTS completion event is invalid")
            completion = data
        elif kind == "rts_skirmish_participant_summary":
            summary = _summary(data)
            participant = summary["participant_id"]
            if participants != [participant] or participant in summaries:
                raise RtsShowcaseBuildError("RTS participant summary is invalid")
            summaries[participant] = summary
        elif kind == "rts_unit_lost":
            if set(data) != {"remaining_units", "unit_id"}:
                raise RtsShowcaseBuildError("RTS unit loss event is invalid")
            unit_id = _unit_id(data["unit_id"])
            casualties.append((unit_id, _team_for_unit(unit_id), tick))
        elif kind == "rts_material_gathered":
            if set(data) != {"kind", "resource_id", "unit_id"} or len(participants) != 1:
                raise RtsShowcaseBuildError("RTS gather event is invalid")
            participant = participants[0]
            unit_id = _unit_for_participant(data["unit_id"], participant)
            material = _material_kind(data["kind"])
            _resource_for_participant(data["resource_id"], participant, material)
            if unit_id.rsplit("_", 1)[-1] not in {"0", "1", "2"}:
                raise RtsShowcaseBuildError("RTS gather event is invalid")
            gathered[participant] += 1
        elif kind == "rts_material_deposited":
            if set(data) != {"kind", "team_total", "unit_id"} or len(participants) != 1:
                raise RtsShowcaseBuildError("RTS deposit event is invalid")
            participant = participants[0]
            _unit_for_participant(data["unit_id"], participant)
            _material_kind(data["kind"])
            if (
                not isinstance(data["team_total"], int)
                or isinstance(data["team_total"], bool)
                or data["team_total"] <= 0
            ):
                raise RtsShowcaseBuildError("RTS deposit event is invalid")
            deposits[participant] += 1
        elif kind == "rts_construction_started":
            if set(data) != {"structure"} or len(participants) != 1:
                raise RtsShowcaseBuildError("RTS construction event is invalid")
            structure = data["structure"]
            if participants[0] not in construction_starts or structure not in {"barracks", "tower"}:
                raise RtsShowcaseBuildError("RTS construction event is invalid")
            construction_starts[participants[0]][structure] += 1
        elif kind == "rts_structure_built":
            if set(data) != {"structure"} or len(participants) != 1:
                raise RtsShowcaseBuildError("RTS build event is invalid")
            structure = data["structure"]
            if participants[0] not in builds or structure not in builds[participants[0]]:
                raise RtsShowcaseBuildError("RTS build event is invalid")
            builds[participants[0]][structure] += 1
        elif kind == "rts_unit_spawned":
            if set(data) != {"unit_count", "unit_id"} or len(participants) != 1:
                raise RtsShowcaseBuildError("RTS spawn event is invalid")
            participant = participants[0]
            _unit_for_participant(data["unit_id"], participant)
            if (
                not isinstance(data["unit_count"], int)
                or isinstance(data["unit_count"], bool)
                or data["unit_count"] not in {2, 3}
            ):
                raise RtsShowcaseBuildError("RTS spawn event is invalid")
        elif kind == "rts_unit_armed":
            if set(data) != {"unit_id"} or len(participants) != 1:
                raise RtsShowcaseBuildError("RTS arming event is invalid")
            _unit_for_participant(data["unit_id"], participants[0])
        elif kind == "rts_unit_hit":
            if (
                set(data) != {"damage", "health", "unit_id"}
                or not isinstance(data["damage"], int)
                or isinstance(data["damage"], bool)
                or data["damage"] <= 0
                or not isinstance(data["health"], int)
                or isinstance(data["health"], bool)
                or data["health"] < 0
            ):
                raise RtsShowcaseBuildError("RTS unit damage event is invalid")
            _known_unit_id(data["unit_id"])
            damage_events += 1
        elif kind == "rts_structure_damaged":
            if (
                set(data) != {"health", "structure"}
                or data["structure"] not in {"tower", "town_hall"}
                or not isinstance(data["health"], int)
                or isinstance(data["health"], bool)
                or data["health"] < 0
            ):
                raise RtsShowcaseBuildError("RTS structure damage event is invalid")
            damage_events += 1
        elif kind == "rts_structure_destroyed":
            if set(data) != {"structure"} or data["structure"] not in {
                "barracks",
                "tower",
                "town_hall",
            }:
                raise RtsShowcaseBuildError("RTS destruction event is invalid")
            destroyed.append(str(data["structure"]))

    if completion is None or set(summaries) != set(_PARTICIPANTS):
        raise RtsShowcaseBuildError("RTS terminal evidence is incomplete")
    required_completion = {
        "task_id": SHOWCASE_ID,
        "completion_tick": EXPECTED_COMPLETION_TICK,
        "terminal_outcome": "win",
        "terminal_reason": "town_hall_destroyed",
        "winner_id": "participant_0",
    }
    if completion != required_completion:
        raise RtsShowcaseBuildError("RTS completion does not match the locked showcase story")
    if (
        summaries["participant_0"]["outcome"] != "win"
        or summaries["participant_1"]["outcome"] != "loss"
    ):
        raise RtsShowcaseBuildError(
            "RTS participant outcomes do not match the locked showcase story"
        )
    if tuple(casualties) != EXPECTED_CASUALTIES:
        raise RtsShowcaseBuildError(
            "RTS casualty sequence does not match the locked showcase story"
        )
    # The victory proof is the ordered tower siege followed by the Town Hall kill.  The
    # authority then marks Red's remaining barracks destroyed for the terminal presentation.
    # Keep that cleanup explicit rather than allowing an arbitrary structure event after victory.
    if destroyed != ["tower", "town_hall", "barracks"]:
        raise RtsShowcaseBuildError("RTS structure destruction sequence is invalid")
    for participant, summary in summaries.items():
        if (
            summary["completion_tick"] != EXPECTED_COMPLETION_TICK
            or summary["deposits"] != deposits[participant]
            or summary["materials_gathered"] != gathered[participant]
        ):
            raise RtsShowcaseBuildError("RTS summary economy does not match public events")
        if (
            summary["barracks_built"] != builds[participant]["barracks"]
            or summary["towers_built"] != builds[participant]["tower"]
            or construction_starts[participant] != builds[participant]
        ):
            raise RtsShowcaseBuildError("RTS construction summary does not match public events")
    return {
        "completion": {
            "tick": EXPECTED_COMPLETION_TICK,
            "outcome": "win",
            "reason": "town_hall_destroyed",
        },
        "summaries": summaries,
        "casualties": casualties,
        "damage_events": damage_events,
        "destroyed": destroyed,
    }


def _public_rts_events(replay: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    steps = replay.get("steps")
    if not isinstance(steps, list):
        raise RtsShowcaseBuildError("verified replay has no steps")
    output: list[Mapping[str, Any]] = []
    previous_tick = -1
    for step in steps:
        result = _mapping(_mapping(step, "replay step").get("result"), "replay result")
        events = result.get("public_events")
        if not isinstance(events, list):
            raise RtsShowcaseBuildError("replay public events are invalid")
        for raw in events:
            event = _mapping(raw, "RTS event")
            kind = event.get("kind")
            if not isinstance(kind, str) or not kind.startswith("rts_"):
                continue
            if kind not in _EVENT_KINDS:
                raise RtsShowcaseBuildError("replay contains an unsupported RTS event")
            tick = event.get("tick")
            participants = event.get("participant_ids")
            data = event.get("data")
            if (
                not isinstance(tick, int)
                or isinstance(tick, bool)
                or tick < previous_tick
                or not isinstance(participants, list)
                or any(participant not in _PARTICIPANTS for participant in participants)
                or not isinstance(data, dict)
            ):
                raise RtsShowcaseBuildError("RTS event shape is invalid")
            previous_tick = tick
            output.append(
                {"kind": kind, "tick": tick, "participant_ids": participants, "data": data}
            )
    return output


def _summary(value: Any) -> Mapping[str, Any]:
    summary = _mapping(value, "RTS participant summary")
    if set(summary) != _SUMMARY_FIELDS or summary.get("task_id") != SHOWCASE_ID:
        raise RtsShowcaseBuildError("RTS participant summary fields are invalid")
    participant = summary.get("participant_id")
    if participant not in _PARTICIPANTS or summary.get("outcome") not in {"win", "loss"}:
        raise RtsShowcaseBuildError("RTS participant summary identity is invalid")
    for key in _SUMMARY_FIELDS - {
        "outcome",
        "participant_id",
        "task_id",
        "terminal_outcome",
        "terminal_reason",
    }:
        if (
            not isinstance(summary.get(key), int)
            or isinstance(summary[key], bool)
            or summary[key] < 0
        ):
            raise RtsShowcaseBuildError("RTS participant summary counters are invalid")
    if (
        summary.get("terminal_outcome") != "win"
        or summary.get("terminal_reason") != "town_hall_destroyed"
    ):
        raise RtsShowcaseBuildError("RTS participant summary terminal state is invalid")
    return summary


def _material_kind(value: Any) -> str:
    if value not in {"wood", "ore"}:
        raise RtsShowcaseBuildError("RTS material kind is invalid")
    return str(value)


def _resource_for_participant(value: Any, participant: str, material: str) -> str:
    if not isinstance(value, str):
        raise RtsShowcaseBuildError("RTS resource identity is invalid")
    prefix = "blue" if participant == "participant_0" else "red"
    maximum = 3 if material == "wood" else 2
    resource_kind = "tree" if material == "wood" else "ore"
    allowed = {f"{prefix}_{resource_kind}_{index}" for index in range(maximum + 1)}
    if value not in allowed:
        raise RtsShowcaseBuildError("RTS resource identity is invalid")
    return value


def _evaluation(
    story: Mapping[str, Any], replay_sha256: str, video_sha256: str, final_state_sha256: str
) -> dict[str, Any]:
    summaries = story["summaries"]
    participants = {
        participant: {
            key: summaries[participant][key]
            for key in sorted(_SUMMARY_FIELDS)
            if key not in {"participant_id", "task_id"}
        }
        for participant in _PARTICIPANTS
    }
    return {
        "artifact_version": "worldarena/rts-skirmish-presentation/2",
        "schema_version": "rts-skirmish-evaluation/2",
        "scope": "duo_game",
        "task_id": SHOWCASE_ID,
        "completion": story["completion"],
        "participants": participants,
        "combat": {
            "casualties": len(story["casualties"]),
            "damage_events": story["damage_events"],
            "destroyed_structures": story["destroyed"],
        },
        "replay": {
            "path": REPLAY_NAME,
            "sha256": replay_sha256,
            "final_state_sha256": final_state_sha256,
            "python_verified": True,
            "verifier": "python-registry-v2",
        },
        "media": {
            "path": VIDEO_NAME,
            "sha256": video_sha256,
            "duration_seconds": 150,
            "width": 1920,
            "height": 1080,
            "fps": 30,
            "renderer": "godot-movie-maker+ffmpeg",
        },
    }


def _metadata(story: Mapping[str, Any]) -> dict[str, Any]:
    summaries = story["summaries"]
    blue = summaries["participant_0"]
    red = summaries["participant_1"]
    casualties_by_team = {
        "Blue": sum(1 for _unit_id, team, _tick in story["casualties"] if team == "Blue"),
        "Red": sum(1 for _unit_id, team, _tick in story["casualties"] if team == "Red"),
    }
    # The sealed story starts each side with exactly three first-class units by the bridge phase.
    # Do not present the historical `units_trained` counter as a survivor count: Red trains all
    # three workers before they are defeated.
    blue_survivors = 3 - casualties_by_team["Blue"]
    red_survivors = 3 - casualties_by_team["Red"]
    return {
        "label": "WorldArena: Mini RTS — Terra vs Luna",
        "winner": {"team": "Terra"},
        "completion": story["completion"],
        "casualties": [
            {
                "unit_id": _public_unit_id(unit_id),
                "team": _PUBLIC_TEAM_NAMES[team],
                "at_tick": tick,
            }
            for unit_id, team, tick in story["casualties"]
        ],
        "highlights": [
            {"at_seconds": 0, "label": "Terra and Luna workers deploy"},
            {"at_seconds": 15, "label": "First workers walk to separate resource nodes"},
            {"at_seconds": 40, "label": "Three workers harvest and return materials"},
            {"at_seconds": 65, "label": "Barracks build and militia arming complete"},
            {"at_seconds": 80, "label": "Three-versus-three bridge battle begins"},
            {"at_seconds": 100, "label": "Luna retreats as Terra pursues"},
            {"at_seconds": 116, "label": "Terra destroys Luna's tower"},
            {"at_seconds": 132, "label": "Terra attacks Luna's Town Hall"},
            {"at_seconds": 145, "label": "Terra victory celebration"},
        ],
        "evaluation_metrics": [
            {
                "id": "terra_economy",
                "label": "Terra economy",
                "value": f"{blue['deposits']} deposits · {blue['units_trained']} militia armed",
            },
            {
                "id": "luna_economy",
                "label": "Luna economy",
                "value": f"{red['deposits']} deposits · {red['units_trained']} militia armed",
            },
            {
                "id": "unit_survival",
                "label": "Unit survival",
                "value": f"Terra {blue_survivors} · Luna {red_survivors}",
            },
            {
                "id": "combat",
                "label": "Combat",
                "value": f"{len(story['casualties'])} casualties · town hall destroyed",
            },
            {
                "id": "determinism",
                "label": "Determinism",
                "value": "1,200 authority ticks · replay verified",
            },
        ],
    }


def _mapping(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise RtsShowcaseBuildError(f"{label} is invalid")
    return value


def _unit_id(value: Any) -> str:
    if not isinstance(value, str) or value not in {item[0] for item in EXPECTED_CASUALTIES}:
        raise RtsShowcaseBuildError("RTS unit identifier is invalid")
    return value


def _known_unit_id(value: Any) -> str:
    if not isinstance(value, str) or value not in {
        "blue_0",
        "blue_1",
        "blue_2",
        "red_0",
        "red_1",
        "red_2",
    }:
        raise RtsShowcaseBuildError("RTS unit identifier is invalid")
    return value


def _team_for_unit(unit_id: str) -> str:
    return "Blue" if unit_id.startswith("blue_") else "Red"


def _public_unit_id(unit_id: str) -> str:
    """Translate a sealed replay ID into a readable public showcase alias."""

    team, raw_index = unit_id.split("_", 1)
    return f"{_PUBLIC_UNIT_PREFIXES[team]}_agent_{int(raw_index) + 1}"


def _unit_for_participant(value: Any, participant: str) -> str:
    unit_id = _known_unit_id(value)
    if not unit_id.startswith(
        "blue_" if participant == "participant_0" else "red_"
    ):
        raise RtsShowcaseBuildError("RTS event unit owner is invalid")
    return unit_id


def _required_hash(value: Any) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise RtsShowcaseBuildError("replay final-state hash is invalid")
    return value


def _readable_file(value: Path, label: str) -> Path:
    path = Path(value).resolve()
    if not path.is_file() or path.is_symlink():
        raise RtsShowcaseBuildError(f"{label} file is unavailable")
    return path


def _output_path(value: Path, label: str) -> Path:
    path = Path(value).resolve()
    if path.is_dir() or not path.parent.is_dir():
        raise RtsShowcaseBuildError(f"{label} parent is unavailable")
    return path


def _write_canonical(path: Path, value: Mapping[str, Any]) -> None:
    temporary = path.with_name(f".{path.name}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(canonical_json_bytes(value))
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        evaluation, metadata = build_rts_showcase_artifacts(
            repository_root=arguments.repository_root,
            replay_path=arguments.replay,
            video_path=arguments.video,
            evaluation_output=arguments.evaluation_output,
            metadata_output=arguments.metadata_output,
        )
    except (OSError, RtsShowcaseBuildError) as error:
        print(f"RTS_SHOWCASE_BUILD_FAILED: {error}")
        return 2
    print(f"RTS_SHOWCASE_BUILD_OK evaluation={evaluation} metadata={metadata}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
