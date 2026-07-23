
from fastapi import FastAPI
from fastapi.testclient import TestClient
from genesis_arena.embodiment.api import router
from genesis_arena.embodiment.solo_showcase import CachedSoloShowcase
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT


def test_checked_in_solo_showcase_is_evidence_bound_and_public_safe() -> None:
    showcase = CachedSoloShowcase.load(ROOT)
    public = showcase.public_view()

    assert public["showcase_id"] == "solo-multi-action-v0"
    assert public["scenario_id"] == "multi-action-demo-v0"
    assert public["video"] == {
        "duration_seconds": 121.9,
        "fps": 30,
        "height": 1080,
        "mime_type": "video/mp4",
        "sha256": "3e54bc538ebad897c32905274934381bac3ef4468ba37e63c188ce533785856d",
        "width": 1920,
    }
    assert public["verification"]["state"] == "verified"
    serialized = repr(public).casefold()
    for protected in ("api_key", "credential", "prompt", "raw_output", "scratchpad"):
        assert protected not in serialized


def test_solo_showcase_serves_range_video_without_exposing_evidence() -> None:
    app = FastAPI()
    app.state.embodiment_solo_showcase = CachedSoloShowcase.load(ROOT)
    app.include_router(router)

    with TestClient(app) as client:
        metadata = client.get("/api/embodiment/showcases/solo-multi-action-v0")
        video = client.get(
            "/api/embodiment/showcases/solo-multi-action-v0/video",
            headers={"Range": "bytes=0-7"},
        )
        evidence = client.get("/api/embodiment/showcases/solo-multi-action-v0/evidence")

    assert metadata.status_code == 200
    assert metadata.headers["cache-control"] == "public, max-age=3600, immutable"
    assert video.status_code == 206
    assert video.content[4:8] == b"ftyp"
    assert evidence.status_code == 404
