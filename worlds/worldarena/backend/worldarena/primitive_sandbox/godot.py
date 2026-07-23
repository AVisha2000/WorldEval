"""Managed, provider-free Godot processes for runs and decision sessions."""

from __future__ import annotations

import hashlib
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence

from worldeval.contracts import AgentProtocolValidator, canonical_json_bytes, strict_json_loads
from worldeval.replay import (
    NativeReplayClaims,
    NativeVerificationResult,
    canonical_sha256,
)

from .configuration import PrimitiveSandboxConfiguration, load_configuration

RUNNER_SCRIPT = "res://scripts/agent_sandbox/primitive_sandbox_headless_runner.gd"
SESSION_RUNNER_SCRIPT = "res://scripts/agent_sandbox/primitive_sandbox_session_runner.gd"
REPLAY_VERIFIER_SCRIPT = (
    "res://scripts/agent_sandbox/primitive_sandbox_replay_verifier_cli.gd"
)
NATIVE_SCHEMA = "replay-bundle.v1"
NATIVE_VERIFIER = "primitive-sandbox-godot-reexecution-v1"
_SUCCESS = re.compile(
    r"PRIMITIVE_SANDBOX_HEADLESS_OK scenario=(?P<scenario>\S+) "
    r"outcome=(?P<outcome>\S+) tick=(?P<tick>\d+) "
    r"final_state_hash=(?P<hash>sha256:[0-9a-f]{64})"
)
_SESSION_SUCCESS = re.compile(
    r"PRIMITIVE_SANDBOX_SESSION_OK scenario=(?P<scenario>\S+) "
    r"boundaries=(?P<boundaries>\d+) terminal=(?P<terminal>true|false) "
    r"tick=(?P<tick>\d+) state_hash=(?P<hash>sha256:[0-9a-f]{64})"
)
_REPLAY_SUCCESS = re.compile(
    r"PRIMITIVE_SANDBOX_REPLAY_VERIFIED scenario=(?P<scenario>\S+) "
    r"provider_calls=(?P<provider_calls>\d+) "
    r"final_state_hash=(?P<hash>sha256:[0-9a-f]{64})"
)
_SENSITIVE_ENV = re.compile(
    r"(?:api.?key|authorization|credential|secret|token|http_proxy|https_proxy|all_proxy)",
    re.IGNORECASE,
)
_ENGINE_COMPONENTS = (
    "scripts/agent_sandbox/primitive_sandbox_authority.gd",
    "scripts/agent_sandbox/primitive_sandbox_demo_policy.gd",
    "scripts/agent_sandbox/primitive_sandbox_headless_runner.gd",
    "scripts/agent_sandbox/primitive_sandbox_replay_verifier.gd",
    "scripts/agent_sandbox/primitive_sandbox_replay_verifier_cli.gd",
    "scripts/agent_sandbox/primitive_sandbox_session_runner.gd",
)


class GodotSandboxError(RuntimeError):
    """The managed Godot authority did not produce a valid terminal replay."""


@dataclass(frozen=True)
class GodotSandboxResult:
    configuration: PrimitiveSandboxConfiguration
    replay: Mapping[str, Any]
    stdout: str
    engine_build_hash: str


@dataclass(frozen=True)
class GodotSandboxSnapshot:
    configuration: PrimitiveSandboxConfiguration
    replay: Mapping[str, Any]
    observation: Mapping[str, Any]
    receipt: Mapping[str, Any] | None
    terminal: bool
    stdout: str
    engine_build_hash: str


