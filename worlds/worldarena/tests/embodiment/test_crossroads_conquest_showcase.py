from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Mapping

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from genesis_arena.embodiment.api import router
from genesis_arena.embodiment.crossroads_conquest import (
    MAX_VIDEO_BYTES,
    CachedCrossroadsShowcase,
    CrossroadsShowcaseError,
)

ZERO_HASH = "0" * 64
POLICY_HASH = "1" * 64
MAP_HASH = "2" * 64
RULES_HASH = "3" * 64
TRACE_HASH = "4" * 64
FINAL_HASH = "5" * 64


def _json_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()


def _sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _atom(kind: bytes, payload: bytes = b"") -> bytes:
    return (8 + len(payload)).to_bytes(4, "big") + kind + payload


def _timeline() -> list[dict[str, Any]]:
    beat_ids = (
        "opening_reveal",
        "sol_introduction",
        "terra_introduction",
        "luna_introduction",
        "terra_claims_crossroads",
        "sol_prepares_assault",
        "luna_observes",
        "crossroads_clash",
        "sol_takes_crossroads",
        "two_front_march",
        "terra_counterpunch",
        "sol_breaches_terra",
        "terra_eliminated",
        "exposed_sol_overview",
        "luna_strikes",
        "sol_eliminated",
        "verified_result",
    )
    labels = (
        "Aerial map reveal",
        "Sol prepares siege",
        "Terra advances on the center",
        "Luna scouts",
        "Terra claims the center",
        "Sol prepares its assault",
        "Luna holds fire",
        "The Crossroads clash begins",
        "Sol takes the center",
        "Two fronts open",
        "Terra's counterpunch lands",
        "Sol breaches Terra",
        "Terra eliminated",
        "Luna stages west",
        "Luna strikes",
        "Sol eliminated",
        "Luna wins",
    )
    seconds = (0, 12, 19, 26, 33, 44, 55, 65, 78, 90, 102, 114, 126, 137, 146, 158, 169)
    rounds = (0, 1, 1, 2, 10, 11, 12, 16, 20, 22, 24, 25, 25, 26, 26, 29, 29)
    event_ids = (
        "",
        "",
        "",
        "",
        "event_4",
        "event_5",
        "event_6",
        "event_7",
        "event_8",
        "event_9",
        "event_10",
        "event_11",
        "event_12",
        "event_12",
        "event_14",
        "event_15",
        "event_15",
    )
    return [
        {
            "beat_id": beat_ids[index],
            "at_seconds": at_seconds,
            "round": rounds[index],
            "frame_index": max(0, index - 3),
            "event_id": event_ids[index],
            "kind": "editorial" if index < 4 else "authority_event",
            "editorial": index < 4,
            "label": label,
        }
        for index, (at_seconds, label) in enumerate(zip(seconds, labels))
    ]


def _placements() -> list[dict[str, Any]]:
    return [
        {
            "placement": 1,
            "entrant_id": "participant_1",
            "faction_id": "luna",
            "display_name": "Luna",
        },
        {"placement": 2, "entrant_id": "participant_0", "faction_id": "sol", "display_name": "Sol"},
        {
            "placement": 3,
            "entrant_id": "participant_2",
            "faction_id": "terra",
            "display_name": "Terra",
        },
    ]


def _eliminations() -> list[dict[str, Any]]:
    return [
        {
            "order": 1,
            "faction_id": "terra",
            "eliminated_by": "sol",
            "round": 25,
            "event_id": "event_12",
        },
        {
            "order": 2,
            "faction_id": "sol",
            "eliminated_by": "luna",
            "round": 29,
            "event_id": "event_15",
        },
    ]


