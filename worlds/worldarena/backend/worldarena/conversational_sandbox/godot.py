"""Small, provider-free bridge to the conversational warehouse authority."""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Mapping, Sequence

from worldeval.contracts import canonical_json_bytes, strict_json_loads
from worldeval.replay import NativeVerificationResult

RUNNER_SCRIPT = "res://scripts/conversational_sandbox/conversational_warehouse_session_runner.gd"
REPLAY_VERIFIER_SCRIPT = (
    "res://scripts/conversational_sandbox/conversational_warehouse_replay_verifier_cli.gd"
)
NATIVE_SCHEMA = "conversational-warehouse-replay.v1"
NATIVE_VERIFIER = "conversational-warehouse-godot-reexecution-v1"
_SUCCESS = re.compile(
    r"CONVERSATIONAL_WAREHOUSE_SESSION_OK scenario=(?P<scenario>\S+)"
    r".*state_hash=(?P<hash>sha256:[0-9a-f]{64})"
)
_VERIFY = re.compile(
    r"CONVERSATIONAL_WAREHOUSE_REPLAY_VERIFIED run_id=(?P<run>\S+) "
    r"state_hash=(?P<hash>sha256:[0-9a-f]{64})"
)
_SENSITIVE = re.compile(r"(?:api.?key|authorization|credential|secret|token|proxy)", re.I)


class ConversationGodotError(RuntimeError):
    pass


class GodotConversationWarehouseRunner:
    def __init__(
        self,
        *,
        executable: Path,
        project_path: Path,
        scenario_path: Path,
        timeout_seconds: float = 30.0,
    ) -> None:
        self.executable = Path(executable).resolve()
        self.project_path = Path(project_path).resolve()
        self.scenario_path = Path(scenario_path).resolve()
        self.timeout_seconds = timeout_seconds

    def advance(
        self, *, history: Sequence[Mapping[str, Any]], initialization_hash: str, run_id: str
    ) -> Mapping[str, Any]:
        self._check()
        with tempfile.TemporaryDirectory(prefix="worldeval-conversation-") as directory:
            root = Path(directory)
            history_path, output_path = root / "history.json", root / "snapshot.json"
            history_path.write_bytes(canonical_json_bytes(list(history)))
            command = [
                str(self.executable),
                "--no-header",
                "--headless",
                "--audio-driver",
                "Dummy",
                "--path",
                str(self.project_path),
                "--script",
                RUNNER_SCRIPT,
                "--",
                f"--scenario={self.scenario_path}",
                f"--history={history_path}",
                f"--initialization-hash={initialization_hash}",
                f"--run-id={run_id}",
                f"--output={output_path}",
            ]
            completed = self._run(command)
            match = _SUCCESS.search(completed.stdout)
            if completed.returncode != 0 or match is None or not output_path.is_file():
                raise ConversationGodotError((completed.stderr or completed.stdout)[-2000:])
            # Godot's JSON writer can serialize integer grid coordinates as 3.0.
            # Normalize only exact integral values before our canonical boundary.
            snapshot = _integerize(json.loads(output_path.read_text(encoding="utf-8")))
        if not isinstance(snapshot, dict) or not isinstance(snapshot.get("replay"), dict):
            raise ConversationGodotError("Godot session output is malformed")
        replay = snapshot["replay"]
        if match.group("scenario") != replay.get("scenario_id") or match.group(
            "hash"
        ) != replay.get("terminal_state_hash"):
            raise ConversationGodotError("Godot output identity mismatch")
        return snapshot

    def verify_native_replay(self, replay: Mapping[str, Any]) -> NativeVerificationResult:
        # Re-execute the exact typed history through the same headless Godot
        # session runner with networking and provider credentials absent.
        history = replay.get("history")
        if not isinstance(history, list):
            raise ConversationGodotError("native replay lacks typed history")
        rebuilt = self.advance(
            history=history,
            initialization_hash=str(replay.get("initialization_hash", "")),
            run_id=str(replay.get("run_id", "")),
        )["replay"]
        for field in (
            "scenario_id",
            "terminal_outcome",
            "terminal_tick",
            "terminal_state_hash",
            "provider_calls",
        ):
            if rebuilt.get(field) != replay.get(field):
                raise ConversationGodotError(
                    f"native replay {field} differs after Godot re-execution"
                )
        return NativeVerificationResult(
            final_state_hash=str(rebuilt["terminal_state_hash"]), provider_calls=0
        )

    def _run(self, command: list[str]) -> subprocess.CompletedProcess[str]:
        try:
            return subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                timeout=self.timeout_seconds,
                env={
                    key: value
                    for key, value in os.environ.items()
                    if _SENSITIVE.search(key) is None
                }
                | {"WORLDEVAL_OFFLINE": "1", "NO_PROXY": "*"},
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ConversationGodotError("Godot authority did not complete") from error

    def _check(self) -> None:
        if (
            not self.executable.is_file()
            or not (self.project_path / "project.godot").is_file()
            or not self.scenario_path.is_file()
        ):
            raise ConversationGodotError("conversational warehouse installation is unavailable")


def _integerize(value: Any) -> Any:
    if isinstance(value, list):
        return [_integerize(item) for item in value]
    if isinstance(value, dict):
        return {str(key): _integerize(item) for key, item in value.items()}
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, float):
        raise ConversationGodotError("warehouse authority emitted a non-integral number")
    return value


def native_replay_verifier(
    payload: bytes,
    descriptor: Mapping[str, Any],
    *,
    executable: Path,
    project_path: Path,
    game_root: Path | None = None,
    timeout_seconds: float = 30.0,
    require_network_isolation: bool = False,
) -> NativeVerificationResult:
    if (
        descriptor.get("native_schema") != NATIVE_SCHEMA
        or descriptor.get("verifier") != NATIVE_VERIFIER
    ):
        raise ConversationGodotError("unsupported conversational warehouse verifier descriptor")
    replay = strict_json_loads(payload)
    if not isinstance(replay, dict):
        raise ConversationGodotError("native replay must be an object")
    root = (
        Path(game_root)
        if game_root
        else Path(__file__).resolve().parents[3] / "games" / "conversational-warehouse"
    )
    return GodotConversationWarehouseRunner(
        executable=executable,
        project_path=project_path,
        scenario_path=root / "scenario.json",
        timeout_seconds=timeout_seconds,
    ).verify_native_replay(replay)
