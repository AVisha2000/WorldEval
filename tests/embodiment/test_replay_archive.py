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
from genesis_arena.embodiment.demo_provider import DemoPolicyLock
from genesis_arena.embodiment.episode_service import (
    EpisodeRunSpec,
    EpisodeService,
    demo_fixture_bytes,
)
from genesis_arena.embodiment.evaluation_projection import (
    build_unavailable_evaluation_projection,
)
from genesis_arena.embodiment.protocol import EmbodimentProtocolPackage
from genesis_arena.embodiment.replay_archive import SavedReplay, SavedReplayArchive
from genesis_arena.embodiment.scripted_construction_demo import (
    SCRIPTED_CONSTRUCTION_PROVIDER,
    SCRIPTED_CONSTRUCTION_TASK,
)
from genesis_arena.embodiment.scripted_solo_demo import scripted_demo_model

ROOT = Path(__file__).resolve().parents[2]


def test_v2_movie_archive_selects_versioned_participant_renderer(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from genesis_arena.embodiment import replay_archive as module

    replay_path = tmp_path / "authority.replay.json"
    replay_path.write_bytes(b"{}")
    output_path = tmp_path / "participant-replay.mp4"
    commands: list[tuple[str, ...]] = []

    def run(command, **_kwargs):
        commands.append(command)
        if "--write-movie" in command:
            movie_path = Path(command[command.index("--write-movie") + 1])
            movie_path.write_bytes(b"A" * 2048)
        elif command[-1] == str(output_path):
            output_path.write_bytes(b"\x00\x00\x00\x18ftypmp42moovmdat" + b"P" * 64)

    monkeypatch.setattr(module, "_run", run)
    module._render_participant_mp4(
        replay_path=replay_path,
        output_path=output_path,
        godot_executable=Path("/usr/bin/true"),
        godot_project_path=ROOT / "godot",
        ffmpeg_executable=Path("/usr/bin/true"),
        protocol_version="llm-controller/0.2.0",
    )

    assert any(
        "res://scripts/embodiment/v2/replay/embodiment_movie_maker_cli_v2.gd"
        in command
        for command in commands
    )
    assert not any(
        "res://scripts/embodiment/replay/embodiment_movie_maker_cli.gd" in command
        for command in commands
    )


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


def _demo_spec(task_id: str = "orientation-v0") -> EpisodeRunSpec:
    model = scripted_demo_model(task_id)
    fixture = demo_fixture_bytes(model=model, task_id=task_id)
    return EpisodeRunSpec(
        episode_id="ep_saved_demo_provider",
        provider="demo",
        model=model,
        task_id=task_id,
        seed=7,
        maximum_episode_ticks=600,
        demo_policy_lock=DemoPolicyLock(
            scenario_id=task_id,
            policy_id=model,
            fixture_sha256=hashlib.sha256(fixture).hexdigest(),
            seed=7,
            participant_id="participant_0",
            model=model,
            total_decision_budget=600,
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


def _showcase_replay(spec: EpisodeRunSpec) -> dict:
    value = _replay(spec)
    participant_id = "participant_0"
    value["config"]["participant_ids"] = [participant_id]
    event_kinds = (
        "resource_gathered",
        "material_deposited",
        "barricade_completed",
        "episode_succeeded",
    )
    end_ticks = (200, 500, 800, 900)
    value["steps"] = []
    for index, (kind, end_tick) in enumerate(zip(event_kinds, end_ticks)):
        effects = []
        control = {"look_x": 0, "look_y": 0, "move_x": 0, "move_y": 0}
        if index == 0:
            effects = [
                {"kind": "heading_steps", "value": 1},
                {"kind": "distance_moved_mt", "value": 1_000},
            ]
            control.update({"look_x": 1_000, "move_y": 1_000})
        value["steps"].append(
            {
                "decision_window": {
                    "decisions": {participant_id: {"action": {"control": control}}}
                },
                "result": {
                    "observations": {participant_id: {"tick": end_tick}},
                    "receipts": {
                        participant_id: {
                            "accepted": True,
                            "applied_ticks": end_tick - (end_ticks[index - 1] if index else 0),
                            "codes": ["applied"],
                            "effects": effects,
                            "end_tick": end_tick,
                        }
                    },
                    "public_events": [{"kind": kind, "tick": end_tick}],
                },
            }
        )
    return value


def test_replay_archive_accepts_demo_provider_without_rewriting_run_identity() -> None:
    from genesis_arena.embodiment import replay_archive as module

    spec = _demo_spec()
    module._validate_scripted_solo_spec(spec)

    assert spec.provider == "demo"
    assert spec.run_class == "demo"
    assert spec.public_dict()["certification_eligible"] is False


def test_multi_action_replay_persists_scenario_label_and_evaluation_identity(tmp_path) -> None:
    from genesis_arena.embodiment import replay_archive as module

    fixture = demo_fixture_bytes(
        model="construction-demo-v1",
        task_id="construction-v0",
        scenario_id="multi-action-demo-v0",
    )
    spec = EpisodeRunSpec(
        episode_id="ep_saved_multi_action",
        provider="demo",
        model="construction-demo-v1",
        task_id="construction-v0",
        scenario_id="multi-action-demo-v0",
        seed=7,
        maximum_episode_ticks=1_300,
        demo_policy_lock=DemoPolicyLock(
            scenario_id="multi-action-demo-v0",
            policy_id="multi-action-construction-demo-v1",
            fixture_sha256=hashlib.sha256(fixture).hexdigest(),
            seed=7,
            participant_id="participant_0",
            model="construction-demo-v1",
            total_decision_budget=1_300,
        ),
    )
    video_path = tmp_path / "participant-replay.mp4"
    video_path.write_bytes(b"participant-pixels-only")
    manifest = module._manifest_for(
        spec,
        _showcase_replay(spec),
        b'{"authority":"sealed"}',
        _bundles().public,
        video_path,
    )
    saved = module._saved_replay_from_manifest(manifest)

    assert manifest["task_id"] == "construction-v0"
    assert manifest["scenario_id"] == "multi-action-demo-v0"
    assert manifest["label"] == "Multi-action solo showcase"
    assert manifest["evaluation_profile_id"] == "solo-multi-action-showcase-v1"
    assert saved.public_dict()["scenario_id"] == "multi-action-demo-v0"
    assert saved.public_dict()["evaluation_profile_id"] == "solo-multi-action-showcase-v1"

    with pytest.raises(module.SavedReplayError, match="showcase evidence"):
        module._manifest_for(
            spec,
            _replay(spec),
            b'{"authority":"sealed"}',
            _bundles().public,
            video_path,
        )


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

    evaluation = build_unavailable_evaluation_projection(
        run_spec={
            "certification_eligible": False,
            "episode_id": spec.episode_id,
            "run_class": spec.run_class,
            "task_id": spec.task_id,
        },
        scope="solo",
        reason="evaluation_unavailable",
    )
    saved = await archive.save(spec, bundles, evaluation=evaluation)

    assert saved.public_dict() == {
        "replay_id": spec.episode_id,
        "episode_id": spec.episode_id,
        "scenario_id": "construction-v0",
        "evaluation_profile_id": "solo-construction-v1",
        "evaluation": {
            "available": True,
            "sha256": hashlib.sha256(evaluation.canonical_bytes).hexdigest(),
        },
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
    restarted = SavedReplayArchive(
        runs_dir=tmp_path,
        protocol_package=package,
        godot_executable=Path("/bin/true"),
        godot_project_path=ROOT / "godot",
        ffmpeg_executable=Path("/bin/true"),
    )
    assert restarted.evaluation(spec.episode_id) == evaluation.as_dict()
    manifest = (directory / "manifest.json").read_bytes()
    assert b'"archive_format":"llm-controller/embodiment-saved-replay/1.2.0"' in manifest
    assert b'"evaluation_sha256"' in manifest
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
