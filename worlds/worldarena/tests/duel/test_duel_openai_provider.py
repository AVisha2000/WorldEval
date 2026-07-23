from __future__ import annotations

import hashlib
from typing import Any

import httpx
import openai
import pytest
from genesis_arena.duel.canonical import canonical_json_bytes
from genesis_arena.duel.openai_provider import (
    InMemoryOpenAIProviderAuditLog,
    OpenAIProviderConfigurationError,
    OpenAIResponsesDuelAdapter,
    build_openai_responses_request,
)
from genesis_arena.duel.provider_adapters import (
    EndpointOwnership,
    ProviderFailureKind,
    ProviderRequest,
)


class _Clock:
    def __init__(self, *values: int) -> None:
        self.values = list(values)

    def __call__(self) -> int:
        if not self.values:
            raise AssertionError("test clock exhausted")
        return self.values.pop(0)


class _FakeStream:
    def __init__(self, events: list[dict[str, Any]]) -> None:
        self._events = iter(events)
        self.closed = False

    def __aiter__(self) -> _FakeStream:
        return self

    async def __anext__(self) -> dict[str, Any]:
        try:
            return next(self._events)
        except StopIteration:
            raise StopAsyncIteration from None

    async def close(self) -> None:
        self.closed = True


class _FakeResponses:
    def __init__(
        self,
        *,
        stream: _FakeStream | None = None,
        error: Exception | None = None,
    ) -> None:
        self.stream = stream
        self.error = error
        self.requests: list[dict[str, Any]] = []

    async def create(self, **kwargs: Any) -> _FakeStream:
        self.requests.append(kwargs)
        if self.error is not None:
            raise self.error
        assert self.stream is not None
        return self.stream


class _FakeClient:
    def __init__(self, responses: _FakeResponses) -> None:
        self.responses = responses


def _request() -> ProviderRequest:
    schema = {
        "type": "object",
        "properties": {},
        "required": [],
        "additionalProperties": False,
    }
    return ProviderRequest(
        match_id="m_openai_adapter",
        opportunity_id="opp_00000000",
        player_slot=0,
        observation_seq=3,
        boundary_tick=150,
        deadline_monotonic_ns=1_000_000_100,
        system_prompt="Return exactly one action_batch object.",
        match_init_json=canonical_json_bytes({"message_type": "match_init"}),
        observation_json=canonical_json_bytes(
            {"message_type": "observation", "observation_seq": 3}
        ),
        action_schema_json=canonical_json_bytes(schema),
    )


def _completed_response(response_id: str = "resp_test_123") -> dict[str, Any]:
    return {
        "id": response_id,
        "status": "completed",
        "service_tier": "default",
        "usage": {
            "input_tokens": 123,
            "output_tokens": 17,
            "input_tokens_details": {"cached_tokens": 100},
        },
        "output": [],
    }


def test_request_builder_is_stateless_and_uses_strict_structured_output() -> None:
    request = _request()
    payload = build_openai_responses_request(
        request,
        model="gpt-test-snapshot",
        reasoning_effort="medium",
        service_tier="default",
        max_output_tokens=2048,
    )

    assert payload["model"] == "gpt-test-snapshot"
    assert payload["instructions"] == request.system_prompt
    content = payload["input"][0]["content"]
    assert content == [
        {"type": "input_text", "text": "MATCH_INIT\n"},
        {"type": "input_text", "text": request.match_init_json.decode("utf-8")},
        {"type": "input_text", "text": "\nOBSERVATION\n"},
        {"type": "input_text", "text": request.observation_json.decode("utf-8")},
    ]
    strict_schema = {
        "type": "object",
        "properties": {},
        "required": [],
        "additionalProperties": False,
    }
    assert payload["text"]["format"] == {
        "type": "json_schema",
        "name": "worldeval_duel_action_batch",
        "strict": True,
        "schema": strict_schema,
    }
    assert strict_schema == payload["text"]["format"]["schema"]
    assert payload["reasoning"] == {"effort": "medium"}
    assert payload["service_tier"] == "default"
    assert payload["max_output_tokens"] == 2048
    assert payload["store"] is False
    assert payload["stream"] is True
    assert payload["truncation"] == "disabled"
    assert "previous_response_id" not in payload
    assert "conversation" not in payload
    assert "api_key" not in repr(payload)


