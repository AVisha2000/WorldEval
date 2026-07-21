"""Credential-safe lifecycle for one managed Godot embodiment authority."""

from __future__ import annotations

import asyncio
import ipaddress
import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Mapping, MutableMapping
from urllib.parse import urlsplit

from .protocol import ProtocolValidationError, canonical_json_bytes, canonical_sha256

MANAGED_LAUNCH_SCHEMA_VERSION = "llm-controller/managed-authority-launch/1.0.0"
MANAGED_AUTHORITY_SCRIPT = "res://scripts/embodiment/transport/embodiment_managed_authority_cli.gd"
MAX_MANAGED_LAUNCH_BYTES = 65_536
MAX_CONTROL_LINE_BYTES = 4_096
_STARTED_KIND = "embodiment_managed_started"
_ERROR_KIND = "embodiment_managed_error"
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_EPISODE = re.compile(r"^ep_[A-Za-z0-9._-]{1,120}$")
_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_TICKET = re.compile(r"^[A-Za-z0-9_-]{43}$")
_SAFE_CODE = re.compile(r"^[a-z][a-z0-9_]{0,95}$")


class ManagedProcessError(RuntimeError):
    """Stable, secret-free launch/lifecycle error."""

    def __init__(self, code: str) -> None:
        safe = (
            code
            if isinstance(code, str) and _SAFE_CODE.fullmatch(code)
            else "embodiment_process_failed"
        )
        super().__init__(safe)
        self.code = safe


@dataclass
class ManagedLaunchSpec:
    episode_id: str
    attachment_ticket: str
    connection_id: str
    gateway_url: str
    config: Mapping[str, Any]
    config_sha256: str
    protocol_package_sha256: str
    session_secret: bytearray = field(repr=False)

    def scrub(self) -> None:
        _zero_bytearray(self.session_secret)


class ManagedProcessHandle:
    """Exact owned process with bounded idempotent terminate/kill/reap."""

    def __init__(
        self,
        process: asyncio.subprocess.Process,
        output_task: asyncio.Task[None],
        *,
        shutdown_timeout_s: float,
    ) -> None:
        self._process = process
        self._output_task = output_task
        self._shutdown_timeout_s = shutdown_timeout_s
        self._stop_task: asyncio.Task[None] | None = None

    @property
    def pid(self) -> int | None:
        return self._process.pid

    @property
    def returncode(self) -> int | None:
        return self._process.returncode

    async def stop(self) -> None:
        if self._stop_task is None:
            self._stop_task = asyncio.create_task(self._stop(), name=f"embodiment-stop-{self.pid}")
        await asyncio.shield(self._stop_task)

    async def _stop(self) -> None:
        await _stop_process(self._process, self._shutdown_timeout_s)
        try:
            await asyncio.wait_for(asyncio.shield(self._output_task), self._shutdown_timeout_s)
        except asyncio.TimeoutError:
            self._output_task.cancel()
            try:
                await self._output_task
            except asyncio.CancelledError:
                pass
        except asyncio.CancelledError:
            if not self._output_task.cancelled():
                raise
        except Exception:
            pass