class GodotPrimitiveSandboxRunner:
    def __init__(
        self,
        *,
        executable: Path,
        project_path: Path,
        sandbox_root: Path | None = None,
        timeout_seconds: float = 30.0,
        require_network_isolation: bool = False,
    ) -> None:
        self.executable = Path(executable).resolve()
        self.project_path = Path(project_path).resolve()
        self.sandbox_root = Path(sandbox_root).resolve() if sandbox_root else None
        self.timeout_seconds = timeout_seconds
        self.require_network_isolation = require_network_isolation

    def run(self, scenario_id: str, *, run_id: str) -> GodotSandboxResult:
        configuration = load_configuration(scenario_id, sandbox_root=self.sandbox_root)
        self._check_installation()
        with tempfile.TemporaryDirectory(prefix="worldeval-primitive-sandbox-") as temporary:
            output = Path(temporary) / "primary.replay.json"
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
                f"--scenario={configuration.scenario_path}",
                f"--initialization-hash={configuration.initialization.initialization_hash}",
                f"--run-id={run_id}",
                f"--output={output}",
            ]
            try:
                completed = subprocess.run(
                    command,
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=self.timeout_seconds,
                    env=_provider_free_environment(),
                )
            except (OSError, subprocess.TimeoutExpired) as error:
                raise GodotSandboxError("Godot authority process failed to complete") from error
            stdout = completed.stdout
            match = _SUCCESS.search(stdout)
            if completed.returncode != 0 or match is None or not output.is_file():
                detail = (completed.stderr or stdout)[-2000:]
                raise GodotSandboxError(f"Godot authority failed closed: {detail}")
            replay = strict_json_loads(output.read_bytes())

        if not isinstance(replay, dict):
            raise GodotSandboxError("Godot replay root must be an object")
        validator = AgentProtocolValidator()
        validator.validate("replay-bundle.v1.schema.json", replay, model=False)
        if match.group("scenario") != scenario_id:
            raise GodotSandboxError("Godot terminal scenario identity differs")
        if match.group("outcome") != replay.get("terminal_outcome"):
            raise GodotSandboxError("Godot terminal outcome differs from replay")
        if int(match.group("tick")) != replay.get("terminal_tick"):
            raise GodotSandboxError("Godot terminal tick differs from replay")
        if match.group("hash") != replay.get("terminal_state_hash"):
            raise GodotSandboxError("Godot terminal state hash differs from replay")
        verification = self.verify_native_replay(replay)
        if verification.provider_calls != 0:
            raise GodotSandboxError("provider-free replay verification did not pass")
        return GodotSandboxResult(
            configuration=configuration,
            replay=replay,
            stdout=stdout,
            engine_build_hash=self.engine_build_hash(),
        )

    def advance(
        self,
        scenario_id: str,
        *,
        run_id: str,
        history: Sequence[Mapping[str, Any]],
    ) -> GodotSandboxSnapshot:
        """Rebuild a session and apply exactly the supplied normalized boundaries."""

        configuration = load_configuration(scenario_id, sandbox_root=self.sandbox_root)
        self._check_installation()
        normalized_history = [dict(entry) for entry in history]
        with tempfile.TemporaryDirectory(
            prefix="worldeval-primitive-sandbox-session-"
        ) as temporary:
            history_path = Path(temporary) / "history.json"
            output = Path(temporary) / "snapshot.json"
            history_path.write_bytes(canonical_json_bytes(normalized_history))
            command = [
                str(self.executable),
                "--no-header",
                "--headless",
                "--audio-driver",
                "Dummy",
                "--path",
                str(self.project_path),
                "--script",
                SESSION_RUNNER_SCRIPT,
                "--",
                f"--scenario={configuration.scenario_path}",
                f"--initialization-hash={configuration.initialization.initialization_hash}",
                f"--run-id={run_id}",
                f"--history={history_path}",
                f"--output={output}",
            ]
            try:
                completed = subprocess.run(
                    command,
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=self.timeout_seconds,
                    env=_provider_free_environment(),
                )
            except (OSError, subprocess.TimeoutExpired) as error:
                raise GodotSandboxError(
                    "Godot session authority failed to complete"
                ) from error
            stdout = completed.stdout
            match = _SESSION_SUCCESS.search(stdout)
            if completed.returncode != 0 or match is None or not output.is_file():
                detail = (completed.stderr or stdout)[-2000:]
                raise GodotSandboxError(
                    f"Godot session authority failed closed: {detail}"
                )
            snapshot = strict_json_loads(output.read_bytes())

        if not isinstance(snapshot, dict):
            raise GodotSandboxError("Godot session snapshot root must be an object")
        replay = snapshot.get("replay")
        observation = snapshot.get("observation")
        receipt = snapshot.get("receipt")
        terminal = snapshot.get("terminal")
        if not isinstance(replay, dict) or not isinstance(observation, dict):
            raise GodotSandboxError("Godot session snapshot is incomplete")
        if receipt is not None and not isinstance(receipt, dict):
            raise GodotSandboxError("Godot session receipt must be an object or null")
        if not isinstance(terminal, bool):
            raise GodotSandboxError("Godot session terminal flag must be boolean")
        validator = AgentProtocolValidator()
        validator.validate("replay-bundle.v1.schema.json", replay, model=False)
        validator.validate("observation.v1.schema.json", observation)
        if receipt is not None:
            validator.validate("action-receipt.v1.schema.json", receipt)
        expected_boundaries = len(normalized_history)
        if snapshot.get("history_count") != expected_boundaries:
            raise GodotSandboxError("Godot session boundary count differs")
        if len(replay.get("decisions", [])) != expected_boundaries:
            raise GodotSandboxError("Godot replay decision count differs")
        if len(replay.get("receipts", [])) != expected_boundaries:
            raise GodotSandboxError("Godot replay receipt count differs")
        if len(replay.get("observations", [])) != expected_boundaries + 1:
            raise GodotSandboxError("Godot replay observation count differs")
        if observation != replay["observations"][-1]:
            raise GodotSandboxError("Godot current observation differs from replay")
        if receipt != (None if not replay["receipts"] else replay["receipts"][-1]):
            raise GodotSandboxError("Godot current receipt differs from replay")
        if bool(observation["terminal"]) != terminal:
            raise GodotSandboxError("Godot observation terminal flag differs")
        if terminal and replay.get("terminal_outcome") == "incomplete":
            raise GodotSandboxError("terminal Godot session has no terminal outcome")
        if not terminal and replay.get("terminal_outcome") != "incomplete":
            raise GodotSandboxError("non-terminal Godot session declared an outcome")
        if replay.get("offline_verified") is not terminal:
            raise GodotSandboxError("Godot session verification flag is inconsistent")
        if match.group("scenario") != scenario_id:
            raise GodotSandboxError("Godot session scenario identity differs")
        if int(match.group("boundaries")) != expected_boundaries:
            raise GodotSandboxError("Godot session stdout boundary count differs")
        if (match.group("terminal") == "true") != terminal:
            raise GodotSandboxError("Godot session stdout terminal flag differs")
        if int(match.group("tick")) != observation["tick"]:
            raise GodotSandboxError("Godot session stdout tick differs")
        if match.group("hash") != observation["state_hash"]:
            raise GodotSandboxError("Godot session stdout state hash differs")
        if replay.get("provider_calls") != 0:
            raise GodotSandboxError("Godot session replay declared provider calls")
        return GodotSandboxSnapshot(
            configuration=configuration,
            replay=replay,
            observation=observation,
            receipt=receipt,
            terminal=terminal,
            stdout=stdout,
            engine_build_hash=self.engine_build_hash(),
        )

    def verify_native_replay(
        self,
        replay: Mapping[str, Any],
    ) -> NativeVerificationResult:
        """Re-execute a terminal replay in a separate Godot verifier process."""

        return native_replay_verifier(
            canonical_json_bytes(replay),
            {
                "native_schema": NATIVE_SCHEMA,
                "verifier": NATIVE_VERIFIER,
            },
            executable=self.executable,
            project_path=self.project_path,
            sandbox_root=self.sandbox_root,
            timeout_seconds=self.timeout_seconds,
            require_network_isolation=self.require_network_isolation,
        )

    def _check_installation(self) -> None:
        if not self.executable.is_file():
            raise GodotSandboxError("Godot executable is unavailable")
        if not (self.project_path / "project.godot").is_file():
            raise GodotSandboxError("WorldArena Godot project is unavailable")

    def engine_build_hash(self) -> str:
        return _engine_build_hash(self.executable, self.project_path)


