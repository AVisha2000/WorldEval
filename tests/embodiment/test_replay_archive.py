from __future__ import annotations

import hashlib
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from genesis_arena.embodiment.api import router
from genesis_arena.embodiment.artifacts import (
    PROTECTED_LAYER,
    PUBLIC_LAYER,
    EpisodeArtifact,
    EpisodeArtifactBundle,
    EpisodeBundles,
)
from genesis_arena.embodiment.episode_service import EpisodeRunSpec, EpisodeService
from genesis_arena.embodiment.protocol import EmbodimentProtocolPackage
from genesis_arena.embodiment.replay_archive import SavedReplay, SavedReplayArchive
from genesis_arena.embodiment.scripted_construction_demo import (
    SCRIPTED_CONSTRUCTION_PROVIDER,
    SCRIPTED_CONSTRUCTION_TASK,
)
from genesis_arena.embodiment.scripted_solo_demo import scripted_demo_model

ROOT = Path(__file__).resolve().parents[2]


def _spec(task_id: str = SCRIPTED_CONSTRUCTION_TASK) -> EpisodeRunSpec:
    return EpisodeRunSpec(
        episode_id="ep_saved_construction",
        provider=SCRIPTED_CONSTRUCTION_PROVIDER,
        model=scripted_demo_model(task_id),
        task_id=task_id,
        seed=7,
        maximum_episode_ticks=1300 if task_id == SCRIPTED_CONSTRUCTION_TASK else 600,
    )


def _bundles() -> EpisodeBundles:
    return EpisodeBundles(
        public=EpisodeArtifactBundle.create(
            PUBLIC_LAYER, (EpisodeArtifact.json("evaluation", {"score": 1}),)
        ),
        protected=EpisodeArtifactBundle.create(
            PROTECTED_LAYER,
            (
                EpisodeArtifact(
                    "authority_replay",
                    "application/json",
                    b'{"hidden":"raw-model-output-must-stay-local"}',
                ),
            ),
        ),
    )


def _replay(spec: EpisodeRunSpec) -> dict:
    return {
        "config": {
            "episode_id": spec.episode_id,
            "mode": "solo-curriculum-v0",
            "task_id": spec.task_id,
            "observation_profile": "hybrid-visible-v1",
        },
        "final_terminal": {"ended": True, "outcome": "success", "reason": "barricade_built"},
        "steps": [{"result": {"observations": {"participant_0": {"tick": 12}}}}],
    }


@pytest.mark.asyncio
async def test_saved_replay_archives_only_verified_participant_video(tmp_path, monkeypatch) -> None:
    from genesis_arena.embodiment import replay_archive as module

    spec = _spec()
    bundles = _bundles()
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    archive = SavedReplayArchive(
        runs_dir=tmp_path,
        protocol_package=package,
        godot_executable=Path("/bin/true"),
        godot_project_path=ROOT / "godot",
        ffmpeg_executable=Path("/bin/true"),
    )

    async def verify_with_godot(*_args, **_kwargs):
        return {"kind": "embodiment_replay_verified"}

    def render_participant_mp4(*, output_path: Path, **_kwargs) -> None:
        output_path.write_bytes(b"\x00\x00\x00\x18ftypmp42moovmdatparticipant-pixels-only")

    monkeypatch.setattr(module, "verify_offline_replay", lambda *_args, **_kwargs: _replay(spec))
    monkeypatch.setattr(module, "verify_offline_replay_with_godot", verify_with_godot)
    monkeypatch.setattr(module, "_render_participant_mp4", render_participant_mp4)

    saved = await archive.save(spec, bundles)

    assert saved.public_dict() == {
        "replay_id": spec.episode_id,
        "episode_id": spec.episode_id,
        "task_id": "construction-v0",
        "label": "Construction v0 scripted demo",
        "outcome": "success",
        "reason": "barricade_built",
        "authority_ticks": 12,
        "duration_seconds": 1.2,
        "video": {
            "available": True,
            "mime_type": "video/mp4",
            "sha256": hashlib.sha256(
                b"\x00\x00\x00\x18ftypmp42moovmdatparticipant-pixels-only"
            ).hexdigest(),
            "width": 1280,
            "height": 720,
            "fps": 30,
        },
    }
    directory = tmp_path / "embodiment-replays" / spec.episode_id
    assert (directory / "authority.replay.json").is_file()
    assert (directory / "public.bundle.json").is_file()
    assert archive.video_path(spec.episode_id) == directory / "participant-replay.mp4"
    assert archive.get("../authority.replay.json") is None
    assert archive.list() == (saved,)
    assert b"raw-model-output-must-stay-local" not in (directory / "manifest.json").read_bytes()
    assert (directory / "authority.replay.json").stat().st_mode & 0o077 == 0


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("task_id", "episode_id", "label"),
    (
        ("orientation-v0", "ep_saved_orientation", "Orientation v0 scripted demo"),
        ("interaction-v0", "ep_saved_interaction", "Interaction v0 scripted demo"),
        ("neutral-encounter-v0", "ep_saved_neutral", "Neutral Encounter v0 scripted demo"),
    ),
)
async def test_saved_replay_archives_each_scripted_solo_stage(
    tmp_path, monkeypatch, task_id: str, episode_id: str, label: str
) -> None:
    from genesis_arena.embodiment import replay_archive as module

    spec = _spec(task_id)
    spec = EpisodeRunSpec(
        episode_id=episode_id,
        provider=spec.provider,
        model=spec.model,
        task_id=spec.task_id,
        seed=spec.seed,
        maximum_episode_ticks=spec.maximum_episode_ticks,
    )
    archive = SavedReplayArchive(
        runs_dir=tmp_path,
        protocol_package=EmbodimentProtocolPackage.from_repository(ROOT),
        godot_executable=Path("/bin/true"),
        godot_project_path=ROOT / "godot",
        ffmpeg_executable=Path("/bin/true"),
    )

    async def verify_with_godot(*_args, **_kwargs):
        return {"kind": "embodiment_replay_verified"}

    def render_participant_mp4(*, output_path: Path, **_kwargs) -> None:
        output_path.write_bytes(b"\x00\x00\x00\x18ftypmp42moovmdatparticipant-pixels-only")

    monkeypatch.setattr(module, "verify_offline_replay", lambda *_args, **_kwargs: _replay(spec))
    monkeypatch.setattr(module, "verify_offline_replay_with_godot", verify_with_godot)
    monkeypatch.setattr(module, "_render_participant_mp4", render_participant_mp4)

    saved = await archive.save(spec, _bundles())

    assert saved.task_id == task_id
    assert saved.label == label
    assert archive.list() == (saved,)


