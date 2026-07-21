"""Production assembly for a verified, symmetric two-leg managed duel."""

from __future__ import annotations

import asyncio
import hashlib
import secrets
from pathlib import Path
from typing import Iterable

from ..contracts import CapabilityStatus, EpisodeConfig
from ..credentials import SessionCredential
from ..live_runtime import SYSTEM_PROMPT, provider_adapter
from ..managed_process import ManagedLaunchSpec, ManagedProcessLauncher
from ..managed_session import ManagedWorldArenaSession
from ..protocol import EmbodimentProtocolPackage, canonical_json_bytes, canonical_sha256
from ..series import ModelLock, SeriesLock
from ..transport import ManagedWebSocketEndpoint
from .contracts import DuelCallSettings, DuelEntrant, DuelLegPlan, PairedDuelPlan
from .managed import VerifiedManagedDuelSession
from .scheduler import LiveProviderCallBudget, PairedDuelScheduler, run_paired_duel_with_reruns
from .scripted_provider import ScriptedBaselineAdapter
from .service import DuelSeriesService, DuelSeriesSpec

_MAX_INPUT_BYTES = 8_388_608
_MAX_OUTPUT_BYTES = 4_096
_DUEL_AUTHORITY = Path("scripts/embodiment/duel_authority/embodiment_duel_authority.gd")
_ARENA_MAP = Path("scripts/embodiment/authority/arena_map.gd")
_CHECKPOINT_SERIALIZER = Path("scripts/embodiment/authority/checkpoint_serializer.gd")
_VISIBILITY = Path("scripts/embodiment/authority/visibility.gd")
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
                    else (adapter_path, _PROVIDER_FACTORY),
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
            "duel-rules",
            (_DUEL_AUTHORITY, _ARENA_MAP, _CHECKPOINT_SERIALIZER, _VISIBILITY),
        ),
        map_sha256=_source_lock_sha256(project, "duel-map", (_ARENA_MAP,)),
        body_sha256=_source_lock_sha256(project, "duel-body", (_DUEL_AUTHORITY,)),
        controller_sha256=_source_lock_sha256(project, "duel-controller", (_DUEL_AUTHORITY,)),
        projector_sha256=_source_lock_sha256(
            project, "duel-observation-projector", (_DUEL_AUTHORITY, _VISIBILITY)
        ),
        evaluator_sha256=_source_lock_sha256(
            project, "duel-terminal-evaluator", (_DUEL_AUTHORITY,)
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
) -> DuelSeriesService:
    root = Path(repository_root)
    project = Path(godot_project_path)
    executable = Path(godot_executable)
    package = EmbodimentProtocolPackage.from_repository(root)
    launcher = ManagedProcessLauncher(executable=executable, project_path=project)
    capabilities = CapabilityStatus(
        implemented_modes=("solo-curriculum-v0", "scripted-duel-v0", "model-duel-v0"),
        implemented_observation_profiles=("hybrid-visible-v1",),
        implemented_tasks=(
            "orientation-v0",
            "interaction-v0",
            "construction-v0",
            "neutral-encounter-v0",
            "central-relay-v0",
        ),
        certified_modes=(),
        certified_observation_profiles=(),
        scored_observation_profiles=(),
    )

    async def execute(
        spec: DuelSeriesSpec,
        credentials: dict[str, SessionCredential],
        cancel_event: asyncio.Event,
    ):
        plan = build_paired_duel_plan(
            spec=spec,
            repository_root=root,
            godot_project_path=project,
            protocol_package=package,
            provider_timeout_s=provider_timeout_s,
        )
        call_budget = LiveProviderCallBudget(plan.max_live_provider_calls)

        async def session_factory(leg: DuelLegPlan):
            config = EpisodeConfig(
                episode_id=leg.episode_id,
                mode=leg.mode,
                task_id="central-relay-v0",
                seed=leg.seed,
                observation_profile="hybrid-visible-v1",
                maximum_episode_ticks=1800,
                participant_ids=("participant_0", "participant_1"),
                capability_status=capabilities,
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
            )
            managed = ManagedWorldArenaSession(
                config=config,
                launcher=launcher,
                launch_spec=launch,
                socket_future=future,
                protocol_package=package,
                step_timeout_s=max(10.0, provider_timeout_s),
            )
            return VerifiedManagedDuelSession(
                managed,
                protocol_package=package,
                godot_executable=executable,
                project_path=project,
            )

        async def provider_factory(entrant: DuelEntrant, _leg: DuelLegPlan):
            if entrant.provider == "scripted":
                if entrant.entrant_id in credentials:
                    raise ValueError("scripted entrants cannot receive credentials")
                return ScriptedBaselineAdapter(entrant.model)
            credential = credentials.get(entrant.entrant_id)
            if credential is None:
                raise ValueError("model entrant credential is unavailable")
            return provider_adapter(entrant.provider, credential)

        def scheduler_factory(attempt_plan: PairedDuelPlan) -> PairedDuelScheduler:
            return PairedDuelScheduler(
                plan=attempt_plan,
                session_factory=session_factory,
                provider_factory=provider_factory,
                protocol_package=package,
                require_verified_evidence=True,
                live_provider_call_budget=call_budget,
            )

        return await run_paired_duel_with_reruns(
            initial_plan=plan,
            scheduler_factory=scheduler_factory,
            cancel_event=cancel_event,
        )

    return DuelSeriesService(execute)


__all__ = ["build_paired_duel_plan", "default_duel_series_service"]