class ManagedProcessLauncher:
    def __init__(
        self,
        *,
        executable: Path,
        project_path: Path,
        startup_timeout_s: float = 10.0,
        shutdown_timeout_s: float = 5.0,
    ) -> None:
        if startup_timeout_s <= 0 or shutdown_timeout_s <= 0:
            raise ValueError("timeouts must be positive")
        self._executable = Path(executable)
        self._project_path = Path(project_path)
        self._startup_timeout_s = startup_timeout_s
        self._shutdown_timeout_s = shutdown_timeout_s

    async def launch(self, spec: ManagedLaunchSpec) -> ManagedProcessHandle:
        payload = bytearray()
        launch: MutableMapping[str, Any] = {}
        process: asyncio.subprocess.Process | None = None
        handle: ManagedProcessHandle | None = None
        ready: asyncio.Future[None] | None = None
        try:
            executable, project = self._validate_runtime()
            self._validate_spec(spec)
            launch = {
                "attachment_ticket": spec.attachment_ticket,
                "config": dict(spec.config),
                "config_sha256": spec.config_sha256,
                "connection_id": spec.connection_id,
                "episode_id": spec.episode_id,
                "gateway_url": spec.gateway_url,
                "protocol_package_sha256": spec.protocol_package_sha256,
                "session_secret": list(spec.session_secret),
            }
            payload.extend(
                canonical_json_bytes(
                    {"schema_version": MANAGED_LAUNCH_SCHEMA_VERSION, "launch": launch}
                )
            )
            if len(payload) > MAX_MANAGED_LAUNCH_BYTES:
                raise ManagedProcessError("embodiment_bootstrap_input_rejected")
            if spec.config.get("observation_profile") == "hybrid-visible-v1":
                command = (
                    str(executable),
                    "--no-header",
                    "--audio-driver",
                    "Dummy",
                    "--display-driver",
                    "macos",
                    "--windowed",
                    "--resolution",
                    "1280x720",
                    "--position",
                    "10000,10000",
                    "--path",
                    str(project),
                    "--script",
                    MANAGED_AUTHORITY_SCRIPT,
                )
            else:
                command = (
                    str(executable),
                    "--no-header",
                    "--headless",
                    "--path",
                    str(project),
                    "--script",
                    MANAGED_AUTHORITY_SCRIPT,
                )
            try:
                process = await asyncio.create_subprocess_exec(
                    *command,
                    cwd=str(project),
                    env=minimal_child_environment(),
                    stdin=asyncio.subprocess.PIPE,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.STDOUT,
                    limit=MAX_CONTROL_LINE_BYTES * 2,
                    start_new_session=os.name != "nt",
                )
            except (OSError, ValueError):
                raise ManagedProcessError("embodiment_spawn_failed") from None
            if process.stdin is None or process.stdout is None:
                raise ManagedProcessError("embodiment_spawn_failed")
            ready = asyncio.get_running_loop().create_future()
            output_task = asyncio.create_task(
                _consume_control_output(process.stdout, ready, expected_episode_id=spec.episode_id),
                name=f"embodiment-output-{spec.episode_id}",
            )
            handle = ManagedProcessHandle(
                process, output_task, shutdown_timeout_s=self._shutdown_timeout_s
            )
            await asyncio.wait_for(_handoff(process.stdin, payload), self._startup_timeout_s)
            await asyncio.wait_for(asyncio.shield(ready), self._startup_timeout_s)
            if process.returncode is not None:
                raise ManagedProcessError("embodiment_bootstrap_exited")
            return handle
        except asyncio.CancelledError:
            if handle is not None:
                await asyncio.shield(handle.stop())
            elif process is not None:
                await asyncio.shield(_stop_process(process, self._shutdown_timeout_s))
            raise
        except asyncio.TimeoutError:
            if handle is not None:
                await handle.stop()
            elif process is not None:
                await _stop_process(process, self._shutdown_timeout_s)
            raise ManagedProcessError("embodiment_bootstrap_timeout") from None
        except (ManagedProcessError, ProtocolValidationError, TypeError, ValueError) as error:
            if handle is not None:
                await handle.stop()
            elif process is not None:
                await _stop_process(process, self._shutdown_timeout_s)
            if isinstance(error, ManagedProcessError):
                raise
            raise ManagedProcessError("embodiment_bootstrap_input_rejected") from None
        finally:
            if ready is not None and ready.done() and not ready.cancelled():
                ready.exception()
            _scrub_mutable(launch.get("session_secret"))
            launch.clear()
            _zero_bytearray(payload)
            spec.scrub()

    def _validate_runtime(self) -> tuple[Path, Path]:
        try:
            executable = self._executable.expanduser().resolve(strict=True)
            project = self._project_path.expanduser().resolve(strict=True)
        except OSError:
            raise ManagedProcessError("embodiment_runtime_unavailable") from None
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise ManagedProcessError("embodiment_runtime_unavailable")
        if not project.is_dir() or not (project / "project.godot").is_file():
            raise ManagedProcessError("embodiment_runtime_unavailable")
        script = project / "scripts/embodiment/transport/embodiment_managed_authority_cli.gd"
        if not script.is_file():
            raise ManagedProcessError("embodiment_runtime_unavailable")
        return executable, project

    @staticmethod
    def _validate_spec(spec: ManagedLaunchSpec) -> None:
        if _EPISODE.fullmatch(spec.episode_id) is None:
            raise ManagedProcessError("embodiment_bootstrap_input_rejected")
        if (
            _TICKET.fullmatch(spec.attachment_ticket) is None
            or _IDENTIFIER.fullmatch(spec.connection_id) is None
        ):
            raise ManagedProcessError("embodiment_bootstrap_input_rejected")
        if (
            not isinstance(spec.config, Mapping)
            or spec.config.get("episode_id") != spec.episode_id
            or _SHA256.fullmatch(spec.config_sha256) is None
            or canonical_sha256(spec.config) != spec.config_sha256
        ):
            raise ManagedProcessError("embodiment_bootstrap_input_rejected")
        if (
            _SHA256.fullmatch(spec.protocol_package_sha256) is None
            or len(spec.session_secret) != 32
        ):
            raise ManagedProcessError("embodiment_bootstrap_input_rejected")
        if not _is_loopback_gateway(spec.gateway_url, spec.attachment_ticket):
            raise ManagedProcessError("embodiment_gateway_not_loopback")


