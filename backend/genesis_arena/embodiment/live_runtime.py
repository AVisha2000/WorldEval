"""Production assembly for one credential-safe managed hybrid solo episode."""

from __future__ import annotations

import asyncio
import secrets
from pathlib import Path
from typing import Any, Awaitable, Callable

import httpx

from .contracts import CapabilityStatus, EpisodeConfig
from .credentials import SessionCredential
from .episode_service import EpisodeRunSpec, EpisodeService
from .live_solo import LiveSoloOutcome, LiveSoloRunner
from .managed_process import ManagedLaunchSpec, ManagedProcessLauncher
from .managed_session import ManagedWorldArenaSession
from .protocol import EmbodimentProtocolPackage, canonical_sha256
from .providers.anthropic_adapter import AnthropicAdapter, AnthropicHTTPResponse
from .providers.gemini_adapter import GeminiAdapter, GeminiHTTPResponse
from .providers.openai_adapter import OpenAIProviderAdapter
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
    provider_timeout_s: float = 45.0,
) -> EpisodeService:
    """Assemble the production executor without persisting credentials or evidence."""

    root = Path(repository_root)
    package = EmbodimentProtocolPackage.from_repository(root)
    launcher = ManagedProcessLauncher(
        executable=godot_executable,
        project_path=godot_project_path,
    )

    async def execute(
        spec: EpisodeRunSpec,
        credential: SessionCredential,
        cancel_event: asyncio.Event,
        publish_frame: Callable[[str, int, bytes], Awaitable[None]],
    ) -> LiveSoloOutcome:
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
                certified_modes=(),
                certified_observation_profiles=(),
                scored_observation_profiles=(),
            ),
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
        session = ManagedWorldArenaSession(
            config=config,
            launcher=launcher,
            launch_spec=launch,
            socket_future=socket_future,
            protocol_package=package,
            step_timeout_s=max(10.0, provider_timeout_s),
        )
        adapter = provider_adapter(spec.provider, credential)
        try:
            return await LiveSoloRunner(
                config=config,
                session=session,
                provider=adapter,
                model=spec.model,
                system_prompt=SYSTEM_PROMPT,
                protocol_package=package,
                provider_timeout_s=provider_timeout_s,
                frame_publisher=publish_frame,
            ).run(cancel_event=cancel_event)
        finally:
            endpoint.cancel(ticket)
            await close_provider_adapter(adapter)

    return EpisodeService(execute)


def provider_adapter(provider: str, credential: SessionCredential) -> Any:
    key = credential.reveal()
    if provider == "openai":
        return OpenAIProviderAdapter(api_key=key)
    if provider == "anthropic":
        return AnthropicAdapter(api_key=key, transport=_anthropic_transport)
    if provider == "gemini":
        return GeminiAdapter(api_key=key, transport=_gemini_transport)
    raise ValueError("unsupported provider")


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
