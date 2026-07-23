from pathlib import Path

from fastapi import FastAPI
from fastapi.testclient import TestClient
from genesis_arena.embodiment.dashboard import mount_built_dashboard


def test_dashboard_mount_preserves_api_routes_and_serves_vite_build(tmp_path: Path) -> None:
    build = tmp_path / "dist"
    build.mkdir()
    (build / "index.html").write_text("<main>Controller Lab</main>", encoding="utf-8")
    app = FastAPI()

    @app.get("/api/probe")
    async def probe() -> dict[str, bool]:
        return {"ok": True}

    assert mount_built_dashboard(app, build)

    with TestClient(app) as client:
        assert client.get("/api/probe").json() == {"ok": True}
        response = client.get("/")
        assert response.status_code == 200
        assert "Controller Lab" in response.text
        assert response.headers["cache-control"] == "no-store"


def test_dashboard_mount_is_absent_until_the_build_exists(tmp_path: Path) -> None:
    app = FastAPI()

    assert not mount_built_dashboard(app, tmp_path / "missing")
    assert all(route.name != "embodiment-controller-dashboard" for route in app.routes)
