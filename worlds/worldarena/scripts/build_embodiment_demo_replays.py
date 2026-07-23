#!/usr/bin/env python3
"""Generate sealed hybrid Stage-C and paired-duel replays through managed Godot."""

from __future__ import annotations

import argparse
import asyncio
import json
import secrets
import socket
import sys
from pathlib import Path

import uvicorn
from fastapi import FastAPI, WebSocket
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
sys.path.insert(0, str(ROOT / "backend"))

from genesis_arena.embodiment.contracts import (  # noqa: E402
    CapabilityStatus,
    ControllerAction,
    ControllerButtons,
    ControllerState,
    DecisionWindow,
    EpisodeConfig,
    ParticipantDecision,
)
from genesis_arena.embodiment.golden import load_golden_transcript  # noqa: E402
from genesis_arena.embodiment.managed_process import (  # noqa: E402
    ManagedLaunchSpec,
    ManagedProcessLauncher,
)
from genesis_arena.embodiment.managed_session import ManagedWorldArenaSession  # noqa: E402
from genesis_arena.embodiment.protocol import (  # noqa: E402
    EmbodimentProtocolPackage,
    canonical_sha256,
)
from genesis_arena.embodiment.replay import verify_replay_bytes  # noqa: E402
from genesis_arena.embodiment.transport import ManagedWebSocketEndpoint  # noqa: E402


def _window_from_dict(value: dict[str, object]) -> DecisionWindow:
    decisions: dict[str, ParticipantDecision] = {}
    for participant_id, raw_decision in value["decisions"].items():  # type: ignore[union-attr]
        decision = raw_decision  # type: ignore[assignment]
        action_value = decision["action"]
        if action_value is None:
            decisions[participant_id] = ParticipantDecision.no_input(decision["no_input_reason"])
            continue
        control = action_value["control"]
        decisions[participant_id] = ParticipantDecision(
            "accepted",
            ControllerAction(
                episode_id=action_value["episode_id"],
                observation_seq=action_value["observation_seq"],
                action_id=action_value["action_id"],
                control=ControllerState(
                    control["move_x"],
                    control["move_y"],
                    control["look_x"],
                    control["look_y"],
                    control["duration_ticks"],
                    ControllerButtons(**control["buttons"]),
                ),
                intent_label=action_value["intent_label"],
                memory_update=action_value["memory_update"],
            ),
        )
    return DecisionWindow(
        episode_id=value["episode_id"],  # type: ignore[arg-type]
        observation_seq=value["observation_seq"],  # type: ignore[arg-type]
        mode=value["mode"],  # type: ignore[arg-type]
        start_tick=value["start_tick"],  # type: ignore[arg-type]
        duration_ticks=value["duration_ticks"],  # type: ignore[arg-type]
        decisions=decisions,
    )


class _ManagedReplayFactory:
    def __init__(self, *, godot: Path) -> None:
        self.godot = godot
        self.endpoint = ManagedWebSocketEndpoint()
        self.package = EmbodimentProtocolPackage.from_repository(ROOT)
        self.app = FastAPI()
        self.listener: socket.socket | None = None
        self.server: uvicorn.Server | None = None
        self.server_task: asyncio.Task[None] | None = None
        self.port = 0
        self.tickets: list[str] = []

        @self.app.websocket("/ws/embodiment/{ticket}")
        async def attach(ticket: str, websocket: WebSocket) -> None:
            await self.endpoint.handle(ticket, websocket)

    async def start(self) -> None:
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(128)
        listener.setblocking(False)
        self.listener = listener
        self.port = listener.getsockname()[1]
        self.server = uvicorn.Server(
            uvicorn.Config(self.app, log_level="error", lifespan="off", loop="asyncio")
        )
        self.server_task = asyncio.create_task(self.server.serve(sockets=[listener]))
        while not self.server.started:
            if self.server_task.done():
                await self.server_task
            await asyncio.sleep(0)

    async def close(self) -> None:
        for ticket in self.tickets:
            self.endpoint.cancel(ticket)
        if self.server is not None:
            self.server.should_exit = True
        if self.server_task is not None:
            try:
                await asyncio.wait_for(asyncio.shield(self.server_task), 10)
            except asyncio.TimeoutError:
                assert self.server is not None
                self.server.force_exit = True
                await asyncio.wait_for(self.server_task, 5)
        if self.listener is not None:
            self.listener.close()

    def session(self, config: EpisodeConfig) -> ManagedWorldArenaSession:
        value = config.as_dict()
        ticket = secrets.token_urlsafe(32)
        secret = bytearray(secrets.token_bytes(32))
        connection_id = f"movie_{secrets.token_hex(8)}"
        self.tickets.append(ticket)
        future = self.endpoint.register(
            ticket=ticket,
            episode_id=config.episode_id,
            connection_id=connection_id,
            session_secret=bytearray(secret),
        )
        launch = ManagedLaunchSpec(
            episode_id=config.episode_id,
            attachment_ticket=ticket,
            connection_id=connection_id,
            gateway_url=f"ws://127.0.0.1:{self.port}/ws/embodiment/{ticket}",
            config=value,
            config_sha256=canonical_sha256(value),
            protocol_package_sha256=self.package.package_sha256,
            session_secret=secret,
        )
        return ManagedWorldArenaSession(
            config=config,
            launcher=ManagedProcessLauncher(executable=self.godot, project_path=ROOT / "godot"),
            launch_spec=launch,
            socket_future=future,
            protocol_package=self.package,
            attachment_timeout_s=20,
            step_timeout_s=20,
        )