def _write_package(root: Path) -> Path:
    directory = root / "godot" / "showcases" / "crossroads_conquest"
    directory.mkdir(parents=True)
    timeline = _timeline()
    replay = {
        "schema": "worldarena/crossroads-conquest-replay/1",
        "showcase_id": "crossroads-conquest-v0",
        "task_id": "crossroads-conquest-v0",
        "protocol": "world-arena/0.4",
        "map_id": "tri_13_v1",
        "rules_id": "arena-v0.4",
        "seed": 424242,
        "policy": {"id": "crossroads-conquest-demo-v1", "sha256": POLICY_HASH},
        "duration_seconds": 180,
        "authority": {
            "completed_rounds": 29,
            "normalized_trace_sha256": TRACE_HASH,
            "final_state_sha256": FINAL_HASH,
        },
        "initial_snapshot": {"round": 0},
        "rounds": [
            {"round": round_number, "plans": {"sol": [], "luna": [], "terra": []}, "frames": []}
            for round_number in range(1, 30)
        ],
        "events": [
            {"event_id": event_id}
            for event_id in dict.fromkeys(item["event_id"] for item in timeline)
            if event_id
        ],
        "result": {
            "winner": "luna",
            "placements": ["luna", "sol", "terra"],
            "elimination_order": ["terra", "sol"],
        },
        "public_timeline": timeline,
    }
    replay_bytes = _json_bytes(replay)
    replay_sha256 = _sha256(replay_bytes)
    evaluation = {
        "schema": "worldarena/crossroads-conquest-evaluation/1",
        "showcase_id": "crossroads-conquest-v0",
        "derived_from": {
            "replay_sha256": replay_sha256,
            "normalized_trace_sha256": TRACE_HASH,
            "final_state_sha256": FINAL_HASH,
        },
        "outcome": {
            "winner": {"entrant_id": "participant_1", "faction_id": "luna", "display_name": "Luna"},
            "placements": _placements(),
            "elimination_order": _eliminations(),
        },
        "verification": {
            "deterministic_runs": 2,
            "order_rejections": 0,
            "luna_first_hostile_round": 26,
        },
        "factions": [
            {
                "faction_id": "sol",
                "placement": 2,
                "core_hp": 0,
                "eliminated_round": 29,
                "eliminated_by": "luna",
                "strongholds_destroyed": 1,
            },
            {
                "faction_id": "luna",
                "placement": 1,
                "core_hp": 1000,
                "eliminated_round": None,
                "eliminated_by": None,
                "strongholds_destroyed": 1,
            },
            {
                "faction_id": "terra",
                "placement": 3,
                "core_hp": 0,
                "eliminated_round": 25,
                "eliminated_by": "sol",
                "strongholds_destroyed": 0,
            },
        ],
    }
    evaluation_bytes = _json_bytes(evaluation)
    video_bytes = _atom(b"ftyp", b"isom\x00\x00\x02\x00isom") + _atom(b"moov") + _atom(b"mdat")
    manifest = {
        "schema": "worldarena/crossroads-conquest-showcase-manifest/1",
        "schema_version": 1,
        "showcase_id": "crossroads-conquest-v0",
        "task_id": "crossroads-conquest-v0",
        "title": "WorldArena: Crossroads Conquest",
        "tagline": "Three strongholds. One crossroads. Last faction standing.",
        "verified": True,
        "entrants": [
            {
                "entrant_id": "participant_0",
                "faction_id": "sol",
                "display_name": "Sol",
                "glyph": "△",
                "color": "#fbbf24",
                "policy_id": "crossroads-conquest-demo-v1",
            },
            {
                "entrant_id": "participant_1",
                "faction_id": "luna",
                "display_name": "Luna",
                "glyph": "○",
                "color": "#a78bfa",
                "policy_id": "crossroads-conquest-demo-v1",
            },
            {
                "entrant_id": "participant_2",
                "faction_id": "terra",
                "display_name": "Terra",
                "glyph": "□",
                "color": "#34d399",
                "policy_id": "crossroads-conquest-demo-v1",
            },
        ],
        "authority_bindings": {
            "protocol": "world-arena/0.4",
            "seed": 424242,
            "policy_id": "crossroads-conquest-demo-v1",
            "policy_sha256": POLICY_HASH,
            "map_id": "tri_13_v1",
            "map_sha256": MAP_HASH,
            "rules_id": "arena-v0.4",
            "rules_sha256": RULES_HASH,
            "normalized_trace_sha256": TRACE_HASH,
            "final_state_sha256": FINAL_HASH,
        },
        "winner": {"entrant_id": "participant_1", "faction_id": "luna", "display_name": "Luna"},
        "placements": _placements(),
        "elimination_order": _eliminations(),
        "replay": {"path": "crossroads-conquest-demo.replay.json", "sha256": replay_sha256},
        "evaluation": {"path": "evaluation.json", "sha256": _sha256(evaluation_bytes)},
        "video": {
            "path": "crossroads-conquest-broadcast.mp4",
            "sha256": _sha256(video_bytes),
            "duration_seconds": 180,
            "width": 1920,
            "height": 1080,
            "fps": 30,
            "codec": "h264",
            "pixel_format": "yuv420p",
            "audio_codec": "aac",
            "audio_channels": 2,
            "fast_start": True,
            "size_bytes": len(video_bytes),
        },
        "public_timeline": timeline,
    }
    (directory / "crossroads-conquest-demo.replay.json").write_bytes(replay_bytes)
    (directory / "evaluation.json").write_bytes(evaluation_bytes)
    (directory / "crossroads-conquest-broadcast.mp4").write_bytes(video_bytes)
    (directory / "manifest.json").write_bytes(_json_bytes(manifest))
    return directory


