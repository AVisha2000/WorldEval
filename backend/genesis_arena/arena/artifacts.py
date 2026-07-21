from __future__ import annotations

# ruff: noqa: UP045 -- Pydantic-compatible Python 3.9 annotations are intentional.
import re
from pathlib import Path
from typing import Dict, List, Literal, Optional

from pydantic import Field

from .canonical import canonical_json
from .models import (
    ArenaEvent,
    ArenaModel,
    DecisionDiagnostic,
    FactionId,
    FactionObservation,
    FactionPlan,
    HashHex,
    Identifier,
    ProtocolVersion,
    UsageRecord,
    MAX_CONQUEST_ROUNDS,
)


class ModelSnapshot(ArenaModel):
    faction_id: FactionId
    model: str = Field(min_length=1, max_length=120)
    reasoning_effort: Literal["none", "low", "medium", "high", "xhigh", "max"]
    prompt_hash: HashHex


class RunMetadata(ArenaModel):
    """Non-sensitive presentation metadata permitted in a replay manifest."""

    mode: Literal["benchmark", "demo"] = "benchmark"
    app_version: Optional[Identifier] = None
    build_id: Optional[Identifier] = None
    host_platform: Optional[
        Literal["macos_apple_silicon", "macos_intel", "linux", "windows", "other"]
    ] = None


class RunManifest(ArenaModel):
    schema_version: Literal[1] = 1
    match_id: Identifier
    protocol: ProtocolVersion = "world-arena/0.4"
    map_id: Identifier
    map_hash: HashHex
    rules_id: Identifier
    rules_hash: HashHex
    tool_hash: HashHex
    seed: int = Field(ge=0)
    cognition_track: Literal["standard", "agentic", "open"]
    round_limit: int = Field(default=120, ge=1, le=MAX_CONQUEST_ROUNDS)
    models: List[ModelSnapshot] = Field(min_length=3, max_length=3)
    metadata: RunMetadata = Field(default_factory=RunMetadata)

    def model_post_init(self, __context: object) -> None:
        if {model.faction_id for model in self.models} != {"sol", "terra", "luna"}:
            raise ValueError("manifest requires exactly one model per faction")


class CommittedPlanArtifact(ArenaModel):
    faction_id: FactionId
    observation: FactionObservation
    plan: FactionPlan
    salt: str = Field(pattern=r"^[0-9a-f]{32}$")
    commit_hash: HashHex
    diagnostic: DecisionDiagnostic


class RoundArtifact(ArenaModel):
    schema_version: Literal[1] = 1
    match_id: Identifier
    round: int = Field(ge=1, le=MAX_CONQUEST_ROUNDS)
    previous_state_hash: HashHex
    state_hash: Optional[HashHex] = None
    plans: List[CommittedPlanArtifact] = Field(min_length=3, max_length=3)
    events: List[ArenaEvent] = Field(default_factory=list)


class RunResult(ArenaModel):
    schema_version: Literal[1] = 1
    match_id: Identifier
    placements: Dict[FactionId, int]
    final_state_hash: HashHex
    completed_rounds: int = Field(ge=1, le=MAX_CONQUEST_ROUNDS)
    winner_id: Optional[FactionId] = None
    draw: bool = False
    usage: Dict[FactionId, UsageRecord] = Field(default_factory=dict)
    metrics: Dict[str, object] = Field(default_factory=dict)


class ReplayIndex(ArenaModel):
    schema_version: Literal[1] = 1
    match_id: Identifier
    manifest_file: str = "manifest.json"
    rounds_file: str = "rounds.jsonl"
    events_file: str = "events.jsonl"
    result_file: str = "result.json"
    checkpoint_rounds: List[int] = Field(default_factory=list)


