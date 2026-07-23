from __future__ import annotations

import asyncio
import json
from pathlib import Path

import pytest
from genesis_arena.embodiment.artifacts import (
    PROTECTED_LAYER,
    EpisodeArtifact,
    EpisodeArtifactBundle,
    verify_offline_replay,
    verify_offline_replay_with_godot,
)
from genesis_arena.embodiment.contracts import (
    CapabilityStatus,
    ControllerAction,
    ControllerState,
    EpisodeConfig,
)
from genesis_arena.embodiment.managed_process import ManagedLaunchSpec, ManagedProcessLauncher
from genesis_arena.embodiment.managed_session import ManagedWorldArenaSession
from genesis_arena.embodiment.protocol import (
    ProtocolValidationError,
    canonical_json_bytes,
    canonical_sha256,
)
from genesis_arena.embodiment.protocol_registry import EmbodimentProtocolRegistry
from genesis_arena.embodiment.replay import (
    ReplayLedger,
    ReplayValidationError,
    verify_replay_bytes,
)
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
V1 = "llm-controller/0.1.0"
V2 = "llm-controller/0.2.0"


@pytest.fixture(scope="module")
def registry() -> EmbodimentProtocolRegistry:
    return EmbodimentProtocolRegistry.from_repository(ROOT)


def v2_capabilities() -> CapabilityStatus:
    return CapabilityStatus(
        implemented_modes=("solo-curriculum-v0",),
        implemented_observation_profiles=("hybrid-visible-v1",),
        implemented_tasks=("movement-maze-v0", "operator-action-course-v0"),
    )


def v2_config(task_id: str = "movement-maze-v0") -> EpisodeConfig:
    return EpisodeConfig(
        episode_id="ep_v2_dispatch",
        mode="solo-curriculum-v0",
        task_id=task_id,
        seed=29,
        protocol_version=V2,
        observation_profile="hybrid-visible-v1",
        maximum_episode_ticks=100,
        capability_status=v2_capabilities(),
    )


def v2_replay(registry: EmbodimentProtocolRegistry) -> bytes:
    package = registry.package(V2)
    config = v2_config().as_dict()
    initial = {
        "protocol_version": V2,
        "episode_id": "ep_v2_dispatch",
        "observation_seq": 0,
        "tick": 0,
        "profile": "hybrid-visible-v1",
        "goal": "Reach the visible checkpoints in order.",
        "remaining_ticks": 100,
        "self": {
            "health_percent": 100,
            "energy_percent": 100,
            "facing": "north",
            "contact": "clear",
            "inventory": [],
            "status": [],
        },
        "visible_entities": [],
        "recent_events": [],
        "previous_receipt": None,
        "memory": "",
        "frame": {
            "sensor_id": "operator-follow-v1",
            "mime_type": "image/png",
            "width": 1280,
            "height": 720,
            "sha256": "1" * 64,
            "transport_ref": "frame:v2_0",
        },
        "terminal": {"ended": False, "outcome": "running", "reason": "running"},
    }
    receipt = {
        "action_id": "no_input_0",
        "observation_seq": 0,
        "accepted": False,
        "disposition": "no_input",
        "fallback": "neutral",
        "no_input_reason": "missing",
        "start_tick": 0,
        "end_tick": 10,
        "applied_ticks": 10,
        "codes": [],
        "effects": [],
    }
    terminal = {"ended": True, "outcome": "success", "reason": "beacon_held"}
    final = {
        **initial,
        "observation_seq": 1,
        "tick": 10,
        "remaining_ticks": 90,
        "previous_receipt": receipt,
        "frame": {
            **initial["frame"],
            "sha256": "2" * 64,
            "transport_ref": "frame:v2_1",
        },
        "terminal": terminal,
    }
    window = {
        "episode_id": "ep_v2_dispatch",
        "observation_seq": 0,
        "mode": "solo-curriculum-v0",
        "start_tick": 0,
        "duration_ticks": 10,
        "decisions": {
            "participant_0": {
                "disposition": "no_input",
                "action": None,
                "fallback": "neutral",
                "no_input_reason": "missing",
            }
        },
    }
    result = {
        "observations": {"participant_0": final},
        "receipts": {"participant_0": receipt},
        "public_events": [],
        "state_hash": "b" * 64,
        "terminal": terminal,
    }
    ledger = ReplayLedger(config, canonical_sha256(config), package.package_sha256)
    ledger.record_initial(observations={"participant_0": initial}, state_hash="a" * 64)
    ledger.record_step(decision_window=window, result=result)
    return ledger.seal(final_terminal=terminal, final_state_hash="b" * 64)


