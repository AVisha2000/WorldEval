"""Private local archive for rewatchable scripted solo curriculum replays.

The browser never receives an authority replay, a protected evidence bundle, a prompt, or a
provider output from this module.  It can receive only the already-rendered, participant-filtered
MP4 and this module's small allow-listed manifest.
"""

from __future__ import annotations

import asyncio
import hashlib
import os
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any, Mapping

from .artifacts import (
    PROTECTED_LAYER,
    PUBLIC_LAYER,
    EpisodeArtifactBundle,
    EpisodeBundles,
    verify_offline_replay,
    verify_offline_replay_with_godot,
)
from .protocol import EmbodimentProtocolPackage, canonical_json_bytes, strict_json_loads
from .scripted_solo_demo import SCRIPTED_SOLO_TASKS, is_scripted_solo_demo

if TYPE_CHECKING:
    from .episode_service import EpisodeRunSpec

ARCHIVE_FORMAT = "llm-controller/embodiment-saved-replay/1.0.0"
_ARCHIVE_DIR = "embodiment-replays"
_REPLAY_ID = re.compile(r"^ep_[A-Za-z0-9._-]{1,120}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_MANIFEST_FIELDS = frozenset(
    {
        "archive_format",
        "authority_replay_sha256",
        "authority_ticks",
        "duration_milliseconds",
        "episode_id",
        "label",
        "outcome",
        "public_bundle_sha256",
        "reason",
        "replay_id",
        "task_id",
        "video",
    }
)
_VIDEO_FIELDS = frozenset({"fps", "height", "mime_type", "sha256", "width"})
_SCRIPTED_DEMO_LABELS = {
    "orientation-v0": "Orientation v0 scripted demo",
    "interaction-v0": "Interaction v0 scripted demo",
    "construction-v0": "Construction v0 scripted demo",
    "neutral-encounter-v0": "Neutral Encounter v0 scripted demo",
}


class SavedReplayError(RuntimeError):
    """A replay cannot be safely archived or presented."""


@dataclass(frozen=True)
class SavedReplay:
    """The deliberately small browser-safe saved replay projection."""

    replay_id: str
    episode_id: str
    task_id: str
    label: str
    outcome: str
    reason: str
    authority_ticks: int
    duration_milliseconds: int
    authority_replay_sha256: str
    public_bundle_sha256: str
    video_sha256: str
    video_width: int
    video_height: int
    video_fps: int

    def public_dict(self) -> Mapping[str, Any]:
        return {
            "replay_id": self.replay_id,
            "episode_id": self.episode_id,
            "task_id": self.task_id,
            "label": self.label,
            "outcome": self.outcome,
            "reason": self.reason,
            "authority_ticks": self.authority_ticks,
            "duration_seconds": self.duration_milliseconds / 1000,
            "video": {
                "available": True,
                "mime_type": "video/mp4",
                "sha256": self.video_sha256,
                "width": self.video_width,
                "height": self.video_height,
                "fps": self.video_fps,
            },
        }


