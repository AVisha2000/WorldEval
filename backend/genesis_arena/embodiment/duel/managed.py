"""Independent replay verification for one managed Godot duel leg."""

from __future__ import annotations

import asyncio
import hashlib
import tempfile
from pathlib import Path
from typing import Any, Callable, Mapping

from ..contracts import DecisionWindow, MultiParticipantStepResult
from ..managed_session import ManagedWorldArenaSession
from ..protocol import EmbodimentProtocolPackage, strict_json_loads
from ..replay import verify_replay_bytes
from .contracts import DuelLegPlan, DuelLegVerification


class VerifiedManagedDuelSession:
    """Add pinned-Godot genesis verification to a managed authority session.

    The live process and the verifier are distinct Godot processes. A leg is eligible for paired
    aggregation only after both Python and the independent Godot verifier accept the sealed replay.
    """

    def __init__(
        self,
        session: ManagedWorldArenaSession,
        *,
        protocol_package: EmbodimentProtocolPackage,
        godot_executable: Path,
        project_path: Path,
        verification_timeout_s: float = 20.0,
        on_close: Callable[[], None] | None = None,
    ) -> None:
        if not isinstance(session, ManagedWorldArenaSession):
            raise TypeError("session must be ManagedWorldArenaSession")
        if not isinstance(protocol_package, EmbodimentProtocolPackage):
            raise TypeError("protocol_package must be EmbodimentProtocolPackage")
        if verification_timeout_s <= 0:
            raise ValueError("verification_timeout_s must be positive")
        self._session = session
        self._package = protocol_package
        self._godot_executable = Path(godot_executable)
        self._project_path = Path(project_path)
        self._verification_timeout_s = float(verification_timeout_s)
        self._verified_replay_bytes: bytes | None = None
        self._on_close = on_close

    async def reset(self) -> Mapping[str, Mapping[str, Any]]:
        return await self._session.reset()

    async def step(self, window: DecisionWindow) -> MultiParticipantStepResult:
        return await self._session.step(window)

    async def render(
        self,
        participant_id: str,
        sensor_id: str,
        transport_ref: str,
        observation_seq: int,
    ) -> bytes:
        return await self._session.render(participant_id, sensor_id, transport_ref, observation_seq)

    async def verify_leg(self, plan: DuelLegPlan) -> DuelLegVerification:
        if not isinstance(plan, DuelLegPlan):
            raise TypeError("plan must be DuelLegPlan")
        replay_bytes = self._session.replay_bytes
        replay = verify_replay_bytes(replay_bytes, package=self._package)
        if replay["config"]["episode_id"] != plan.episode_id:
            raise ValueError("replay belongs to a different duel leg")
        seal = await self._verify_with_godot(replay_bytes)
        if (
            seal.get("episode_id") != plan.episode_id
            or seal.get("final_state_hash") != replay["final_state_hash"]
        ):
            raise ValueError("Godot replay seal differs from Python verification")
        terminal = replay["final_terminal"]
        winner = _winner_participant(replay)
        if terminal["outcome"] == "win":
            outcome = "win"
        elif terminal["outcome"] == "draw":
            outcome = "draw"
        else:
            outcome = "void"
            winner = None
        verification = DuelLegVerification(
            plan_sha256=plan.plan_sha256,
            replay_sha256=hashlib.sha256(replay_bytes).hexdigest(),
            terminal_state_sha256=replay["final_state_hash"],
            complete=bool(terminal["ended"]),
            verified=True,
            outcome=outcome,
            winner_participant_id=winner,
        )
        self._verified_replay_bytes = replay_bytes
        return verification

    def take_verified_replay_bytes(self) -> bytes | None:
        replay = self._verified_replay_bytes
        self._verified_replay_bytes = None
        return replay

    async def close(self) -> None:
        try:
            await self._session.close()
        finally:
            if self._on_close is not None:
                callback = self._on_close
                self._on_close = None
                callback()

    async def _verify_with_godot(self, replay: bytes) -> Mapping[str, Any]:
        v2 = self._package.PROTOCOL_VERSION == "llm-controller/0.2.0"
        replay_path: Path | None = None
        command = [
            str(self._godot_executable),
            "--no-header",
            "--headless",
            "--audio-driver",
            "Dummy",
            "--path",
            str(self._project_path),
            "--script",
        ]
        if v2:
            temporary = tempfile.NamedTemporaryFile(
                mode="wb", prefix="worldarena-duo-replay-", suffix=".json", delete=False
            )
            try:
                temporary.write(replay)
                temporary.flush()
            finally:
                temporary.close()
            replay_path = Path(temporary.name)
            command.extend(
                (
                    "res://scripts/embodiment/v2/replay/embodiment_versioned_replay_cli.gd",
                    "--",
                    str(replay_path),
                )
            )
        else:
            command.append("res://scripts/embodiment/replay/embodiment_replay_cli.gd")
        process = await asyncio.create_subprocess_exec(
            *command,
            stdin=None if v2 else asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        try:
            output, _ = await asyncio.wait_for(
                process.communicate(None if v2 else replay), self._verification_timeout_s
            )
        except asyncio.TimeoutError:
            process.kill()
            await process.wait()
            raise RuntimeError("duel Godot replay verification timed out") from None
        finally:
            if replay_path is not None:
                replay_path.unlink(missing_ok=True)
        if process.returncode != 0:
            raise RuntimeError("duel Godot replay verification failed")
        lines = output.strip().splitlines()
        if not lines:
            raise RuntimeError("duel Godot replay verifier emitted no seal")
        if v2:
            replay_value = verify_replay_bytes(replay, package=self._package)
            expected = (
                f"EMBODIMENT_REPLAY_VERIFIED {self._package.PROTOCOL_VERSION} "
                f"{replay_value['final_state_hash']}"
            ).encode()
            if lines[-1] != expected:
                raise RuntimeError("duel Godot replay verifier emitted an invalid seal")
            return {
                "episode_id": replay_value["config"]["episode_id"],
                "final_state_hash": replay_value["final_state_hash"],
            }
        seal = strict_json_loads(lines[-1])
        if not isinstance(seal, dict) or seal.get("kind") != "embodiment_replay_verified":
            raise RuntimeError("duel Godot replay verifier emitted an invalid seal")
        return seal


def _winner_participant(replay: Mapping[str, Any]) -> str | None:
    winners = set()
    for step in replay["steps"]:
        for event in step["result"]["public_events"]:
            if event.get("kind") == "episode_won":
                winner = event.get("data", {}).get("winner")
                if winner in ("participant_0", "participant_1"):
                    winners.add(winner)
            elif event.get("kind") == "duo_game_completed":
                winner = event.get("data", {}).get("winner_id")
                if winner in ("participant_0", "participant_1"):
                    winners.add(winner)
    if len(winners) > 1:
        raise ValueError("replay contains multiple winner events")
    return next(iter(winners)) if winners else None


__all__ = ["VerifiedManagedDuelSession"]