async def _handoff(stdin: asyncio.StreamWriter, payload: bytearray) -> None:
    try:
        stdin.write(payload)
        await stdin.drain()
    except (BrokenPipeError, ConnectionError, OSError):
        raise ManagedProcessError("embodiment_bootstrap_ipc_failed") from None
    finally:
        stdin.close()
        try:
            await stdin.wait_closed()
        except (BrokenPipeError, ConnectionError, OSError):
            pass


async def _consume_control_output(
    stream: asyncio.StreamReader,
    ready: asyncio.Future[None],
    *,
    expected_episode_id: str,
) -> None:
    try:
        while True:
            line = await stream.readline()
            if not line:
                break
            if len(line) > MAX_CONTROL_LINE_BYTES:
                if not ready.done():
                    ready.set_exception(ManagedProcessError("embodiment_bootstrap_output_invalid"))
                continue
            try:
                value = json.loads(line)
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if not isinstance(value, dict):
                continue
            if value.get("kind") == _STARTED_KIND and not ready.done():
                if value == {
                    "kind": _STARTED_KIND,
                    "schema_version": MANAGED_LAUNCH_SCHEMA_VERSION,
                    "episode_id": expected_episode_id,
                }:
                    ready.set_result(None)
                else:
                    ready.set_exception(ManagedProcessError("embodiment_bootstrap_output_invalid"))
            elif value.get("kind") == _ERROR_KIND and not ready.done():
                if (
                    set(value) == {"kind", "schema_version", "code"}
                    and value.get("schema_version") == MANAGED_LAUNCH_SCHEMA_VERSION
                ):
                    ready.set_exception(ManagedProcessError(value["code"]))
                else:
                    ready.set_exception(ManagedProcessError("embodiment_bootstrap_output_invalid"))
    finally:
        if not ready.done():
            ready.set_exception(ManagedProcessError("embodiment_bootstrap_exited"))


async def _stop_process(process: asyncio.subprocess.Process, timeout_s: float) -> None:
    if process.returncode is None:
        try:
            process.terminate()
        except ProcessLookupError:
            pass
    try:
        await asyncio.wait_for(process.wait(), timeout_s)
    except asyncio.TimeoutError:
        if process.returncode is None:
            try:
                process.kill()
            except ProcessLookupError:
                pass
        try:
            await asyncio.wait_for(process.wait(), timeout_s)
        except asyncio.TimeoutError:
            pass


def minimal_child_environment() -> Dict[str, str]:
    if os.name != "nt":
        return {"LANG": "C", "LC_ALL": "C"}
    result: Dict[str, str] = {}
    for key in ("COMSPEC", "PATHEXT", "SYSTEMROOT", "WINDIR"):
        if os.environ.get(key):
            result[key] = os.environ[key]
    return result


def _is_loopback_gateway(value: str, ticket: str) -> bool:
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except (TypeError, ValueError):
        return False
    if (
        parsed.scheme != "ws"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or port is None
        or parsed.path != f"/ws/embodiment/{ticket}"
    ):
        return False
    try:
        return ipaddress.ip_address(parsed.hostname or "").is_loopback
    except ValueError:
        return (parsed.hostname or "").lower() == "localhost"


def _scrub_mutable(value: Any) -> None:
    if isinstance(value, bytearray):
        _zero_bytearray(value)
    elif isinstance(value, list):
        for item in value:
            _scrub_mutable(item)
        for index in range(len(value)):
            value[index] = 0
        value.clear()
    elif isinstance(value, MutableMapping):
        for item in value.values():
            _scrub_mutable(item)
        value.clear()


def _zero_bytearray(value: bytearray) -> None:
    if value:
        value[:] = b"\x00" * len(value)
        value.clear()


__all__ = [
    "MANAGED_AUTHORITY_SCRIPT",
    "MANAGED_LAUNCH_SCHEMA_VERSION",
    "MAX_MANAGED_LAUNCH_BYTES",
    "ManagedLaunchSpec",
    "ManagedProcessError",
    "ManagedProcessHandle",
    "ManagedProcessLauncher",
    "minimal_child_environment",
]
