from __future__ import annotations

import json
from pathlib import Path

import pytest

from scripts import build_rts_showcase_artifacts as builder
from scripts import package_rts_showcase as packager

ROOT = Path(__file__).resolve().parents[2]


def _summary(participant: str, outcome: str, *, units_trained: int) -> dict[str, object]:
    return {
        "barracks_built": 1,
        "central_hold_ticks": 0,
        "completion_tick": 1200,
        "decision_windows": 120,
        "deposits": 3,
        "fallback_windows": 0,
        "hits_landed": 0,
        "hits_received": 0,
        "knockouts": 0,
        "materials_gathered": 3,
        "outcome": outcome,
        "participant_id": participant,
        "task_id": "rts-skirmish-v0",
        "terminal_outcome": "win",
        "terminal_reason": "town_hall_destroyed",
        "towers_built": 1,
        "town_hall_damage_dealt": 0,
        "town_hall_damage_received": 0,
        "units_trained": units_trained,
    }


def _event(
    kind: str, tick: int, participant_ids: list[str], data: dict[str, object]
) -> dict[str, object]:
    return {"kind": kind, "tick": tick, "participant_ids": participant_ids, "data": data}


def _verified_replay(*, casualty_tick: int = 850) -> dict[str, object]:
    events: list[dict[str, object]] = []
    for participant, prefix in (("participant_0", "blue"), ("participant_1", "red")):
        events.extend(
            [
                _event(
                    "rts_material_gathered",
                    120,
                    [participant],
                    {"kind": "wood", "resource_id": f"{prefix}_tree_0", "unit_id": f"{prefix}_0"},
                ),
                _event(
                    "rts_material_deposited",
                    160,
                    [participant],
                    {"kind": "wood", "team_total": 1, "unit_id": f"{prefix}_0"},
                ),
                _event(
                    "rts_material_gathered",
                    260,
                    [participant],
                    {"kind": "ore", "resource_id": f"{prefix}_ore_0", "unit_id": f"{prefix}_1"},
                ),
                _event(
                    "rts_material_deposited",
                    300,
                    [participant],
                    {"kind": "ore", "team_total": 1, "unit_id": f"{prefix}_1"},
                ),
                _event(
                    "rts_material_gathered",
                    460,
                    [participant],
                    {"kind": "wood", "resource_id": f"{prefix}_tree_1", "unit_id": f"{prefix}_2"},
                ),
                _event(
                    "rts_material_deposited",
                    500,
                    [participant],
                    {"kind": "wood", "team_total": 2, "unit_id": f"{prefix}_2"},
                ),
                _event("rts_construction_started", 520, [participant], {"structure": "barracks"}),
                _event("rts_structure_built", 590, [participant], {"structure": "barracks"}),
                _event("rts_construction_started", 600, [participant], {"structure": "tower"}),
                _event("rts_structure_built", 640, [participant], {"structure": "tower"}),
            ]
        )
    events.extend(
        [
            _event(
                "rts_unit_hit",
                820,
                ["participant_0", "participant_1"],
                {"unit_id": "blue_0", "damage": 250, "health": 750},
            ),
            _event(
                "rts_unit_lost",
                casualty_tick,
                ["participant_0", "participant_1"],
                {"unit_id": "blue_0", "remaining_units": 2},
            ),
            _event(
                "rts_unit_lost",
                880,
                ["participant_1", "participant_0"],
                {"unit_id": "red_0", "remaining_units": 2},
            ),
            _event(
                "rts_unit_lost",
                900,
                ["participant_1", "participant_0"],
                {"unit_id": "red_1", "remaining_units": 1},
            ),
            _event(
                "rts_unit_lost",
                1020,
                ["participant_1", "participant_0"],
                {"unit_id": "red_2", "remaining_units": 0},
            ),
            _event(
                "rts_structure_damaged",
                1080,
                ["participant_0", "participant_1"],
                {"structure": "tower", "health": 0},
            ),
            _event(
                "rts_structure_destroyed",
                1080,
                ["participant_0", "participant_1"],
                {"structure": "tower"},
            ),
            _event(
                "rts_structure_damaged",
                1180,
                ["participant_0", "participant_1"],
                {"structure": "town_hall", "health": 0},
            ),
            _event(
                "rts_structure_destroyed",
                1180,
                ["participant_0", "participant_1"],
                {"structure": "town_hall"},
            ),
            _event(
                "rts_structure_destroyed",
                1180,
                ["participant_0", "participant_1"],
                {"structure": "barracks"},
            ),
            _event(
                "rts_skirmish_completed",
                1200,
                ["participant_0", "participant_1"],
                {
                    "task_id": "rts-skirmish-v0",
                    "completion_tick": 1200,
                    "terminal_outcome": "win",
                    "terminal_reason": "town_hall_destroyed",
                    "winner_id": "participant_0",
                },
            ),
            _event(
                "rts_skirmish_participant_summary",
                1200,
                ["participant_0"],
                _summary("participant_0", "win", units_trained=2),
            ),
            _event(
                "rts_skirmish_participant_summary",
                1200,
                ["participant_1"],
                _summary("participant_1", "loss", units_trained=0),
            ),
        ]
    )
    return {
        "config": {
            "task_id": "rts-skirmish-v0",
            "maximum_episode_ticks": 1200,
            "participant_ids": ["participant_0", "participant_1"],
        },
        "final_state_hash": "f" * 64,
        "steps": [{"result": {"public_events": sorted(events, key=lambda item: item["tick"])}}],
    }


