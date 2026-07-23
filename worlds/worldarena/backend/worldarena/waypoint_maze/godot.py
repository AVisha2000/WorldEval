"""Managed provider-free Godot authority and native replay verifier."""

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

from worldeval.contracts import (
    AgentProtocolValidator,
    canonical_json_bytes,
    strict_json_loads,
)
from worldeval.replay import (
    NativeReplayClaims,
    NativeVerificationResult,
    NativeVerifierRegistry,
    canonical_sha256,
)

from .configuration import WaypointMazeConfiguration, load_configuration

RUNNER_SCRIPT = (
    "res://scripts/agent_waypoint_maze/waypoint_maze_headless_runner.gd"
)
REPLAY_VERIFIER_SCRIPT = (
    "res://scripts/agent_waypoint_maze/waypoint_maze_replay_verifier_cli.gd"
)
NATIVE_SCHEMA = "replay-bundle.v1"
NATIVE_VERIFIER = "waypoint-maze-godot-reexecution-v1"
_SUCCESS = re.compile(
    r"WAYPOINT_MAZE_HEADLESS_OK scenario=(?P<scenario>\S+) "
    r"outcome=(?P<outcome>\S+) tick=(?P<tick>\d+) "
    r"decisions=(?P<decisions>\d+) "
    r"final_state_hash=(?P<hash>sha256:[0-9a-f]{64})"
)
_REPLAY_SUCCESS = re.compile(
    r"WAYPOINT_MAZE_REPLAY_VERIFIED scenario=(?P<scenario>\S+) "
    r"provider_calls=(?P<provider_calls>\d+) "
    r"final_state_hash=(?P<hash>sha256:[0-9a-f]{64})"
)
_SENSITIVE_ENV = re.compile(
    r"(?:api.?key|authorization|credential|secret|token|http_proxy|https_proxy|all_proxy)",
    re.IGNORECASE,
)
_ENGINE_COMPONENTS = (
    "scripts/agent_sandbox/primitive_sandbox_authority.gd",
    "scripts/agent_waypoint_maze/waypoint_maze_authority.gd",
    "scripts/agent_waypoint_maze/waypoint_maze_demo_policy.gd",
    "scripts/agent_waypoint_maze/waypoint_maze_headless_runner.gd",
    "scripts/agent_waypoint_maze/waypoint_maze_replay_verifier.gd",
    "scripts/agent_waypoint_maze/waypoint_maze_replay_verifier_cli.gd",
)


class WaypointMazeAuthorityError(RuntimeError):
    """The Godot authority or verifier failed closed."""


@dataclass(frozen=True)
class GodotWaypointMazeResult:
    configuration: WaypointMazeConfiguration
    replay: Mapping[str, Any]
    skill_expansion: Mapping[str, Any]
    stdout: str
    engine_build_hash: str


