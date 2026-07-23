"""Credential-safe subprocess boundary for the live Godot Duel authority.

The authority receives one canonical launch envelope through an anonymous stdin transport. Protected
launch material is never placed in argv, the child environment, a log message, or a filesystem
artifact.  Godot only receives a deliberately tiny environment and connects back to the Python
gateway through the loopback-only URL already authenticated by ``GatewayGodotBridge``.
"""

from __future__ import annotations

# ruff: noqa: UP045 -- Keep public annotations importable on the Python 3.9 floor.
import asyncio
import ipaddress
import json
import os
import re
from pathlib import Path
from typing import TYPE_CHECKING, Any, Dict, Mapping, MutableMapping, Optional
from urllib.parse import urlsplit

from .canonical import DuelCanonicalError, canonical_json_bytes

if TYPE_CHECKING:
    from .match_service import GodotDuelLaunchSpec


MANAGED_AUTHORITY_SCHEMA_VERSION = "worldeval-rts/managed-authority-launch/1.0.0"
MANAGED_AUTHORITY_SCRIPT = "res://scripts/duel/match/duel_managed_authority_cli.gd"
MAX_MANAGED_LAUNCH_BYTES = 4 * 1024 * 1024

_SAFE_CODE_RE = re.compile(r"^[a-z0-9][a-z0-9_.:-]{0,95}$")
_MATCH_ID_RE = re.compile(r"^m_[A-Za-z0-9][A-Za-z0-9_.:-]{0,126}$")
_CAPABILITY_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_AUTHORITY_HASH_KEYS = frozenset(
    {
        "engine_build_hash",
        "faction_hash",
        "helper_hash",
        "item_hash",
        "map_hash",
        "neutral_hash",
        "prompt_hash",
        "protocol_hash",
        "ruleset_hash",
        "tie_key_commitment",
    }
)
_BOOTSTRAP_ERROR_CODES = frozenset(
    {
        "duel_godot_bootstrap_input_rejected",
        "duel_godot_controller_rejected",
        "duel_godot_controller_start_failed",
        "duel_godot_engine_mismatch",
        "duel_godot_environment_rejected",
    }
)
_STARTED_KIND = "worldarena_duel_managed_started"
_ERROR_KIND = "worldarena_duel_managed_error"
_MAX_CONTROL_LINE_BYTES = 4_096


class DuelGodotProcessLaunchError(RuntimeError):
    """A stable, secret-free managed authority launch failure."""

    def __init__(self, code: str) -> None:
        safe_code = code if _SAFE_CODE_RE.fullmatch(code) is not None else "godot_launch_failed"
        super().__init__(safe_code)
        self.code = safe_code


class GodotManagedProcessHandle:
    """Owned child process with bounded, idempotent termination and output draining."""

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
        self._stop_task: Optional[asyncio.Task[None]] = None

    @property
    def pid(self) -> Optional[int]:
        """Process identifier for diagnostics; never includes launch material."""

        return self._process.pid

    async def stop(self) -> None:
        """Terminate and reap the exact owned child, escalating to kill after the bound."""

        # There is no await between this check and assignment, so concurrent event-loop callers
        # cannot create two cleanup tasks. Shielding lets cleanup continue if its caller is
        # cancelled; a later idempotent stop awaits the same owned task.
        if self._stop_task is None:
            self._stop_task = asyncio.create_task(
                self._stop_owned_process(), name=f"duel-godot-stop-{self._process.pid}"
            )
        await asyncio.shield(self._stop_task)

    async def _stop_owned_process(self) -> None:
        if self._process.returncode is None:
            try:
                self._process.terminate()
            except ProcessLookupError:
                pass
        try:
            await asyncio.wait_for(self._process.wait(), timeout=self._shutdown_timeout_s)
        except asyncio.TimeoutError:
            if self._process.returncode is None:
                try:
                    self._process.kill()
                except ProcessLookupError:
                    pass
            try:
                await asyncio.wait_for(self._process.wait(), timeout=self._shutdown_timeout_s)
            except asyncio.TimeoutError:
                # asyncio's Process API provides no stronger portable primitive. The process was
                # killed and remains owned; do not turn cleanup into a secret-bearing error.
                pass
        try:
            await asyncio.wait_for(
                asyncio.shield(self._output_task), timeout=self._shutdown_timeout_s
            )
        except asyncio.CancelledError:
            if not self._output_task.cancelled():
                raise
        except Exception:
            if not self._output_task.done():
                self._output_task.cancel()
                try:
                    await self._output_task
                except asyncio.CancelledError:
                    pass


