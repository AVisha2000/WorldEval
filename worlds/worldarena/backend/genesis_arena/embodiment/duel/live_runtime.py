"""Production assembly for a verified, symmetric two-leg managed duel."""

from __future__ import annotations

import asyncio
import hashlib
import secrets
from pathlib import Path
from typing import Iterable

from ..contracts import CapabilityStatus, EpisodeConfig
from ..credentials import SessionCredential
from ..duo_games.catalog import (
    CENTRAL_RELAY_TASK_ID,
    build_duo_game_demo_provider,
    duo_game,
)
from ..duo_games.rts_skirmish_v1 import (
    TASK_ID as RTS_SKIRMISH_V1_TASK_ID,
)
from ..duo_games.rts_skirmish_v1 import (
    RtsTaskPlanProvider,
)
from ..live_runtime import SYSTEM_PROMPT, provider_adapter
from ..managed_process import ManagedLaunchSpec, ManagedProcessLauncher
from ..managed_session import ManagedWorldArenaSession
from ..presentation.preview_ingress import (
    InternalParticipantPreviewIngress,
    derive_duel_broadcast_preview_ticket,
    derive_duel_preview_ticket,
)
from ..protocol import EmbodimentProtocolPackage, canonical_json_bytes, canonical_sha256
from ..protocol_registry import EmbodimentProtocolRegistry
from ..series import ModelLock, SeriesLock
from ..transport import ManagedWebSocketEndpoint
from .archive import DuelSeriesArchive
from .contracts import DuelCallSettings, DuelEntrant, DuelLegPlan, PairedDuelPlan
from .demo_provider import build_demo_duel_provider
from .managed import VerifiedManagedDuelSession
from .participant_frames import DuelParticipantFrameStore
from .scheduler import LiveProviderCallBudget, PairedDuelScheduler, run_paired_duel_with_reruns
from .scripted_provider import ScriptedBaselineAdapter
from .service import DuelSeriesService, DuelSeriesSpec

_MAX_INPUT_BYTES = 8_388_608
_MAX_OUTPUT_BYTES = 4_096
_DUEL_AUTHORITY = Path("scripts/embodiment/duel_authority/embodiment_duel_authority.gd")
_ARENA_MAP = Path("scripts/embodiment/authority/arena_map.gd")
_CHECKPOINT_SERIALIZER = Path("scripts/embodiment/authority/checkpoint_serializer.gd")
_VISIBILITY = Path("scripts/embodiment/authority/visibility.gd")
_DUO_GAME_AUTHORITY = Path("scripts/embodiment/duo_games/duo_game_authority.gd")
_DUO_TASK_SOURCES = {
    "duo-checkpoint-race-v0": Path("scripts/embodiment/duo_games/checkpoint_race_authority.gd"),
    "duo-relay-control-v0": Path("scripts/embodiment/duo_games/relay_control_authority.gd"),
    "duo-spar-v0": Path("scripts/embodiment/duo_games/spar_authority.gd"),
    "duo-resource-relay-v0": Path("scripts/embodiment/duo_games/resource_relay_authority.gd"),
    "rts-skirmish-v0": Path("scripts/embodiment/rts_skirmish/rts_skirmish_authority.gd"),
    RTS_SKIRMISH_V1_TASK_ID: Path("scripts/embodiment/rts_skirmish/rts_skirmish_v1_authority.gd"),
}
_DUO_PROVIDER_SOURCES = {
    "duo-checkpoint-race-v0": Path("backend/genesis_arena/embodiment/duo_games/checkpoint_race.py"),
    "duo-relay-control-v0": Path("backend/genesis_arena/embodiment/duo_games/relay_control.py"),
    "duo-spar-v0": Path("backend/genesis_arena/embodiment/duo_games/spar.py"),
    "duo-resource-relay-v0": Path("backend/genesis_arena/embodiment/duo_games/resource_relay.py"),
    "rts-skirmish-v0": Path("backend/genesis_arena/embodiment/duo_games/rts_skirmish.py"),
    RTS_SKIRMISH_V1_TASK_ID: Path("backend/genesis_arena/embodiment/duo_games/rts_skirmish_v1.py"),
}
_PROVIDER_FACTORY = Path("backend/genesis_arena/embodiment/live_runtime.py")
_PROVIDER_LOCKS = {
    "openai": (
        Path("backend/genesis_arena/embodiment/providers/openai_adapter.py"),
        "low",
    ),
    "anthropic": (
        Path("backend/genesis_arena/embodiment/providers/anthropic_adapter.py"),
        "disabled",
    ),
    "gemini": (
        Path("backend/genesis_arena/embodiment/providers/gemini_adapter.py"),
        "provider-default",
    ),
    "scripted": (
        Path("backend/genesis_arena/embodiment/duel/scripted_provider.py"),
        "deterministic",
    ),
    "demo": (
        Path("backend/genesis_arena/embodiment/duel/demo_provider.py"),
        "deterministic",
    ),
}


