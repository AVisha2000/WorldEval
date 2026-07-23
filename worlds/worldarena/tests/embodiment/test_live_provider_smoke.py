from __future__ import annotations

import hashlib
import os
import time
import zlib
from binascii import crc32
from struct import pack

import pytest
from genesis_arena.embodiment.credentials import SessionCredential
from genesis_arena.embodiment.live_runtime import (
    SYSTEM_PROMPT,
    close_provider_adapter,
    provider_adapter,
)
from genesis_arena.embodiment.live_solo import parse_controller_action
from genesis_arena.embodiment.protocol import EmbodimentProtocolPackage, canonical_json_bytes
from genesis_arena.embodiment.providers.contracts import ProviderRequest
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT


def _png() -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return pack(">I", len(data)) + kind + data + pack(">I", crc32(kind + data) & 0xFFFFFFFF)

    rows = b"".join(b"\x00" + b"\x20\x38\x48" * 1280 for _ in range(720))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", pack(">IIBBBBB", 1280, 720, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows, 9))
        + chunk(b"IEND", b"")
    )


@pytest.mark.live_provider
@pytest.mark.parametrize("provider", ["openai", "anthropic", "gemini"])
@pytest.mark.asyncio
async def test_opt_in_provider_returns_strict_hybrid_action(provider: str) -> None:
    prefix = f"WORLDARENA_{provider.upper()}"
    key = os.environ.get(f"{prefix}_API_KEY")
    model = os.environ.get(f"{prefix}_MODEL")
    if not key or not model:
        pytest.skip(f"set {prefix}_API_KEY and {prefix}_MODEL to run this smoke test")
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    png = _png()
    metadata = {
        "sensor_id": "operator-follow-v1",
        "mime_type": "image/png",
        "width": 1280,
        "height": 720,
        "sha256": hashlib.sha256(png).hexdigest(),
        "transport_ref": "frame:participant_0.0.live_smoke",
    }
    observation = {
        "protocol_version": "llm-controller/0.1.0",
        "episode_id": "ep_live_provider_smoke",
        "observation_seq": 0,
        "tick": 0,
        "profile": "hybrid-visible-v1",
        "goal": "Remain still for one decision window.",
        "remaining_ticks": 20,
        "self": {
            "health_percent": 100,
            "energy_percent": 100,
            "facing": "north",
            "contact": "clear",
            "inventory": [],
            "status": [],
        },
        "visible_entities": [],
        "recent_events": [],
        "previous_receipt": None,
        "memory": "",
        "frame": metadata,
        "terminal": {"ended": False, "outcome": "running", "reason": "running"},
    }
    package.validate("observation", observation)
    credential = SessionCredential(key)
    adapter = provider_adapter(provider, credential)
    try:
        result = await adapter.request(
            ProviderRequest(
                episode_id=observation["episode_id"],
                participant_id="participant_0",
                observation_seq=0,
                deadline_monotonic_ns=time.monotonic_ns() + 60_000_000_000,
                model=model,
                system_prompt=SYSTEM_PROMPT,
                observation_json=canonical_json_bytes(observation),
                action_schema_json=canonical_json_bytes(package.schema("controller-action")),
                frame_png=png,
            )
        )
        assert result.failure is None
        action = parse_controller_action(result.raw_output or b"", package=package)
        assert action.episode_id == observation["episode_id"]
        assert action.observation_seq == 0
    finally:
        await close_provider_adapter(adapter)
        credential.close()