class GodotManagedProcessLauncher:
    """Launch the live authority with one-use canonical anonymous stdin IPC.

    The executable and project locations are organizer configuration, so they may appear in argv.
    Match IDs, gateway capabilities, session keys, tie keys, salts, and MATCH_INIT bytes may not.
    """

    def __init__(
        self,
        *,
        executable: Path,
        project_path: Path,
        startup_timeout_s: float = 10.0,
        shutdown_timeout_s: float = 5.0,
    ) -> None:
        if startup_timeout_s <= 0 or shutdown_timeout_s <= 0:
            raise ValueError("managed Godot process timeouts must be positive")
        self._executable = Path(executable)
        self._project_path = Path(project_path)
        self._startup_timeout_s = float(startup_timeout_s)
        self._shutdown_timeout_s = float(shutdown_timeout_s)

    async def launch(self, spec: GodotDuelLaunchSpec) -> GodotManagedProcessHandle:
        payload = bytearray()
        launch_value: MutableMapping[str, Any] = {}
        launch_fields: Any = None
        process: Optional[asyncio.subprocess.Process] = None
        handle: Optional[GodotManagedProcessHandle] = None
        ready: Optional[asyncio.Future[None]] = None
        try:
            executable, project_path = self._validate_local_runtime()
            self._validate_launch_spec(spec)
            launch_fields = spec.controller_fields()
            launch_value = launch_fields.model_dump(mode="json")
            payload.extend(
                canonical_json_bytes(
                    {
                        "launch": launch_value,
                        "schema_version": MANAGED_AUTHORITY_SCHEMA_VERSION,
                    }
                )
            )
            if not payload or len(payload) > MAX_MANAGED_LAUNCH_BYTES:
                raise DuelGodotProcessLaunchError("duel_godot_bootstrap_input_rejected")

            command = (
                str(executable),
                "--no-header",
                "--headless",
                "--path",
                str(project_path),
                "--script",
                MANAGED_AUTHORITY_SCRIPT,
            )
            try:
                process = await asyncio.create_subprocess_exec(
                    *command,
                    cwd=str(project_path),
                    env=_minimal_child_environment(),
                    stdin=asyncio.subprocess.PIPE,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.STDOUT,
                    limit=_MAX_CONTROL_LINE_BYTES * 2,
                    start_new_session=os.name != "nt",
                )
            except (OSError, ValueError):
                raise DuelGodotProcessLaunchError("duel_godot_spawn_failed") from None
            if process.stdin is None or process.stdout is None:
                raise DuelGodotProcessLaunchError("duel_godot_spawn_failed")

            loop = asyncio.get_running_loop()
            ready = loop.create_future()
            output_task = asyncio.create_task(
                _consume_control_output(process.stdout, ready, expected_match_id=spec.match_id),
                name=f"duel-godot-output-{spec.match_id}",
            )
            handle = GodotManagedProcessHandle(
                process,
                output_task,
                shutdown_timeout_s=self._shutdown_timeout_s,
            )

            try:
                await asyncio.wait_for(
                    _handoff_payload(process.stdin, payload), timeout=self._startup_timeout_s
                )
            except DuelGodotProcessLaunchError as ipc_failure:
                # A fail-closed bootstrap may reject its environment/input and close stdin while
                # the parent is still draining a large MATCH_INIT. Prefer its authenticated fixed
                # control code when it is already available; otherwise retain the IPC diagnosis.
                try:
                    await asyncio.wait_for(asyncio.shield(ready), timeout=0.5)
                except DuelGodotProcessLaunchError as bootstrap_failure:
                    raise bootstrap_failure from None
                except (asyncio.TimeoutError, asyncio.CancelledError):
                    raise ipc_failure from None
                raise ipc_failure from None
            await asyncio.wait_for(
                asyncio.shield(ready), timeout=self._startup_timeout_s
            )
            if process.returncode is not None:
                raise DuelGodotProcessLaunchError("duel_godot_bootstrap_exited")
            return handle
        except asyncio.CancelledError:
            if handle is not None:
                await asyncio.shield(handle.stop())
            elif process is not None:
                await asyncio.shield(_stop_unwrapped_process(process, self._shutdown_timeout_s))
            raise
        except asyncio.TimeoutError:
            if handle is not None:
                await handle.stop()
            elif process is not None:
                await _stop_unwrapped_process(process, self._shutdown_timeout_s)
            raise DuelGodotProcessLaunchError("duel_godot_bootstrap_timeout") from None
        except DuelGodotProcessLaunchError:
            if handle is not None:
                await handle.stop()
            elif process is not None:
                await _stop_unwrapped_process(process, self._shutdown_timeout_s)
            raise
        except (DuelCanonicalError, TypeError, ValueError):
            if handle is not None:
                await handle.stop()
            elif process is not None:
                await _stop_unwrapped_process(process, self._shutdown_timeout_s)
            raise DuelGodotProcessLaunchError("duel_godot_bootstrap_input_rejected") from None
        finally:
            if ready is not None and ready.done() and not ready.cancelled():
                # Retrieve any exception even when IPC failed before the normal readiness await.
                # This prevents asyncio from later reporting a detached control-channel failure.
                ready.exception()
            _scrub_controller_fields(launch_fields)
            _scrub_mutable_json(launch_value)
            _zero_bytearray(payload)
            # The launch spec is explicitly one-use.  This is also repeated by the service so a
            # custom launcher cannot accidentally leave its mutable IPC copy live after return.
            spec.scrub_protected_bytes()

    def _validate_local_runtime(self) -> tuple[Path, Path]:
        try:
            executable = self._executable.expanduser().resolve(strict=True)
        except OSError:
            raise DuelGodotProcessLaunchError("duel_godot_executable_unavailable") from None
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise DuelGodotProcessLaunchError("duel_godot_executable_unavailable")
        try:
            project_path = self._project_path.expanduser().resolve(strict=True)
        except OSError:
            raise DuelGodotProcessLaunchError("duel_godot_project_unavailable") from None
        if not project_path.is_dir() or not (project_path / "project.godot").is_file():
            raise DuelGodotProcessLaunchError("duel_godot_project_unavailable")
        if not (project_path / "scripts/duel/match/duel_managed_authority_cli.gd").is_file():
            raise DuelGodotProcessLaunchError("duel_godot_project_unavailable")
        return executable, project_path

    @staticmethod
    def _validate_launch_spec(spec: GodotDuelLaunchSpec) -> None:
        if _MATCH_ID_RE.fullmatch(spec.match_id) is None:
            raise DuelGodotProcessLaunchError("duel_godot_bootstrap_input_rejected")
        if (
            not isinstance(spec.connection_id, str)
            or not spec.connection_id
            or len(spec.connection_id) > 128
            or any(
                ord(character) < 0x21 or ord(character) > 0x7E
                for character in spec.connection_id
            )
        ):
            raise DuelGodotProcessLaunchError("duel_godot_bootstrap_input_rejected")
        if _CAPABILITY_RE.fullmatch(spec.attachment_ticket) is None:
            raise DuelGodotProcessLaunchError("duel_godot_bootstrap_input_rejected")
        if not _is_exact_loopback_gateway(spec.gateway_url, spec.attachment_ticket):
            raise DuelGodotProcessLaunchError("duel_godot_gateway_not_loopback")
        if not isinstance(spec.authoritative_hashes, Mapping) or not spec.authoritative_hashes:
            raise DuelGodotProcessLaunchError("duel_godot_bootstrap_input_rejected")
        if (
            not isinstance(spec.scored, bool)
            or _SHA256_RE.fullmatch(spec.protocol_hash) is None
            or set(spec.authoritative_hashes) != _AUTHORITY_HASH_KEYS
            or any(
                not isinstance(value, str) or _SHA256_RE.fullmatch(value) is None
                for value in spec.authoritative_hashes.values()
            )
            or spec.authoritative_hashes.get("protocol_hash") != spec.protocol_hash
        ):
            raise DuelGodotProcessLaunchError("duel_godot_bootstrap_input_rejected")
        if (
            len(spec.session_secret) != 32
            or len(spec.tie_key) != 32
            or len(spec.alias_salt_seat_0) != 32
            or len(spec.alias_salt_seat_1) != 32
            or spec.alias_salt_seat_0 == spec.alias_salt_seat_1
            or not spec.match_init_json
            or len(spec.match_init_json) > MAX_MANAGED_LAUNCH_BYTES
        ):
            raise DuelGodotProcessLaunchError("duel_godot_bootstrap_input_rejected")