def build_paired_duel_plan(
    *,
    spec: DuelSeriesSpec,
    repository_root: Path,
    godot_project_path: Path,
    protocol_package: EmbodimentProtocolPackage,
    provider_timeout_s: float,
) -> PairedDuelPlan:
    """Freeze every production fairness input before either authority leg is reset."""

    if not isinstance(spec, DuelSeriesSpec):
        raise TypeError("spec must be DuelSeriesSpec")
    if not isinstance(protocol_package, EmbodimentProtocolPackage):
        raise TypeError("protocol_package must be EmbodimentProtocolPackage")
    if (
        isinstance(provider_timeout_s, bool)
        or not isinstance(provider_timeout_s, (int, float))
        or provider_timeout_s <= 0
    ):
        raise ValueError("provider_timeout_s must be positive")
    root = Path(repository_root).resolve()
    project = Path(godot_project_path).resolve()
    deadline_ms = int(provider_timeout_s * 1000)
    game = duo_game(spec.task_id)
    settings = DuelCallSettings(
        system_prompt=SYSTEM_PROMPT,
        action_schema_json=canonical_json_bytes(protocol_package.schema("controller-action")),
        timeout_ms=deadline_ms,
        max_input_bytes=_MAX_INPUT_BYTES,
        max_output_bytes=_MAX_OUTPUT_BYTES,
    )
    locked_entrants = []
    for entrant in spec.entrants:
        try:
            adapter_path, reasoning = _PROVIDER_LOCKS[entrant.provider]
        except KeyError as error:
            raise ValueError("unsupported provider") from error
        adapter_sources = (
            (adapter_path, _PROVIDER_FACTORY)
            if entrant.provider != "demo" or spec.task_id == CENTRAL_RELAY_TASK_ID
            else (
                adapter_path,
                Path("backend/genesis_arena/embodiment/duo_games/common.py"),
                _DUO_PROVIDER_SOURCES[spec.task_id],
            )
        )
        locked_entrants.append(
            ModelLock(
                entrant_id=entrant.entrant_id,
                provider=entrant.provider,
                adapter_sha256=_source_lock_sha256(
                    root,
                    f"provider-adapter:{entrant.provider}",
                    (
                        adapter_path,
                        Path("backend/genesis_arena/embodiment/baselines.py"),
                        Path("godot/scripts/embodiment/baselines/duel_baseline_policy.gd"),
                    )
                    if entrant.provider == "scripted"
                    else adapter_sources,
                ),
                model=entrant.model,
                reasoning=reasoning,
            )
        )
    fairness_lock = SeriesLock(
        protocol_version=protocol_package.PROTOCOL_VERSION,
        protocol_sha256=protocol_package.package_sha256,
        rules_sha256=_source_lock_sha256(
            project,
            "duel-rules" if not game.is_managed_v2 else f"duo-game-rules:{spec.task_id}",
            (_DUEL_AUTHORITY, _ARENA_MAP, _CHECKPOINT_SERIALIZER, _VISIBILITY)
            if not game.is_managed_v2
            else (_DUO_GAME_AUTHORITY, _DUO_TASK_SOURCES[spec.task_id]),
        ),
        map_sha256=_source_lock_sha256(
            project,
            "duel-map" if not game.is_managed_v2 else f"duo-game-map:{spec.task_id}",
            (_ARENA_MAP,) if not game.is_managed_v2 else (_DUO_GAME_AUTHORITY,),
        ),
        body_sha256=_source_lock_sha256(
            project,
            "duel-body" if not game.is_managed_v2 else "duo-game-body",
            (_DUEL_AUTHORITY,) if not game.is_managed_v2 else (_DUO_GAME_AUTHORITY,),
        ),
        controller_sha256=_source_lock_sha256(
            project,
            "duel-controller" if not game.is_managed_v2 else "duo-game-controller",
            (_DUEL_AUTHORITY,) if not game.is_managed_v2 else (_DUO_GAME_AUTHORITY,),
        ),
        projector_sha256=_source_lock_sha256(
            project,
            "duel-observation-projector" if not game.is_managed_v2 else "duo-game-projector",
            (_DUEL_AUTHORITY, _VISIBILITY) if not game.is_managed_v2 else (_DUO_GAME_AUTHORITY,),
        ),
        evaluator_sha256=_source_lock_sha256(
            project,
            (
                "duel-terminal-evaluator"
                if not game.is_managed_v2
                else f"duo-game-evaluator:{spec.task_id}"
            ),
            (
                (_DUEL_AUTHORITY,)
                if not game.is_managed_v2
                else (_DUO_GAME_AUTHORITY, _DUO_TASK_SOURCES[spec.task_id])
            ),
        ),
        entrants=(locked_entrants[0], locked_entrants[1]),
        max_input_bytes=settings.max_input_bytes,
        max_output_bytes=settings.max_output_bytes,
        deadline_ms=settings.timeout_ms,
        observation_profile="hybrid-visible-v1",
        timing_track="step-locked-v1",
        seed=spec.seed,
        schedule_nonce=spec.schedule_nonce,
    )
    return PairedDuelPlan(
        series_id=spec.series_id,
        episode_ids=(f"ep_{spec.series_id}_a", f"ep_{spec.series_id}_b"),
        entrants=spec.entrants,
        seed=spec.seed,
        schedule_nonce=spec.schedule_nonce,
        settings=settings,
        fairness_lock=fairness_lock,
        max_live_provider_calls=spec.max_live_provider_calls,
    )


