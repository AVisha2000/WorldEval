from __future__ import annotations

import asyncio
from io import BytesIO

import httpx
import pytest
from fastapi import FastAPI
from genesis_arena.embodiment.api import router
from genesis_arena.embodiment.artifacts import PUBLIC_LAYER, EpisodeArtifact, EpisodeArtifactBundle
from genesis_arena.embodiment.trio_games.evidence import TrioSeriesEvidenceBundle
from genesis_arena.embodiment.trio_games.participant_frames import (
    TrioParticipantFrameStore,
    TrioParticipantPreviewChannel,
)
from genesis_arena.embodiment.trio_games.scheduling import TRIO_DEMO_ENTRANTS
from genesis_arena.embodiment.trio_games.service import TrioSeriesService, _timeline
from PIL import Image, PngImagePlugin


def _png(metadata: str) -> bytes:
    image = Image.new("RGBA", (1280, 720), (19, 61, 103, 255))
    info = PngImagePlugin.PngInfo()
    info.add_text("private", metadata)
    output = BytesIO()
    image.save(output, format="PNG", pnginfo=info)
    return output.getvalue()


def _jpeg(metadata: str) -> bytes:
    image = Image.new("RGB", (1280, 720), (19, 61, 103))
    output = BytesIO()
    image.save(output, format="JPEG", quality=82, comment=metadata.encode())
    return output.getvalue()


async def test_trio_api_accepts_only_exact_keyless_demo_entrants() -> None:
    async def executor(_spec, cancel_event):
        await cancel_event.wait()
        raise asyncio.CancelledError

    service = TrioSeriesService(executor)
    app = FastAPI()
    app.state.embodiment_trio_series = service
    app.include_router(router)
    transport = httpx.ASGITransport(app=app)
    exact = [
        {"provider": "demo", "model": entrant.model}
        for entrant in TRIO_DEMO_ENTRANTS
    ]
    try:
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            accepted = await client.post(
                "/api/embodiment/trio-series",
                json={"task_id": "trio-relay-v0", "seed": 9, "entrants": exact},
            )
            assert accepted.status_code == 202
            assert accepted.json()["rotations"] == 3
            assert "api_key" not in accepted.text
            assert "credential" not in accepted.text
            series_id = accepted.json()["series_id"]
            waiting_frame = await client.get(
                f"/api/embodiment/trio-series/{series_id}/participants/participant_2/frame"
            )
            assert waiting_frame.status_code == 204
            assert waiting_frame.headers["x-frame-state"] == "loading"
            await service.publish_frame(series_id, 0, "participant_2", 0, _png("removed"))
            live_frame = await client.get(
                f"/api/embodiment/trio-series/{series_id}/participants/participant_2/frame"
            )
            assert live_frame.status_code == 200
            assert live_frame.headers["x-frame-state"] == "live"
            assert live_frame.headers["x-participant-id"] == "participant_2"
            assert b"removed" not in live_frame.content

            invalid_payloads = (
                {"task_id": "trio-relay-v0", "seed": 9, "entrants": exact[:2]},
                {"task_id": "trio-relay-v0", "seed": 9, "entrants": list(reversed(exact))},
                {"task_id": "trio-relay-v0", "seed": 9, "entrants": [
                    {**exact[0], "api_key": "never"}, exact[1], exact[2]
                ]},
                {"task_id": "trio-relay-v0", "seed": 9, "entrants": [
                    {"provider": "openai", "model": "demo-sol-v1"}, exact[1], exact[2]
                ]},
            )
            for payload in invalid_payloads:
                response = await client.post("/api/embodiment/trio-series", json=payload)
                assert response.status_code == 422
                assert response.json() == {
                    "detail": {"code": "invalid_embodiment_trio_series_request"}
                }
                assert "never" not in response.text
    finally:
        await service.aclose()


def test_trio_png_store_is_participant_isolated_and_metadata_free() -> None:
    store = TrioParticipantFrameStore()
    for index, participant_id in enumerate(
        ("participant_0", "participant_1", "participant_2")
    ):
        store.publish(2, participant_id, 7, _png(f"prompt-{index}-credential"))
    snapshots = [
        store.snapshot(participant_id)
        for participant_id in ("participant_0", "participant_1", "participant_2")
    ]
    assert all(snapshot is not None for snapshot in snapshots)
    assert {snapshot.participant_id for snapshot in snapshots if snapshot} == {
        "participant_0", "participant_1", "participant_2"
    }
    assert len({snapshot.sha256 for snapshot in snapshots if snapshot}) == 1
    for snapshot in snapshots:
        assert snapshot is not None
        assert b"prompt" not in snapshot.png and b"credential" not in snapshot.png
        with Image.open(BytesIO(snapshot.png)) as image:
            assert image.size == (1280, 720)
            assert image.info == {}
    with pytest.raises(ValueError):
        store.snapshot("spectator")


@pytest.mark.asyncio
async def test_trio_jpeg_preview_has_depth_one_and_strips_metadata() -> None:
    channel = TrioParticipantPreviewChannel()
    token, queue, initial = channel.subscribe("participant_2")
    assert initial is None and queue.maxsize == 1
    assert await channel.publish(1, "participant_2", 1, _jpeg("raw-output-one"))
    assert await channel.publish(1, "participant_2", 2, _jpeg("credential-two"))
    newest = queue.get_nowait()
    assert newest.participant_id == "participant_2"
    assert newest.sequence == 2
    assert b"credential-two" not in newest.jpeg
    assert not await channel.publish(1, "participant_2", 2, _jpeg("stale"))
    assert not await channel.publish(1, "spectator", 3, _jpeg("never"))
    channel.unsubscribe("participant_2", token)


def test_public_trio_timeline_projects_only_safe_three_seat_receipts() -> None:
    receipt = {
        "action_id": "demo_action",
        "applied_ticks": 10,
        "codes": ["applied"],
        "disposition": "accepted",
        "private_output": "must be dropped",
    }
    legs = tuple(
        EpisodeArtifactBundle.create(
            PUBLIC_LAYER,
            (
                EpisodeArtifact.json("public_events", [{
                    "kind": "relay_progress", "participant_ids": ["participant_0"],
                    "summary": "Visible relay progress", "tick": leg_index * 10,
                }]),
                EpisodeArtifact.json("receipts", [{
                    "observation_seq": 0,
                    "participants": {
                        participant_id: dict(receipt)
                        for participant_id in ("participant_0", "participant_1", "participant_2")
                    },
                }]),
            ),
        )
        for leg_index in (0, 1, 2)
    )
    bundle = TrioSeriesEvidenceBundle.create(
        layer=PUBLIC_LAYER,
        series_id="trio_timeline",
        plan_sha256="a" * 64,
        protocol_package_sha256="b" * 64,
        legs=legs,
    )
    value = _timeline(bundle)
    assert len(value["legs"]) == 3
    assert set(value["legs"][0]["receipts"][0]["participants"]) == {
        "participant_0", "participant_1", "participant_2"
    }
    rendered = repr(value)
    assert "private_output" not in rendered
    assert "must be dropped" not in rendered