async def _handoff_payload(
    stdin: asyncio.StreamWriter, payload: bytearray
) -> None:
    failure: Optional[DuelGodotProcessLaunchError] = None
    try:
        stdin.write(payload)
        await stdin.drain()
    except (BrokenPipeError, ConnectionError, OSError):
        failure = DuelGodotProcessLaunchError("duel_godot_ipc_failed")
    finally:
        stdin.close()
        try:
            await stdin.wait_closed()
        except (BrokenPipeError, ConnectionError, OSError):
            failure = DuelGodotProcessLaunchError("duel_godot_ipc_failed")
    if failure is not None:
        raise failure from None


async def _consume_control_output(
    stream: asyncio.StreamReader,
    ready: asyncio.Future[None],
    *,
    expected_match_id: str,
) -> None:
    try:
        while True:
            line = await stream.readline()
            if not line:
                break
            if len(line) > _MAX_CONTROL_LINE_BYTES:
                if not ready.done():
                    ready.set_exception(
                        DuelGodotProcessLaunchError("duel_godot_bootstrap_output_invalid")
                    )
                continue
            try:
                value = json.loads(line)
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if not isinstance(value, dict):
                continue
            kind = value.get("kind")
            if kind == _STARTED_KIND:
                if (
                    set(value) == {"kind", "match_id", "schema_version"}
                    and value.get("schema_version") == MANAGED_AUTHORITY_SCHEMA_VERSION
                    and value.get("match_id") == expected_match_id
                    and not ready.done()
                ):
                    ready.set_result(None)
                elif not ready.done():
                    ready.set_exception(
                        DuelGodotProcessLaunchError("duel_godot_bootstrap_output_invalid")
                    )
            elif kind == _ERROR_KIND and not ready.done():
                code = value.get("code")
                ready.set_exception(
                    DuelGodotProcessLaunchError(
                        code if code in _BOOTSTRAP_ERROR_CODES else "duel_godot_bootstrap_rejected"
                    )
                )
    except (ValueError, asyncio.LimitOverrunError):
        if not ready.done():
            ready.set_exception(
                DuelGodotProcessLaunchError("duel_godot_bootstrap_output_invalid")
            )
    finally:
        if not ready.done():
            ready.set_exception(DuelGodotProcessLaunchError("duel_godot_bootstrap_exited"))


