from __future__ import annotations

import asyncio
from io import BytesIO

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from genesis_arena.embodiment.api import router
from genesis_arena.embodiment.duel.contracts import DuelEntrant
from genesis_arena.embodiment.duel.evidence import _evaluate_duo_game_replay
from genesis_arena.embodiment.duel.live_runtime import build_paired_duel_plan
from genesis_arena.embodiment.duel.service import DuelSeriesService, DuelSeriesSpec
from genesis_arena.embodiment.duo_games.catalog import DUO_GAME_CATALOG
from genesis_arena.embodiment.protocol_registry import EmbodimentProtocolRegistry
from PIL import Image
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT


async def _waiting_executor(spec, credentials, cancel_event):
    del spec, credentials
    await cancel_event.wait()
    raise asyncio.CancelledError


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("task_id", "models"),
    [(task_id, game.models) for task_id, game in DUO_GAME_CATALOG.items() if game.is_additive_game],
)
async def test_service_selects_exact_keyless_demo_pair_for_each_duo_game(
    task_id: str, models: tuple[str, str]
) -> None:
    service = DuelSeriesService(_waiting_executor)
    created = await service.create(
        entrants=(
            {"provider": "demo", "model": models[0]},
            {"provider": "demo", "model": models[1]},
        ),
        seed=17,
        task_id=task_id,
    )
    assert created["task_id"] == task_id
    assert created["config"]["task_id"] == task_id
    assert created["config"]["certification"] == {
        "eligible": False,
        "reason": "demo_provider",
    }
    assert "api_key" not in repr(created)
    await service.cancel(created["series_id"])
    await service.aclose()


@pytest.mark.asyncio
async def test_service_rejects_cross_game_or_non_demo_duo_entrants() -> None:
    service = DuelSeriesService(_waiting_executor)
    with pytest.raises(ValueError, match="selected duo task"):
        await service.create(
            entrants=(
                {"provider": "demo", "model": "checkpoint-racer-alpha-v1"},
                {"provider": "demo", "model": "sparring-bravo-v1"},
            ),
            seed=1,
            task_id="duo-checkpoint-race-v0",
        )
    with pytest.raises(ValueError, match="exactly two Demo"):
        await service.create(
            entrants=(
                {"provider": "openai", "model": "model-a", "api_key": "secret-a"},
                {"provider": "anthropic", "model": "model-b", "api_key": "secret-b"},
            ),
            seed=1,
            task_id="duo-spar-v0",
        )
    await service.aclose()


def test_api_forwards_task_and_never_requires_or_echoes_a_demo_key() -> None:
    app = FastAPI()
    app.state.embodiment_series = DuelSeriesService(_waiting_executor)
    app.include_router(router)
    payload = {
        "task_id": "duo-relay-control-v0",
        "seed": 11,
        "entrants": [
            {"provider": "demo", "model": "relay-controller-alpha-v1"},
            {"provider": "demo", "model": "relay-controller-bravo-v1"},
        ],
    }
    with TestClient(app) as client:
        response = client.post("/api/embodiment/series", json=payload)
        assert response.status_code == 202
        assert response.json()["task_id"] == payload["task_id"]
        assert "api_key" not in response.text


def _broadcast_jpeg(private_marker: bytes) -> bytes:
    image = Image.new("RGB", (1280, 720), (48, 107, 72))
    encoded = BytesIO()
    image.save(encoded, format="JPEG", quality=82, comment=private_marker)
    return encoded.getvalue()


def test_rts_broadcast_websocket_is_public_pixels_only_and_not_a_player_stream() -> None:
    """The judge view uses its own route and strips metadata before browser delivery."""

    marker = b"hidden-state-prompt-and-credentials-never-reach-broadcast"
    service: DuelSeriesService

    async def broadcast_executor(spec, credentials, cancel_event):
        del credentials
        assert spec.task_id == "rts-skirmish-v0"
        assert await service.publish_live_broadcast_preview(
            spec.series_id, 0, 1, _broadcast_jpeg(marker)
        )
        await cancel_event.wait()
        raise asyncio.CancelledError

    app = FastAPI()
    service = DuelSeriesService(broadcast_executor)
    app.state.embodiment_series = service
    app.include_router(router)
    payload = {
        "task_id": "rts-skirmish-v0",
        "seed": 81,
        "entrants": [
            {"provider": "demo", "model": "rts-harvester-alpha-v1"},
            {"provider": "demo", "model": "rts-commander-bravo-v1"},
        ],
    }
    with TestClient(app) as client:
        created = client.post("/api/embodiment/series", json=payload)
        assert created.status_code == 202
        series_id = created.json()["series_id"]
        with client.websocket_connect(
            f"/api/embodiment/series/{series_id}/broadcast/preview-live"
        ) as websocket:
            pixels = websocket.receive_bytes()
        client.post(f"/api/embodiment/series/{series_id}/cancel")

    assert pixels.startswith(b"\xff\xd8") and pixels.endswith(b"\xff\xd9")
    assert marker not in pixels
    assert b"participant_0" not in pixels and b"participant_1" not in pixels