class SavedReplayArchive:
    """Render and durably retain one verified scripted solo curriculum replay.

    A replay is first independently replayed by the pinned Godot verifier.  Only then does the
    Movie Maker process reconstruct the participant-filtered presentation.  All files are staged
    privately and moved into the archive only after the MP4 and manifest validate.
    """

    def __init__(
        self,
        *,
        runs_dir: Path,
        protocol_package: EmbodimentProtocolPackage,
        godot_executable: Path,
        godot_project_path: Path,
        ffmpeg_executable: Path,
    ) -> None:
        self._root = Path(runs_dir).resolve() / _ARCHIVE_DIR
        self._package = protocol_package
        self._godot_executable = Path(godot_executable).resolve()
        self._godot_project_path = Path(godot_project_path).resolve()
        self._ffmpeg_executable = Path(ffmpeg_executable).resolve()

    async def save(self, spec: EpisodeRunSpec, bundles: EpisodeBundles) -> SavedReplay:
        """Archive a successful scripted solo episode without exposing its replay."""

        _validate_scripted_solo_spec(spec)
        public = EpisodeArtifactBundle.verify(bundles.public.bundle_bytes)
        protected = EpisodeArtifactBundle.verify(bundles.protected.bundle_bytes)
        if public.layer != PUBLIC_LAYER or protected.layer != PROTECTED_LAYER:
            raise SavedReplayError("replay archive bundle layers differ")
        replay = verify_offline_replay(protected.bundle_bytes, package=self._package)
        _validate_replay_identity(spec, replay)
        terminal = replay["final_terminal"]
        if terminal.get("outcome") != "success":
            raise SavedReplayError("only successful scripted solo runs are archived")

        # Verification happens before filesystem writes.  It uses the protected bundle only in
        # trusted backend memory and never reaches a router or dashboard state.
        try:
            await verify_offline_replay_with_godot(
                protected.bundle_bytes,
                package=self._package,
                godot_executable=self._godot_executable,
                project_path=self._godot_project_path,
            )
        except Exception as error:
            raise SavedReplayError("Godot replay verification failed") from error

        return await asyncio.to_thread(
            self._render_and_persist,
            spec,
            public,
            protected.read("authority_replay"),
            replay,
        )

    def list(self, *, limit: int = 50) -> tuple[SavedReplay, ...]:
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
            raise ValueError("limit is invalid")
        if not self._root.is_dir():
            return ()
        values: list[SavedReplay] = []
        for child in self._root.iterdir():
            if not child.is_dir() or _REPLAY_ID.fullmatch(child.name) is None:
                continue
            try:
                values.append(self._load(child.name))
            except (OSError, SavedReplayError):
                # A partial/corrupt local directory must not become a browser-visible record.
                continue
        return tuple(sorted(values, key=lambda item: item.replay_id, reverse=True)[:limit])

    def get(self, replay_id: str) -> SavedReplay | None:
        if _REPLAY_ID.fullmatch(replay_id) is None:
            return None
        try:
            return self._load(replay_id)
        except (OSError, SavedReplayError):
            return None

    def video_path(self, replay_id: str) -> Path | None:
        replay = self.get(replay_id)
        if replay is None:
            return None
        target = self._directory_for(replay_id) / "participant-replay.mp4"
        try:
            if (
                not target.is_file()
                or hashlib.sha256(target.read_bytes()).hexdigest() != replay.video_sha256
            ):
                return None
        except OSError:
            return None
        return target

    def public_bundle_path(self, replay_id: str) -> Path | None:
        replay = self.get(replay_id)
        if replay is None:
            return None
        target = self._directory_for(replay_id) / "public.bundle.json"
        try:
            if (
                not target.is_file()
                or hashlib.sha256(target.read_bytes()).hexdigest() != replay.public_bundle_sha256
            ):
                return None
        except OSError:
            return None
        return target

    def _render_and_persist(
        self,
        spec: EpisodeRunSpec,
        public_bundle: EpisodeArtifactBundle,
        authority_replay: bytes,
        replay: Mapping[str, Any],
    ) -> SavedReplay:
        self._root.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            os.chmod(self._root, 0o700)
        except OSError:
            pass
        existing = self.get(spec.episode_id)
        if existing is not None:
            return existing
        target = self._directory_for(spec.episode_id)
        if target.exists():
            raise SavedReplayError("replay archive target already exists")
        stage = Path(tempfile.mkdtemp(prefix=f".{spec.episode_id}.", dir=self._root))
        try:
            authority_path = stage / "authority.replay.json"
            public_path = stage / "public.bundle.json"
            video_path = stage / "participant-replay.mp4"
            _write_private(authority_path, authority_replay)
            _write_private(public_path, public_bundle.bundle_bytes)
            _render_participant_mp4(
                replay_path=authority_path,
                output_path=video_path,
                godot_executable=self._godot_executable,
                godot_project_path=self._godot_project_path,
                ffmpeg_executable=self._ffmpeg_executable,
            )
            manifest = _manifest_for(spec, replay, authority_replay, public_bundle, video_path)
            _write_private(stage / "manifest.json", canonical_json_bytes(manifest))
            loaded = _saved_replay_from_manifest(manifest)
            _validate_persisted_stage(stage, loaded)
            try:
                os.replace(stage, target)
            except OSError as error:
                raise SavedReplayError("replay archive could not be finalized") from error
            return loaded
        except SavedReplayError:
            raise
        except (OSError, subprocess.SubprocessError) as error:
            raise SavedReplayError("replay archive rendering failed") from error
        finally:
            if stage.exists():
                shutil.rmtree(stage, ignore_errors=True)

    def _load(self, replay_id: str) -> SavedReplay:
        directory = self._directory_for(replay_id)
        payload = (directory / "manifest.json").read_bytes()
        try:
            value = strict_json_loads(payload)
        except Exception as error:
            raise SavedReplayError("replay archive manifest is invalid") from error
        if not isinstance(value, dict) or canonical_json_bytes(value) != payload:
            raise SavedReplayError("replay archive manifest is not canonical")
        loaded = _saved_replay_from_manifest(value)
        if loaded.replay_id != replay_id:
            raise SavedReplayError("replay archive manifest identity differs")
        _validate_persisted_stage(directory, loaded)
        return loaded

    def _directory_for(self, replay_id: str) -> Path:
        if _REPLAY_ID.fullmatch(replay_id) is None:
            raise SavedReplayError("replay archive identity is invalid")
        target = self._root / replay_id
        if target.parent != self._root:
            raise SavedReplayError("replay archive path is invalid")
        return target


