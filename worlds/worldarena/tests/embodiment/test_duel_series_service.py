from __future__ import annotations

import asyncio

import genesis_arena.embodiment.duel.archive as archive_module
import genesis_arena.embodiment.duel.service as service_module
import pytest
from genesis_arena.embodiment.artifacts import (
    PROTECTED_LAYER,
    PUBLIC_LAYER,
    EpisodeArtifact,
    EpisodeArtifactBundle,
)
from genesis_arena.embodiment.credentials import CredentialError, SessionCredential
from genesis_arena.embodiment.duel import (
    DuelCallSettings,
    DuelEntrant,
    DuelLegResult,
    DuelLegVerification,
    PairedDuelPlan,
    aggregate_verified_pair,
)
from genesis_arena.embodiment.duel.archive import DuelSeriesArchive
from genesis_arena.embodiment.duel.evidence import (
    DuelSeriesEvidenceBundle,
    DuelSeriesExecution,
    PairedDuelEvidence,
)
from genesis_arena.embodiment.duel.scheduler import RepeatedInvalidPairError
from genesis_arena.embodiment.duel.service import (
    DuelSeriesEvidenceNotReadyError,
    DuelSeriesService,
)
from genesis_arena.embodiment.evaluation import EVALUATION_SCHEMA_VERSION
from genesis_arena.embodiment.series import ModelLock, SeriesLock


def _execution(
    series_id: str, *, valid: bool = True, certification_eligible: bool = True
) -> DuelSeriesExecution:
    entrants = (
        DuelEntrant("entrant_0", "openai", "model-a"),
        DuelEntrant("entrant_1", "anthropic", "model-b"),
    )
    lock = SeriesLock(
        protocol_version="llm-controller/0.1.0",
        protocol_sha256="1" * 64,
        rules_sha256="2" * 64,
        map_sha256="3" * 64,
        body_sha256="4" * 64,
        controller_sha256="5" * 64,
        projector_sha256="6" * 64,
        evaluator_sha256="7" * 64,
        entrants=(
            ModelLock("entrant_0", "openai", "8" * 64, "model-a", "medium"),
            ModelLock("entrant_1", "anthropic", "9" * 64, "model-b", "disabled"),
        ),
        max_input_bytes=8_388_608,
        max_output_bytes=4096,
        deadline_ms=30_000,
        observation_profile="hybrid-visible-v1",
        timing_track="step-locked-v1",
        seed=7,
        schedule_nonce="service-nonce",
    )
    plan = PairedDuelPlan(
        series_id=series_id,
        episode_ids=(f"ep_{series_id}_a", f"ep_{series_id}_b"),
        entrants=entrants,
        seed=7,
        schedule_nonce="service-nonce",
        settings=DuelCallSettings(
            system_prompt="Return one action.",
            action_schema_json=b'{"type":"object"}',
            timeout_ms=30_000,
            max_input_bytes=8_388_608,
            max_output_bytes=4096,
        ),
        fairness_lock=lock,
    )
    leg_results = []
    for index, leg in enumerate(plan.legs):
        outcome = "void" if not valid and index == 0 else "draw"
        verification = DuelLegVerification(
            plan_sha256=leg.plan_sha256,
            replay_sha256=f"{index + 1:064x}",
            terminal_state_sha256=f"{index + 3:064x}",
            complete=True,
            verified=True,
            outcome=outcome,
        )
        leg_results.append(DuelLegResult(leg, verification, None, 1, 0))
    result = aggregate_verified_pair(plan, (leg_results[0], leg_results[1]))
    if not valid:
        return DuelSeriesExecution(result, None)
    public_legs = []
    for index in (0, 1):
        leg = plan.legs[index]
        terminal = {"ended": True, "outcome": "draw", "reason": "time_limit"}
        receipt = {
            "accepted": True,
            "action_id": f"action_{index}",
            "applied_ticks": 10,
            "disposition": "accepted",
            "fallback": "none",
            "no_input_reason": None,
        }
        public_legs.append(
            EpisodeArtifactBundle.create(
                PUBLIC_LAYER,
                (
                    EpisodeArtifact.json(
                        "evaluation", _paired_evaluation(index, leg.assignments)
                    ),
                    EpisodeArtifact.json("public_events", []),
                    EpisodeArtifact.json(
                        "receipts",
                        [
                            {
                                "observation_seq": 0,
                                "participants": {
                                    "participant_0": receipt,
                                    "participant_1": {
                                        **receipt,
                                        "action_id": f"peer_action_{index}",
                                    },
                                },
                            }
                        ],
                    ),
                    EpisodeArtifact.json(
                        "replay_summary",
                        {
                            "call_settings": plan.settings.as_dict(),
                            "certification": {
                                "eligible": certification_eligible,
                                "reason": None
                                if certification_eligible
                                else "demo_provider",
                            },
                            "episode_id": leg.episode_id,
                            "fairness_lock": plan.fairness_lock.as_dict(),
                            "final_state_hash": (
                                leg_results[index].verification.terminal_state_sha256
                            ),
                            "leg_plan": leg.as_dict(),
                            "terminal": terminal,
                        },
                    ),
                ),
            )
        )
    protected_legs = tuple(
        EpisodeArtifactBundle.create(PROTECTED_LAYER, (EpisodeArtifact.json("observations", []),))
        for _ in (0, 1)
    )
    public = DuelSeriesEvidenceBundle.create(
        layer=PUBLIC_LAYER,
        series_id=series_id,
        plan_sha256=plan.plan_sha256,
        fairness_lock_sha256=lock.lock_sha256,
        legs=(public_legs[0], public_legs[1]),
    )
    protected = DuelSeriesEvidenceBundle.create(
        layer=PROTECTED_LAYER,
        series_id=series_id,
        plan_sha256=plan.plan_sha256,
        fairness_lock_sha256=lock.lock_sha256,
        legs=(protected_legs[0], protected_legs[1]),
    )
    return DuelSeriesExecution(result, PairedDuelEvidence(public, protected))


