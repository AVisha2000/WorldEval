from __future__ import annotations

import asyncio

import pytest
from genesis_arena.embodiment.managed_process import (
    ManagedLaunchSpec,
    ManagedProcessHandle,
    ManagedProcessLauncher,
    minimal_child_environment,
)
from genesis_arena.embodiment.protocol import canonical_sha256


class FakeProcess:
    pid = 123

    def __init__(self) -> None:
        self.returncode = None
        self.terminated = 0
        self.killed = 0

    def terminate(self) -> None:
        self.terminated += 1
        self.returncode = 0

    def kill(self) -> None:
        self.killed += 1
        self.returncode = -9

    async def wait(self) -> int:
        return self.returncode or 0


@pytest.mark.asyncio
async def test_owned_process_cleanup_is_bounded_and_idempotent() -> None:
    process = FakeProcess()
    output = asyncio.create_task(asyncio.sleep(0))
    handle = ManagedProcessHandle(process, output, shutdown_timeout_s=0.1)
    await asyncio.gather(handle.stop(), handle.stop())
    assert process.terminated == 1
    assert process.killed == 0


def test_launch_validation_recomputes_config_hash_and_scrubs_secret() -> None:
    config = {"episode_id": "ep_launch"}
    spec = ManagedLaunchSpec(
        episode_id="ep_launch",
        attachment_ticket="T" * 43,
        connection_id="connection_0",
        gateway_url="ws://127.0.0.1:8765/ws/embodiment/" + "T" * 43,
        config=config,
        config_sha256=canonical_sha256(config),
        protocol_package_sha256="a" * 64,
        session_secret=bytearray(range(32)),
    )
    ManagedProcessLauncher._validate_spec(spec)
    spec.scrub()
    assert spec.session_secret == bytearray()
    assert minimal_child_environment() == {"LANG": "C", "LC_ALL": "C"}