@pytest.mark.parametrize(
    ("task_id", "reason", "participant_fields"),
    [
        ("duo-checkpoint-race-v0", "finish", {"checkpoints_reached": 4}),
        ("duo-relay-control-v0", "hold_target", {"control_ticks": 60}),
        (
            "duo-spar-v0",
            "knockout",
            {"hits_landed": 4, "hits_received": 0, "knockouts": 1},
        ),
    ],
)
def test_sealed_public_terminal_events_drive_safe_duo_evaluation(
    task_id: str, reason: str, participant_fields: dict[str, int]
) -> None:
    peer_fields = dict(participant_fields)
    if task_id == "duo-checkpoint-race-v0":
        peer_fields["checkpoints_reached"] = 3
    elif task_id == "duo-relay-control-v0":
        peer_fields["control_ticks"] = 20
    else:
        peer_fields = {"hits_landed": 0, "hits_received": 4, "knockouts": 0}

    def summary(participant_id: str, outcome: str, fields: dict[str, int]):
        return {
            "kind": "duo_participant_summary",
            "participant_ids": [participant_id],
            "data": {
                "task_id": task_id,
                "completion_tick": 120,
                "terminal_outcome": "win",
                "terminal_reason": reason,
                "participant_id": participant_id,
                "outcome": outcome,
                "decision_windows": 12,
                "accepted_windows": 11,
                "fallback_windows": 1,
                "checkpoints_reached": 0,
                "control_ticks": 0,
                "hits_landed": 0,
                "hits_received": 0,
                "knockouts": 0,
                **fields,
            },
        }

    replay = {
        "config": {"task_id": task_id},
        "steps": [
            {
                "result": {
                    "public_events": [
                        {
                            "kind": "duo_game_completed",
                            "participant_ids": ["participant_0", "participant_1"],
                            "data": {
                                "task_id": task_id,
                                "completion_tick": 120,
                                "terminal_outcome": "win",
                                "terminal_reason": reason,
                                "winner_id": "participant_0",
                            },
                        },
                        summary("participant_0", "win", participant_fields),
                        summary("participant_1", "loss", peer_fields),
                    ]
                }
            }
        ],
    }
    value = _evaluate_duo_game_replay(replay)
    assert value["task_id"] == task_id
    assert value["completion"] == {"tick": 120, "outcome": "win", "reason": reason}
    assert set(value["participants"]) == {"participant_0", "participant_1"}
    assert "position" not in repr(value)


@pytest.mark.parametrize(
    "task_id",
    (
        "duo-checkpoint-race-v0",
        "duo-relay-control-v0",
        "duo-spar-v0",
        "rts-skirmish-v0",
    ),
)
def test_product_plan_selects_v2_and_preserves_two_leg_seat_swap(task_id: str) -> None:
    registry = EmbodimentProtocolRegistry.from_repository(ROOT)
    game = DUO_GAME_CATALOG[task_id]
    spec = DuelSeriesSpec(
        "series_product_test",
        (
            DuelEntrant("entrant_0", "demo", game.models[0]),
            DuelEntrant("entrant_1", "demo", game.models[1]),
        ),
        5,
        "fixed-nonce",
        task_id=task_id,
    )
    plan = build_paired_duel_plan(
        spec=spec,
        repository_root=ROOT,
        godot_project_path=ROOT / "godot",
        protocol_package=registry.package("llm-controller/0.2.0"),
        provider_timeout_s=1,
    )
    assert plan.fairness_lock.protocol_version == "llm-controller/0.2.0"
    assert plan.legs[0].assignments[0].entrant_id == "entrant_0"
    assert plan.legs[1].assignments[0].entrant_id == "entrant_1"
    assert all(leg.decision_ticks == 10 for leg in plan.legs)