def _inputs(tmp_path: Path) -> tuple[Path, Path, Path, Path]:
    replay = tmp_path / "replay.json"
    replay.write_bytes(b"verified replay")
    video = tmp_path / "final.mp4"
    video.write_bytes(b"\x00\x00\x00\x18ftypisom" + b"0" * 32)
    return replay, video, tmp_path / "evaluation.json", tmp_path / "metadata.json"


def test_builder_emits_safe_canonical_evaluation_and_metadata(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    replay, video, evaluation_path, metadata_path = _inputs(tmp_path)
    monkeypatch.setattr(
        builder, "verify_replay_bytes", lambda *_args, **_kwargs: _verified_replay()
    )

    builder.build_rts_showcase_artifacts(
        repository_root=ROOT,
        replay_path=replay,
        video_path=video,
        evaluation_output=evaluation_path,
        metadata_output=metadata_path,
    )

    evaluation = json.loads(evaluation_path.read_text(encoding="utf-8"))
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    assert evaluation["completion"] == {
        "outcome": "win",
        "reason": "town_hall_destroyed",
        "tick": 1200,
    }
    assert evaluation["replay"]["python_verified"] is True
    assert [item["at_tick"] for item in metadata["casualties"]] == [850, 880, 900, 1020]
    assert [item["unit_id"] for item in metadata["casualties"]] == [
        "terra_agent_1",
        "luna_agent_1",
        "luna_agent_2",
        "luna_agent_3",
    ]
    assert metadata["highlights"][-1] == {"at_seconds": 145, "label": "Terra victory celebration"}
    metrics = {item["id"]: item["value"] for item in metadata["evaluation_metrics"]}
    assert metrics["unit_survival"] == "Terra 2 · Luna 0"
    assert "militia armed" in metrics["luna_economy"]
    assert "survivor" not in metrics["luna_economy"]
    assert "prompt" not in repr({"evaluation": evaluation, "metadata": metadata}).casefold()
    assert "raw_output" not in repr({"evaluation": evaluation, "metadata": metadata}).casefold()


def test_builder_rejects_a_casualty_tick_that_does_not_match_the_locked_story(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    replay, video, evaluation_path, metadata_path = _inputs(tmp_path)
    monkeypatch.setattr(
        builder,
        "verify_replay_bytes",
        lambda *_args, **_kwargs: _verified_replay(casualty_tick=851),
    )

    with pytest.raises(builder.RtsShowcaseBuildError, match="casualty sequence"):
        builder.build_rts_showcase_artifacts(
            repository_root=ROOT,
            replay_path=replay,
            video_path=video,
            evaluation_output=evaluation_path,
            metadata_output=metadata_path,
        )

    assert not evaluation_path.exists()
    assert not metadata_path.exists()


def test_builder_outputs_are_consumed_by_the_atomic_packager(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    replay, video, evaluation_path, metadata_path = _inputs(tmp_path)
    verified = _verified_replay()
    monkeypatch.setattr(builder, "verify_replay_bytes", lambda *_args, **_kwargs: verified)
    builder.build_rts_showcase_artifacts(
        repository_root=ROOT,
        replay_path=replay,
        video_path=video,
        evaluation_output=evaluation_path,
        metadata_output=metadata_path,
    )
    monkeypatch.setattr(packager, "verify_replay_bytes", lambda *_args, **_kwargs: verified)
    monkeypatch.setattr(
        packager,
        "probe_video",
        lambda *_args: {
            "duration_seconds": 150.0,
            "width": 1920,
            "height": 1080,
            "fps": 30.0,
        },
    )

    destination = packager.package_rts_showcase(
        repository_root=ROOT,
        replay_path=replay,
        evaluation_path=evaluation_path,
        video_path=video,
        metadata_path=metadata_path,
        ffmpeg_executable=tmp_path / "unused-ffmpeg",
        destination=tmp_path / "rts_skirmish",
    )

    assert (destination / packager.MANIFEST_NAME).is_file()