async def test_streamed_success_records_first_token_usage_and_protected_bytes() -> None:
    completed = _completed_response()
    stream = _FakeStream(
        [
            {"type": "response.created", "response": {"id": completed["id"]}},
            {"type": "response.output_text.delta", "delta": '{"commands":'},
            {"type": "response.output_text.delta", "delta": "[]}"},
            {"type": "response.completed", "response": completed},
        ]
    )
    responses = _FakeResponses(stream=stream)
    audit = InMemoryOpenAIProviderAuditLog()
    adapter = OpenAIResponsesDuelAdapter(
        model="gpt-test-snapshot",
        reasoning_effort="low",
        service_tier="default",
        max_output_tokens=2048,
        client=_FakeClient(responses),
        audit_sink=audit,
        monotonic_ns=_Clock(100, 110, 120),
    )

    result = await adapter.request(_request())

    assert result.raw_output == b'{"commands":[]}'
    assert result.failure is None
    assert result.first_token_monotonic_ns == 110
    assert result.telemetry.input_tokens == 123
    assert result.telemetry.output_tokens == 17
    assert result.telemetry.cached_input_tokens == 100
    assert result.telemetry.service_tier == "default"
    assert result.telemetry.provider_request_id_sha256 == hashlib.sha256(
        completed["id"].encode("utf-8")
    ).hexdigest()
    assert responses.requests[0]["timeout"] == pytest.approx(1.0)

    assert len(audit.records) == 1
    record = audit.records[0]
    assert record.request == _request()
    assert record.raw_output == result.raw_output
    assert record.failure is None
    assert record.started_monotonic_ns == 100
    assert record.first_token_monotonic_ns == 110
    assert record.completed_monotonic_ns == 120
    assert record.provider_response_id == completed["id"]
    assert audit.drain_match("m_openai_adapter") == (record,)
    assert audit.records == ()


async def test_refusal_is_sanitized_but_retained_in_protected_audit() -> None:
    completed = _completed_response("resp_refusal")
    completed["output"] = [
        {"type": "message", "content": [{"type": "refusal", "refusal": "No"}]}
    ]
    stream = _FakeStream(
        [
            {"type": "response.refusal.delta", "delta": "No"},
            {"type": "response.completed", "response": completed},
        ]
    )
    audit = InMemoryOpenAIProviderAuditLog()
    adapter = OpenAIResponsesDuelAdapter(
        model="gpt-test-snapshot",
        client=_FakeClient(_FakeResponses(stream=stream)),
        audit_sink=audit,
        monotonic_ns=_Clock(100, 105, 110),
    )

    result = await adapter.request(_request())

    assert result.failure is ProviderFailureKind.REFUSAL
    assert result.raw_output is None
    assert result.first_token_monotonic_ns == 105
    assert audit.records[0].raw_output == b"No"
    assert audit.records[0].failure is ProviderFailureKind.REFUSAL


async def test_output_cap_stops_stream_after_one_overflow_byte() -> None:
    stream = _FakeStream(
        [
            {"type": "response.output_text.delta", "delta": "abcdef"},
            {"type": "response.completed", "response": _completed_response()},
        ]
    )
    adapter = OpenAIResponsesDuelAdapter(
        model="gpt-test-snapshot",
        max_output_bytes=4,
        client=_FakeClient(_FakeResponses(stream=stream)),
        monotonic_ns=_Clock(100, 105, 110),
    )

    result = await adapter.request(_request())

    assert result.raw_output == b"abcde"
    assert result.failure is None
    assert stream.closed is True


@pytest.mark.parametrize(
    ("error", "expected"),
    [
        (
            openai.AuthenticationError(
                message="credential detail must not escape",
                response=httpx.Response(
                    401,
                    request=httpx.Request("POST", "https://api.openai.com/v1/responses"),
                ),
                body={"error": {"code": "invalid_api_key"}},
            ),
            ProviderFailureKind.CREDENTIAL_ERROR,
        ),
        (
            openai.RateLimitError(
                message="quota detail must not escape",
                response=httpx.Response(
                    429,
                    request=httpx.Request("POST", "https://api.openai.com/v1/responses"),
                ),
                body={"error": {"code": "insufficient_quota"}},
            ),
            ProviderFailureKind.QUOTA_ERROR,
        ),
        (
            openai.APIConnectionError(
                message="endpoint detail must not escape",
                request=httpx.Request("POST", "https://api.openai.com/v1/responses"),
            ),
            ProviderFailureKind.TRANSPORT_DISCONNECT,
        ),
    ],
)
async def test_sdk_failures_map_to_allowlisted_codes(
    error: Exception, expected: ProviderFailureKind
) -> None:
    audit = InMemoryOpenAIProviderAuditLog()
    adapter = OpenAIResponsesDuelAdapter(
        model="gpt-test-snapshot",
        endpoint_ownership=EndpointOwnership.PARTICIPANT_HOSTED,
        client=_FakeClient(_FakeResponses(error=error)),
        audit_sink=audit,
        monotonic_ns=_Clock(100, 110),
    )

    result = await adapter.request(_request())

    assert result.failure is expected
    assert result.raw_output is None
    assert audit.records[0].failure is expected
    assert audit.records[0].raw_output == b""
    assert "detail must not escape" not in repr(result)
    assert "detail must not escape" not in repr(audit.records[0])


async def test_unexpected_adapter_bug_propagates_as_infrastructure_failure() -> None:
    adapter = OpenAIResponsesDuelAdapter(
        model="gpt-test-snapshot",
        client=_FakeClient(_FakeResponses(error=RuntimeError("adapter bug"))),
        monotonic_ns=_Clock(100),
    )

    with pytest.raises(RuntimeError, match="adapter bug"):
        await adapter.request(_request())


def test_constructor_requires_explicit_credentials_or_an_injected_client() -> None:
    with pytest.raises(OpenAIProviderConfigurationError, match="api_key"):
        OpenAIResponsesDuelAdapter(model="gpt-test-snapshot")
