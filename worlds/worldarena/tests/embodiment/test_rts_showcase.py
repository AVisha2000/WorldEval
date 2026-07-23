from __future__ import annotations

import json
from copy import deepcopy

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from genesis_arena.embodiment.api import router
from genesis_arena.embodiment.rts_showcase import CachedRtsShowcase, RtsShowcaseError
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT


def _app() -> FastAPI:
    app = FastAPI()
    app.state.embodiment_rts_showcase = CachedRtsShowcase.load(ROOT)
    app.include_router(router)
    return app


def test_cached_rts_showcase_publishes_only_manifest_safe_projections() -> None:
    with TestClient(_app()) as client:
        showcase = client.get("/api/embodiment/showcases/rts-skirmish-v0")
        evaluation = client.get("/api/embodiment/showcases/rts-skirmish-v0/evaluation")

    assert showcase.status_code == 200
    assert showcase.headers["cache-control"] == "public, max-age=3600"
    assert evaluation.status_code == 200
    public = showcase.json()
    metrics = evaluation.json()
    assert public["cached"] is True
    assert public["video"]["mime_type"] == "video/mp4"
    assert metrics["verification"]["state"] == "verified"
    serialized = repr({"showcase": public, "evaluation": metrics}).casefold()
    for protected in ("prompt", "raw_output", "credential", "observation", "memory"):
        assert protected not in serialized


def test_cached_rts_showcase_never_registers_a_public_replay_route() -> None:
    with TestClient(_app()) as client:
        response = client.get("/api/embodiment/showcases/rts-skirmish-v0/replay")

    assert response.status_code == 404


def test_cached_rts_video_supports_range_playback_without_exposing_replay() -> None:
    with TestClient(_app()) as client:
        response = client.get(
            "/api/embodiment/showcases/rts-skirmish-v0/video",
            headers={"Range": "bytes=0-7"},
        )

    assert response.status_code == 206
    assert len(response.content) == 8
    assert response.headers["content-range"].startswith("bytes 0-7/")
    assert response.headers["x-content-type-options"] == "nosniff"


@pytest.mark.parametrize(
    "private_text",
    ("raw_output", "api_key", "API key", "Bearer token", "client secret"),
)
def test_cached_rts_manifest_rejects_private_text_variants(private_text: str) -> None:
    manifest = deepcopy(
        json.loads(
            (ROOT / "godot/showcases/rts_skirmish/manifest.json").read_text(encoding="utf-8")
        )
    )
    manifest["label"] = private_text

    with pytest.raises(RtsShowcaseError, match="manifest_invalid"):
        CachedRtsShowcase._validate_manifest(manifest)
