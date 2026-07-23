"""Production assembly for credential-free managed protocol-v3 trio series."""

from __future__ import annotations

import asyncio
import secrets
from pathlib import Path

from ..contracts import CapabilityStatus, EpisodeConfig
from ..managed_process import ManagedLaunchSpec, ManagedProcessLauncher
from ..managed_session import ManagedWorldArenaSession
from ..presentation.preview_ingress import (
    InternalParticipantPreviewIngress,
    derive_trio_preview_ticket,
)
from ..protocol import canonical_sha256
from ..protocol_registry import EmbodimentProtocolRegistry
from ..transport import ManagedWebSocketEndpoint
from .archive import TrioSeriesArchive
from .common import TRIO_PARTICIPANT_IDS
from .demo_provider import build_trio_demo_controller
from .scheduler import TrioSeriesScheduler
from .service import TrioSeriesService, TrioSeriesSpec


def default_trio_series_service(
    *,
    repository_root: Path,
    godot_executable: Path,
    godot_project_path: Path,
    gateway_port: int,
    endpoint: ManagedWebSocketEndpoint,
    provider_timeout_s: float = 45.0,
    runs_dir: Path | None = None,
    ffmpeg_executable: Path | None = None,
    preview_ingress: InternalParticipantPreviewIngress | None = None,
) -> TrioSeriesService:
    root = Path(repository_root).resolve()
    project = Path(godot_project_path).resolve()
    executable = Path(godot_executable).resolve()
    registry = EmbodimentProtocolRegistry.from_repository(root)
    package = registry.package("llm-controller/0.3.0")
    launcher = ManagedProcessLauncher(
        executable=executable, project_path=project, protocol_registry=registry
    )
    capabilities = CapabilityStatus(
        implemented_modes=("trio-game-v0",),
        implemented_observation_profiles=("hybrid-visible-v1",),
        implemented_tasks=("trio-relay-v0", "trio-free-for-all-v0"),
    )
    service_ref: dict[str, TrioSeriesService] = {}

    async def execute(spec: TrioSeriesSpec, cancel_event: asyncio.Event):
        async def session_factory(leg):
            config = EpisodeConfig(
                episode_id=leg.episode_id,
                mode="trio-game-v0",
                task_id=leg.task_id,
                seed=leg.seed,
                observation_profile="hybrid-visible-v1",
                maximum_episode_ticks=1200,
                participant_ids=TRIO_PARTICIPANT_IDS,
                capability_status=capabilities,
                protocol_version="llm-controller/0.3.0",
                seat_rotation=leg.leg_index,
            )
            config_value = config.as_dict()
            ticket = secrets.token_urlsafe(32)
            secret = bytearray(secrets.token_bytes(32))
            connection_id = f"connection_{secrets.token_hex(12)}"
            future = endpoint.register(
                ticket=ticket,
                episode_id=leg.episode_id,
                connection_id=connection_id,
                session_secret=bytearray(secret),
                protocol_version="llm-controller/0.3.0",
            )
            launch = ManagedLaunchSpec(
                episode_id=leg.episode_id,
                attachment_ticket=ticket,
                connection_id=connection_id,
                gateway_url=f"ws://127.0.0.1:{gateway_port}/ws/embodiment/{ticket}",
                config=config_value,
                config_sha256=canonical_sha256(config_value),
                protocol_package_sha256=package.package_sha256,
                session_secret=secret,
            )
            preview_tickets: list[str] = []
            if preview_ingress is not None:
                service = service_ref.get("service")
                if service is None:
                    raise RuntimeError("trio preview service is unavailable")
                try:
                    for participant_id in TRIO_PARTICIPANT_IDS:
                        preview_ticket = derive_trio_preview_ticket(
                            secret,
                            attachment_ticket=ticket,
                            participant_id=participant_id,
                        )

                        async def preview_sink(
                            bound_participant_id: str,
                            sequence: int,
                            jpeg: bytes,
                            *,
                            current_leg_index: int = leg.leg_index,
                        ) -> bool:
                            return await service.publish_live_preview(
                                spec.series_id,
                                current_leg_index,
                                bound_participant_id,
                                sequence,
                                jpeg,
                            )

                        preview_ingress.register(
                            ticket=preview_ticket,
                            episode_id=leg.episode_id,
                            task_id=leg.task_id,
                            session_secret=secret,
                            sink=preview_sink,
                            participant_id=participant_id,
                        )
                        preview_tickets.append(preview_ticket)
                except Exception:
                    for preview_ticket in preview_tickets:
                        preview_ingress.unregister(preview_ticket)
                    raise

            session = ManagedWorldArenaSession(
                config=config,
                launcher=launcher,
                launch_spec=launch,
                socket_future=future,
                protocol_package=package,
                step_timeout_s=max(10.0, provider_timeout_s),
            )
            return _PreviewManagedSession(session, preview_ingress, tuple(preview_tickets))

        async def controller_factory(entrant, leg, participant_id):
            return build_trio_demo_controller(
                task_id=leg.task_id,
                model=entrant.model,
                participant_id=participant_id,
                seed=leg.seed,
                decision_budget=120,
            )

        service = service_ref["service"]

        async def frame_sink(leg_index, participant_id, observation_seq, png):
            await service.publish_frame(
                spec.series_id, leg_index, participant_id, observation_seq, png
            )

        scheduler = TrioSeriesScheduler(
            plan=spec.plan,
            session_factory=session_factory,
            controller_factory=controller_factory,
            protocol_package=package,
            provider_timeout_s=provider_timeout_s,
            participant_frame_sink=frame_sink,
            max_provider_calls=spec.max_provider_calls,
            cancel_event=cancel_event,
        )
        return await scheduler.run()

    archive = (
        None
        if runs_dir is None
        else TrioSeriesArchive(
            runs_dir,
            godot_executable=executable if ffmpeg_executable is not None else None,
            godot_project_path=project if ffmpeg_executable is not None else None,
            ffmpeg_executable=ffmpeg_executable,
        )
    )
    service = TrioSeriesService(execute, archive=archive)
    service_ref["service"] = service
    return service


class _PreviewManagedSession:
    def __init__(
        self,
        session: ManagedWorldArenaSession,
        ingress: InternalParticipantPreviewIngress | None,
        tickets: tuple[str, ...],
    ) -> None:
        self._session = session
        self._ingress = ingress
        self._tickets = tickets

    async def reset(self):
        return await self._session.reset()

    async def step(self, window):
        return await self._session.step(window)

    async def render(self, participant_id, sensor_id, transport_ref, observation_seq):
        return await self._session.render(
            participant_id, sensor_id, transport_ref, observation_seq
        )

    @property
    def replay_bytes(self) -> bytes:
        return self._session.replay_bytes

    async def close(self) -> None:
        try:
            await self._session.close()
        finally:
            if self._ingress is not None:
                for ticket in self._tickets:
                    self._ingress.unregister(ticket)


__all__ = ["default_trio_series_service"]
