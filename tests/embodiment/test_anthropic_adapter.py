from __future__ import annotations

import asyncio
import hashlib
import json
import time
from typing import Any

import pytest
from genesis_arena.embodiment.providers.anthropic_adapter import (
    AnthropicAdapter,
    AnthropicHTTPResponse,
)
from genesis_arena.embodiment.providers.contracts import (
    InMemoryProviderAuditLog,
    ProviderFailureKind,
    ProviderRequest,
)

PNG = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR" + (1280).to_bytes(4, "big") + (720).to_bytes(4, "big")


def _request(**changes: Any) -> ProviderRequest:
    observation = {
        "episode_id": "episode-a",
        "frame": {
            "height": 720,
            "mime_type": "image/png",
            "sensor_id": "operator-follow-v1",
            "sha256": hashlib.sha256(PNG).hexdigest(),
            "transport_ref": "frame:player-1.4.fixture",
            "width": 1280,
        },
        "goal": "Relay ahead.",
        "observation_seq": 4,
        "profile": "hybrid-visible-v1",
    }
    values: dict[str, Any] = {
        "episode_id": "episode-a",
        "participant_id": "player-1",
        "observation_seq": 4,
        "deadline_monotonic_ns": time.monotonic_ns() + 1_000_000_000,
        "model": "claude-sonnet-4-5",
        "system_prompt": "Return one legal action.",
        "observation_json": json.dumps(observation, sort_keys=True, separators=(",", ":")).encode(),
        "action_schema_json": (
            b'{"type":"object","properties":{"action":{"type":"string"}},'
            b'"required":["action"],"additionalProperties":false}'
        ),
        "scratchpad_utf8": b"approach relay",
        "frame_png": PNG,
        "max_output_bytes": 256,
    }
    values.update(changes)
    return ProviderRequest(**values)


@pytest.mark.asyncio
async def test_success_uses_forced_tool_hybrid_payload_and_sanitized_audit() -> None:
    calls: list[dict[str, Any]] = []
    secret = "anthropic-session-secret"
    audit = InMemoryProviderAuditLog()

    async def transport(**kwargs: Any) -> AnthropicHTTPResponse:
        calls.append(kwargs)
        return AnthropicHTTPResponse(
            200,
            {
                "content": [
                    {"type": "tool_use", "name": "submit_action", "input": {"action": "dash"}}
                ],
                "stop_reason": "tool_use",
                "usage": {
                    "input_tokens": 120,
                    "output_tokens": 8,
                    "cache_read_input_tokens": 20,
                },
            },
            {"request-id": "provider-request-123", "authorization": "never-record"},
        )

    adapter = AnthropicAdapter(api_key=secret, transport=transport, audit_log=audit)
    request = _request()
    result = await adapter.request(request)

    assert result.failure is None
    assert result.raw_output == b'{"action":"dash"}'
    assert result.telemetry.input_tokens == 120
    assert result.telemetry.output_tokens == 8
    assert result.telemetry.cached_input_tokens == 20
    assert result.telemetry.request_id_sha256 is not None
    assert len(calls) == 1
    call = calls[0]
    assert call["headers"]["x-api-key"] == secret
    assert 0 < call["timeout"] <= 1.0
    body = call["json"]
    assert body["tool_choice"] == {"type": "tool", "name": "submit_action"}
    assert body["max_tokens"] == 2048
    assert body["tools"][0]["input_schema"]["additionalProperties"] is False
    parts = body["messages"][0]["content"]
    assert parts[0]["source"]["media_type"] == "image/png"
    player_payload = json.loads(parts[1]["text"])
    assert player_payload["observation"]["goal"] == "Relay ahead."
    assert player_payload["scratchpad"] == "approach relay"
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

    async def transport(**kwargs: Any) -> AnthropicHTTPResponse:
        nonlocal calls
        calls += 1
        raise AssertionError(kwargs)

    adapter = AnthropicAdapter(api_key="secret", transport=transport)
    result = await adapter.request(_request(deadline_monotonic_ns=1))

    assert result.failure is ProviderFailureKind.TIMEOUT
    assert calls == 0


@pytest.mark.asyncio
async def test_in_flight_timeout_is_not_retried() -> None:
    calls = 0

    async def transport(**kwargs: Any) -> AnthropicHTTPResponse:
        nonlocal calls
        calls += 1
        await asyncio.sleep(0.05)
        raise AssertionError(kwargs)

    adapter = AnthropicAdapter(api_key="secret", transport=transport)
    request = _request(deadline_monotonic_ns=time.monotonic_ns() + 10_000_000)
    result = await adapter.request(request)

    assert result.failure is ProviderFailureKind.TIMEOUT
    assert calls == 1


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("response", "expected"),
    [
        (AnthropicHTTPResponse(401, {}, {}), ProviderFailureKind.CREDENTIAL),
        (AnthropicHTTPResponse(429, {}, {}), ProviderFailureKind.RATE_LIMIT),
        (
            AnthropicHTTPResponse(200, {"content": [{"type": "text", "text": "oops"}]}, {}),
            ProviderFailureKind.INVALID_RESPONSE,
        ),
        (
            AnthropicHTTPResponse(
                200,
                {
                    "content": [
                        {"type": "tool_use", "name": "submit_action", "input": "not-json"}
                    ]
                    , "stop_reason": "tool_use"
                },
                {},
            ),
            ProviderFailureKind.INVALID_RESPONSE,
        ),
        (
            AnthropicHTTPResponse(
                200,
                {
                    "content": [
                        {
                            "type": "tool_use",
                            "name": "submit_action",
                            "input": {"action": float("nan")},
                        }
                    ]
                },
                {},
            ),
            ProviderFailureKind.INVALID_RESPONSE,
        ),
        (
            AnthropicHTTPResponse(200, {"content": [], "stop_reason": "refusal"}, {}),
            ProviderFailureKind.REFUSAL,
        ),
    ],
)
async def test_sanitized_provider_failures(
    response: AnthropicHTTPResponse, expected: ProviderFailureKind
) -> None:
    calls = 0

    async def transport(**kwargs: Any) -> AnthropicHTTPResponse:
        nonlocal calls
        calls += 1
        return response

    result = await AnthropicAdapter(api_key="secret", transport=transport).request(_request())
    assert result.failure is expected
    assert result.raw_output is None
    assert calls == 1


@pytest.mark.asyncio
async def test_oversize_tool_output_is_rejected() -> None:
    async def transport(**kwargs: Any) -> AnthropicHTTPResponse:
        return AnthropicHTTPResponse(
            200,
            {
                "content": [
                    {
                        "type": "tool_use",
                        "name": "submit_action",
                        "input": {"action": "x" * 100},
                    }
                ],
                "stop_reason": "tool_use",
            },
            {},
        )

    result = await AnthropicAdapter(api_key="secret", transport=transport).request(
        _request(max_output_bytes=8)
    )
    assert result.failure is ProviderFailureKind.OUTPUT_TOO_LARGE


@pytest.mark.asyncio
async def test_raw_http_response_rejects_duplicate_tool_input_keys() -> None:
    async def transport(**kwargs: Any) -> AnthropicHTTPResponse:
        del kwargs
        return AnthropicHTTPResponse(
            200,
            (
                b'{"content":[{"type":"tool_use","name":"submit_action",'
                b'"input":{"action":"left","action":"right"}}],'
                b'"stop_reason":"tool_use"}'
            ),
            {},
        )

    result = await AnthropicAdapter(api_key="secret", transport=transport).request(_request())

    assert result.failure is ProviderFailureKind.INVALID_RESPONSE
    assert result.raw_output is None