def _read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


def _write_json(path: Path, value: Mapping[str, Any]) -> None:
    path.write_bytes(_json_bytes(value))


def test_cached_crossroads_showcase_serves_safe_views_range_video_and_no_replay(
    tmp_path: Path,
) -> None:
    _write_package(tmp_path)
    showcase = CachedCrossroadsShowcase.load(tmp_path)
    app = FastAPI()
    app.state.embodiment_crossroads_showcase = showcase
    app.include_router(router)
    with TestClient(app) as client:
        metadata = client.get("/api/embodiment/showcases/crossroads-conquest-v0")
        evaluation = client.get("/api/embodiment/showcases/crossroads-conquest-v0/evaluation")
        video = client.get(
            "/api/embodiment/showcases/crossroads-conquest-v0/video",
            headers={"Range": "bytes=0-7"},
        )
        replay = client.get("/api/embodiment/showcases/crossroads-conquest-v0/replay")

    assert metadata.status_code == evaluation.status_code == 200
    assert metadata.headers["cache-control"] == "public, max-age=3600, immutable"
    assert metadata.json()["winner"]["faction_id"] == "luna"
    assert [item["faction_id"] for item in metadata.json()["placements"]] == [
        "luna",
        "sol",
        "terra",
    ]
    assert evaluation.json()["verification"]["order_rejections"] == 0
    assert video.status_code == 206 and len(video.content) == 8
    assert video.headers["x-content-type-options"] == "nosniff"
    assert replay.status_code == 404
    serialized = repr({"metadata": metadata.json(), "evaluation": evaluation.json()}).casefold()
    assert not any(
        term in serialized for term in ("prompt", "raw_output", "scratchpad", "observation")
    )


def test_cached_crossroads_timeline_allows_two_chapters_to_share_an_elimination_event(
    tmp_path: Path,
) -> None:
    _write_package(tmp_path)
    showcase = CachedCrossroadsShowcase.load(tmp_path)
    timeline = showcase.public_view()["timeline"]

    assert timeline[12]["beat_id"] == "terra_eliminated"
    assert timeline[13]["beat_id"] == "exposed_sol_overview"
    assert timeline[12]["event_id"] == timeline[13]["event_id"] == "event_12"
    assert timeline[15]["beat_id"] == "sol_eliminated"
    assert timeline[16]["beat_id"] == "verified_result"
    assert timeline[15]["event_id"] == timeline[16]["event_id"] == "event_15"


@pytest.mark.parametrize(
    ("mutate", "expected"),
    [
        (lambda value: value["replay"].update(path="../replay.json"), "manifest_invalid"),
        (lambda value: value["public_timeline"].reverse(), "manifest_invalid"),
        (lambda value: value["video"].update(duration_seconds=179), "manifest_invalid"),
        (lambda value: value["video"].update(size_bytes=MAX_VIDEO_BYTES + 1), "manifest_invalid"),
        (lambda value: value["replay"].update(sha256=ZERO_HASH), "hash_invalid"),
    ],
)
def test_cached_crossroads_showcase_rejects_unsafe_or_tampered_manifest(
    tmp_path: Path, mutate: Any, expected: str
) -> None:
    directory = _write_package(tmp_path)
    manifest_path = directory / "manifest.json"
    manifest = _read_json(manifest_path)
    mutate(manifest)
    _write_json(manifest_path, manifest)

    with pytest.raises(CrossroadsShowcaseError, match=expected):
        CachedCrossroadsShowcase.load(tmp_path)


def test_cached_crossroads_showcase_rejects_private_evaluation_fields(tmp_path: Path) -> None:
    directory = _write_package(tmp_path)
    evaluation_path = directory / "evaluation.json"
    evaluation = _read_json(evaluation_path)
    evaluation["prompt"] = "private"
    evaluation_bytes = _json_bytes(evaluation)
    evaluation_path.write_bytes(evaluation_bytes)
    manifest_path = directory / "manifest.json"
    manifest = _read_json(manifest_path)
    manifest["evaluation"]["sha256"] = _sha256(evaluation_bytes)
    _write_json(manifest_path, manifest)

    with pytest.raises(CrossroadsShowcaseError, match="evaluation_invalid"):
        CachedCrossroadsShowcase.load(tmp_path)


def test_cached_crossroads_showcase_rejects_partial_output(tmp_path: Path) -> None:
    directory = _write_package(tmp_path)
    (directory / "evaluation.json").unlink()
    with pytest.raises(CrossroadsShowcaseError, match="incomplete"):
        CachedCrossroadsShowcase.load(tmp_path)
