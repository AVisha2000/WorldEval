from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import secrets
import socket
from dataclasses import replace
from pathlib import Path

import pytest
import uvicorn
from fastapi import FastAPI, WebSocket
from genesis_arena.embodiment.contracts import (
    CapabilityStatus,
    ControllerAction,
    ControllerState,
    EpisodeConfig,
)
from genesis_arena.embodiment.duel import (
    DuelCallSettings,
    DuelEntrant,
    PairedDuelPlan,
    PairedDuelScheduler,
    VerifiedManagedDuelSession,
    run_paired_duel_with_reruns,
)
from genesis_arena.embodiment.duel.demo_provider import build_demo_duel_provider
from genesis_arena.embodiment.duel.evidence import (
    DuelSeriesEvidenceBundle,
    verify_offline_paired_duel,
)
from genesis_arena.embodiment.duel.scripted_provider import ScriptedBaselineAdapter
from genesis_arena.embodiment.managed_process import ManagedLaunchSpec, ManagedProcessLauncher
from genesis_arena.embodiment.managed_session import ManagedWorldArenaSession
from genesis_arena.embodiment.protocol import (
    EmbodimentProtocolPackage,
    canonical_json_bytes,
    canonical_sha256,
    strict_json_loads,
)
from genesis_arena.embodiment.providers.contracts import ProviderCallResult, ProviderTelemetry
from genesis_arena.embodiment.series import ModelLock, SeriesLock
from genesis_arena.embodiment.transport import ManagedWebSocketEndpoint
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")


class _SeatLocalProvider:
    def __init__(self, provider_name: str, *, permuted: bool = False) -> None:
        self.provider_name = provider_name
        self.permuted = permuted

    async def request(self, request) -> ProviderCallResult:
        if self.permuted and (
            (request.observation_seq + (request.participant_id == "participant_1")) % 2 == 0
        ):
            await asyncio.sleep(0.002)
        approaching = request.participant_id == "participant_0" and request.observation_seq < 3
        action = ControllerAction(
            episode_id=request.episode_id,
            observation_seq=request.observation_seq,
            action_id=f"action_{request.participant_id}_{request.observation_seq}",
            control=ControllerState(0, 1000 if approaching else 0, 0, 0, 10),
            intent_label="Approach or hold relay.",
            memory_update="participant-local relay plan",
        )
        value = action.as_dict()
        output = (
            json.dumps(_reverse_dicts(value), separators=(",", ":")).encode("utf-8")
            if self.permuted
            else canonical_json_bytes(value)
        )
        return ProviderCallResult.success(output, ProviderTelemetry(latency_ms=0))


def _reverse_dicts(value):
    if isinstance(value, dict):
        return {key: _reverse_dicts(item) for key, item in reversed(tuple(value.items()))}
    if isinstance(value, list):
        return [_reverse_dicts(item) for item in value]
    return value


class _PermutedSession:
    def __init__(self, session: VerifiedManagedDuelSession) -> None:
        self._session = session

    async def reset(self):
        return _reverse_dicts(await self._session.reset())

    async def step(self, window):
        reversed_window = replace(
            window,
            decisions={
                participant_id: decision
                for participant_id, decision in reversed(tuple(window.decisions.items()))
            },
        )
        result = await self._session.step(reversed_window)
        return replace(result, observations=_reverse_dicts(dict(result.observations)))

    async def render(self, participant_id, sensor_id, transport_ref, observation_seq):
        return await self._session.render(participant_id, sensor_id, transport_ref, observation_seq)

    async def verify_leg(self, plan):
        return await self._session.verify_leg(plan)

    def take_verified_replay_bytes(self):
        return self._session.take_verified_replay_bytes()

    async def close(self):
        await self._session.close()


class _NeutralProvider:
    def __init__(self, provider_name: str) -> None:
        self.provider_name = provider_name

    async def request(self, request) -> ProviderCallResult:
        action = ControllerAction(
            episode_id=request.episode_id,
            observation_seq=request.observation_seq,
            action_id=f"neutral_{request.participant_id}_{request.observation_seq}",
            control=ControllerState.neutral(10),
            intent_label="Hold neutral input.",
            memory_update="",
        )
        return ProviderCallResult.success(
            canonical_json_bytes(action.as_dict()), ProviderTelemetry(latency_ms=0)
        )


