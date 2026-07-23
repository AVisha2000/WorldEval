from __future__ import annotations

import shutil
from pathlib import Path
from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict
from worldeval.workspace import find_workspace

_WORKSPACE = find_workspace(Path(__file__))
WORKSPACE_ROOT = _WORKSPACE.root
REPOSITORY_ROOT = _WORKSPACE.path("worldarena")


def _default_godot_executable() -> Path:
    """Choose a conventional local Godot binary without invoking a shell."""

    candidates = (
        Path("/Applications/Godot.app/Contents/MacOS/Godot"),
        Path("/Applications/Godot.app/Godot.app/Contents/MacOS/Godot"),
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    discovered = shutil.which("godot") or shutil.which("Godot")
    return Path(discovered) if discovered else candidates[0]


def _default_ffmpeg_executable() -> Path:
    """Use the checked-in local video tool when one is available."""

    candidates = (
        WORKSPACE_ROOT
        / ".video-tools/lib/python3.9/site-packages/imageio_ffmpeg/binaries/"
        "ffmpeg-macos-aarch64-v7.1",
        Path("/opt/homebrew/bin/ffmpeg"),
        Path("/usr/local/bin/ffmpeg"),
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    discovered = shutil.which("ffmpeg")
    return Path(discovered) if discovered else candidates[0]


class Settings(BaseSettings):
    """Runtime configuration loaded from GENESIS_* variables and .env."""

    model_config = SettingsConfigDict(
        env_file=str(WORKSPACE_ROOT / ".env"),
        env_prefix="GENESIS_",
        extra="ignore",
    )

    brain_mode: Literal["demo", "openai", "auto"] = "demo"
    openai_model: str = "gpt-5.6-sol"
    reasoning_effort: Literal["none", "low", "medium", "high", "xhigh", "max"] = "low"
    host: str = "127.0.0.1"
    port: int = Field(default=8000, ge=1, le=65535)
    decision_timeout_seconds: float = Field(default=45.0, gt=1, le=300)
    action_catalog_path: Path = REPOSITORY_ROOT / "game" / "actions.json"
    memory_dir: Path = REPOSITORY_ROOT / "legacy" / "survival" / "memory"
    agents_dir: Path = REPOSITORY_ROOT / "legacy" / "survival" / "agents"
    runs_dir: Path = WORKSPACE_ROOT / "runs"
    embodiment_readiness_path: Path = (
        WORKSPACE_ROOT / "exports/embodiment-pilot/readiness.json"
    )
    godot_executable: Path = Field(default_factory=_default_godot_executable)
    godot_project_path: Path = REPOSITORY_ROOT / "godot"
    ffmpeg_executable: Path = Field(default_factory=_default_ffmpeg_executable)