def _paired_evaluation(index, assignments):
    unavailable = {"reason": "provider_telemetry_not_recorded", "status": "unsupported"}
    ratio = {"basis_points": 10_000, "denominator": 1, "numerator": 1}
    entrant = {
        "action_validity": ratio,
        "damage_dealt": 0,
        "damage_taken": 0,
        "guard_efficiency": {"basis_points": 0, "denominator": 0, "numerator": 0},
        "idle_ticks": 0,
        "objective_control_ticks": 0,
        "oscillation": 0,
        "provider_latency_efficiency": unavailable,
        "provider_token_efficiency": unavailable,
        "total_actions": 1,
        "valid_actions": 1,
    }
    participant_by_entrant = {
        assignment.entrant_id: assignment.participant_id for assignment in assignments
    }
    aggregate = {
        "damage_dealt": 0,
        "damage_taken": 0,
        "draws": 2,
        "idle_ticks": 0,
        "losses": 0,
        "objective_control_ticks": 0,
        "valid_action_rate": ratio,
        "wins": 0,
    }
    def supported(value):
        return {"status": "supported", "value": value}

    def unsupported(reason):
        return {"reason": reason, "status": "unsupported"}
    return {
        "entrants": {
            entrant_id: {**entrant, "participant_id": participant_by_entrant[entrant_id]}
            for entrant_id in ("entrant_0", "entrant_1")
        },
        "leg_index": index,
        "metrics": {
            "adaptation_after_losing_exchange": unsupported(
                "exchange_loss_boundary_not_typed"
            ),
            "deterministic_replay_verification": supported(True),
            "disengagement_success": unsupported("disengagement_outcome_not_typed"),
            "positional_advantage": unsupported("exact_positions_not_in_public_replay"),
        },
        "pair_metrics": {
            "deterministic_replay_verification": supported(True),
            "series_result": supported(
                {
                    "draws": 2,
                    "entrant_wins": {"entrant_0": 0, "entrant_1": 0},
                    "winner_entrant_id": None,
                }
            ),
            "side_normalized_performance": supported(
                {"entrant_0": aggregate, "entrant_1": aggregate}
            ),
        },
        "schema_version": EVALUATION_SCHEMA_VERSION,
        "scope": "paired_duel_leg",
    }


@pytest.mark.asyncio
async def test_series_service_never_returns_keys_and_erases_credentials() -> None:
    released = asyncio.Event()
    captured = {}

    async def execute(spec, credentials, cancel_event):
        del cancel_event
        captured["spec"] = spec
        captured["credentials"] = credentials
        await released.wait()
        raise RuntimeError("expected sanitized failure")

    service = DuelSeriesService(execute)
    created = await service.create(
        entrants=(
            {"provider": "openai", "model": "model-a", "api_key": "secret-a"},
            {"provider": "openai", "model": "model-b", "api_key": "secret-b"},
        ),
        seed=7,
    )
    text = repr(created)
    assert "secret-a" not in text and "secret-b" not in text
    assert created["config"]["entrants"][0]["model"] == "model-a"
    released.set()
    while (await service.status(created["series_id"]))["state"] not in ("failed", "completed"):
        await asyncio.sleep(0)
    result = await service.result(created["series_id"])
    assert result["failure"] == "duel_series_execution_failed"
    assert all(credential.closed for credential in captured["credentials"].values())
    assert "secret" not in repr(result)
    await service.aclose()