class _VoidFirstLegSession:
    """Preserve verified replay bytes while forcing one whole-pair rerun."""

    def __init__(self, session: VerifiedManagedDuelSession, *, void: bool) -> None:
        self._session = session
        self._void = void

    async def reset(self):
        return await self._session.reset()

    async def step(self, window):
        return await self._session.step(window)

    async def render(self, participant_id, sensor_id, transport_ref, observation_seq):
        return await self._session.render(participant_id, sensor_id, transport_ref, observation_seq)

    async def verify_leg(self, plan):
        verification = await self._session.verify_leg(plan)
        if self._void:
            return replace(verification, outcome="void", winner_participant_id=None)
        return verification

    def take_verified_replay_bytes(self):
        return self._session.take_verified_replay_bytes()

    async def close(self):
        await self._session.close()


@pytest.mark.skipif(not GODOT.is_file(), reason="pinned local Godot build is unavailable")
@pytest.mark.asyncio
@pytest.mark.parametrize("second_provider", ["scripted", "anthropic", "demo"])
async def test_verified_managed_two_leg_series(second_provider: str) -> None:
    endpoint = ManagedWebSocketEndpoint()
    app = FastAPI()

    @app.websocket("/ws/embodiment/{ticket}")
    async def attach(ticket: str, websocket: WebSocket) -> None:
        await endpoint.handle(ticket, websocket)

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(128)
    listener.setblocking(False)
    port = listener.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(app, log_level="error", lifespan="off"))
    server_task = asyncio.create_task(server.serve(sockets=[listener]))
    while not server.started:
        await asyncio.sleep(0)

    package = EmbodimentProtocolPackage.from_repository(ROOT)
    tickets: list[str] = []
    permuted = False

    async def session_factory(plan):
        config = EpisodeConfig(
            episode_id=plan.episode_id,
            mode=plan.mode,
            task_id="central-relay-v0",
            seed=plan.seed,
            observation_profile="hybrid-visible-v1",
            maximum_episode_ticks=1800,
            participant_ids=("participant_0", "participant_1"),
            capability_status=CapabilityStatus(
                implemented_modes=("scripted-duel-v0", "model-duel-v0"),
                implemented_observation_profiles=("hybrid-visible-v1",),
                implemented_tasks=("central-relay-v0",),
            ),
        )
        value = config.as_dict()
        ticket = secrets.token_urlsafe(32)
        tickets.append(ticket)
        secret = bytearray(secrets.token_bytes(32))
        connection_id = f"connection_{secrets.token_hex(8)}"
        future = endpoint.register(
            ticket=ticket,
            episode_id=plan.episode_id,
            connection_id=connection_id,
            session_secret=bytearray(secret),
        )
        launch = ManagedLaunchSpec(
            episode_id=plan.episode_id,
            attachment_ticket=ticket,
            connection_id=connection_id,
            gateway_url=f"ws://127.0.0.1:{port}/ws/embodiment/{ticket}",
            config=value,
            config_sha256=canonical_sha256(value),
            protocol_package_sha256=package.package_sha256,
            session_secret=secret,
        )
        managed = ManagedWorldArenaSession(
            config=config,
            launcher=ManagedProcessLauncher(executable=GODOT, project_path=ROOT / "godot"),
            launch_spec=launch,
            socket_future=future,
            protocol_package=package,
            attachment_timeout_s=20,
            step_timeout_s=20,
        )
        session = VerifiedManagedDuelSession(
            managed,
            protocol_package=package,
            godot_executable=GODOT,
            project_path=ROOT / "godot",
        )
        force_void = (
            second_provider == "scripted"
            and plan.schedule_nonce == "schedule-0"
            and plan.leg_index == 0
        )
        if permuted:
            return _PermutedSession(session)
        return _VoidFirstLegSession(session, void=force_void)

    async def provider_factory(entrant, _plan):
        if entrant.provider == "scripted":
            return ScriptedBaselineAdapter(entrant.model)
        if entrant.provider == "demo":
            assignment = next(
                value for value in _plan.assignments if value.entrant_id == entrant.entrant_id
            )
            return build_demo_duel_provider(
                model=entrant.model,
                participant_id=assignment.participant_id,
                seed=_plan.seed,
                decision_budget=180,
            )
        if second_provider == "scripted":
            return _NeutralProvider(entrant.provider)
        return _SeatLocalProvider(entrant.provider, permuted=permuted)

    first_provider = "demo" if second_provider == "demo" else "openai"
    first_model = "duelist-alpha-v1" if second_provider == "demo" else "model-a"
    second_model = (
        "duelist-bravo-v1"
        if second_provider == "demo"
        else "balanced-v1"
        if second_provider == "scripted"
        else "model-b"
    )
    entrants = (
        DuelEntrant("entrant_a", first_provider, first_model),
        DuelEntrant(
            "entrant_b",
            second_provider,
            second_model,
        ),
    )
    fairness_lock = SeriesLock(
        protocol_version=package.PROTOCOL_VERSION,
        protocol_sha256=package.package_sha256,
        rules_sha256="1" * 64,
        map_sha256="2" * 64,
        body_sha256="3" * 64,
        controller_sha256="4" * 64,
        projector_sha256="5" * 64,
        evaluator_sha256="6" * 64,
        entrants=(
            ModelLock(
                "entrant_a",
                first_provider,
                "7" * 64,
                first_model,
                "deterministic" if first_provider == "demo" else "medium",
            ),
            ModelLock(
                "entrant_b",
                second_provider,
                "8" * 64,
                second_model,
                "deterministic" if second_provider in ("scripted", "demo") else "none",
            ),
        ),
        max_input_bytes=8_388_608,
        max_output_bytes=4_096,
        deadline_ms=5_000,
        observation_profile="hybrid-visible-v1",
        timing_track="step-locked-v1",
        seed=17,
        schedule_nonce="schedule-0",
    )
    plan = PairedDuelPlan(
        series_id=f"series_openai_{second_provider}",
        episode_ids=(
            f"ep_series_{second_provider}_leg_0",
            f"ep_series_{second_provider}_leg_1",
        ),
        entrants=entrants,
        seed=17,
        schedule_nonce="schedule-0",
        settings=DuelCallSettings(
            system_prompt="Return exactly one player-visible controller action.",
            action_schema_json=canonical_json_bytes(package.schema("controller-action")),
            timeout_ms=5_000,
            max_input_bytes=8_388_608,
            max_output_bytes=4_096,
        ),
        fairness_lock=fairness_lock,
    )
    try:
        attempt_plans = []
        participant_frames = []

        async def participant_frame_sink(leg_index, participant_id, observation_seq, png):
            participant_frames.append((leg_index, participant_id, observation_seq, png))

        def scheduler_factory(attempt_plan):
            attempt_plans.append(attempt_plan)
            return PairedDuelScheduler(
                plan=attempt_plan,
                session_factory=session_factory,
                provider_factory=provider_factory,
                protocol_package=package,
                require_verified_evidence=True,
                participant_frame_sink=participant_frame_sink,
            )

        execution = await run_paired_duel_with_reruns(
            initial_plan=plan,
            scheduler_factory=scheduler_factory,
            cancel_event=asyncio.Event(),
        )
        result = execution.result
        assert result.status == "complete"
        if second_provider == "scripted":
            assert result.entrant_wins == (0, 2)
            assert result.draws == 0
            assert result.winner_entrant_id == "entrant_b"
        elif second_provider == "anthropic":
            assert result.entrant_wins == (1, 1)
            assert result.draws == 0
            assert result.winner_entrant_id is None
        else:
            assert sum(result.entrant_wins) + result.draws == 2
        assert all(leg.verification.complete for leg in result.legs)
        assert all(leg.verification.verified for leg in result.legs)
        assert {value[1] for value in participant_frames} == {
            "participant_0", "participant_1"
        }
        assert {value[0] for value in participant_frames} >= {0, 1}
        assert all(value[3].startswith(b"\x89PNG\r\n\x1a\n") for value in participant_frames)
        expected_windows = 14 if second_provider == "scripted" else 13
        if second_provider != "demo":
            assert all(leg.windows == expected_windows for leg in result.legs)
        assert execution.evidence is not None
        public = DuelSeriesEvidenceBundle.verify(execution.evidence.public.bundle_bytes)
        protected = DuelSeriesEvidenceBundle.verify(execution.evidence.protected.bundle_bytes)
        assert public.fairness_lock_sha256 == protected.fairness_lock_sha256
        assert public.plan_sha256 == protected.plan_sha256 == result.plan_sha256
        assert len(public.legs) == len(protected.legs) == 2
        assert b"frame_png_base64" not in public.bundle_bytes
        assert b"observation_json_base64" not in public.bundle_bytes
        for leg in public.legs:
            evaluation = strict_json_loads(leg.read("evaluation"))
            assert evaluation["scope"] == "paired_duel_leg"
            assert (
                evaluation["pair_metrics"]["side_normalized_performance"]["status"] == "supported"
            )
            assert evaluation["pair_metrics"]["deterministic_replay_verification"]["value"] is True
        for leg in protected.legs:
            metadata = strict_json_loads(leg.read("telemetry"))
            audits = metadata["provider_audits"]
            leg_index = protected.legs.index(leg)
            assert len(audits) == result.legs[leg_index].windows * 2
            assert {audit["request"]["participant_id"] for audit in audits} == {
                "participant_0",
                "participant_1",
            }
            assert all(
                set(audit)
                == {
                    "completed_monotonic_ns",
                    "entrant_id",
                    "provider",
                    "request",
                    "result",
                    "started_monotonic_ns",
                }
                for audit in audits
            )
            for audit in audits:
                request = audit["request"]
                observation = json.loads(
                    base64.b64decode(request["observation_json_base64"])
                )
                frame = base64.b64decode(request["frame_png_base64"])
                participant_id = request["participant_id"]
                assert observation["frame"]["transport_ref"].startswith(
                    f"frame:{participant_id}."
                )
                assert observation["frame"]["sha256"] == hashlib.sha256(frame).hexdigest()
                assert frame.startswith(b"\x89PNG\r\n\x1a\n")
            lowered = leg.read("telemetry").lower()
            assert b"api_key" not in lowered
            assert b"authorization" not in lowered
            assert b"headers" not in lowered
        replays = verify_offline_paired_duel(
            protected.bundle_bytes,
            package=package,
        )
        final_plan = attempt_plans[-1]
        assert tuple(replay["config"]["episode_id"] for replay in replays) == final_plan.episode_ids
        assert all(replay["config"]["mode"] == final_plan.mode for replay in replays)
        if second_provider == "scripted":
            assert len(attempt_plans) == 2
            assert len(tickets) == 4
            assert set(attempt_plans[0].episode_ids).isdisjoint(final_plan.episode_ids)
            assert attempt_plans[0].plan_sha256.encode("ascii") not in public.bundle_bytes
        else:
            assert len(attempt_plans) == 1
            assert len(tickets) == 2

            canonical_replays = replays
            permuted = True
            permuted_scheduler = PairedDuelScheduler(
                plan=plan,
                session_factory=session_factory,
                provider_factory=provider_factory,
                protocol_package=package,
                require_verified_evidence=True,
            )
            permuted_result = await permuted_scheduler.run()
            assert permuted_result.status == "complete"
            assert permuted_scheduler.evidence is not None
            permuted_replays = verify_offline_paired_duel(
                permuted_scheduler.evidence.protected.bundle_bytes,
                package=package,
            )
            for canonical, reordered in zip(canonical_replays, permuted_replays):
                canonical_hashes = (
                    canonical["initial_state_hash"],
                    tuple(step["result"]["state_hash"] for step in canonical["steps"]),
                    canonical["final_state_hash"],
                )
                reordered_hashes = (
                    reordered["initial_state_hash"],
                    tuple(step["result"]["state_hash"] for step in reordered["steps"]),
                    reordered["final_state_hash"],
                )
                assert reordered_hashes == canonical_hashes
                assert reordered["final_terminal"] == canonical["final_terminal"]
    finally:
        for ticket in tickets:
            endpoint.cancel(ticket)
        server.should_exit = True
        try:
            await asyncio.wait_for(asyncio.shield(server_task), 10)
        except asyncio.TimeoutError:
            server.force_exit = True
            await asyncio.wait_for(server_task, 5)
        listener.close()