def _validate_scripted_solo_spec(spec: EpisodeRunSpec) -> None:
    if not is_scripted_solo_demo(
        provider=spec.provider, model=spec.model, task_id=spec.task_id
    ) or _REPLAY_ID.fullmatch(spec.episode_id) is None:
        raise SavedReplayError("replay archive is reserved for scripted solo demos")


def _label_for_task(task_id: str) -> str:
    try:
        return _SCRIPTED_DEMO_LABELS[task_id]
    except KeyError as error:
        raise SavedReplayError("replay archive task is unsupported") from error


def _validate_replay_identity(spec: EpisodeRunSpec, replay: Mapping[str, Any]) -> None:
    config = replay.get("config")
    if not isinstance(config, Mapping) or (
        config.get("episode_id") != spec.episode_id
        or config.get("mode") != "solo-curriculum-v0"
        or config.get("task_id") != spec.task_id
        or config.get("observation_profile") != "hybrid-visible-v1"
    ):
        raise SavedReplayError("replay archive identity differs")


def _render_participant_mp4(
    *,
    replay_path: Path,
    output_path: Path,
    godot_executable: Path,
    godot_project_path: Path,
    ffmpeg_executable: Path,
) -> None:
    _require_executable(godot_executable, "pinned Godot executable")
    _require_executable(ffmpeg_executable, "local FFmpeg executable")
    if "remotion" in str(ffmpeg_executable).lower():
        raise SavedReplayError("replay archive encoder is invalid")
    if not godot_project_path.is_dir() or not (godot_project_path / "project.godot").is_file():
        raise SavedReplayError("Godot project is unavailable")
    movie_path = output_path.with_suffix(".avi")
    _run(
        (
            str(godot_executable),
            "--no-header",
            "--audio-driver",
            "Dummy",
            "--path",
            str(godot_project_path),
            "--rendering-method",
            "gl_compatibility",
            "--resolution",
            "1280x720",
            "--fixed-fps",
            "30",
            "--disable-vsync",
            "--write-movie",
            str(movie_path),
            "--script",
            "res://scripts/embodiment/replay/embodiment_movie_maker_cli.gd",
            "--",
            f"--embodiment-replay={replay_path}",
        ),
        cwd=godot_project_path,
        description="Godot Movie Maker render failed",
        timeout_s=300,
    )
    if not movie_path.is_file() or movie_path.stat().st_size < 1024:
        raise SavedReplayError("Godot Movie Maker produced no participant video")
    _run(
        (
            str(ffmpeg_executable),
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(movie_path),
            "-f",
            "lavfi",
            "-i",
            "anullsrc=channel_layout=stereo:sample_rate=48000",
            "-shortest",
            "-map_metadata",
            "-1",
            "-vf",
            "scale=1280:720:force_original_aspect_ratio=decrease:"
            "in_range=full:out_range=tv,pad=1280:720:(ow-iw)/2:(oh-ih)/2:black,format=yuv420p",
            "-r",
            "30",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-color_range",
            "tv",
            "-c:a",
            "aac",
            "-b:a",
            "128k",
            "-movflags",
            "+faststart",
            str(output_path),
        ),
        cwd=godot_project_path,
        description="FFmpeg encoding failed",
        timeout_s=180,
    )
    _verify_mp4(output_path, ffmpeg_executable)
    try:
        movie_path.unlink()
    except OSError:
        # The already verified MP4 is the durable browser artifact.  A failure to remove the
        # private Movie Maker intermediate must not invalidate it or expose it through a route.
        pass


def _manifest_for(
    spec: EpisodeRunSpec,
    replay: Mapping[str, Any],
    authority_replay: bytes,
    public_bundle: EpisodeArtifactBundle,
    video_path: Path,
) -> Mapping[str, Any]:
    terminal = replay["final_terminal"]
    steps = replay["steps"]
    final_observation = steps[-1]["result"]["observations"]["participant_0"]
    authority_ticks = final_observation["tick"]
    if (
        isinstance(authority_ticks, bool)
        or not isinstance(authority_ticks, int)
        or authority_ticks < 1
    ):
        raise SavedReplayError("replay archive tick count is invalid")
    video = video_path.read_bytes()
    return {
        "archive_format": ARCHIVE_FORMAT,
        "authority_replay_sha256": hashlib.sha256(authority_replay).hexdigest(),
        "authority_ticks": authority_ticks,
        "duration_milliseconds": authority_ticks * 100,
        "episode_id": spec.episode_id,
        "label": _label_for_task(spec.task_id),
        "outcome": terminal["outcome"],
        "public_bundle_sha256": hashlib.sha256(public_bundle.bundle_bytes).hexdigest(),
        "reason": terminal["reason"],
        "replay_id": spec.episode_id,
        "task_id": spec.task_id,
        "video": {
            "fps": 30,
            "height": 720,
            "mime_type": "video/mp4",
            "sha256": hashlib.sha256(video).hexdigest(),
            "width": 1280,
        },
    }


