from __future__ import annotations

import asyncio
from pathlib import Path

import pytest
from genesis_arena.embodiment.contracts import EpisodeConfig
from genesis_arena.embodiment.managed_process import ManagedLaunchSpec
from genesis_arena.embodiment.managed_session import (
    AsyncEnvironmentSession,
    ManagedSessionError,
    ManagedWorldArenaSession,
    episode_config_as_dict,
)
from genesis_arena.embodiment.protocol import EmbodimentProtocolPackage, canonical_sha256

ROOT = Path(__file__).resolve().parents[2]


def test_episode_config_wire_shape_is_exact() -> None:
    value = episode_config_as_dict(
        EpisodeConfig(
            episode_id="ep_managed",
            mode="solo-curriculum-v0",
            task_id="orientation-v0",
            seed=7,
        )
    )
    assert set(value) == {
        "protocol_version",
        "episode_id",
        "mode",
        "task_id",
        "seed",
        "observation_profile",
        "timing_track",
        "maximum_episode_ticks",
        "participant_ids",
    }
    assert value["participant_ids"] == ["participant_0"]


def test_async_session_protocol_and_stable_error_are_public_contracts() -> None:
    assert AsyncEnvironmentSession is not None
    error = ManagedSessionError("embodiment_render_unsupported")
    assert error.code == str(error) == "embodiment_render_unsupported"


class _FakeProcess:
    def __init__(self) -> None:
        self.stopped = False

    async def stop(self) -> None:
        self.stopped = True


class _FakeLauncher:
    def __init__(self, process: _FakeProcess) -> None:
        self.process = process

    async def launch(self, spec: ManagedLaunchSpec) -> _FakeProcess:
        del spec
        return self.process


@pytest.mark.asyncio
async def test_reset_attachment_timeout_cleans_process_and_pending_future() -> None:
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    config = EpisodeConfig(
        episode_id="ep_attachment_timeout",
        mode="solo-curriculum-v0",
        task_id="orientation-v0",
        seed=1,
    )
    config_value = config.as_dict()
    ticket = "T" * 43
    spec = ManagedLaunchSpec(
        episode_id=config.episode_id,
        attachment_ticket=ticket,
        connection_id="connection_0",
        gateway_url=f"ws://127.0.0.1:8000/ws/embodiment/{ticket}",
        config=config_value,
        config_sha256=canonical_sha256(config_value),
        protocol_package_sha256=package.package_sha256,
        session_secret=bytearray(range(32)),
    )
    process = _FakeProcess()
    socket_future = asyncio.get_running_loop().create_future()
    session = ManagedWorldArenaSession(
        config=config,
        launcher=_FakeLauncher(process),
        launch_spec=spec,
        socket_future=socket_future,
        protocol_package=package,
        attachment_timeout_s=0.01,
    )

    with pytest.raises(ManagedSessionError, match="reset_failed"):
        await session.reset()

    assert process.stopped
    assert socket_future.cancelled()