def test_corrupt_archive_never_becomes_browser_visible(tmp_path) -> None:
    archive = SavedReplayArchive(
        runs_dir=tmp_path,
        protocol_package=EmbodimentProtocolPackage.from_repository(ROOT),
        godot_executable=Path("/bin/true"),
        godot_project_path=ROOT / "godot",
        ffmpeg_executable=Path("/bin/true"),
    )
    directory = tmp_path / "embodiment-replays" / "ep_corrupt"
    directory.mkdir(parents=True)
    (directory / "manifest.json").write_text("{}", encoding="utf-8")

    assert archive.get("ep_corrupt") is None
    assert archive.list() == ()
    assert archive.video_path("ep_corrupt") is None


class _ArchiveDouble:
    def __init__(self, directory: Path, saved: SavedReplay) -> None:
        self.directory = directory
        self.saved = saved

    def list(self, *, limit: int = 50):
        del limit
        return (self.saved,)

    def get(self, replay_id: str):
        return self.saved if replay_id == self.saved.replay_id else None

    def video_path(self, replay_id: str):
        return self.directory / "participant-replay.mp4" if self.get(replay_id) else None

    def public_bundle_path(self, replay_id: str):
        return self.directory / "public.bundle.json" if self.get(replay_id) else None


def test_saved_replay_routes_expose_safe_manifest_and_video_only(tmp_path) -> None:
    directory = tmp_path / "archive"
    directory.mkdir()
    video = b"participant-pixels-only"
    (directory / "participant-replay.mp4").write_bytes(video)
    public = EpisodeArtifactBundle.create(
        PUBLIC_LAYER, (EpisodeArtifact.json("evaluation", {"score": 1}),)
    )
    (directory / "public.bundle.json").write_bytes(public.bundle_bytes)
    saved = SavedReplay(
        replay_id="ep_saved_route",
        episode_id="ep_saved_route",
        task_id="construction-v0",
        label="Construction v0 scripted demo",
        outcome="success",
        reason="barricade_built",
        authority_ticks=12,
        duration_milliseconds=1200,
        authority_replay_sha256="a" * 64,
        public_bundle_sha256=hashlib.sha256(public.bundle_bytes).hexdigest(),
        video_sha256=hashlib.sha256(video).hexdigest(),
        video_width=1280,
        video_height=720,
        video_fps=30,
    )
    app = FastAPI()
    app.state.embodiment_episodes = EpisodeService(
        _never_called_executor, replay_archive=_ArchiveDouble(directory, saved)
    )
    app.include_router(router)

    with TestClient(app) as client:
        listed = client.get("/api/embodiment/replays")
        manifest = client.get("/api/embodiment/replays/ep_saved_route")
        rendered = client.get("/api/embodiment/replays/ep_saved_route/video")
        probed = client.head("/api/embodiment/replays/ep_saved_route/video")
        public_bundle = client.get("/api/embodiment/replays/ep_saved_route/bundle")
        forbidden = client.get("/api/embodiment/replays/ep_saved_route/authority")

    assert (
        listed.status_code
        == manifest.status_code
        == rendered.status_code
        == public_bundle.status_code
        == 200
    )
    assert listed.headers["cache-control"] == manifest.headers["cache-control"] == "no-store"
    assert rendered.headers["content-type"] == "video/mp4"
    assert rendered.content == video
    assert rendered.headers["content-security-policy"] == "default-src 'none'; sandbox"
    assert probed.status_code == 200
    assert probed.headers["content-type"] == "video/mp4"
    assert probed.headers["accept-ranges"] == "bytes"
    assert probed.content == b""
    assert public_bundle.content == public.bundle_bytes
    assert "authority_replay" not in manifest.text
    responses = f"{listed.text}{manifest.text}{rendered.text}{public_bundle.text}"
    assert "raw-model-output" not in responses
    assert forbidden.status_code == 404


async def _never_called_executor(*_args, **_kwargs):
    raise AssertionError("saved replay routes do not start an episode")