class GodotWaypointMazeRunner:
    def __init__(
        self,
        *,
        executable: Path,
        project_path: Path,
        game_root: Path | None = None,
        timeout_seconds: float = 30.0,
        require_network_isolation: bool = False,
    ) -> None:
        self.executable = Path(executable).resolve()
        self.project_path = Path(project_path).resolve()
        self.game_root = Path(game_root).resolve() if game_root else None
        self.timeout_seconds = timeout_seconds
        self.require_network_isolation = require_network_isolation

    def run(self, scenario_id: str, *, run_id: str) -> GodotWaypointMazeResult:
        configuration = load_configuration(scenario_id, game_root=self.game_root)
        self._check_installation()
        with tempfile.TemporaryDirectory(
            prefix="worldeval-waypoint-maze-"
        ) as temporary:
            replay_path = Path(temporary) / "primary.replay.json"
            expansion_path = Path(temporary) / "skill-expansion.json"
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
                f"--decision-profile={configuration.decision_profile_path}",
                f"--skill={configuration.skill_path}",
                (
                    "--initialization-hash="
                    f"{configuration.initialization.initialization_hash}"
                ),
                f"--run-id={run_id}",
                f"--output={replay_path}",
                f"--expansion-output={expansion_path}",
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
                raise WaypointMazeAuthorityError(
                    "Godot Waypoint Maze authority failed to complete"
                ) from error
            match = _SUCCESS.search(completed.stdout)
            if (
                completed.returncode != 0
                or match is None
                or not replay_path.is_file()
                or not expansion_path.is_file()
            ):
                detail = (completed.stderr or completed.stdout)[-2000:]
                raise WaypointMazeAuthorityError(
                    f"Godot Waypoint Maze authority failed closed: {detail}"
                )
            replay = strict_json_loads(replay_path.read_bytes())
            expansion = strict_json_loads(expansion_path.read_bytes())
        if not isinstance(replay, dict) or not isinstance(expansion, dict):
            raise WaypointMazeAuthorityError(
                "Godot Waypoint Maze outputs must be JSON objects"
            )
        AgentProtocolValidator().validate(
            "replay-bundle.v1.schema.json",
            replay,
            model=False,
        )
        if match.group("scenario") != scenario_id:
            raise WaypointMazeAuthorityError("Godot scenario identity differs")
        if match.group("outcome") != replay.get("terminal_outcome"):
            raise WaypointMazeAuthorityError("Godot terminal outcome differs")
        if int(match.group("tick")) != replay.get("terminal_tick"):
            raise WaypointMazeAuthorityError("Godot terminal tick differs")
        if int(match.group("decisions")) != len(replay.get("decisions", [])):
            raise WaypointMazeAuthorityError("Godot decision count differs")
        if match.group("hash") != replay.get("terminal_state_hash"):
            raise WaypointMazeAuthorityError("Godot terminal state hash differs")
        verification = self.verify_native_replay(replay)
        if verification.provider_calls != 0:
            raise WaypointMazeAuthorityError(
                "provider-free replay verification did not pass"
            )
        return GodotWaypointMazeResult(
            configuration=configuration,
            replay=replay,
            skill_expansion=expansion,
            stdout=completed.stdout,
            engine_build_hash=self.engine_build_hash(),
        )

    def verify_native_replay(
        self,
        replay: Mapping[str, Any],
    ) -> NativeVerificationResult:
        return native_replay_verifier(
            canonical_json_bytes(replay),
            {"native_schema": NATIVE_SCHEMA, "verifier": NATIVE_VERIFIER},
            executable=self.executable,
            project_path=self.project_path,
            game_root=self.game_root,
            timeout_seconds=self.timeout_seconds,
            require_network_isolation=self.require_network_isolation,
        )

    def native_verifiers(self) -> NativeVerifierRegistry:
        def callback(
            payload: bytes,
            descriptor: Mapping[str, Any],
        ) -> NativeVerificationResult:
            return native_replay_verifier(
                payload,
                descriptor,
                executable=self.executable,
                project_path=self.project_path,
                game_root=self.game_root,
                timeout_seconds=self.timeout_seconds,
                require_network_isolation=self.require_network_isolation,
            )

        return NativeVerifierRegistry({(NATIVE_VERIFIER, NATIVE_SCHEMA): callback})

    def engine_build_hash(self) -> str:
        return _engine_build_hash(self.executable, self.project_path)

    def _check_installation(self) -> None:
        if not self.executable.is_file():
            raise WaypointMazeAuthorityError("Godot executable is unavailable")
        if not (self.project_path / "project.godot").is_file():
            raise WaypointMazeAuthorityError(
                "WorldArena Godot project is unavailable"
            )


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
    value = strict_json_loads(payload)
    if not isinstance(value, dict):
        raise WaypointMazeAuthorityError("native replay is not an object")
    AgentProtocolValidator().validate(
        "replay-bundle.v1.schema.json",
        value,
        model=False,
    )
    if descriptor.get("native_schema") != NATIVE_SCHEMA:
        raise WaypointMazeAuthorityError("native replay schema is unsupported")
    if descriptor.get("verifier") != NATIVE_VERIFIER:
        raise WaypointMazeAuthorityError("native replay verifier identity differs")
    configuration = load_configuration(
        str(value["scenario_id"]),
        game_root=game_root,
    )
    if (
        value["initialization_hash"]
        != configuration.initialization.initialization_hash
    ):
        raise WaypointMazeAuthorityError(
            "native replay initialization hash differs from authored inputs"
        )
    selected_executable = Path(executable).resolve()
    selected_project = Path(project_path).resolve()
    if not selected_executable.is_file():
        raise WaypointMazeAuthorityError("Godot executable is unavailable")
    if not (selected_project / "project.godot").is_file():
        raise WaypointMazeAuthorityError(
            "WorldArena Godot project is unavailable"
        )
    with tempfile.TemporaryDirectory(
        prefix="worldeval-waypoint-maze-verifier-"
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
            f"--decision-profile={configuration.decision_profile_path}",
            f"--replay={replay_path}",
            (
                "--initialization-hash="
                f"{configuration.initialization.initialization_hash}"
            ),
        ]
        isolated_command, network_isolated = _network_isolated_command(command)
        if require_network_isolation and not network_isolated:
            raise WaypointMazeAuthorityError(
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
            raise WaypointMazeAuthorityError(
                "Godot Waypoint Maze replay verifier failed to complete"
            ) from error
    match = _REPLAY_SUCCESS.search(completed.stdout)
    if completed.returncode != 0 or match is None:
        detail = (completed.stderr or completed.stdout)[-2000:]
        raise WaypointMazeAuthorityError(
            f"Godot Waypoint Maze replay verification failed closed: {detail}"
        )
    if match.group("scenario") != value["scenario_id"]:
        raise WaypointMazeAuthorityError("Godot verifier scenario identity differs")
    if match.group("hash") != value["terminal_state_hash"]:
        raise WaypointMazeAuthorityError(
            "Godot verifier terminal state hash differs"
        )
    provider_calls = int(match.group("provider_calls"))
    if provider_calls != 0:
        raise WaypointMazeAuthorityError("Godot verifier measured provider calls")
    from .service import (
        evaluate_waypoint_maze_replay,
        expected_skill_expansion,
    )

    expansion = expected_skill_expansion(configuration, value)
    evaluation = evaluate_waypoint_maze_replay(
        configuration,
        value,
        expansion,
    )
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
                "skill_manifest": canonical_sha256(
                    configuration.skill.model_dump(mode="json")
                ),
                "skill_expansion": canonical_sha256(expansion),
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


def network_isolation_available() -> bool:
    """Return whether the supported OS-level network sandbox is available."""

    return sys.platform == "darwin" and Path("/usr/bin/sandbox-exec").is_file()


def _provider_free_environment(
    *,
    network_isolated: bool = False,
) -> dict[str, str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if _SENSITIVE_ENV.search(key) is None
    }
    environment["WORLDEVAL_OFFLINE"] = "1"
    environment["WORLDEVAL_NETWORK_ISOLATED"] = (
        "1" if network_isolated else "0"
    )
    environment["NO_PROXY"] = "*"
    return environment


__all__ = [
    "GodotWaypointMazeResult",
    "GodotWaypointMazeRunner",
    "NATIVE_SCHEMA",
    "NATIVE_VERIFIER",
    "REPLAY_VERIFIER_SCRIPT",
    "RUNNER_SCRIPT",
    "WaypointMazeAuthorityError",
    "native_replay_verifier",
    "network_isolation_available",
]