def test_v2_contracts_require_explicit_version_and_runtime_capability(
    registry: EmbodimentProtocolRegistry,
) -> None:
    with pytest.raises(ValueError, match="implemented before reset"):
        EpisodeConfig(
            episode_id="ep_v2_disabled",
            mode="solo-curriculum-v0",
            task_id="movement-maze-v0",
            seed=1,
            protocol_version=V2,
            observation_profile="hybrid-visible-v1",
        )
    config = v2_config()
    registry.package(V2).validate("episode-config", config.as_dict())
    action = ControllerAction(
        episode_id=config.episode_id,
        observation_seq=0,
        action_id="maze_forward",
        control=ControllerState(0, 1000, 0, 0, 10),
        protocol_version=V2,
    )
    registry.package(V2).validate("controller-action", action.as_dict())
    with pytest.raises(ProtocolValidationError):
        registry.package(V1).validate("controller-action", action.as_dict())
    with pytest.raises(ValueError, match="autonomous_task"):
        ControllerAction(
            episode_id=config.episode_id,
            observation_seq=0,
            action_id="invalid_v2_autonomous",
            control=ControllerState(
                0, 0, 0, 0, 10, autonomous_task="gather_materials"
            ),
            protocol_version=V2,
        )


def test_v1_contract_defaults_remain_exact() -> None:
    config = EpisodeConfig(
        episode_id="ep_v1_default",
        mode="solo-curriculum-v0",
        task_id="orientation-v0",
        seed=3,
    )
    action = ControllerAction(
        episode_id=config.episode_id,
        observation_seq=0,
        action_id="forward",
        control=ControllerState(0, 1000, 0, 0, 10),
    )
    assert config.as_dict()["protocol_version"] == V1
    assert action.as_dict()["protocol_version"] == V1

    positional = EpisodeConfig(
        "ep_v1_positional",
        "solo-curriculum-v0",
        "orientation-v0",
        4,
        "text-visible-v1",
        "step-locked-v1",
        100,
        ("participant_0",),
    )
    assert positional.protocol_version == V1

    # The original constructor delegated task vocabulary to runtime capabilities and the frozen
    # package schema. Keep that behavior exact even though the v1 package later rejects this wire.
    legacy_custom = EpisodeConfig(
        episode_id="ep_v1_custom_capability",
        mode="solo-curriculum-v0",
        task_id="legacy-custom-v0",
        seed=5,
        capability_status=CapabilityStatus(implemented_tasks=("legacy-custom-v0",)),
    )
    assert legacy_custom.task_id == "legacy-custom-v0"


def test_v2_replay_is_constructed_and_selected_by_version_and_hash(
    registry: EmbodimentProtocolRegistry,
) -> None:
    replay = v2_replay(registry)
    verified = verify_replay_bytes(replay, registry=registry)
    assert verified["protocol_version"] == V2
    assert verified["config"]["task_id"] == "movement-maze-v0"
    verify_replay_bytes(replay, package=registry.package(V2))
    with pytest.raises(ReplayValidationError, match="identity"):
        verify_replay_bytes(replay)
    with pytest.raises(ReplayValidationError, match="schema validation"):
        verify_replay_bytes(replay, package=registry.package(V1))


def test_registry_rejects_mismatched_and_unknown_replay_identities(
    registry: EmbodimentProtocolRegistry,
) -> None:
    replay = json.loads(v2_replay(registry))
    replay["protocol_package_sha256"] = registry.package(V1).package_sha256
    body = {key: value for key, value in replay.items() if key != "ledger_sha256"}
    replay["ledger_sha256"] = canonical_sha256(body)
    with pytest.raises(ReplayValidationError, match="registry selection"):
        verify_replay_bytes(canonical_json_bytes(replay), registry=registry)

    replay["protocol_version"] = "llm-controller/9.9.9"
    replay["config"]["protocol_version"] = "llm-controller/9.9.9"
    replay["config_sha256"] = canonical_sha256(replay["config"])
    body = {key: value for key, value in replay.items() if key != "ledger_sha256"}
    replay["ledger_sha256"] = canonical_sha256(body)
    with pytest.raises(ReplayValidationError, match="registry selection"):
        verify_replay_bytes(canonical_json_bytes(replay), registry=registry)