def native_replay_verifier(
    payload: bytes,
    descriptor: Mapping[str, Any],
    *,
    executable: Path,
    project_path: Path,
    sandbox_root: Path | None = None,
    timeout_seconds: float = 30.0,
    require_network_isolation: bool = False,
) -> NativeVerificationResult:
    """Validate and re-execute one canonical replay in the Godot authority."""

    value = strict_json_loads(payload)
    if not isinstance(value, dict):
        raise GodotSandboxError("native replay is not an object")
    AgentProtocolValidator().validate("replay-bundle.v1.schema.json", value, model=False)
    if descriptor.get("native_schema") != NATIVE_SCHEMA:
        raise GodotSandboxError("native replay schema is not supported")
    if descriptor.get("verifier") != NATIVE_VERIFIER:
        raise GodotSandboxError("native replay verifier identity differs")
    configuration = load_configuration(
        str(value["scenario_id"]),
        sandbox_root=sandbox_root,
    )
    if (
        value["initialization_hash"]
        != configuration.initialization.initialization_hash
    ):
        raise GodotSandboxError(
            "native replay initialization hash differs from authored inputs"
        )
    selected_executable = Path(executable).resolve()
    selected_project = Path(project_path).resolve()
    if not selected_executable.is_file():
        raise GodotSandboxError("Godot executable is unavailable")
    if not (selected_project / "project.godot").is_file():
        raise GodotSandboxError("WorldArena Godot project is unavailable")

    with tempfile.TemporaryDirectory(
        prefix="worldeval-primitive-sandbox-verifier-"
    ) as temporary:
        replay_path = Path(temporary) / "primary.replay.json"
        replay_path.write_bytes(payload)
        command = [
            str(selected_executable),
            "--no-header",
            "--headless",
            "--audio-driver",
            "Dummy",
            "--path",
            str(selected_project),
            "--script",
            REPLAY_VERIFIER_SCRIPT,
            "--",
            f"--scenario={configuration.scenario_path}",
            f"--replay={replay_path}",
            (
                "--initialization-hash="
                f"{configuration.initialization.initialization_hash}"
            ),
        ]
        isolated_command, network_isolated = _network_isolated_command(command)
        if require_network_isolation and not network_isolated:
            raise GodotSandboxError(
                "OS network isolation is required but unavailable"
            )
        try:
            completed = subprocess.run(
                isolated_command,
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout_seconds,
                env=_provider_free_environment(
                    network_isolated=network_isolated,
                ),
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise GodotSandboxError(
                "Godot native replay verifier failed to complete"
            ) from error
    match = _REPLAY_SUCCESS.search(completed.stdout)
    if completed.returncode != 0 or match is None:
        detail = (completed.stderr or completed.stdout)[-2000:]
        raise GodotSandboxError(
            f"Godot native replay verification failed closed: {detail}"
        )
    if match.group("scenario") != value["scenario_id"]:
        raise GodotSandboxError("Godot verifier scenario identity differs")
    if match.group("hash") != value["terminal_state_hash"]:
        raise GodotSandboxError("Godot verifier final-state hash differs")
    provider_calls = int(match.group("provider_calls"))
    if provider_calls != 0:
        raise GodotSandboxError("Godot verifier measured provider calls")
    from .service import evaluate_primitive_sandbox_replay

    evaluation = evaluate_primitive_sandbox_replay(configuration, value)
    initialization = configuration.initialization
    return NativeVerificationResult(
        final_state_hash=match.group("hash"),
        provider_calls=provider_calls,
        claims=NativeReplayClaims(
            protocol_id="worldeval-agent",
            protocol_version="0.1.0",
            protocol_package_hash=AgentProtocolValidator().package_sha256,
            game_id=initialization.game_id,
            environment_id=initialization.environment_id,
            engine_id="godot",
            engine_build_hash=_engine_build_hash(
                selected_executable,
                selected_project,
            ),
            run_id=str(value["run_id"]),
            scenario_id=str(value["scenario_id"]),
            objective_id=configuration.objective.objective_id,
            action_profile=initialization.profiles.action,
            observation_profile=initialization.profiles.observation,
            decision_profile=initialization.profiles.decision,
            initialization_hash=initialization.initialization_hash,
            terminal_outcome=str(value["terminal_outcome"]),
            terminal_tick=int(value["terminal_tick"]),
            evidence_sha256={
                "environment_init": canonical_sha256(
                    initialization.model_dump(mode="json")
                ),
                "objective": canonical_sha256(
                    configuration.objective.model_dump(mode="json")
                ),
                "evaluation": canonical_sha256(evaluation),
            },
        ),
    )


def _engine_build_hash(executable: Path, project_path: Path) -> str:
    digest = hashlib.sha256()
    try:
        version = subprocess.run(
            [str(executable), "--version"],
            check=False,
            capture_output=True,
            timeout=5,
            env=_provider_free_environment(),
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        version = b"unavailable"
    digest.update(version)
    for relative in _ENGINE_COMPONENTS:
        path = project_path / relative
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def network_isolation_available() -> bool:
    """Return whether this host has the verifier's supported OS network sandbox."""

    return sys.platform == "darwin" and Path("/usr/bin/sandbox-exec").is_file()


def _network_isolated_command(command: Sequence[str]) -> tuple[list[str], bool]:
    if network_isolation_available():
        return (
            [
                "/usr/bin/sandbox-exec",
                "-p",
                "(version 1)(allow default)(deny network*)",
                *command,
            ],
            True,
        )
    return list(command), False


def _provider_free_environment(*, network_isolated: bool = False) -> dict[str, str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if _SENSITIVE_ENV.search(key) is None
    }
    environment["WORLDEVAL_OFFLINE"] = "1"
    environment["WORLDEVAL_NETWORK_ISOLATED"] = "1" if network_isolated else "0"
    environment["NO_PROXY"] = "*"
    return environment


__all__ = [
    "GodotPrimitiveSandboxRunner",
    "GodotSandboxError",
    "GodotSandboxResult",
    "GodotSandboxSnapshot",
    "NATIVE_SCHEMA",
    "NATIVE_VERIFIER",
    "REPLAY_VERIFIER_SCRIPT",
    "SESSION_RUNNER_SCRIPT",
    "native_replay_verifier",
    "network_isolation_available",
]