def _source_lock_sha256(root: Path, domain: str, paths: Iterable[Path]) -> str:
    files = []
    for relative in sorted(paths, key=lambda value: value.as_posix()):
        path = root / relative
        payload = path.read_bytes()
        files.append(
            {
                "path": relative.as_posix(),
                "sha256": hashlib.sha256(payload).hexdigest(),
                "size_bytes": len(payload),
            }
        )
    return canonical_sha256({"domain": domain, "files": files})


def default_duel_series_service(
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
) -> DuelSeriesService:
    root = Path(repository_root)
    project = Path(godot_project_path)
    executable = Path(godot_executable)
    registry = EmbodimentProtocolRegistry.from_repository(root)
    launcher = ManagedProcessLauncher(
        executable=executable, project_path=project, protocol_registry=registry
    )
    capabilities = CapabilityStatus(
        implemented_modes=("solo-curriculum-v0", "scripted-duel-v0", "model-duel-v0"),
        implemented_observation_profiles=("hybrid-visible-v1",),
        implemented_tasks=(
            "orientation-v0",
            "interaction-v0",
            "construction-v0",
            "neutral-encounter-v0",
            "central-relay-v0",
            "duo-checkpoint-race-v0",
            "duo-relay-control-v0",
            "duo-spar-v0",
            "duo-resource-relay-v0",
            "rts-skirmish-v0",
            RTS_SKIRMISH_V1_TASK_ID,
        ),
        certified_modes=(),
        certified_observation_profiles=(),
        scored_observation_profiles=(),
    )
    frame_stores: dict[str, DuelParticipantFrameStore] = {}
    service_ref: dict[str, DuelSeriesService] = {}

    async def execute(
        spec: DuelSeriesSpec,
        credentials: dict[str, SessionCredential],
        cancel_event: asyncio.Event,
    ):
        game = duo_game(spec.task_id)
        package = registry.package(game.protocol_version)
        plan = build_paired_duel_plan(
            spec=spec,
            repository_root=root,
            godot_project_path=project,
            protocol_package=package,
            provider_timeout_s=provider_timeout_s,
        )
        call_budget = LiveProviderCallBudget(plan.max_live_provider_calls)
        frame_store = frame_stores.setdefault(spec.series_id, DuelParticipantFrameStore())

        async def publish_participant_frame(
            leg_index: int,
            participant_id: str,
            observation_seq: int,
            png: bytes,
        ) -> None:
            await asyncio.to_thread(
                frame_store.publish,
                leg_index,
                participant_id,
                observation_seq,
                png,
            )

        async def session_factory(leg: DuelLegPlan):
            config = EpisodeConfig(
                episode_id=leg.episode_id,
                mode=leg.mode,
                task_id=spec.task_id,
                seed=leg.seed,
                observation_profile="hybrid-visible-v1",
                maximum_episode_ticks=game.maximum_episode_ticks,
                participant_ids=("participant_0", "participant_1"),
                capability_status=capabilities,
                protocol_version=game.protocol_version,
            )
            value = config.as_dict()
            ticket = secrets.token_urlsafe(32)
            secret = bytearray(secrets.token_bytes(32))
            connection_id = f"connection_{secrets.token_hex(12)}"
            future = endpoint.register(
                ticket=ticket,
                episode_id=leg.episode_id,
                connection_id=connection_id,
                session_secret=bytearray(secret),
                protocol_version=game.protocol_version,
            )
            presentation_entrant_ids = None
            if game.protocol_version == "llm-controller/0.2.0":
                presentation_entrant_ids = {
                    "participant_0": "alpha" if leg.leg_index == 0 else "bravo",
                    "participant_1": "bravo" if leg.leg_index == 0 else "alpha",
                }
            broadcast_preview_ticket = (
                derive_duel_broadcast_preview_ticket(secret, attachment_ticket=ticket)
                if preview_ingress is not None
                and spec.task_id in ("rts-skirmish-v0", RTS_SKIRMISH_V1_TASK_ID)
                else None
            )
            launch = ManagedLaunchSpec(
                episode_id=leg.episode_id,
                attachment_ticket=ticket,
                connection_id=connection_id,
                gateway_url=f"ws://127.0.0.1:{gateway_port}/ws/embodiment/{ticket}",
                config=value,
                config_sha256=canonical_sha256(value),
                protocol_package_sha256=package.package_sha256,
                session_secret=secret,
                presentation_entrant_ids=presentation_entrant_ids,
                presentation_broadcast_ticket=broadcast_preview_ticket,
            )
            managed = ManagedWorldArenaSession(
                config=config,
                launcher=launcher,
                launch_spec=launch,
                socket_future=future,
                protocol_package=package,
                step_timeout_s=max(10.0, provider_timeout_s),
            )
            preview_tickets = []
            if preview_ingress is not None:
                service = service_ref.get("service")
                if service is None:
                    raise RuntimeError("duel preview service is unavailable")
                try:
                    for participant_id in ("participant_0", "participant_1"):
                        preview_ticket = derive_duel_preview_ticket(
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
                            task_id=spec.task_id,
                            session_secret=secret,
                            sink=preview_sink,
                            participant_id=participant_id,
                        )
                        preview_tickets.append(preview_ticket)
                    if broadcast_preview_ticket is not None:

                        async def broadcast_preview_sink(
                            bound_participant_id: str,
                            sequence: int,
                            jpeg: bytes,
                            *,
                            current_leg_index: int = leg.leg_index,
                        ) -> bool:
                            if bound_participant_id != "broadcast":
                                return False
                            return await service.publish_live_broadcast_preview(
                                spec.series_id, current_leg_index, sequence, jpeg
                            )

                        preview_ingress.register(
                            ticket=broadcast_preview_ticket,
                            episode_id=leg.episode_id,
                            task_id=spec.task_id,
                            session_secret=secret,
                            sink=broadcast_preview_sink,
                            participant_id="broadcast",
                        )
                        preview_tickets.append(broadcast_preview_ticket)
                except Exception:
                    for preview_ticket in preview_tickets:
                        preview_ingress.unregister(preview_ticket)
                    raise

            def close_preview_registrations() -> None:
                if preview_ingress is not None:
                    for preview_ticket in preview_tickets:
                        preview_ingress.unregister(preview_ticket)

            return VerifiedManagedDuelSession(
                managed,
                protocol_package=package,
                godot_executable=executable,
                project_path=project,
                on_close=close_preview_registrations,
            )

        async def provider_factory(entrant: DuelEntrant, _leg: DuelLegPlan):
            if entrant.provider == "scripted":
                if entrant.entrant_id in credentials:
                    raise ValueError("scripted entrants cannot receive credentials")
                return ScriptedBaselineAdapter(entrant.model)
            if entrant.provider == "demo":
                if entrant.entrant_id in credentials:
                    raise ValueError("demo entrants cannot receive credentials")
                assignment = next(
                    value for value in _leg.assignments if value.entrant_id == entrant.entrant_id
                )
                if spec.task_id == CENTRAL_RELAY_TASK_ID:
                    return build_demo_duel_provider(
                        model=entrant.model,
                        participant_id=assignment.participant_id,
                        seed=_leg.seed,
                        decision_budget=plan.max_live_provider_calls,
                    )
                return build_duo_game_demo_provider(
                    task_id=spec.task_id,
                    model=entrant.model,
                    participant_id=assignment.participant_id,
                    seed=_leg.seed,
                    decision_budget=plan.max_live_provider_calls,
                )
            credential = credentials.get(entrant.entrant_id)
            if credential is None:
                raise ValueError("model entrant credential is unavailable")
            adapter = provider_adapter(entrant.provider, credential)
            return (
                RtsTaskPlanProvider(adapter) if spec.task_id == RTS_SKIRMISH_V1_TASK_ID else adapter
            )

        def scheduler_factory(attempt_plan: PairedDuelPlan) -> PairedDuelScheduler:
            return PairedDuelScheduler(
                plan=attempt_plan,
                session_factory=session_factory,
                provider_factory=provider_factory,
                protocol_package=package,
                require_verified_evidence=True,
                live_provider_call_budget=call_budget,
                participant_frame_sink=publish_participant_frame,
            )

        return await run_paired_duel_with_reruns(
            initial_plan=plan,
            scheduler_factory=scheduler_factory,
            cancel_event=cancel_event,
        )

    archive = (
        DuelSeriesArchive(
            runs_dir,
            godot_executable=executable,
            godot_project_path=project,
            ffmpeg_executable=ffmpeg_executable,
        )
        if runs_dir is not None and ffmpeg_executable is not None
        else DuelSeriesArchive(runs_dir)
        if runs_dir is not None
        else None
    )

    def participant_frame_reader(series_id: str, participant_id: str):
        store = frame_stores.get(series_id)
        return None if store is None else store.snapshot(participant_id)

    service = DuelSeriesService(
        execute,
        archive=archive,
        participant_frame_reader=participant_frame_reader,
    )
    service_ref["service"] = service
    return service


__all__ = ["build_paired_duel_plan", "default_duel_series_service"]
