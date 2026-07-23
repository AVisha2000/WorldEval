#!/usr/bin/env python3
"""Run verified managed hybrid-solo episodes for selected live providers.

All three providers remain the default certification set. ``--provider`` supports a bounded
single-provider pilot without weakening the final three-provider evidence validator.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import os
import socket
import time
from pathlib import Path
from typing import Any, Mapping

import uvicorn
from fastapi import FastAPI, WebSocket
from genesis_arena.embodiment.artifacts import (
    EpisodeArtifactBundle,
    verify_offline_replay,
    verify_offline_replay_with_godot,
)
from genesis_arena.embodiment.live_runtime import default_episode_service
from genesis_arena.embodiment.protocol import (
    EmbodimentProtocolPackage,
    canonical_json_bytes,
    strict_json_loads,
)
from genesis_arena.embodiment.transport import ManagedWebSocketEndpoint

ROOT = Path(__file__).resolve().parents[1]
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
PROVIDERS = ("openai", "anthropic", "gemini")
REPORT_FORMAT = "llm-controller/live-provider-managed-solo/1.0.0"
_KEY_ENV = {
    "openai": ("WORLDARENA_OPENAI_API_KEY", "OPENAI_API_KEY"),
    "anthropic": ("WORLDARENA_ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY"),
    "gemini": (
        "WORLDARENA_GEMINI_API_KEY",
        "GEMINI_API_KEY",
        "GOOGLE_API_KEY",
    ),
}
_MODEL_ENV = {
    "openai": "WORLDARENA_OPENAI_MODEL",
    "anthropic": "WORLDARENA_ANTHROPIC_MODEL",
    "gemini": "WORLDARENA_GEMINI_MODEL",
}


def _first_environment(names: tuple[str, ...]) -> str | None:
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    return None


def pilot_preflight(
    models: Mapping[str, str | None], providers: tuple[str, ...] = PROVIDERS
) -> tuple[str, ...]:
    missing: list[str] = []
    if not GODOT.is_file():
        missing.append("pinned Godot executable")
    for provider in providers:
        if _first_environment(_KEY_ENV[provider]) is None:
            missing.append("/".join(_KEY_ENV[provider]))
        if not models.get(provider):
            missing.append(_MODEL_ENV[provider])
    return tuple(missing)


class _Gateway:
    def __init__(self) -> None:
        self.endpoint = ManagedWebSocketEndpoint()
        self.app = FastAPI()
        self.listener: socket.socket | None = None
        self.server: uvicorn.Server | None = None
        self.task: asyncio.Task[None] | None = None
        self.port = 0

        @self.app.websocket("/ws/embodiment/{ticket}")
        async def attach(ticket: str, websocket: WebSocket) -> None:
            await self.endpoint.handle(ticket, websocket)

    async def __aenter__(self) -> _Gateway:
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(128)
        listener.setblocking(False)
        self.listener = listener
        self.port = int(listener.getsockname()[1])
        self.server = uvicorn.Server(
            uvicorn.Config(self.app, log_level="critical", lifespan="off", access_log=False)
        )
        self.task = asyncio.create_task(self.server.serve(sockets=[listener]))
        while not self.server.started:
            if self.task.done():
                raise RuntimeError("local managed gateway failed to start")
            await asyncio.sleep(0)
        return self

    async def __aexit__(self, *_: object) -> None:
        if self.server is not None:
            self.server.should_exit = True
        if self.task is not None:
            try:
                await asyncio.wait_for(self.task, 10)
            except asyncio.TimeoutError:
                assert self.server is not None
                self.server.force_exit = True
                await asyncio.wait_for(self.task, 5)
        if self.listener is not None:
            self.listener.close()


async def _wait_for_terminal(service: Any, episode_id: str, timeout_s: float) -> Mapping[str, Any]:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        status = await service.status(episode_id)
        if status["state"] in ("completed", "failed", "cancelled"):
            return await service.result(episode_id)
        await asyncio.sleep(0.25)
    await service.cancel(episode_id)
    raise RuntimeError("managed provider episode exceeded the pilot timeout")


def _accepted_actions(replay: Mapping[str, Any]) -> int:
    accepted = 0
    for step in replay["steps"]:
        decisions = step["decision_window"]["decisions"]
        for decision in decisions.values():
            if decision.get("disposition") == "accepted" and decision.get("action") is not None:
                accepted += 1
    return accepted


async def _run_provider(
    gateway: _Gateway,
    *,
    provider: str,
    model: str,
    api_key: str,
    seed: int,
    task_id: str,
    output_dir: Path,
    timeout_s: float,
) -> dict[str, Any]:
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    service = default_episode_service(
        repository_root=ROOT,
        godot_executable=GODOT,
        godot_project_path=ROOT / "godot",
        gateway_port=gateway.port,
        endpoint=gateway.endpoint,
        provider_timeout_s=min(timeout_s, 45.0),
    )
    try:
        created = await service.create(
            provider=provider,
            model=model,
            task_id=task_id,
            seed=seed,
            api_key=api_key,
            maximum_episode_ticks=600,
            observation_profile="hybrid-visible-v1",
        )
        episode_id = str(created["episode_id"])
        result = await _wait_for_terminal(service, episode_id, timeout_s)
        outcome = result.get("result")
        if result.get("state") != "completed" or not isinstance(outcome, Mapping):
            raise RuntimeError(f"{provider} managed episode did not complete")
        terminal = outcome.get("terminal")
        if (
            not isinstance(terminal, Mapping)
            or terminal.get("outcome") != "success"
            or outcome.get("provider_failures") != 0
        ):
            raise RuntimeError(f"{provider} managed episode is not certifiable")
        protected = await service.protected_bundle(episode_id)
        verified = verify_offline_replay(protected.bundle_bytes, package=package)
        await verify_offline_replay_with_godot(
            protected.bundle_bytes,
            package=package,
            godot_executable=GODOT,
            project_path=ROOT / "godot",
        )
        bundle = EpisodeArtifactBundle.verify(protected.bundle_bytes)
        replay_bytes = bundle.read("authority_replay")
        telemetry = strict_json_loads(bundle.read("telemetry"))
        if not isinstance(telemetry, list):
            raise RuntimeError("protected provider telemetry is invalid")
        replay_dir = output_dir / "replays"
        replay_dir.mkdir(parents=True, exist_ok=True)
        replay_path = replay_dir / f"{provider}.replay.json"
        replay_path.write_bytes(replay_bytes)
        replay_sha = hashlib.sha256(replay_bytes).hexdigest()
        windows = int(outcome["windows"])
        return {
            "accepted_provider_actions": _accepted_actions(verified),
            "episode_id": episode_id,
            "final_state_hash": str(outcome["final_state_hash"]),
            "managed_process": True,
            "mode": "solo-curriculum-v0",
            "model": model,
            "observation_profile": "hybrid-visible-v1",
            "provider": provider,
            "provider_calls": len(telemetry),
            "provider_failures": 0,
            "replay_path": replay_path.relative_to(output_dir).as_posix(),
            "replay_sha256": replay_sha,
            "replay_verified": True,
            "task_id": task_id,
            "terminal_outcome": "success",
            "windows": windows,
        }
    finally:
        await service.aclose()


async def run_pilot(arguments: argparse.Namespace) -> Path:
    output_dir = arguments.output_dir.resolve()
    selected_providers = tuple(arguments.provider or PROVIDERS)
    models = {
        provider: getattr(arguments, f"{provider}_model") or os.environ.get(_MODEL_ENV[provider])
        for provider in PROVIDERS
    }
    missing = pilot_preflight(models, selected_providers)
    if missing:
        raise RuntimeError("missing pilot prerequisites: " + ", ".join(missing))
    output_dir.mkdir(parents=True, exist_ok=True)
    episodes = []
    async with _Gateway() as gateway:
        for index, provider in enumerate(selected_providers):
            key = _first_environment(_KEY_ENV[provider])
            assert key is not None and models[provider] is not None
            episodes.append(
                await _run_provider(
                    gateway,
                    provider=provider,
                    model=models[provider],
                    api_key=key,
                    seed=arguments.seed + index,
                    task_id=arguments.task_id,
                    output_dir=output_dir,
                    timeout_s=arguments.timeout,
                )
            )
            key = None
    report_path = output_dir / "live-provider-report.json"
    report_path.write_bytes(canonical_json_bytes({"episodes": episodes, "format": REPORT_FORMAT}))
    return report_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "exports/embodiment-pilot")
    parser.add_argument("--task-id", default="orientation-v0")
    parser.add_argument("--seed", type=int, default=20260720)
    parser.add_argument("--timeout", type=float, default=900.0)
    parser.add_argument(
        "--provider",
        action="append",
        choices=PROVIDERS,
        help="Provider to run; repeat for multiple providers. Defaults to all three.",
    )
    for provider in PROVIDERS:
        parser.add_argument(f"--{provider}-model")
    parser.add_argument("--preflight", action="store_true")
    arguments = parser.parse_args()
    models = {
        provider: getattr(arguments, f"{provider}_model") or os.environ.get(_MODEL_ENV[provider])
        for provider in PROVIDERS
    }
    selected_providers = tuple(arguments.provider or PROVIDERS)
    missing = pilot_preflight(models, selected_providers)
    if arguments.preflight:
        if missing:
            print("PILOT_NOT_READY " + ",".join(missing))
            return 2
        print("PILOT_READY")
        return 0
    try:
        report = asyncio.run(run_pilot(arguments))
    except (OSError, RuntimeError, TypeError, ValueError) as error:
        parser.error(str(error))
    print(f"LIVE_PROVIDER_PILOT_OK report={report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
