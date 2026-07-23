"""Production assembly for one credential-safe managed hybrid solo episode."""

from __future__ import annotations

import asyncio
import secrets
from pathlib import Path
from typing import Any, Awaitable, Callable

import httpx

from .construction_task_provider import ConstructionTaskProvider
from .contracts import CapabilityStatus, EpisodeConfig
from .control_games.movement_maze_demo import (
    MOVEMENT_MAZE_SCENARIO_ID,
    movement_maze_demo_behavior,
)
from .control_games.operator_action_course_demo import (
    OPERATOR_ACTION_COURSE_SCENARIO_ID,
    operator_action_course_demo_behavior,
)
from .credentials import SessionCredential
from .demo_provider import DemoPolicyLock, DemoProvider
from .demo_scenarios import demo_scenario_fixture_bytes
from .episode_service import (
    DEMO_PROVIDER,
    EpisodeRunSpec,
    EpisodeService,
)
from .live_solo import LiveSoloOutcome, LiveSoloRunner
from .managed_process import ManagedLaunchSpec, ManagedProcessLauncher
from .managed_session import ManagedWorldArenaSession
from .presentation.preview_ingress import InternalParticipantPreviewIngress
from .protocol import canonical_sha256
from .protocol_registry import EmbodimentProtocolRegistry
from .providers.anthropic_adapter import AnthropicAdapter, AnthropicHTTPResponse
from .providers.gemini_adapter import GeminiAdapter, GeminiHTTPResponse
from .providers.openai_adapter import OpenAIProviderAdapter
from .replay_archive import SavedReplayArchive
from .scripted_construction_demo import (
    SCRIPTED_CONSTRUCTION_PROVIDER,
    ScriptedConstructionDemoProvider,
    demo_task_timeout_ticks,
)
from .scripted_solo_demo import SCRIPTED_SOLO_TASKS, ScriptedSoloDemoProvider
from .transport import ManagedWebSocketEndpoint

SYSTEM_PROMPT = """You control one WorldArena participant. Use only the supplied player-visible
observation, participant camera frame, and episode scratchpad. Return exactly one JSON object that
matches the action schema. Never infer spectator or hidden authority state."""


def default_episode_service(
    *,
    repository_root: Path,
    godot_executable: Path,
    godot_project_path: Path,
    gateway_port: int,
    endpoint: ManagedWebSocketEndpoint,
    preview_ingress: InternalParticipantPreviewIngress | None = None,
    provider_timeout_s: float = 45.0,
    runs_dir: Path | None = None,
    ffmpeg_executable: Path | None = None,
) -> EpisodeService:
    """Assemble the production executor without persisting credentials or evidence."""

    root = Path(repository_root)
    registry = EmbodimentProtocolRegistry.from_repository(root)
    launcher = ManagedProcessLauncher(
        executable=godot_executable,
        project_path=godot_project_path,
        protocol_registry=registry,
    )
    ingress = preview_ingress or InternalParticipantPreviewIngress()
    service: EpisodeService

    async def execute(
        spec: EpisodeRunSpec,
        credential: SessionCredential | None,
        cancel_event: asyncio.Event,
        publish_frame: Callable[[str, int, bytes], Awaitable[None]],
        publish_progress: Callable[[int, int], Awaitable[None]],
    ) -> LiveSoloOutcome:
        package = registry.package(spec.protocol_version)
        control_validation = spec.task_id in (
            MOVEMENT_MAZE_SCENARIO_ID,
            OPERATOR_ACTION_COURSE_SCENARIO_ID,
        )
        config = EpisodeConfig(
            episode_id=spec.episode_id,
            mode="solo-curriculum-v0",
            task_id=spec.task_id,
            seed=spec.seed,
            observation_profile=spec.observation_profile,
            maximum_episode_ticks=spec.maximum_episode_ticks,
            participant_ids=("participant_0",),
            capability_status=CapabilityStatus(
                implemented_observation_profiles=("hybrid-visible-v1",),
                implemented_tasks=(spec.task_id,),
                certified_modes=(),
                certified_observation_profiles=(),
                scored_observation_profiles=(),
            ),
            protocol_version=spec.protocol_version,
        )
        config_value = config.as_dict()
        ticket = secrets.token_urlsafe(32)
        connection_id = f"connection_{secrets.token_hex(12)}"
        session_secret = bytearray(secrets.token_bytes(32))
        socket_future = endpoint.register(
            ticket=ticket,
            episode_id=spec.episode_id,
            connection_id=connection_id,
            session_secret=bytearray(session_secret),
            protocol_version=spec.protocol_version,
        )
        preview_registered = False

        async def publish_direct_preview(
            participant_id: str, observation_seq: int, png: bytes
        ) -> bool:
            return await service.publish_live_preview(
                spec.episode_id, participant_id, observation_seq, png
            )

        launch = ManagedLaunchSpec(
            episode_id=spec.episode_id,
            attachment_ticket=ticket,
            connection_id=connection_id,
            gateway_url=f"ws://127.0.0.1:{gateway_port}/ws/embodiment/{ticket}",
            config=config_value,
            config_sha256=canonical_sha256(config_value),
            protocol_package_sha256=package.package_sha256,
            session_secret=session_secret,
        )
        session = ManagedWorldArenaSession.from_protocol_registry(
            config=config,
            launcher=launcher,
            launch_spec=launch,
            socket_future=socket_future,
            protocol_registry=registry,
            step_timeout_s=max(10.0, provider_timeout_s),
        )
        adapter: Any | None = None
        try:
            # The ingress keeps only a domain-separated HMAC key.  It never sees the provider
            # credential, canonical decisions, replay, or authority state.
            # Every solo curriculum stage can publish the same signed, participant-filtered
            # local preview.  This best-effort channel is intentionally independent from the
            # authority socket and is registered before any provider is contacted.
            if spec.task_id in SCRIPTED_SOLO_TASKS or control_validation:
                ingress.register(
                    ticket=ticket,
                    episode_id=spec.episode_id,
                    task_id=spec.task_id,
                    session_secret=session_secret,
                    sink=publish_direct_preview,
                )
                preview_registered = True
            if spec.provider in (SCRIPTED_CONSTRUCTION_PROVIDER, DEMO_PROVIDER):
                # Local curriculum demos never receive a credential and remain outside every
                # live-provider/scored path. Construction retains its strict task-plan boundary;
                # the other curriculum stages retain the frozen direct-controller contract.
                provider: Any
                if spec.provider == DEMO_PROVIDER:
                    provider = _demo_provider(spec)
                elif spec.task_id == "construction-v0":
                    provider = ScriptedConstructionDemoProvider()
                else:
                    provider = ScriptedSoloDemoProvider(spec.task_id)
                if spec.task_id == "construction-v0":
                    adapter = ConstructionTaskProvider(
                        provider,
                        package,
                        task_timeout_ticks=demo_task_timeout_ticks,
                    )
                else:
                    adapter = provider
            else:
                if credential is None:
                    raise ValueError("live provider credential is unavailable")
                adapter = provider_adapter(spec.provider, credential)
                if spec.task_id == "construction-v0":
                    adapter = ConstructionTaskProvider(adapter, package)
            return await LiveSoloRunner(
                config=config,
                session=session,
                provider=adapter,
                model=spec.model,
                system_prompt=SYSTEM_PROMPT,
                protocol_package=package,
                provider_timeout_s=provider_timeout_s,
                frame_publisher=publish_frame,
                progress_publisher=publish_progress,
            ).run(cancel_event=cancel_event)
        finally:
            if preview_registered:
                ingress.unregister(ticket)
            endpoint.cancel(ticket)
            if adapter is not None:
                await close_provider_adapter(adapter)

    replay_archive = (
        SavedReplayArchive(
            runs_dir=runs_dir,
            protocol_registry=registry,
            godot_executable=godot_executable,
            godot_project_path=godot_project_path,
            ffmpeg_executable=ffmpeg_executable,
        )
        if runs_dir is not None and ffmpeg_executable is not None
        else None
    )
    service = EpisodeService(execute, replay_archive=replay_archive)
    return service


