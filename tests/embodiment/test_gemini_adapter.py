from __future__ import annotations

import asyncio
import hashlib
import json
import time
from typing import Any

import pytest
from genesis_arena.embodiment.providers.contracts import (
    InMemoryProviderAuditLog,
    ProviderFailureKind,
    ProviderRequest,
)
from genesis_arena.embodiment.providers.gemini_adapter import GeminiAdapter, GeminiHTTPResponse

PNG = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR" + (1280).to_bytes(4, "big") + (720).to_bytes(4, "big")


def _request(**changes: Any) -> ProviderRequest:
    observation = {
        "episode_id": "episode-g",
        "frame": {
            "height": 720,
            "mime_type": "image/png",
            "sensor_id": "operator-follow-v1",
            "sha256": hashlib.sha256(PNG).hexdigest(),
            "transport_ref": "frame:player-1.7.fixture",
            "width": 1280,
        },
        "goal": "Target left.",
        "observation_seq": 7,
        "profile": "hybrid-visible-v1",
    }
    values: dict[str, Any] = {
        "episode_id": "episode-g",
        "participant_id": "player-1",
        "observation_seq": 7,
        "deadline_monotonic_ns": time.monotonic_ns() + 1_000_000_000,
        "model": "gemini-2.5-flash",
        "system_prompt": "Return one legal action.",
        "observation_json": json.dumps(observation, sort_keys=True, separators=(",", ":")).encode(),
        "action_schema_json": (
            b'{"type":"object","properties":{"action":{"type":"string"}},'
            b'"required":["action"],"additionalProperties":false}'
        ),
        "scratchpad_utf8": b"guard first",
        "frame_png": PNG,
        "max_output_bytes": 256,
    }
    values.update(changes)
    return ProviderRequest(**values)


def _success_response(text: str = '{"action":"guard"}') -> GeminiHTTPResponse:
    return GeminiHTTPResponse(
        200,
        {
            "candidates": [
                {
                    "finishReason": "STOP",
                    "content": {"parts": [{"text": text}]},
                }
            ],
            "usageMetadata": {
                "promptTokenCount": 90,
                "candidatesTokenCount": 6,
                "cachedContentTokenCount": 11,
            },
        },
        {"x-goog-request-id": "google-request-456", "authorization": "never-record"},
    )


@pytest.mark.asyncio
async def test_success_uses_json_schema_hybrid_payload_and_sanitized_audit() -> None:
    calls: list[dict[str, Any]] = []
    secret = "gemini-session-secret"
    audit = InMemoryProviderAuditLog()

    async def transport(**kwargs: Any) -> GeminiHTTPResponse:
        calls.append(kwargs)
        return _success_response()

    adapter = GeminiAdapter(api_key=secret, transport=transport, audit_log=audit)
    request = _request()
    result = await adapter.request(request)

    assert result.failure is None
    assert result.raw_output == b'{"action":"guard"}'
    assert result.telemetry.input_tokens == 90
    assert result.telemetry.output_tokens == 6
    assert result.telemetry.cached_input_tokens == 11
    assert result.telemetry.request_id_sha256 is not None
    assert len(calls) == 1
    call = calls[0]
    assert call["headers"]["x-goog-api-key"] == secret
    assert "?key=" not in call["url"]
    assert call["url"].endswith("/gemini-2.5-flash:generateContent")
    assert 0 < call["timeout"] <= 1.0
    body = call["json"]
    assert body["generationConfig"]["responseMimeType"] == "application/json"
    assert body["generationConfig"]["maxOutputTokens"] == 2048
    assert body["generationConfig"]["responseJsonSchema"]["additionalProperties"] is False
    parts = body["contents"][0]["parts"]
    assert parts[0]["inlineData"]["mimeType"] == "image/png"
    player_payload = json.loads(parts[1]["text"])
    assert player_payload["observation"]["goal"] == "Target left."
    assert player_payload["scratchpad"] == "guard first"
    assert "opponent" not in parts[1]["text"]
    assert "spectator" not in parts[1]["text"]
    serialized_body = repr(body)
    assert "hidden_state" not in serialized_body
    assert secret not in serialized_body

    records = audit.drain_episode(request.episode_id)
    assert len(records) == 1
    assert records[0].result == result
    assert secret not in repr(result)
    assert secret not in repr(records[0])
    assert "never-record" not in repr(records[0])


@pytest.mark.asyncio
async def test_expired_deadline_is_timeout_without_transport_call() -> None:
    calls = 0

    async def transport(**kwargs: Any) -> GeminiHTTPResponse:
        nonlocal calls
        calls += 1
        raise AssertionError(kwargs)

    adapter = GeminiAdapter(api_key="secret", transport=transport)
    result = await adapter.request(_request(deadline_monotonic_ns=1))
    assert result.failure is ProviderFailureKind.TIMEOUT
    assert calls == 0


@pytest.mark.asyncio
async def test_in_flight_timeout_is_not_retried() -> None:
    calls = 0

    async def transport(**kwargs: Any) -> GeminiHTTPResponse:
        nonlocal calls
        calls += 1
        await asyncio.sleep(0.05)
        raise AssertionError(kwargs)

    request = _request(deadline_monotonic_ns=time.monotonic_ns() + 10_000_000)
    result = await GeminiAdapter(api_key="secret", transport=transport).request(request)
    assert result.failure is ProviderFailureKind.TIMEOUT
    assert calls == 1


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("response", "expected"),
    [
        (GeminiHTTPResponse(403, {}, {}), ProviderFailureKind.CREDENTIAL),
        (GeminiHTTPResponse(429, {}, {}), ProviderFailureKind.RATE_LIMIT),
        (
            GeminiHTTPResponse(
                200,
                {"candidates": [{"finishReason": "STOP", "content": {"parts": []}}]},
                {},
            ),
            ProviderFailureKind.INVALID_RESPONSE,
        ),
        (_success_response("not-json"), ProviderFailureKind.INVALID_RESPONSE),
        (_success_response('{"action":NaN}'), ProviderFailureKind.INVALID_RESPONSE),
        (
            GeminiHTTPResponse(200, {"promptFeedback": {"blockReason": "SAFETY"}}, {}),
            ProviderFailureKind.REFUSAL,
        ),
        (
            GeminiHTTPResponse(
                200,
                {"candidates": [{"finishReason": "SAFETY", "content": {"parts": []}}]},
                {},
            ),
            ProviderFailureKind.REFUSAL,
        ),
    ],
)
async def test_sanitized_provider_failures(
    response: GeminiHTTPResponse, expected: ProviderFailureKind
) -> None:
    calls = 0

    async def transport(**kwargs: Any) -> GeminiHTTPResponse:
        nonlocal calls
        calls += 1
        return response

    result = await GeminiAdapter(api_key="secret", transport=transport).request(_request())
    assert result.failure is expected
    assert result.raw_output is None
    assert calls == 1


@pytest.mark.asyncio
async def test_oversize_json_output_is_rejected() -> None:
    async def transport(**kwargs: Any) -> GeminiHTTPResponse:
        return _success_response(json.dumps({"action": "x" * 100}))

    result = await GeminiAdapter(api_key="secret", transport=transport).request(
        _request(max_output_bytes=8)
    )
    assert result.failure is ProviderFailureKind.OUTPUT_TOO_LARGE
