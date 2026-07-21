import asyncio
import struct
import zlib

from fastapi import FastAPI
from fastapi.testclient import TestClient
from genesis_arena.embodiment.api import router
from genesis_arena.embodiment.artifacts import (
    PROTECTED_LAYER,
    PUBLIC_LAYER,
    EpisodeArtifact,
    EpisodeArtifactBundle,
    EpisodeBundles,
)
from genesis_arena.embodiment.duel.evidence import DuelSeriesEvidenceBundle
from genesis_arena.embodiment.duel.service import DuelSeriesService
from genesis_arena.embodiment.episode_service import EpisodeService
from genesis_arena.embodiment.live_solo import LiveSoloOutcome
from genesis_arena.embodiment.scripted_solo_demo import (
    SCRIPTED_SOLO_MODELS,
    scripted_demo_model,
)


def _chunk(kind: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


def _participant_png(metadata: bytes = b"") -> bytes:
    ihdr = struct.pack(">IIBBBBB", 1280, 720, 8, 6, 0, 0, 0)
    scanlines = b"".join(b"\x00" + b"\x00" * (1280 * 4) for _ in range(720))
    chunks = [_chunk(b"IHDR", ihdr)]
    if metadata:
        chunks.append(_chunk(b"tEXt", b"private\x00" + metadata))
    chunks.extend((_chunk(b"IDAT", zlib.compress(scanlines)), _chunk(b"IEND", b"")))
    return b"\x89PNG\r\n\x1a\n" + b"".join(chunks)


async def _executor(spec, credential, cancel_event, publish_frame, publish_progress):
    if spec.provider == "scripted":
        assert credential is None
    else:
        assert credential is not None
        assert credential.reveal().startswith("sk-")
    await publish_frame(
        "participant_0", 0, _participant_png(b"prompt-and-hidden-state-must-not-leak")
    )
    await publish_progress(1, 1)
    await asyncio.sleep(0)
    public = EpisodeArtifactBundle.create(
        PUBLIC_LAYER, (EpisodeArtifact.json("evaluation", {"score": 1}),)
    )
    protected = EpisodeArtifactBundle.create(
        PROTECTED_LAYER, (EpisodeArtifact.json("observations", []),)
    )
    return LiveSoloOutcome(
        spec.episode_id,
        {"ended": True, "outcome": "success", "reason": "goal_reached"},
        "a" * 64,
        1,
        0,
        EpisodeBundles(public, protected),
    )


def _app() -> FastAPI:
    app = FastAPI()
    app.state.embodiment_episodes = EpisodeService(_executor)

    async def duel_executor(spec, credentials, cancel_event):
        del spec, credentials, cancel_event
        await asyncio.Event().wait()

    app.state.embodiment_series = DuelSeriesService(duel_executor)
    app.include_router(router)
    return app


def _payload(secret: str = "sk-api-never-echo") -> dict:
    return {
        "api_key": secret,
        "model": "test-model",
        "provider": "openai",
        "seed": 7,
        "task_id": "orientation-v0",
    }


def _scripted_demo_payload(task_id: str = "construction-v0") -> dict:
    return {
        "model": scripted_demo_model(task_id),
        "provider": "scripted",
        "seed": 7,
        "task_id": task_id,
        # This represents an older dashboard; the backend must reserve the full demo budget.
        "maximum_episode_ticks": 600,
    }


def _public_series_bundle(series_id: str) -> DuelSeriesEvidenceBundle:
    legs = tuple(
        EpisodeArtifactBundle.create(
            PUBLIC_LAYER,
            (EpisodeArtifact.json("evaluation", {"leg_index": index}),),
        )
        for index in (0, 1)
    )
    return DuelSeriesEvidenceBundle.create(
        layer=PUBLIC_LAYER,
        series_id=series_id,
        plan_sha256="a" * 64,
        fairness_lock_sha256="b" * 64,
        legs=(legs[0], legs[1]),
    )


def test_episode_api_lifecycle_and_replay_never_echo_key() -> None:
    secret = "sk-api-never-echo"
    with TestClient(_app()) as client:
        created_response = client.post("/api/embodiment/episodes", json=_payload(secret))
        assert created_response.status_code == 202
        assert created_response.headers["cache-control"] == "no-store"
        assert secret not in created_response.text
        episode_id = created_response.json()["episode_id"]

        for _ in range(20):
            status = client.get(f"/api/embodiment/episodes/{episode_id}")
            if status.json()["state"] == "completed":
                break
        assert status.json()["state"] == "completed"
        assert status.json()["progress"] == {"authority_tick": 1, "observation_seq": 1}
        timeline = client.get(f"/api/embodiment/episodes/{episode_id}/timeline")
        result = client.get(f"/api/embodiment/episodes/{episode_id}/result")
        replay = client.get(f"/api/embodiment/episodes/{episode_id}/replay")
        frame = client.get(f"/api/embodiment/episodes/{episode_id}/frame")
        assert timeline.status_code == result.status_code == replay.status_code == 200
        assert frame.status_code == 200
        assert frame.headers["content-type"] == "image/png"
        assert frame.headers["cache-control"] == "no-store"
        assert frame.headers["x-frame-state"] == "finished"
        assert frame.headers["x-observation-seq"] == "0"
        assert frame.headers["x-content-sha256"]
        assert b"prompt-and-hidden-state-must-not-leak" not in frame.content
        assert b"tEXt" not in frame.content
        assert replay.headers["x-content-sha256"]
        for response in (status, timeline, result, replay, frame):
            assert secret not in response.text


def test_episode_frame_is_loading_without_player_pixels() -> None:
    async def waiting_executor(spec, credential, cancel_event, publish_frame, publish_progress):
        del spec, credential, publish_frame, publish_progress
        await cancel_event.wait()
        raise asyncio.CancelledError

    app = _app()
    app.state.embodiment_episodes = EpisodeService(waiting_executor)
    with TestClient(app) as client:
        created = client.post("/api/embodiment/episodes", json=_payload())
        episode_id = created.json()["episode_id"]
        frame = client.get(f"/api/embodiment/episodes/{episode_id}/frame")
        assert frame.status_code == 204
        assert frame.content == b""
        assert frame.headers["cache-control"] == "no-store"
        assert frame.headers["x-frame-state"] == "loading"
        assert frame.headers["x-content-type-options"] == "nosniff"
        client.post(f"/api/embodiment/episodes/{episode_id}/cancel")


def test_live_preview_websocket_is_isolated_from_canonical_frame_fallback() -> None:
    private_marker = b"prompt-raw-output-hidden-state-must-not-reach-browser"
    service: EpisodeService

    async def live_preview_executor(
        spec, credential, cancel_event, publish_frame, publish_progress
    ):
        del credential, publish_frame, publish_progress
        accepted = await service.publish_live_preview(
            spec.episode_id, "participant_0", 3, _participant_png(private_marker)
        )
        assert accepted
        await cancel_event.wait()
        raise asyncio.CancelledError

    app = _app()
    service = EpisodeService(live_preview_executor)
    app.state.embodiment_episodes = service
    with TestClient(app) as client:
        created = client.post("/api/embodiment/episodes", json=_payload())
        episode_id = created.json()["episode_id"]
        with client.websocket_connect(
            f"/api/embodiment/episodes/{episode_id}/preview-live"
        ) as websocket:
            pixels = websocket.receive_bytes()
        canonical_frame = client.get(f"/api/embodiment/episodes/{episode_id}/frame")
        client.post(f"/api/embodiment/episodes/{episode_id}/cancel")

    assert pixels.startswith(b"\x89PNG\r\n\x1a\n")
    assert private_marker not in pixels
    assert b"tEXt" not in pixels
    # Direct ingress pixels must never replace the canonical snapshot/final-frame fallback.
    assert canonical_frame.status_code == 204
    assert canonical_frame.headers["x-frame-state"] == "loading"


def test_invalid_create_payload_cannot_reflect_credentials() -> None:
    secret = "sk-malformed-must-not-return"
    payload = _payload(secret)
    payload["unexpected"] = {"authorization": secret}
    with TestClient(_app()) as client:
        response = client.post("/api/embodiment/episodes", json=payload)
    assert response.status_code == 422
    assert response.json() == {"detail": {"code": "invalid_embodiment_episode_request"}}
    assert secret not in response.text


def test_scripted_construction_demo_requires_no_key_and_never_stores_one() -> None:
    with TestClient(_app()) as client:
        created = client.post("/api/embodiment/episodes", json=_scripted_demo_payload())
        assert created.status_code == 202
        assert created.headers["cache-control"] == "no-store"
        body = created.json()
        assert body["config"] == {
            "episode_id": body["episode_id"],
            "maximum_episode_ticks": 1300,
            "model": "construction-demo-v1",
            "observation_profile": "hybrid-visible-v1",
            "provider": "scripted",
            "seed": 7,
            "task_id": "construction-v0",
        }
        # The injected executor completes immediately, but it asserted that it received no
        # SessionCredential.  The service's credential store therefore has no scripted entry.
        assert len(client.app.state.embodiment_episodes._credentials) == 0
        response = client.post(
            "/api/embodiment/episodes",
            json={**_scripted_demo_payload(), "api_key": "sk-must-not-be-accepted"},
        )
        assert response.status_code == 422
        assert "sk-must-not-be-accepted" not in response.text


def test_all_scripted_solo_demos_require_no_key_and_keep_their_task_budget() -> None:
    with TestClient(_app()) as client:
        for task_id, model in SCRIPTED_SOLO_MODELS.items():
            created = client.post("/api/embodiment/episodes", json=_scripted_demo_payload(task_id))
            assert created.status_code == 202
            config = created.json()["config"]
            assert config["provider"] == "scripted"
            assert config["model"] == model
            assert config["task_id"] == task_id
            assert config["maximum_episode_ticks"] == (
                1300 if task_id == "construction-v0" else 600
            )
        assert len(client.app.state.embodiment_episodes._credentials) == 0


def test_scripted_solo_demo_cannot_select_a_live_or_scored_route() -> None:
    invalid_payloads = (
        {**_scripted_demo_payload(), "task_id": "orientation-v0"},
        {**_scripted_demo_payload(), "model": "balanced-v1"},
        {
            "provider": "scripted",
            "model": "orientation-demo-v1",
            "task_id": "not-a-solo-stage-v0",
            "seed": 7,
        },
    )
    with TestClient(_app()) as client:
        for payload in invalid_payloads:
            response = client.post("/api/embodiment/episodes", json=payload)
            assert response.status_code == 422
            assert response.json() == {"detail": {"code": "invalid_embodiment_episode_request"}}


def test_series_api_never_echoes_either_key() -> None:
    keys = ("sk-series-alpha", "sk-series-bravo")
    payload = {
        "entrants": [
            {"provider": "openai", "model": "model-a", "api_key": keys[0]},
            {"provider": "anthropic", "model": "model-b", "api_key": keys[1]},
        ],
        "seed": 19,
    }
    with TestClient(_app()) as client:
        created = client.post("/api/embodiment/series", json=payload)
        assert created.status_code == 202
        assert created.headers["cache-control"] == "no-store"
        series_id = created.json()["series_id"]
        status = client.get(f"/api/embodiment/series/{series_id}")
        cancelled = client.post(f"/api/embodiment/series/{series_id}/cancel")
        assert status.status_code == cancelled.status_code == 200
        assert status.headers["cache-control"] == "no-store"
        assert cancelled.json()["state"] == "cancelled"
        for response in (created, status, cancelled):
            assert all(key not in response.text for key in keys)


def test_series_api_accepts_credential_free_scripted_opponent() -> None:
    secret = "sk-model-versus-scripted"
    payload = {
        "entrants": [
            {"provider": "openai", "model": "model-a", "api_key": secret},
            {"provider": "scripted", "model": "balanced-v1"},
        ],
        "seed": 21,
        "max_live_provider_calls": 360,
    }
    with TestClient(_app()) as client:
        created = client.post("/api/embodiment/series", json=payload)
        assert created.status_code == 202
        series_id = created.json()["series_id"]
        assert created.json()["config"]["entrants"][1] == {
            "entrant_id": "entrant_1",
            "provider": "scripted",
            "model": "balanced-v1",
        }
        assert created.json()["config"]["max_live_provider_calls"] == 360
        assert secret not in created.text
        client.post(f"/api/embodiment/series/{series_id}/cancel")


def test_series_api_rejects_any_scripted_credential_and_two_scripted_entrants() -> None:
    invalid_payloads = (
        {
            "entrants": [
                {"provider": "openai", "model": "model-a", "api_key": "key"},
                {"provider": "scripted", "model": "balanced-v1", "api_key": ""},
            ],
            "seed": 1,
        },
        {
            "entrants": [
                {"provider": "scripted", "model": "scout-v1"},
                {"provider": "scripted", "model": "balanced-v1"},
            ],
            "seed": 1,
        },
    )
    with TestClient(_app()) as client:
        for payload in invalid_payloads:
            response = client.post("/api/embodiment/series", json=payload)
            assert response.status_code == 422
            assert response.json() == {"detail": {"code": "invalid_embodiment_series_request"}}


def test_series_public_replay_is_no_store_and_protected_layer_has_no_route() -> None:
    keys = ("sk-series-replay-alpha", "sk-series-replay-bravo")
    payload = {
        "entrants": [
            {"provider": "openai", "model": "model-a", "api_key": keys[0]},
            {"provider": "anthropic", "model": "model-b", "api_key": keys[1]},
        ],
        "seed": 19,
    }
    app = _app()
    with TestClient(app) as client:
        created = client.post("/api/embodiment/series", json=payload)
        series_id = created.json()["series_id"]
        bundle = _public_series_bundle(series_id)
        app.state.embodiment_series._records[series_id].public_evidence = bundle

        replay = client.get(f"/api/embodiment/series/{series_id}/replay")
        protected = client.get(f"/api/embodiment/series/{series_id}/protected-replay")
        assert replay.status_code == 200
        assert replay.headers["cache-control"] == "no-store"
        assert replay.headers["x-content-sha256"] == bundle.content_sha256
        assert replay.content == bundle.bundle_bytes
        assert protected.status_code == 404
        assert all(key not in replay.text for key in keys)


def test_series_replay_is_conflict_until_a_complete_pair_is_sealed() -> None:
    payload = {
        "entrants": [
            {"provider": "openai", "model": "model-a", "api_key": "key-alpha"},
            {"provider": "anthropic", "model": "model-b", "api_key": "key-bravo"},
        ],
        "seed": 19,
    }
    with TestClient(_app()) as client:
        created = client.post("/api/embodiment/series", json=payload)
        response = client.get(f"/api/embodiment/series/{created.json()['series_id']}/replay")
    assert response.status_code == 409
    assert response.headers["cache-control"] == "no-store"
    assert response.json() == {"detail": {"code": "embodiment_series_evidence_not_ready"}}