async def _stop_unwrapped_process(
    process: asyncio.subprocess.Process, timeout_s: float
) -> None:
    if process.returncode is None:
        try:
            process.terminate()
        except ProcessLookupError:
            pass
    try:
        await asyncio.wait_for(process.wait(), timeout=timeout_s)
    except asyncio.TimeoutError:
        if process.returncode is None:
            try:
                process.kill()
            except ProcessLookupError:
                pass
        try:
            await asyncio.wait_for(process.wait(), timeout=timeout_s)
        except asyncio.TimeoutError:
            pass


def _minimal_child_environment() -> Dict[str, str]:
    """Return only non-secret values required by common desktop process loaders."""

    if os.name != "nt":
        return {"LANG": "C", "LC_ALL": "C"}
    allowed: Dict[str, str] = {}
    for key in ("COMSPEC", "PATHEXT", "SYSTEMROOT", "WINDIR"):
        value = os.environ.get(key)
        if value:
            allowed[key] = value
    return allowed


def _is_exact_loopback_gateway(value: str, attachment_ticket: str) -> bool:
    if not isinstance(value, str) or not isinstance(attachment_ticket, str):
        return False
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError:
        return False
    if (
        parsed.scheme != "ws"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or port is None
        or not 1 <= port <= 65_535
        or parsed.path != f"/ws/duel/{attachment_ticket}"
    ):
        return False
    try:
        return ipaddress.ip_address(parsed.hostname or "").is_loopback
    except ValueError:
        return (parsed.hostname or "").lower() == "localhost"


def _scrub_mutable_json(value: Any) -> None:
    if isinstance(value, bytearray):
        _zero_bytearray(value)
    elif isinstance(value, list):
        for item in value:
            _scrub_mutable_json(item)
        for index in range(len(value)):
            value[index] = 0
        value.clear()
    elif isinstance(value, MutableMapping):
        for item in value.values():
            _scrub_mutable_json(item)
        value.clear()


def _scrub_controller_fields(fields: Any) -> None:
    if fields is None:
        return
    for name in ("token",):
        _scrub_mutable_json(getattr(fields, name, None))
    authority = getattr(fields, "authority", None)
    if authority is not None:
        for name in ("tie_key", "alias_salt_seat_0", "alias_salt_seat_1"):
            _scrub_mutable_json(getattr(authority, name, None))
        hashes = getattr(authority, "authoritative_hashes", None)
        _scrub_mutable_json(hashes)
    _scrub_mutable_json(getattr(fields, "match_init", None))


def _zero_bytearray(value: bytearray) -> None:
    if value:
        value[:] = b"\x00" * len(value)
        value.clear()


__all__ = [
    "DuelGodotProcessLaunchError",
    "GodotManagedProcessHandle",
    "GodotManagedProcessLauncher",
    "MANAGED_AUTHORITY_SCHEMA_VERSION",
    "MANAGED_AUTHORITY_SCRIPT",
    "MAX_MANAGED_LAUNCH_BYTES",
]