@pytest.mark.asyncio
async def test_model_versus_scripted_uses_exactly_one_session_credential() -> None:
    captured = {}

    async def execute(spec, credentials, cancel_event):
        del cancel_event
        captured["spec"] = spec
        captured["credentials"] = credentials
        raise RuntimeError("finish after credential inspection")

    service = DuelSeriesService(execute)
    created = await service.create(
        entrants=(
            {"provider": "openai", "model": "model-a", "api_key": "session-only"},
            {"provider": "scripted", "model": "balanced-v1"},
        ),
        seed=11,
        max_live_provider_calls=360,
    )
    while (await service.status(created["series_id"]))["state"] != "failed":
        await asyncio.sleep(0)

    assert captured["spec"].mode == "scripted-duel-v0"
    assert captured["spec"].max_live_provider_calls == 360
    assert created["config"]["max_live_provider_calls"] == 360
    assert set(captured["credentials"]) == {"entrant_0"}
    assert captured["credentials"]["entrant_0"].closed
    assert "session-only" not in repr(await service.result(created["series_id"]))
    await service.aclose()


@pytest.mark.asyncio
async def test_scripted_entrant_shape_and_cardinality_fail_closed() -> None:
    async def execute(spec, credentials, cancel_event):
        raise AssertionError((spec, credentials, cancel_event))

    service = DuelSeriesService(execute)
    model = {"provider": "openai", "model": "model-a", "api_key": "key"}
    for scripted in (
        {"provider": "scripted", "model": "balanced-v1", "api_key": "forbidden"},
        {"provider": "scripted", "model": "unknown-v1"},
    ):
        with pytest.raises(ValueError):
            await service.create(entrants=(model, scripted), seed=1)
    with pytest.raises(ValueError):
        await service.create(
            entrants=(
                {"provider": "scripted", "model": "scout-v1"},
                {"provider": "scripted", "model": "challenger-v1"},
            ),
            seed=1,
        )
    assert not service._records
    await service.aclose()


@pytest.mark.asyncio
async def test_demo_series_requires_exactly_two_keyless_policies_and_is_non_certifying() -> None:
    captured = {}

    async def execute(spec, credentials, cancel_event):
        del cancel_event
        captured["spec"] = spec
        captured["credentials"] = credentials
        raise RuntimeError("stop after demo boundary inspection")

    service = DuelSeriesService(execute)
    created = await service.create(
        entrants=(
            {"provider": "demo", "model": "duelist-alpha-v1"},
            {"provider": "demo", "model": "duelist-bravo-v1"},
        ),
        seed=19,
        max_live_provider_calls=12,
    )
    while (await service.status(created["series_id"]))["state"] != "failed":
        await asyncio.sleep(0)

    assert captured["credentials"] == {}
    assert captured["spec"].is_demo is True
    assert captured["spec"].mode == "model-duel-v0"
    assert created["config"]["certification"] == {
        "eligible": False,
        "reason": "demo_provider",
    }
    assert "api_key" not in repr(created)

    live = {"provider": "openai", "model": "model-a", "api_key": "key"}
    for invalid in (
        (
            {"provider": "demo", "model": "duelist-alpha-v1"},
            live,
        ),
        (
            {"provider": "demo", "model": "duelist-alpha-v1", "api_key": "forbidden"},
            {"provider": "demo", "model": "duelist-bravo-v1"},
        ),
        (
            {"provider": "demo", "model": "unknown-v1"},
            {"provider": "demo", "model": "duelist-bravo-v1"},
        ),
    ):
        with pytest.raises(ValueError):
            await service.create(entrants=invalid, seed=19)
    await service.aclose()


