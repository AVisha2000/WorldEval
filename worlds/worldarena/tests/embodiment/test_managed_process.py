from __future__ import annotations

import asyncio
from pathlib import Path

import pytest
from genesis_arena.embodiment.managed_process import (
    MANAGED_AUTHORITY_SCRIPT,
    V2_MANAGED_AUTHORITY_SCRIPT,
    ManagedLaunchSpec,
    ManagedProcessError,
    ManagedProcessHandle,
    ManagedProcessLauncher,
    _consume_control_output,
    _managed_authority_command,
    minimal_child_environment,
)
from genesis_arena.embodiment.protocol import canonical_sha256
from genesis_arena.embodiment.protocol_registry import EmbodimentProtocolRegistry

ROOT = Path(__file__).resolve().parents[2]


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


def _v2_launch_spec(registry: EmbodimentProtocolRegistry) -> ManagedLaunchSpec:
    config = {
        "protocol_version": "llm-controller/0.2.0",
        "episode_id": "ep_v2_process",
        "mode": "solo-curriculum-v0",
        "task_id": "movement-maze-v0",
        "seed": 7,
        "observation_profile": "text-visible-v1",
        "timing_track": "step-locked-v1",
        "maximum_episode_ticks": 1200,
        "participant_ids": ["participant_0"],
    }
    return ManagedLaunchSpec(
        episode_id="ep_v2_process",
        attachment_ticket="V" * 43,
        connection_id="connection_v2",
        gateway_url="ws://127.0.0.1:8765/ws/embodiment/" + "V" * 43,
        config=config,
        config_sha256=canonical_sha256(config),
        protocol_package_sha256=registry.package("llm-controller/0.2.0").package_sha256,
        session_secret=bytearray(range(32)),
    )


def test_v2_launch_requires_registry_bound_package_identity() -> None:
    registry = EmbodimentProtocolRegistry.from_repository(ROOT)
    spec = _v2_launch_spec(registry)
    ManagedProcessLauncher._validate_spec(spec, protocol_registry=registry)
    with pytest.raises(ManagedProcessError, match="input_rejected"):
        ManagedProcessLauncher._validate_spec(_v2_launch_spec(registry))
    mismatched = _v2_launch_spec(registry)
    mismatched.protocol_package_sha256 = registry.package("llm-controller/0.1.0").package_sha256
    with pytest.raises(ManagedProcessError, match="input_rejected"):
        ManagedProcessLauncher._validate_spec(mismatched, protocol_registry=registry)


def test_broadcast_ticket_is_restricted_to_the_additive_rts_task() -> None:
    registry = EmbodimentProtocolRegistry.from_repository(ROOT)
    spec = _v2_launch_spec(registry)
    spec.presentation_broadcast_ticket = "B" * 43
    with pytest.raises(ManagedProcessError, match="input_rejected"):
        ManagedProcessLauncher._validate_spec(spec, protocol_registry=registry)


def test_managed_authority_commands_select_exact_versioned_cli() -> None:
    v1 = _managed_authority_command(
        Path("/godot"),
        Path("/project"),
        protocol_version="llm-controller/0.1.0",
        hybrid=False,
    )
    v2 = _managed_authority_command(
        Path("/godot"),
        Path("/project"),
        protocol_version="llm-controller/0.2.0",
        hybrid=True,
    )
    assert v1[-1] == MANAGED_AUTHORITY_SCRIPT
    assert v2[-1] == V2_MANAGED_AUTHORITY_SCRIPT
    assert "--headless" in v1
    assert "--windowed" in v2


@pytest.mark.asyncio
async def test_v2_control_output_contract_accepts_only_v2_started_kind() -> None:
    stream = asyncio.StreamReader()
    stream.feed_data(
        b'{"episode_id":"ep_v2_process","kind":"embodiment_managed_v2_started",'
        b'"schema_version":"llm-controller/managed-authority-launch/1.0.0"}\n'
    )
    stream.feed_eof()
    ready = asyncio.get_running_loop().create_future()
    await _consume_control_output(
        stream,
        ready,
        expected_episode_id="ep_v2_process",
        protocol_version="llm-controller/0.2.0",
    )
    assert ready.result() is None