def _capabilities() -> CapabilityStatus:
    return CapabilityStatus(
        implemented_modes=("solo-curriculum-v0", "scripted-duel-v0", "model-duel-v0"),
        implemented_observation_profiles=("hybrid-visible-v1",),
        implemented_tasks=(
            "orientation-v0",
            "interaction-v0",
            "construction-v0",
            "neutral-encounter-v0",
            "central-relay-v0",
        ),
    )


async def _stage_c(factory: _ManagedReplayFactory) -> bytes:
    transcript = load_golden_transcript(
        ROOT / "game/embodiment_protocol/golden/stage-c-construction-v1.json",
        package=factory.package,
    )
    config_value = transcript["config"]
    config = EpisodeConfig(
        episode_id=config_value["episode_id"],
        mode="solo-curriculum-v0",
        task_id="construction-v0",
        seed=config_value["seed"],
        observation_profile="hybrid-visible-v1",
        timing_track="step-locked-v1",
        maximum_episode_ticks=config_value["maximum_episode_ticks"],
        participant_ids=("participant_0",),
        capability_status=_capabilities(),
    )
    session = factory.session(config)
    try:
        observations = await session.reset()
        await _consume_boundary_frames(session, observations)
        result = None
        for expected in transcript["steps"]:
            result = await session.step(_window_from_dict(expected["decision_window"]))
            await _consume_boundary_frames(session, result.observations)
        if result is None or not result.terminal.ended:
            raise RuntimeError("Stage-C replay did not terminate")
        payload = session.replay_bytes
        verify_replay_bytes(payload, package=factory.package)
        return payload
    finally:
        await session.close()


def _duel_window(episode_id: str, observation_seq: int, winning_seat: str) -> DecisionWindow:
    decisions: dict[str, ParticipantDecision] = {}
    for participant_id in ("participant_0", "participant_1"):
        move_y = 1000 if participant_id == winning_seat and observation_seq < 3 else 0
        decisions[participant_id] = ParticipantDecision(
            "accepted",
            ControllerAction(
                episode_id=episode_id,
                observation_seq=observation_seq,
                action_id=f"{participant_id}_{observation_seq}",
                control=ControllerState(0, move_y, 0, 0, 10),
                intent_label="Approach or hold central relay.",
                memory_update="paired replay plan",
            ),
        )
    return DecisionWindow(
        episode_id=episode_id,
        observation_seq=observation_seq,
        mode="model-duel-v0",
        start_tick=observation_seq * 10,
        duration_ticks=10,
        decisions=decisions,
    )


async def _duel_leg(
    factory: _ManagedReplayFactory, *, episode_id: str, winning_seat: str
) -> bytes:
    config = EpisodeConfig(
        episode_id=episode_id,
        mode="model-duel-v0",
        task_id="central-relay-v0",
        seed=17,
        observation_profile="hybrid-visible-v1",
        timing_track="step-locked-v1",
        maximum_episode_ticks=1800,
        participant_ids=("participant_0", "participant_1"),
        capability_status=_capabilities(),
    )
    session = factory.session(config)
    try:
        observations = await session.reset()
        await _consume_boundary_frames(session, observations)
        result = None
        for observation_seq in range(13):
            result = await session.step(_duel_window(episode_id, observation_seq, winning_seat))
            await _consume_boundary_frames(session, result.observations)
            if result.terminal.ended:
                break
        if result is None or result.terminal.outcome != "win":
            raise RuntimeError(f"duel replay did not produce a win: {episode_id}")
        payload = session.replay_bytes
        verify_replay_bytes(payload, package=factory.package)
        return payload
    finally:
        await session.close()


async def _consume_boundary_frames(
    session: ManagedWorldArenaSession, observations: object
) -> None:
    for participant_id, observation in observations.items():  # type: ignore[union-attr]
        frame = observation["frame"]
        await session.render(
            participant_id,
            frame["sensor_id"],
            frame["transport_ref"],
            observation["observation_seq"],
        )


async def _async_main(args: argparse.Namespace) -> int:
    args.output_dir.mkdir(parents=True, exist_ok=True)
    factory = _ManagedReplayFactory(godot=args.godot)
    await factory.start()
    try:
        replays = {
            "stage-c.replay.json": await _stage_c(factory),
            "duel-leg-a.replay.json": await _duel_leg(
                factory, episode_id="ep_native_demo_duel_leg_a", winning_seat="participant_0"
            ),
            "duel-leg-b.replay.json": await _duel_leg(
                factory, episode_id="ep_native_demo_duel_leg_b", winning_seat="participant_1"
            ),
        }
        for name, payload in replays.items():
            (args.output_dir / name).write_bytes(payload)
        print(
            json.dumps(
                {"output_dir": str(args.output_dir.resolve()), "replays": sorted(replays)}
            )
        )
        return 0
    finally:
        await factory.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument(
        "--godot", type=Path, default=Path("/Applications/Godot.app/Contents/MacOS/Godot")
    )
    args = parser.parse_args()
    if not args.godot.is_file():
        raise FileNotFoundError(args.godot)
    return asyncio.run(_async_main(args))


if __name__ == "__main__":
    sys.exit(main())
