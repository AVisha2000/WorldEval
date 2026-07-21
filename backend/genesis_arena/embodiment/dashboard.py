"""Serve the built local controller dashboard without mixing it into authority code."""

from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles


def mount_built_dashboard(app: FastAPI, directory: Path) -> bool:
    """Mount a completed Vite build last, leaving API/WebSocket routes authoritative."""

    build = Path(directory).resolve()
    if not (build / "index.html").is_file():
        return False
    app.mount(
        "/",
        StaticFiles(directory=build, html=True, check_dir=True),
        name="embodiment-controller-dashboard",
    )
    return True


__all__ = ["mount_built_dashboard"]