@pytest.mark.asyncio
async def test_demo_series_exposes_only_safe_non_certifying_timeline_and_evaluation() -> None:
    async def execute(spec, credentials, cancel_event):
        assert credentials == {}
        del cancel_event
        return _execution(spec.series_id, certification_eligible=False)

    service = DuelSeriesService(execute)
    created = await service.create(
        entrants=(
            {"provider": "demo", "model": "duelist-alpha-v1"},
            {"provider": "demo", "model": "duelist-bravo-v1"},
        ),
        seed=19,
    )
    while (await service.status(created["series_id"]))["state"] != "completed":
        await asyncio.sleep(0)

    evaluation = await service.evaluation(created["series_id"])
    timeline = await service.timeline(created["series_id"])
    assert evaluation["certification"] == {
        "eligible": False,
        "reason": "demo_provider",
    }
    assert len(evaluation["legs"]) == len(timeline["legs"]) == 2
    assert all(leg["run"]["certification_eligible"] is False for leg in evaluation["legs"])
    assert all(leg["scope"] == "paired_duel_leg" for leg in evaluation["legs"])
    assert set(timeline["legs"][0]["receipts"][0]["participants"]["participant_0"]) == {
        "accepted",
        "action_id",
        "applied_ticks",
        "disposition",
        "fallback",
        "no_input_reason",
    }
    public_text = repr((evaluation, timeline)).lower()
    for forbidden in (
        "observation_json",
        "frame_png",
        "system_prompt",
        "raw_output",
        "api_key",
        "credential",
        "spectator",
    ):
        assert forbidden not in public_text
    await service.aclose()


@pytest.mark.asyncio
async def test_series_service_cancellation_closes_both_same_provider_credentials() -> None:
    started = asyncio.Event()

    async def execute(spec, credentials, cancel_event):
        del spec, credentials, cancel_event
        started.set()
        await asyncio.Event().wait()

    service = DuelSeriesService(execute)
    created = await service.create(
        entrants=(
            {"provider": "gemini", "model": "model-a", "api_key": "key-a"},
            {"provider": "gemini", "model": "model-b", "api_key": "key-b"},
        ),
        seed=0,
    )
    await started.wait()
    status = await service.cancel(created["series_id"])
    assert status["state"] == "cancelled"
    await service.aclose()


@pytest.mark.asyncio
async def test_series_validation_closes_credentials_created_before_later_key_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    created: list[SessionCredential] = []

    class RecordingCredential(SessionCredential):
        def __init__(self, secret: str) -> None:
            super().__init__(secret)
            created.append(self)

    monkeypatch.setattr(service_module, "SessionCredential", RecordingCredential)

    async def execute(spec, credentials, cancel_event):
        raise AssertionError((spec, credentials, cancel_event))

    service = DuelSeriesService(execute)
    with pytest.raises(CredentialError, match="invalid"):
        await service.create(
            entrants=(
                {"provider": "openai", "model": "model-a", "api_key": "secret-a"},
                {"provider": "gemini", "model": "model-b", "api_key": "bad\x00key"},
            ),
            seed=3,
        )

    assert len(created) == 1
    assert created[0].closed
    assert len(service._records) == 0
    await service.aclose()


@pytest.mark.asyncio
async def test_complete_series_retains_both_layers_but_exposes_only_public_replay() -> None:
    captured_credentials = {}

    async def execute(spec, credentials, cancel_event):
        nonlocal captured_credentials
        del cancel_event
        captured_credentials = credentials
        return _execution(spec.series_id)

    service = DuelSeriesService(execute)
    created = await service.create(
        entrants=(
            {"provider": "openai", "model": "model-a", "api_key": "session-alpha"},
            {"provider": "anthropic", "model": "model-b", "api_key": "session-bravo"},
        ),
        seed=7,
    )
    while (await service.status(created["series_id"]))["state"] != "completed":
        await asyncio.sleep(0)

    public = await service.replay(created["series_id"])
    protected = await service.protected_bundle(created["series_id"])
    assert public.layer == PUBLIC_LAYER
    assert protected.layer == PROTECTED_LAYER
    assert len(public.legs) == len(protected.legs) == 2
    assert b"session-alpha" not in public.bundle_bytes
    assert b"session-bravo" not in public.bundle_bytes
    assert all(credential.closed for credential in captured_credentials.values())
    await service.aclose()


