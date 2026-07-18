from __future__ import annotations

from pathlib import Path
from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


class Settings(BaseSettings):
    """Runtime configuration loaded from GENESIS_* variables and .env."""

    model_config = SettingsConfigDict(
        env_file=str(REPOSITORY_ROOT / ".env"),
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
    memory_dir: Path = REPOSITORY_ROOT / "memory"
    agents_dir: Path = REPOSITORY_ROOT / "agents"