def test_managed_launch_selection_validates_config_version_and_hash(
    registry: EmbodimentProtocolRegistry,
) -> None:
    config = v2_config().as_dict()
    selected = registry.package_for_launch(config, registry.package(V2).package_sha256)
    assert selected.PROTOCOL_VERSION == V2
    with pytest.raises(ProtocolValidationError, match="hash does not match"):
        registry.package_for_launch(config, registry.package(V1).package_sha256)
    with pytest.raises(ProtocolValidationError, match="task_id"):
        registry.package_for_launch(
            {**config, "protocol_version": V1}, registry.package(V1).package_sha256
        )


@pytest.mark.asyncio
async def test_managed_session_factory_dispatches_launch_through_registry(
    registry: EmbodimentProtocolRegistry,
) -> None:
    config = v2_config()
    config_value = config.as_dict()
    package = registry.package(V2)
    launch = ManagedLaunchSpec(
        episode_id=config.episode_id,
        attachment_ticket="a" * 43,
        connection_id="v2-dispatch",
        gateway_url="ws://127.0.0.1:1/internal",
        config=config_value,
        config_sha256=canonical_sha256(config_value),
        protocol_package_sha256=package.package_sha256,
        session_secret=bytearray(b"x" * 32),
    )
    socket_future = asyncio.get_running_loop().create_future()
    session = ManagedWorldArenaSession.from_protocol_registry(
        config=config,
        launcher=ManagedProcessLauncher(
            executable=ROOT / "unused-godot",
            project_path=ROOT / "godot",
            protocol_registry=registry,
        ),
        launch_spec=launch,
        socket_future=socket_future,
        protocol_registry=registry,
    )
    assert session.protocol_version == V2


def test_offline_bundle_verifier_dispatches_v2_through_registry(
    registry: EmbodimentProtocolRegistry,
) -> None:
    replay = v2_replay(registry)
    protected = EpisodeArtifactBundle.create(
        PROTECTED_LAYER,
        (EpisodeArtifact("authority_replay", "application/json", replay),),
    )
    verified = verify_offline_replay(protected.bundle_bytes, registry=registry)
    assert verified["protocol_version"] == V2


@pytest.mark.asyncio
async def test_v2_godot_replay_uses_the_versioned_hash_bound_cli(
    registry: EmbodimentProtocolRegistry, monkeypatch: pytest.MonkeyPatch
) -> None:
    replay = v2_replay(registry)
    protected = EpisodeArtifactBundle.create(
        PROTECTED_LAYER,
        (EpisodeArtifact("authority_replay", "application/json", replay),),
    )
    seen: dict[str, object] = {}

    class Process:
        returncode = 0

        async def communicate(self, stdin: bytes | None) -> tuple[bytes, None]:
            seen["stdin"] = stdin
            replay_path = Path(seen["command"][-1])
            seen["replay"] = replay_path.read_bytes()
            return (
                b"EMBODIMENT_REPLAY_VERIFIED llm-controller/0.2.0 "
                + b"b" * 64
                + b"\n",
                None,
            )

    async def create_process(*command: str, **options: object) -> Process:
        seen["command"] = command
        seen["options"] = options
        return Process()

    monkeypatch.setattr(asyncio, "create_subprocess_exec", create_process)
    verified = await verify_offline_replay_with_godot(
        protected.bundle_bytes,
        package=registry.package(V2),
        godot_executable=ROOT / "unused-godot",
        project_path=ROOT / "godot",
    )
    command = seen["command"]
    assert isinstance(command, tuple)
    assert "res://scripts/embodiment/v2/replay/embodiment_versioned_replay_cli.gd" in command
    assert seen["stdin"] is None
    assert seen["replay"] == replay
    assert verified["protocol_version"] == V2
