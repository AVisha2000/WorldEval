from __future__ import annotations

from pathlib import Path

import pytest
from genesis_arena.embodiment.construction_task_provider import ConstructionTaskProvider
from genesis_arena.embodiment.protocol import EmbodimentProtocolPackage, canonical_json_bytes
from genesis_arena.embodiment.providers.contracts import (
    ProviderCallResult,
    ProviderRequest,
    ProviderTelemetry,
)

ROOT = Path(__file__).resolve().parents[2]


class _Provider:
    provider_name = "openai"

    def __init__(self, output: dict) -> None:
        self.output = output
        self.calls = 0

    async def request(self, _request: ProviderRequest) -> ProviderCallResult:
        self.calls += 1
        return ProviderCallResult.success(canonical_json_bytes(self.output), ProviderTelemetry(3))


def _request(
    seq: int = 0, *, inventory: list[dict] | None = None, receipt: dict | None = None
) -> ProviderRequest:
    frame = (
        b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"
        + (1280).to_bytes(4, "big")
        + (720).to_bytes(4, "big")
    )
    observation = {
        "episode_id": "ep_task",
        "observation_seq": seq,
        "profile": "hybrid-visible-v1",
        "frame": {
            "sensor_id": "operator-follow-v1",
            "mime_type": "image/png",
            "width": 1280,
            "height": 720,
            "sha256": __import__("hashlib").sha256(frame).hexdigest(),
            "transport_ref": f"frame:participant_0.{seq}",
        },
        "self": {"inventory": inventory or []},
        "visible_entities": [
            {"id": "v_resource_1", "state": "available"},
            {"id": "v_relay_1", "state": "empty"},
            {"id": "v_build_pad_1", "state": "needs_materials"},
        ],
        "previous_receipt": receipt,
        "terminal": {"ended": False},
    }
    return ProviderRequest(
        episode_id="ep_task",
        participant_id="participant_0",
        observation_seq=seq,
        deadline_monotonic_ns=1,
        model="gpt-5.6",
        system_prompt="test",
        observation_json=canonical_json_bytes(observation),
        action_schema_json=b"{}",
        frame_png=frame,
    )


@pytest.mark.asyncio
async def test_construction_task_provider_calls_model_once_then_replays_local_ticks() -> None:
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    provider = _Provider(
        {
            "protocol_version": "llm-controller/0.1.0",
            "episode_id": "ep_task",
            "observation_seq": 0,
            "task_id": "gather_materials",
            "intent_label": "collect a load",
            "memory_update": "",
        }
    )
    adapter = ConstructionTaskProvider(provider, package)

    first = await adapter.request(_request())
    assert not adapter.last_request_was_continuation
    second = await adapter.request(_request(1))

    assert provider.calls == 1
    assert adapter.last_request_was_continuation
    assert b'"autonomous_task":"gather_materials"' in first.raw_output
    assert b'"autonomous_task":"gather_materials"' in second.raw_output


@pytest.mark.asyncio
async def test_construction_task_provider_rejects_hidden_or_invalid_milestone() -> None:
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    provider = _Provider(
        {
            "protocol_version": "llm-controller/0.1.0",
            "episode_id": "ep_task",
            "observation_seq": 0,
            "task_id": "build_barricade",
            "intent_label": "build",
            "memory_update": "",
        }
    )
    result = await ConstructionTaskProvider(provider, package).request(_request())

    assert result.failure is not None