def _saved_replay_from_manifest(value: Mapping[str, Any]) -> SavedReplay:
    if set(value) != _MANIFEST_FIELDS or value.get("archive_format") != ARCHIVE_FORMAT:
        raise SavedReplayError("replay archive manifest fields differ")
    video = value.get("video")
    if not isinstance(video, Mapping) or set(video) != _VIDEO_FIELDS:
        raise SavedReplayError("replay archive video descriptor differs")
    for name in (
        "replay_id",
        "episode_id",
        "task_id",
        "label",
        "outcome",
        "reason",
        "authority_replay_sha256",
        "public_bundle_sha256",
    ):
        if not isinstance(value.get(name), str) or not value[name]:
            raise SavedReplayError("replay archive manifest value is invalid")
    if (
        _REPLAY_ID.fullmatch(str(value["replay_id"])) is None
        or value["replay_id"] != value["episode_id"]
        or value["task_id"] not in SCRIPTED_SOLO_TASKS
        or value["label"] != _label_for_task(value["task_id"])
        or value["outcome"] != "success"
        or _SHA256.fullmatch(str(value["authority_replay_sha256"])) is None
        or _SHA256.fullmatch(str(value["public_bundle_sha256"])) is None
        or _SHA256.fullmatch(str(video.get("sha256"))) is None
        or video.get("mime_type") != "video/mp4"
        or video.get("width") != 1280
        or video.get("height") != 720
        or video.get("fps") != 30
    ):
        raise SavedReplayError("replay archive manifest semantics differ")
    ticks = value.get("authority_ticks")
    duration = value.get("duration_milliseconds")
    if (
        isinstance(ticks, bool)
        or not isinstance(ticks, int)
        or ticks < 1
        or isinstance(duration, bool)
        or not isinstance(duration, int)
        or duration != ticks * 100
    ):
        raise SavedReplayError("replay archive timing is invalid")
    return SavedReplay(
        replay_id=value["replay_id"],
        episode_id=value["episode_id"],
        task_id=value["task_id"],
        label=value["label"],
        outcome=value["outcome"],
        reason=value["reason"],
        authority_ticks=ticks,
        duration_milliseconds=duration,
        authority_replay_sha256=value["authority_replay_sha256"],
        public_bundle_sha256=value["public_bundle_sha256"],
        video_sha256=video["sha256"],
        video_width=video["width"],
        video_height=video["height"],
        video_fps=video["fps"],
    )


def _validate_persisted_stage(directory: Path, replay: SavedReplay) -> None:
    authority = directory / "authority.replay.json"
    public = directory / "public.bundle.json"
    video = directory / "participant-replay.mp4"
    if (
        not authority.is_file()
        or not public.is_file()
        or not video.is_file()
        or hashlib.sha256(authority.read_bytes()).hexdigest() != replay.authority_replay_sha256
        or hashlib.sha256(public.read_bytes()).hexdigest() != replay.public_bundle_sha256
        or hashlib.sha256(video.read_bytes()).hexdigest() != replay.video_sha256
    ):
        raise SavedReplayError("replay archive files differ from manifest")
    # Re-check the public evidence before its optional download route is ever enabled.
    bundle = EpisodeArtifactBundle.verify(public.read_bytes())
    if bundle.layer != PUBLIC_LAYER:
        raise SavedReplayError("replay archive public bundle differs")


def _write_private(path: Path, payload: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
    except BaseException:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass
        raise
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def _require_executable(path: Path, label: str) -> None:
    if not path.is_file() or not os.access(path, os.X_OK):
        raise SavedReplayError(f"{label} is unavailable")


def _run(
    command: tuple[str, ...], *, cwd: Path, description: str, timeout_s: float
) -> None:
    try:
        completed = subprocess.run(
            command,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
            timeout=timeout_s,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SavedReplayError(description) from error
    if completed.returncode != 0:
        raise SavedReplayError(description)


def _verify_mp4(output: Path, ffmpeg: Path) -> None:
    try:
        payload = output.read_bytes()
    except OSError as error:
        raise SavedReplayError("participant replay video is missing") from error
    if (
        len(payload) < 32
        or b"ftyp" not in payload[:32]
        or payload.find(b"moov") > payload.find(b"mdat")
    ):
        raise SavedReplayError("participant replay video is not a fast-start MP4")
    _run(
        (str(ffmpeg), "-hide_banner", "-i", str(output), "-f", "null", "-"),
        cwd=output.parent,
        description="participant replay video verification failed",
        timeout_s=60,
    )


__all__ = ["ARCHIVE_FORMAT", "SavedReplay", "SavedReplayArchive", "SavedReplayError"]