@pytest.mark.asyncio
async def test_void_pair_retains_result_without_any_aggregate_evidence() -> None:
    async def execute(spec, credentials, cancel_event):
        del credentials, cancel_event
        return _execution(spec.series_id, valid=False)

    service = DuelSeriesService(execute)
    created = await service.create(
        entrants=(
            {"provider": "openai", "model": "model-a", "api_key": "session-alpha"},
            {"provider": "anthropic", "model": "model-b", "api_key": "session-bravo"},
        ),
        seed=7,
    )
    while (await service.status(created["series_id"]))["state"] != "completed":
        await asyncio.sleep(0)
    result = await service.result(created["series_id"])
    assert result["result"]["status"] == "invalid"
    assert result["result"]["entrant_wins"] == (0, 0)
    assert result["result"]["rerun_required"] is True
    with pytest.raises(DuelSeriesEvidenceNotReadyError):
        await service.replay(created["series_id"])
    with pytest.raises(DuelSeriesEvidenceNotReadyError):
        await service.protected_bundle(created["series_id"])
    await service.aclose()


@pytest.mark.asyncio
async def test_repeated_void_rerun_exhaustion_becomes_one_sanitized_failed_state() -> None:
    attempts = 0

    async def execute(spec, credentials, cancel_event):
        nonlocal attempts
        del spec, credentials, cancel_event
        for _ in range(3):
            attempts += 1
            await asyncio.sleep(0)
        raise RepeatedInvalidPairError("internal rerun detail must not escape")

    service = DuelSeriesService(execute)
    created = await service.create(
        entrants=(
            {"provider": "openai", "model": "model-a", "api_key": "session-alpha"},
            {"provider": "anthropic", "model": "model-b", "api_key": "session-bravo"},
        ),
        seed=7,
    )
    while (await service.status(created["series_id"]))["state"] != "failed":
        await asyncio.sleep(0)
    result = await service.result(created["series_id"])
    assert attempts == 3
    assert result["state"] == "failed"
    assert result["failure"] == "duel_series_execution_failed"
    assert result["result"] is None
    assert "rerun detail" not in repr(result)
    with pytest.raises(DuelSeriesEvidenceNotReadyError):
        await service.replay(created["series_id"])
    await service.aclose()


@pytest.mark.asyncio
async def test_cancellation_during_a_rerun_closes_credentials_and_stays_cancelled() -> None:
    rerun_started = asyncio.Event()
    captured_credentials = {}

    async def execute(spec, credentials, cancel_event):
        nonlocal captured_credentials
        del spec, cancel_event
        captured_credentials = credentials
        await asyncio.sleep(0)  # first invalid attempt completed
        rerun_started.set()
        await asyncio.Event().wait()

    service = DuelSeriesService(execute)
    created = await service.create(
        entrants=(
            {"provider": "openai", "model": "model-a", "api_key": "session-alpha"},
            {"provider": "anthropic", "model": "model-b", "api_key": "session-bravo"},
        ),
        seed=7,
    )
    await rerun_started.wait()
    status = await service.cancel(created["series_id"])
    assert status["state"] == "cancelled"
    assert all(credential.closed for credential in captured_credentials.values())
    with pytest.raises(DuelSeriesEvidenceNotReadyError):
        await service.replay(created["series_id"])
    await service.aclose()


@pytest.mark.asyncio
async def test_completed_demo_pair_is_durable_and_public_routes_survive_service_restart(
    tmp_path,
) -> None:
    archive = DuelSeriesArchive(tmp_path)

    async def execute(spec, credentials, cancel_event):
        assert credentials == {}
        del cancel_event
        return _execution(spec.series_id, certification_eligible=False)

    service = DuelSeriesService(execute, archive=archive)
    created = await service.create(
        entrants=(
            {"provider": "demo", "model": "duelist-alpha-v1"},
            {"provider": "demo", "model": "duelist-bravo-v1"},
        ),
        seed=7,
    )
    series_id = created["series_id"]
    while (await service.status(series_id))["state"] != "completed":
        await asyncio.sleep(0)
    status = await service.status(series_id)
    while status["archive"]["evidence"]["state"] == "saving":
        await asyncio.sleep(0)
        status = await service.status(series_id)
    assert status["archive"]["evidence"]["state"] == "ready"
    assert status["archive"]["native_replay"] == {
        "state": "unavailable",
        "reason": "participant_video_not_configured",
    }
    await service.aclose()

    async def must_not_execute(*args):
        raise AssertionError(args)

    restarted = DuelSeriesService(must_not_execute, archive=archive)
    replay = await restarted.replay(series_id)
    evaluation = await restarted.evaluation(series_id)
    timeline = await restarted.timeline(series_id)
    archived = await restarted.archive_status(series_id)
    assert replay.series_id == evaluation["series_id"] == timeline["series_id"] == series_id
    assert archived["evidence"]["state"] == "ready"
    assert not any(
        forbidden in repr((evaluation, timeline, archived)).lower()
        for forbidden in (
            "api_key", "credential", "observation_json", "frame_png",
            "system_prompt", "raw_output", "spectator",
        )
    )
    assert not (tmp_path / "embodiment-duel-series" / series_id / "protected.bundle.json").exists()
    await restarted.aclose()


