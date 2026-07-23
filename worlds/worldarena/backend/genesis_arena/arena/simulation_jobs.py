"""Bounded local jobs for Godot-authoritative headless replay generation."""

from __future__ import annotations

# ruff: noqa: UP045 -- Python 3.9-compatible annotations are intentional.
import asyncio
import hashlib
import json
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Awaitable, Callable, Dict, List, Literal, Optional, Union

from pydantic import BaseModel, ConfigDict, Field, JsonValue, field_validator, model_validator

from ..config import Settings

RUNNER_SCRIPT = "res://scripts/arena/simulation/arena_batch_runner.gd"
REPLAY_PROTOCOL = "world-arena-replay/1"
MAX_CAPTURE_BYTES = 32_768
MAX_INDEX_BUNDLE_BYTES = 4 * 1024 * 1024
RUN_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _safe_error(value: str) -> str:
    text = " ".join(value.replace("\x00", " ").split())
    return text[:500] or "headless Godot runner failed without diagnostic output"


def _under(root: Path, candidate: Path) -> Path:
    resolved_root = root.resolve()
    resolved_candidate = candidate.resolve()
    if resolved_candidate != resolved_root and resolved_root not in resolved_candidate.parents:
        raise ValueError("simulation artifact path escapes runs/simulations")
    return resolved_candidate


class SimulationRequest(BaseModel):
    """The intentionally small public surface passed to the fixed local runner."""

    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)

    seed: str = "1"
    numeric_seed: int = Field(default=1, ge=0, le=2_147_483_647)
    max_rounds: int = Field(default=24, ge=1, le=200)
    policy: Literal["deterministic_demo"] = "deterministic_demo"

    @field_validator("seed", mode="before")
    @classmethod
    def parse_seed(cls, value: object) -> str:
        if isinstance(value, bool):
            raise ValueError("seed must be an integer or a safe seed label")
        if isinstance(value, int):
            if not 0 <= value <= 2_147_483_647:
                raise ValueError("seed must be between 0 and 2147483647")
            return str(value)
        if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", value):
            raise ValueError("seed must be an integer or a safe seed label")
        if value.isdecimal() and int(value) > 2_147_483_647:
            raise ValueError("seed must be between 0 and 2147483647")
        return value

    @model_validator(mode="after")
    def derive_numeric_seed(self) -> SimulationRequest:
        if self.seed.isdecimal():
            self.numeric_seed = int(self.seed)
        else:
            self.numeric_seed = (
                int.from_bytes(hashlib.sha256(self.seed.encode("utf-8")).digest()[:4], "big")
                & 0x7FFFFFFF
            )
        return self


class SimulationJob(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)

    job_id: str = Field(pattern=r"^[a-z0-9][a-z0-9_-]{0,63}$")
    request: SimulationRequest
    state: Literal["queued", "running", "completed", "failed"]
    created_at: datetime
    started_at: Optional[datetime] = None
    completed_at: Optional[datetime] = None
    runtime_seconds: Optional[float] = Field(default=None, ge=0)
    replay_id: Optional[str] = None
    artifact_path: Optional[str] = None
    error: Optional[str] = None


class ReplaySummary(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)

    replay_id: str = Field(pattern=r"^[a-z0-9][a-z0-9_-]{0,63}$")
    protocol: Literal["world-arena-replay/1"]
    run_id: str
    created_at: datetime
    source: str = Field(min_length=1, max_length=120)
    seed: Union[int, str]
    numeric_seed: Optional[int] = Field(default=None, ge=0, le=2_147_483_647)
    policy: str = "deterministic_demo"
    max_rounds: int = Field(ge=1, le=200)
    completed_rounds: int = Field(ge=0, le=200)
    simulated_seconds: float = Field(ge=0)
    runtime_seconds: float = Field(ge=0)
    duration_seconds: Optional[float] = Field(default=None, ge=0)
    frame_count: int = Field(ge=0)
    result: Dict[str, JsonValue] = Field(default_factory=dict)

    @field_validator("seed", mode="before")
    @classmethod
    def validate_seed_metadata(cls, value: object) -> Union[int, str]:
        if isinstance(value, bool):
            raise ValueError("replay seed must be an integer or a safe seed label")
        if isinstance(value, int):
            if not 0 <= value <= 2_147_483_647:
                raise ValueError("replay numeric seed is out of bounds")
            return value
        if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", value):
            raise ValueError("replay seed must be an integer or a safe seed label")
        if value.isdecimal() and int(value) > 2_147_483_647:
            raise ValueError("replay numeric seed is out of bounds")
        return value

    @field_validator("policy")
    @classmethod
    def validate_policy_metadata(cls, value: str) -> str:
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", value):
            raise ValueError("replay policy must be a safe identifier")
        return value


class ReplayBundle(ReplaySummary):
    initial_snapshot: Dict[str, JsonValue]
    frames: List[Dict[str, JsonValue]]


