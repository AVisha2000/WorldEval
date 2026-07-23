"""Serve the built local controller dashboard without mixing it into authority code."""

from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from starlette.responses import Response
from starlette.types import Scope


class _ControllerDashboardFiles(StaticFiles):
    """Static dashboard files with a fresh application shell on local refresh.

    Vite gives JavaScript and CSS assets content-hashed filenames, but the HTML
    entrypoint is always ``index.html``.  Leaving that entrypoint to heuristic
    browser caching can keep a local Controller Lab on an old JavaScript bundle
    after a rebuild, which is especially confusing while iterating on the
    dashboard.  Keep the shell non-cacheable while retaining ordinary static
    delivery for the immutable assets it references.
    """

    async def get_response(self, path: str, scope: Scope) -> Response:
        response = await super().get_response(path, scope)
        if path in {"", ".", "index.html"}:
            response.headers["Cache-Control"] = "no-store"
        return response


def mount_built_dashboard(app: FastAPI, directory: Path) -> bool:
    """Mount a completed Vite build last, leaving API/WebSocket routes authoritative."""

    build = Path(directory).resolve()
    if not (build / "index.html").is_file():
        return False
    app.mount(
        "/",
        _ControllerDashboardFiles(directory=build, html=True, check_dir=True),
        name="embodiment-controller-dashboard",
    )
    return True


__all__ = ["mount_built_dashboard"]