def test_paired_archive_renders_four_verified_participant_videos_without_retaining_authority(
    tmp_path, monkeypatch
) -> None:
    execution = _execution("series_native", certification_eligible=False)
    assert execution.evidence is not None
    calls = []

    def fake_render(**kwargs):
        calls.append((kwargs["participant_id"], kwargs["replay_path"].name))
        kwargs["output_path"].write_bytes(b"native-participant-mp4" * 128)

    monkeypatch.setattr(archive_module, "_render_participant_mp4", fake_render)
    archive = DuelSeriesArchive(
        tmp_path,
        godot_executable=tmp_path / "godot",
        godot_project_path=tmp_path / "project",
        ffmpeg_executable=tmp_path / "ffmpeg",
    )
    protected = DuelSeriesEvidenceBundle.create(
        layer=PROTECTED_LAYER,
        series_id="series_native",
        plan_sha256=execution.evidence.public.plan_sha256,
        fairness_lock_sha256=execution.evidence.public.fairness_lock_sha256,
        legs=(
            EpisodeArtifactBundle.create(
                PROTECTED_LAYER,
                (EpisodeArtifact("authority_replay", "application/json", b"{}"),),
            ),
            EpisodeArtifactBundle.create(
                PROTECTED_LAYER,
                (EpisodeArtifact("authority_replay", "application/json", b"{}"),),
            ),
        ),
    )
    saved = archive.save(
        execution.evidence.public,
        evaluation={"series_id": "series_native", "legs": []},
        timeline={"series_id": "series_native", "legs": []},
        protected_bundle=protected,
    )

    assert len(saved.videos) == 4
    assert {(video.leg_index, video.participant_id) for video in saved.videos} == {
        (0, "participant_0"), (0, "participant_1"),
        (1, "participant_0"), (1, "participant_1"),
    }
    assert len(calls) == 4
    assert archive.video_path("series_native", 1, "participant_1").is_file()
    directory = tmp_path / "embodiment-duel-series" / "series_native"
    assert not tuple(directory.glob("*.replay.json"))
    assert not (directory / "protected.bundle.json").exists()
    public = saved.public_dict()
    assert public["native_replay"]["state"] == "ready"
    assert len(public["native_replay"]["artifacts"]) == 4


def test_paired_archive_dispatches_v2_native_rendering_for_every_leg_and_seat(
    tmp_path, monkeypatch
) -> None:
    execution = _execution("series_native_v2", certification_eligible=False)
    assert execution.evidence is not None
    calls = []

    def fake_render(**kwargs):
        calls.append((kwargs["protocol_version"], kwargs["participant_id"]))
        kwargs["output_path"].write_bytes(b"native-v2-participant-mp4" * 128)

    monkeypatch.setattr(archive_module, "_render_participant_mp4", fake_render)
    archive = DuelSeriesArchive(
        tmp_path,
        godot_executable=tmp_path / "godot",
        godot_project_path=tmp_path / "project",
        ffmpeg_executable=tmp_path / "ffmpeg",
    )
    replay = b'{"protocol_version":"llm-controller/0.2.0"}'
    protected = DuelSeriesEvidenceBundle.create(
        layer=PROTECTED_LAYER,
        series_id="series_native_v2",
        plan_sha256=execution.evidence.public.plan_sha256,
        fairness_lock_sha256=execution.evidence.public.fairness_lock_sha256,
        legs=tuple(
            EpisodeArtifactBundle.create(
                PROTECTED_LAYER,
                (EpisodeArtifact("authority_replay", "application/json", replay),),
            )
            for _ in (0, 1)
        ),
    )
    saved = archive.save(
        execution.evidence.public,
        evaluation={"series_id": "series_native_v2", "legs": []},
        timeline={"series_id": "series_native_v2", "legs": []},
        protected_bundle=protected,
    )

    assert len(saved.videos) == 4
    assert calls == [
        ("llm-controller/0.2.0", "participant_0"),
        ("llm-controller/0.2.0", "participant_1"),
        ("llm-controller/0.2.0", "participant_0"),
        ("llm-controller/0.2.0", "participant_1"),
    ]