class LaunchResult(BaseModel):
    model_config = ConfigDict(extra="forbid")

    returncode: int
    stdout: str = ""
    stderr: str = ""


Launcher = Callable[[List[str], Path], Awaitable[LaunchResult]]


async def _read_capped(stream: asyncio.StreamReader) -> str:
    retained = bytearray()
    while chunk := await stream.read(4096):
        if len(retained) < MAX_CAPTURE_BYTES:
            retained.extend(chunk[: MAX_CAPTURE_BYTES - len(retained)])
    return retained.decode("utf-8", errors="replace")


async def default_launcher(argv: List[str], cwd: Path) -> LaunchResult:
    """Run only a fixed executable argv; no shell or request-controlled paths."""

    process = await asyncio.create_subprocess_exec(
        *argv,
        cwd=str(cwd),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    assert process.stdout is not None and process.stderr is not None
    stdout_task = asyncio.create_task(_read_capped(process.stdout))
    stderr_task = asyncio.create_task(_read_capped(process.stderr))
    returncode = await process.wait()
    stdout, stderr = await asyncio.gather(stdout_task, stderr_task)
    return LaunchResult(returncode=returncode, stdout=stdout, stderr=stderr)


def _validate_identifier(value: str) -> str:
    if not RUN_ID_PATTERN.fullmatch(value):
        raise ValueError("unknown simulation or replay id")
    return value


def _bundle_path(simulations_dir: Path, replay_id: str) -> Path:
    return _under(
        simulations_dir, simulations_dir / _validate_identifier(replay_id) / "bundle.json"
    )


def _summary_path(simulations_dir: Path, replay_id: str) -> Path:
    return _under(
        simulations_dir, simulations_dir / _validate_identifier(replay_id) / "summary.json"
    )


def _write_summary(path: Path, summary: ReplaySummary) -> None:
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        temporary.write_text(
            json.dumps(summary.model_dump(mode="json"), sort_keys=True, separators=(",", ":")),
            encoding="utf-8",
        )
        temporary.replace(path)
    finally:
        if temporary.exists():
            temporary.unlink()


def _read_summary(path: Path) -> ReplaySummary:
    try:
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
        if not isinstance(payload, dict):
            raise ValueError("replay summary must be an object")
        # Older CLI sidecars did not record the directory-derived replay id.
        payload["replay_id"] = path.parent.name
        return ReplaySummary.model_validate(payload)
    except Exception as exc:
        raise ValueError("invalid replay summary") from exc


def _read_bundle(
    path: Path, *, full: bool, for_index: bool = False
) -> Union[ReplaySummary, ReplayBundle]:
    # Bundles are local artifacts created by the fixed runner.  The list scanner uses
    # only the summary model and declines oversized artifacts rather than materializing
    # an unbounded frame list during a list request.  Full replay retrieval is explicit.
    try:
        if for_index and path.stat().st_size > MAX_INDEX_BUNDLE_BYTES:
            raise ValueError("replay bundle is too large to index")
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError("invalid replay bundle") from exc
    if not isinstance(payload, dict) or payload.get("protocol") != REPLAY_PROTOCOL:
        raise ValueError("invalid replay bundle protocol")
    frames = payload.get("frames")
    if not isinstance(frames, list):
        raise ValueError("invalid replay bundle frames")
    if not isinstance(payload.get("initial_snapshot"), dict) or not isinstance(
        payload.get("result"), dict
    ):
        raise ValueError("invalid replay bundle state")
    required_frame_keys = {"index", "round", "at_seconds", "snapshot", "events"}
    if any(
        not isinstance(frame, dict)
        or not required_frame_keys.issubset(frame)
        or not isinstance(frame["snapshot"], dict)
        or not isinstance(frame["events"], list)
        for frame in frames
    ):
        raise ValueError("invalid replay bundle frame")
    summary_payload = {
        key: value for key, value in payload.items() if key not in {"frames", "initial_snapshot"}
    }
    summary_payload["replay_id"] = path.parent.name
    summary_payload["frame_count"] = len(frames)
    try:
        summary = ReplaySummary.model_validate(summary_payload)
    except Exception as exc:
        raise ValueError("invalid replay bundle metadata") from exc
    if not full:
        return summary
    try:
        return ReplayBundle.model_validate(
            {
                **summary.model_dump(mode="json"),
                "initial_snapshot": payload.get("initial_snapshot"),
                "frames": frames,
            }
        )
    except Exception as exc:
        raise ValueError("invalid replay bundle content") from exc


class SimulationJobManager:
    def __init__(self, settings: Settings, *, launcher: Launcher = default_launcher):
        self.settings = settings
        self.launcher = launcher
        self._jobs: Dict[str, SimulationJob] = {}
        self._tasks: Dict[str, asyncio.Task[None]] = {}
        self._semaphore = asyncio.Semaphore(1)

    @property
    def simulations_dir(self) -> Path:
        return _under(self.settings.runs_dir, self.settings.runs_dir / "simulations")

    def create(self, request: SimulationRequest) -> SimulationJob:
        job_id = f"sim-{uuid.uuid4().hex[:20]}"
        job = SimulationJob(job_id=job_id, request=request, state="queued", created_at=_utc_now())
        self._jobs[job_id] = job
        self._tasks[job_id] = asyncio.create_task(self._run(job_id))
        return job.model_copy(deep=True)

    def get(self, job_id: str) -> Optional[SimulationJob]:
        _validate_identifier(job_id)
        job = self._jobs.get(job_id)
        return job.model_copy(deep=True) if job is not None else None

    def list_jobs(self, limit: int) -> List[SimulationJob]:
        return [item.model_copy(deep=True) for item in list(self._jobs.values())[-limit:][::-1]]

    async def _run(self, job_id: str) -> None:
        """Keep excess local submissions queued instead of spawning unlimited Godots."""

        async with self._semaphore:
            await self._run_locked(job_id)

    async def _run_locked(self, job_id: str) -> None:
        job = self._jobs[job_id]
        started = _utc_now()
        self._jobs[job_id] = job.model_copy(update={"state": "running", "started_at": started})
        simulation_root = self.simulations_dir
        run_dir = _under(simulation_root, simulation_root / job_id)
        try:
            simulation_root.mkdir(parents=True, exist_ok=True)
            run_dir.mkdir(parents=False, exist_ok=False)
            executable = self.settings.godot_executable.expanduser().resolve()
            project = self.settings.godot_project_path.expanduser().resolve()
            runner = project / "scripts/arena/simulation/arena_batch_runner.gd"
            if not executable.is_file():
                raise RuntimeError("configured Godot executable was not found")
            if not project.is_dir() or not runner.is_file():
                raise RuntimeError("configured Godot project or batch runner was not found")
            bundle = _bundle_path(simulation_root, job_id)
            argv = [
                str(executable),
                "--headless",
                "--path",
                str(project),
                "--script",
                RUNNER_SCRIPT,
                "--",
                "--output",
                str(bundle),
                "--run-id",
                job_id,
                "--seed",
                str(job.request.numeric_seed),
                "--seed-label",
                job.request.seed,
                "--max-rounds",
                str(job.request.max_rounds),
                "--policy",
                job.request.policy,
            ]
            launched = await self.launcher(argv, project)
            if launched.returncode != 0:
                raise RuntimeError(_safe_error(launched.stderr or launched.stdout))
            summary = _read_bundle(bundle, full=False)
            assert isinstance(summary, ReplaySummary)
            _write_summary(_summary_path(simulation_root, job_id), summary)
            finished = _utc_now()
            self._jobs[job_id] = self._jobs[job_id].model_copy(
                update={
                    "state": "completed",
                    "completed_at": finished,
                    "runtime_seconds": (finished - started).total_seconds(),
                    "replay_id": job_id,
                    "artifact_path": f"simulations/{job_id}/bundle.json",
                }
            )
        except Exception as exc:
            finished = _utc_now()
            self._jobs[job_id] = self._jobs[job_id].model_copy(
                update={
                    "state": "failed",
                    "completed_at": finished,
                    "runtime_seconds": (finished - started).total_seconds(),
                    "error": _safe_error(str(exc)),
                }
            )

    def list_replays(self, limit: int) -> List[ReplaySummary]:
        root = self.simulations_dir
        if not root.is_dir():
            return []
        results: List[ReplaySummary] = []
        run_directories = sorted(
            (
                item
                for item in root.iterdir()
                if item.is_dir() and RUN_ID_PATTERN.fullmatch(item.name)
            ),
            key=lambda item: item.stat().st_mtime,
            reverse=True,
        )
        for run_directory in run_directories:
            try:
                summary_file = _summary_path(root, run_directory.name)
                if summary_file.is_file():
                    summary = _read_summary(summary_file)
                else:
                    bundle = _bundle_path(root, run_directory.name)
                    summary = _read_bundle(bundle, full=False, for_index=True)
                    assert isinstance(summary, ReplaySummary)
                    _write_summary(summary_file, summary)
                results.append(summary)
            except (OSError, ValueError):
                continue
            if len(results) >= limit:
                break
        return results

    def get_replay(
        self, replay_id: str, *, full: bool
    ) -> Optional[Union[ReplaySummary, ReplayBundle]]:
        path = _bundle_path(self.simulations_dir, replay_id)
        if not path.is_file():
            return None
        if not full:
            summary_path = _summary_path(self.simulations_dir, replay_id)
            if summary_path.is_file():
                return _read_summary(summary_path)
        return _read_bundle(path, full=full)