def provider_adapter(provider: str, credential: SessionCredential) -> Any:
    key = credential.reveal()
    if provider == "openai":
        return OpenAIProviderAdapter(api_key=key)
    if provider == "anthropic":
        return AnthropicAdapter(api_key=key, transport=_anthropic_transport)
    if provider == "gemini":
        return GeminiAdapter(api_key=key, transport=_gemini_transport)
    raise ValueError("unsupported provider")


def _demo_provider(spec: EpisodeRunSpec) -> DemoProvider:
    """Wrap the proven solo fixture behind the bounded provider-neutral Demo adapter."""

    policy_lock = spec.demo_policy_lock
    if not isinstance(policy_lock, DemoPolicyLock):
        raise ValueError("demo policy lock is unavailable")
    if spec.scenario_id is None:
        raise ValueError("demo scenario identity is unavailable")
    fixture = demo_scenario_fixture_bytes(spec.scenario_id)
    behavior = None
    delegate: Any | None = None
    if spec.task_id == MOVEMENT_MAZE_SCENARIO_ID:
        behavior = movement_maze_demo_behavior
    elif spec.task_id == OPERATOR_ACTION_COURSE_SCENARIO_ID:
        behavior = operator_action_course_demo_behavior
    else:
        delegate = (
            ScriptedConstructionDemoProvider(
                showcase=spec.scenario_id == "multi-action-demo-v0"
            )
            if spec.task_id == "construction-v0"
            else ScriptedSoloDemoProvider(spec.task_id)
        )
    return DemoProvider(
        policy_lock,
        behavior=behavior,
        delegate=delegate,
        fixture_bytes=fixture,
    )


async def _anthropic_transport(**request: Any) -> AnthropicHTTPResponse:
    timeout = float(request.pop("timeout"))
    async with httpx.AsyncClient(timeout=timeout) as client:
        response = await client.post(**request)
    return AnthropicHTTPResponse(response.status_code, bytes(response.content), response.headers)


async def _gemini_transport(**request: Any) -> GeminiHTTPResponse:
    timeout = float(request.pop("timeout"))
    async with httpx.AsyncClient(timeout=timeout) as client:
        response = await client.post(**request)
    return GeminiHTTPResponse(response.status_code, _json_object(response), response.headers)


def _json_object(response: httpx.Response) -> dict[str, Any]:
    value = response.json()
    return value if isinstance(value, dict) else {}


async def close_provider_adapter(adapter: Any) -> None:
    close = getattr(adapter, "aclose", None)
    if callable(close):
        value = close()
        if hasattr(value, "__await__"):
            await value
    else:
        client = getattr(adapter, "_client", None)
        close = getattr(client, "close", None)
        if callable(close):
            value = close()
            if hasattr(value, "__await__"):
                await value
        if hasattr(adapter, "_client"):
            adapter._client = None  # noqa: SLF001 - credential-bearing client teardown boundary
    if hasattr(adapter, "_api_key"):
        adapter._api_key = ""  # noqa: SLF001 - explicit local credential teardown boundary


__all__ = [
    "SYSTEM_PROMPT",
    "close_provider_adapter",
    "default_episode_service",
    "provider_adapter",
]