class RunArtifactStore:
    """Small append-only store for replayable, secret-free run artifacts."""

    FORBIDDEN_KEYS = {
        "api_key",
        "apikey",
        "authorization",
        "client_secret",
        "credential",
        "credentials",
        "id_token",
        "openai_api_key",
        "password",
        "refresh_token",
        "secret",
        "x-api-key",
        "x_api_key",
        "access_token",
    }
    SECRET_VALUE_PATTERNS = (
        re.compile(r"(?i)\bbearer\s+[a-z0-9._~+/=-]{10,}"),
        re.compile(r"\bsk-[A-Za-z0-9_-]{10,}"),
        re.compile(r"\b(?:ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{10,}"),
        re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}"),
        re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    )

    def __init__(self, root: Path):
        self.root = root
        # A protocol match ID is not a filesystem run ID: benchmark clients may reuse a
        # deterministic match ID.  This in-memory binding keeps all writes for one live
        # session together while ``create`` allocates an immutable directory on disk.
        self._directories: Dict[str, Path] = {}

    def create(self, manifest: RunManifest) -> Path:
        self.root.mkdir(parents=True, exist_ok=True)
        directory = self._allocate_directory(manifest.match_id)
        self._write_json(directory / "manifest.json", manifest.model_dump(mode="json"))
        self._write_json(
            directory / "replay.json",
            ReplayIndex(match_id=manifest.match_id).model_dump(mode="json"),
        )
        self._directories[manifest.match_id] = directory
        return directory

    def directory_for(self, match_id: str) -> Path:
        """Return this store instance's immutable directory for a protocol match ID."""

        return self._require_run(match_id)

    def append_round(self, artifact: RoundArtifact) -> None:
        directory = self._require_run(artifact.match_id)
        self._append_jsonl(directory / "rounds.jsonl", artifact.model_dump(mode="json"))
        for event in artifact.events:
            self._append_jsonl(directory / "events.jsonl", event.model_dump(mode="json"))

    def write_checkpoint(self, match_id: str, round_number: int, state: Dict[str, object]) -> None:
        if round_number < 0 or round_number > MAX_CONQUEST_ROUNDS:
            raise ValueError("checkpoint round is outside Arena limits")
        self._assert_secret_free(state)
        directory = self._require_run(match_id)
        checkpoint_dir = directory / "checkpoints"
        checkpoint_dir.mkdir(exist_ok=True)
        self._write_json(checkpoint_dir / f"round-{round_number:02d}.json", state)
        replay_path = directory / "replay.json"
        replay = ReplayIndex.model_validate_json(replay_path.read_text(encoding="utf-8"))
        if round_number not in replay.checkpoint_rounds:
            replay.checkpoint_rounds.append(round_number)
            replay.checkpoint_rounds.sort()
            self._write_json(replay_path, replay.model_dump(mode="json"))

    def finish(self, result: RunResult) -> None:
        directory = self._require_run(result.match_id)
        result_path = directory / "result.json"
        if result_path.exists():
            raise FileExistsError(f"run already has an immutable result: {result.match_id}")
        self._write_json(result_path, result.model_dump(mode="json"))

    def _require_run(self, match_id: str) -> Path:
        directory = self._directories.get(match_id, self.root / match_id)
        if not directory.is_dir():
            raise FileNotFoundError(f"run does not exist: {match_id}")
        return directory

    def _allocate_directory(self, match_id: str) -> Path:
        """Atomically reserve a new append-only directory without changing match_id."""

        for suffix in range(10_000):
            name = match_id if suffix == 0 else f"{match_id}-{suffix:03d}"
            candidate = self.root / name
            try:
                candidate.mkdir(exist_ok=False)
                return candidate
            except FileExistsError:
                continue
        raise RuntimeError("unable to allocate an append-only Arena run directory")

    def _write_json(self, path: Path, value: object) -> None:
        self._assert_secret_free(value)
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(canonical_json(value) + "\n", encoding="utf-8")
        temporary.replace(path)

    def _append_jsonl(self, path: Path, value: object) -> None:
        self._assert_secret_free(value)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(canonical_json(value))
            handle.write("\n")

    def _assert_secret_free(self, value: object) -> None:
        if isinstance(value, dict):
            for key, child in value.items():
                normalized_key = str(key).strip().lower()
                if normalized_key in self.FORBIDDEN_KEYS or normalized_key.endswith(
                    ("_api_key", "_password", "_secret")
                ):
                    raise ValueError(f"secret-bearing field cannot be persisted: {key}")
                self._assert_secret_free(child)
        elif isinstance(value, (list, tuple)):
            for child in value:
                self._assert_secret_free(child)
        elif isinstance(value, str):
            if any(pattern.search(value) for pattern in self.SECRET_VALUE_PATTERNS):
                raise ValueError("secret-like value cannot be persisted")
