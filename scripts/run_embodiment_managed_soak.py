#!/usr/bin/env python3
"""Exercise repeated real managed Godot sessions and verify bounded cleanup."""

from __future__ import annotations

import argparse
import asyncio
import gc
import os
import secrets
from pathlib import Path
from typing import Mapping

from genesis_arena.embodiment.contracts import (
    CapabilityStatus,
    DecisionWindow,
    EpisodeConfig,
    ParticipantDecision,
)
from genesis_arena.embodiment.managed_process import ManagedLaunchSpec, ManagedProcessLauncher
from genesis_arena.embodiment.managed_session import ManagedWorldArenaSession
from genesis_arena.embodiment.protocol import (
    EmbodimentProtocolPackage,
    canonical_json_bytes,
    canonical_sha256,
)
from genesis_arena.embodiment.replay import verify_replay_bytes

try:
    from scripts.run_embodiment_live_provider_pilot import _Gateway
except ModuleNotFoundError:  # Direct `python scripts/...` execution.
    from run_embodiment_live_provider_pilot import _Gateway  # type: ignore[no-redef]

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")


class ManagedSoakError(RuntimeError):
    """Stable provider-free soak failure."""


class _TrackingLauncher(ManagedProcessLauncher):
    def __init__(self, **kwargs: object) -> None:
        super().__init__(**kwargs)
        self.handles = []

    async def launch(self, spec: ManagedLaunchSpec):
        handle = await super().launch(spec)
        self.handles.append(handle)
        return handle


def validate_soak_metrics(
    *,
    iterations: int,
    handles_reaped: int,
    pending_samples: tuple[int, ...],
    fd_samples: tuple[int, ...],
) -> Mapping[str, int | list[int]]:
    if iterations < 1 or handles_reaped != iterations:
        raise ManagedSoakError("managed_soak_process_not_reaped")
    if len(pending_samples) != iterations or any(value != 0 for value in pending_samples):
        raise ManagedSoakError("managed_soak_attachment_leak")
    if len(fd_samples) < 2 or fd_samples[-1] > fd_samples[0] + 2:
        raise ManagedSoakError("managed_soak_fd_growth")
    for left, middle, right in zip(fd_samples, fd_samples[1:], fd_samples[2:]):
        if left < middle < right:
            raise ManagedSoakError("managed_soak_fd_growth")
    return {
        "fd_samples": list(fd_samples),
        "handles_reaped": handles_reaped,
        "iterations": iterations,
        "maximum_pending_attachments": max(pending_samples, default=0),
    }


def _fd_count() -> int:
    for candidate in (Path("/dev/fd"), Path("/proc/self/fd")):
        if candidate.is_dir():
            return len(tuple(candidate.iterdir()))
    raise ManagedSoakError("managed_soak_fd_metrics_unavailable")


def _pid_gone(pid: int | None) -> bool:
    if pid is None:
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def _capabilities() -> CapabilityStatus:
    return CapabilityStatus(
        implemented_modes=("solo-curriculum-v0",),
        implemented_observation_profiles=("hybrid-visible-v1",),
        implemented_tasks=("orientation-v0",),
    )


async def run_soak(*, iterations: int, godot: Path) -> Mapping[str, int | list[int]]:
    if not 1 <= iterations <= 256:
        raise ManagedSoakError("managed_soak_iterations_invalid")
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    launcher = _TrackingLauncher(executable=godot, project_path=ROOT / "godot")
    pending_samples: list[int] = []
    fd_samples = [_fd_count()]
    async with _Gateway() as gateway:
        for index in range(iterations):
            episode_id = f"ep_managed_soak_{index:04d}"
            config = EpisodeConfig(
                episode_id=episode_id,
                mode="solo-curriculum-v0",
                task_id="orientation-v0",
                seed=7000 + index,
                observation_profile="hybrid-visible-v1",
                timing_track="step-locked-v1",
                maximum_episode_ticks=1,
                participant_ids=("participant_0",),
                capability_status=_capabilities(),
            )
            config_value = config.as_dict()
            ticket = secrets.token_urlsafe(32)
            secret = bytearray(secrets.token_bytes(32))
            connection_id = f"soak_{index:04d}"
            future = gateway.endpoint.register(
                ticket=ticket,
                episode_id=episode_id,
                connection_id=connection_id,
                session_secret=bytearray(secret),
            )
            launch = ManagedLaunchSpec(
                episode_id=episode_id,
                attachment_ticket=ticket,
                connection_id=connection_id,
                gateway_url=f"ws://127.0.0.1:{gateway.port}/ws/embodiment/{ticket}",
                config=config_value,
                config_sha256=canonical_sha256(config_value),
                protocol_package_sha256=package.package_sha256,
                session_secret=secret,
            )
            session = ManagedWorldArenaSession(
                config=config,
                launcher=launcher,
                launch_spec=launch,
                socket_future=future,
                protocol_package=package,
                attachment_timeout_s=20,
                step_timeout_s=20,
            )
            try:
                observations = await session.reset()
                observation = observations["participant_0"]
                frame = observation["frame"]
                await session.render(
                    "participant_0",
                    frame["sensor_id"],
                    frame["transport_ref"],
                    observation["observation_seq"],
                )
                result = await session.step(
                    DecisionWindow(
                        episode_id=episode_id,
                        observation_seq=0,
                        mode="solo-curriculum-v0",
                        start_tick=0,
                        duration_ticks=1,
                        decisions={"participant_0": ParticipantDecision.no_input("missing")},
                    )
                )
                if not result.terminal.ended:
                    raise ManagedSoakError("managed_soak_episode_not_terminal")
                verify_replay_bytes(session.replay_bytes, package=package)
            finally:
                await session.close()
                gateway.endpoint.cancel(ticket)
            handle = launcher.handles[-1]
            if handle.returncode is None or not _pid_gone(handle.pid):
                raise ManagedSoakError("managed_soak_process_not_reaped")
            diagnostics = gateway.endpoint.diagnostics()
            pending_samples.append(diagnostics["pending"])
            if (index + 1) % 8 == 0:
                gc.collect()
                await asyncio.sleep(0)
                fd_samples.append(_fd_count())
    gc.collect()
    await asyncio.sleep(0)
    fd_samples.append(_fd_count())
    return validate_soak_metrics(
        iterations=iterations,
        handles_reaped=sum(handle.returncode is not None for handle in launcher.handles),
        pending_samples=tuple(pending_samples),
        fd_samples=tuple(fd_samples),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iterations", type=int, default=32)
    parser.add_argument("--godot", type=Path, default=DEFAULT_GODOT)
    arguments = parser.parse_args()
    try:
        summary = asyncio.run(run_soak(iterations=arguments.iterations, godot=arguments.godot))
    except (ManagedSoakError, OSError, RuntimeError, TypeError, ValueError) as error:
        print(f"EMBODIMENT_MANAGED_SOAK_FAILED {error}")
        return 2
    print("EMBODIMENT_MANAGED_SOAK_OK " + canonical_json_bytes(summary).decode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
