"""Production OpenAI Responses API adapter for WorldArena Duel.

The adapter is deliberately thin: it sends the frozen player-scoped protocol bytes, asks for one
strict ``action_batch`` object, streams only to obtain local first-token timing, and returns the
model's text bytes without repair.  Provider SDK objects, headers, exception messages, and API keys
never cross the provider boundary.
"""

from __future__ import annotations

# ruff: noqa: UP045 -- Keep the public adapter surface explicit on the Python 3.9 floor.
import asyncio
import hashlib
import inspect
import re
import time
from dataclasses import dataclass
from typing import Any, Callable, Dict, Mapping, Optional, Protocol, Tuple

import openai
from openai import AsyncOpenAI

from .canonical import canonical_json_bytes, strict_json_loads
from .provider_adapters import (
    EndpointOwnership,
    ProviderCallResult,
    ProviderFailureKind,
    ProviderRequest,
    ProviderTelemetry,
)

OPENAI_ACTION_SCHEMA_NAME = "worldeval_duel_action_batch"
OPENAI_RESPONSES_FRAME_VERSION = "worldeval-rts/openai-responses-input/v1"
DEFAULT_MAX_OUTPUT_BYTES = 16_384

_SAFE_MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$")
_SAFE_REASONING_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}$")
_SAFE_TIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,95}$")


class OpenAIProviderConfigurationError(ValueError):
    """The selected provider configuration cannot be used safely."""


@dataclass(frozen=True)
class OpenAIProviderAuditRecord:
    """Protected in-memory evidence for exactly one provider call.

    This record is never part of the publishable replay.  It intentionally retains the exact
    player-visible inputs and raw model output needed by an authorized benchmark audit while
    excluding credentials, HTTP headers, exception text, and hidden reasoning.
    """

    request: ProviderRequest
    model: str
    reasoning_effort: Optional[str]
    configured_service_tier: Optional[str]
    started_monotonic_ns: int
    first_token_monotonic_ns: Optional[int]
    completed_monotonic_ns: int
    raw_output: bytes
    failure: Optional[ProviderFailureKind]
    telemetry: ProviderTelemetry
    provider_response_id: Optional[str]

    def __post_init__(self) -> None:
        if not isinstance(self.request, ProviderRequest):
            raise TypeError("request must be a ProviderRequest")
        if _SAFE_MODEL_RE.fullmatch(self.model) is None:
            raise ValueError("model must be a safe resolved model identifier")
        for name in ("started_monotonic_ns", "completed_monotonic_ns"):
            value = getattr(self, name)
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise ValueError(f"{name} must be a non-negative integer")
        if self.completed_monotonic_ns < self.started_monotonic_ns:
            raise ValueError("provider completion precedes request start")
        if self.first_token_monotonic_ns is not None and not (
            self.started_monotonic_ns
            <= self.first_token_monotonic_ns
            <= self.completed_monotonic_ns
        ):
            raise ValueError("first-token time is outside the provider call")
        if not isinstance(self.raw_output, bytes):
            raise TypeError("raw_output must be immutable bytes")
        if self.provider_response_id is not None and (
            not isinstance(self.provider_response_id, str)
            or not self.provider_response_id
            or len(self.provider_response_id) > 512
        ):
            raise ValueError("provider_response_id is invalid")


class OpenAIProviderAuditSink(Protocol):
    """Non-blocking protected sink used before the adapter result is released."""

    def record(self, record: OpenAIProviderAuditRecord) -> None:
        """Retain one complete protected provider record or fail closed."""


class InMemoryOpenAIProviderAuditLog:
    """Process-local protected audit log suitable for later artifact sealing."""

    def __init__(self) -> None:
        self._records: list[OpenAIProviderAuditRecord] = []

    @property
    def records(self) -> Tuple[OpenAIProviderAuditRecord, ...]:
        return tuple(self._records)

    def records_for_match(self, match_id: str) -> Tuple[OpenAIProviderAuditRecord, ...]:
        return tuple(record for record in self._records if record.request.match_id == match_id)

    def drain_match(self, match_id: str) -> Tuple[OpenAIProviderAuditRecord, ...]:
        selected = self.records_for_match(match_id)
        self._records = [
            record for record in self._records if record.request.match_id != match_id
        ]
        return selected

    def record(self, record: OpenAIProviderAuditRecord) -> None:
        if not isinstance(record, OpenAIProviderAuditRecord):
            raise TypeError("record must be an OpenAIProviderAuditRecord")
        self._records.append(record)


def build_openai_responses_request(
    request: ProviderRequest,
    *,
    model: str,
    reasoning_effort: Optional[str],
    service_tier: Optional[str],
    max_output_tokens: Optional[int],
) -> Dict[str, Any]:
    """Build the stateless strict-output request passed to ``responses.create``.

    ``MATCH_INIT`` and ``OBSERVATION`` are separate text blocks so the immutable prefix can be
    cached by a provider without changing the benchmark's logical byte accounting.  The action
    schema is supplied as the Responses API ``text.format`` constraint and is still included in
    the provider-neutral input envelope used by the runtime.
    """

    if not isinstance(request, ProviderRequest):
        raise TypeError("request must be a ProviderRequest")
    _validate_adapter_configuration(
        model=model,
        reasoning_effort=reasoning_effort,
        service_tier=service_tier,
        max_output_tokens=max_output_tokens,
        max_output_bytes=DEFAULT_MAX_OUTPUT_BYTES,
    )
    match_init_text = _exact_utf8_text(request.match_init_json, "MATCH_INIT")
    observation_text = _exact_utf8_text(request.observation_json, "OBSERVATION")
    action_schema = strict_json_loads(request.action_schema_json)
    if not isinstance(action_schema, dict):
        raise OpenAIProviderConfigurationError("action schema must be a JSON object")
    if canonical_json_bytes(action_schema) != request.action_schema_json:
        raise OpenAIProviderConfigurationError("action schema must be canonical JSON")

    payload: Dict[str, Any] = {
        "model": model,
        "instructions": request.system_prompt,
        "input": [
            {
                "role": "user",
                "content": [
                    {"type": "input_text", "text": "MATCH_INIT\n"},
                    {"type": "input_text", "text": match_init_text},
                    {"type": "input_text", "text": "\nOBSERVATION\n"},
                    {"type": "input_text", "text": observation_text},
                ],
            }
        ],
        "text": {
            "format": {
                "type": "json_schema",
                "name": OPENAI_ACTION_SCHEMA_NAME,
                "strict": True,
                "schema": action_schema,
            }
        },
        "store": False,
        "stream": True,
        "truncation": "disabled",
    }
    if reasoning_effort is not None:
        payload["reasoning"] = {"effort": reasoning_effort}
    if service_tier is not None:
        payload["service_tier"] = service_tier
    if max_output_tokens is not None:
        payload["max_output_tokens"] = max_output_tokens
    return payload


class OpenAIResponsesDuelAdapter:
    """Stateless, retry-free OpenAI Responses adapter for one benchmark participant."""

    def __init__(
        self,
        *,
        model: str,
        reasoning_effort: Optional[str] = None,
        service_tier: Optional[str] = None,
        max_output_tokens: Optional[int] = None,
        max_output_bytes: int = DEFAULT_MAX_OUTPUT_BYTES,
        endpoint_ownership: EndpointOwnership = EndpointOwnership.ORGANIZER_HOSTED,
        api_key: Optional[str] = None,
        client: Optional[Any] = None,
        audit_sink: Optional[OpenAIProviderAuditSink] = None,
        monotonic_ns: Callable[[], int] = time.monotonic_ns,
    ) -> None:
        _validate_adapter_configuration(
            model=model,
            reasoning_effort=reasoning_effort,
            service_tier=service_tier,
            max_output_tokens=max_output_tokens,
            max_output_bytes=max_output_bytes,
        )
        if not isinstance(endpoint_ownership, EndpointOwnership):
            raise OpenAIProviderConfigurationError(
                "endpoint_ownership must be an EndpointOwnership"
            )
        if client is None:
            if not api_key:
                raise OpenAIProviderConfigurationError(
                    "api_key is required when no OpenAI client is injected"
                )
            client = AsyncOpenAI(api_key=api_key, max_retries=0)
        elif api_key is not None:
            raise OpenAIProviderConfigurationError(
                "api_key must not be supplied with an injected client"
            )
        self.endpoint_ownership = endpoint_ownership
        self._client = client
        self._model = model
        self._reasoning_effort = reasoning_effort
        self._service_tier = service_tier
        self._max_output_tokens = max_output_tokens
        self._max_output_bytes = max_output_bytes
        self._audit_sink = audit_sink
        self._monotonic_ns = monotonic_ns

    @property
    def model(self) -> str:
        return self._model

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        started_ns = self._monotonic_ns()
        if started_ns >= request.deadline_monotonic_ns:
            raise RuntimeError("provider request started after its authoritative deadline")
        request_payload = build_openai_responses_request(
            request,
            model=self._model,
            reasoning_effort=self._reasoning_effort,
            service_tier=self._service_tier,
            max_output_tokens=self._max_output_tokens,
        )
        request_payload["timeout"] = max(
            0.001, (request.deadline_monotonic_ns - started_ns) / 1_000_000_000
        )

        stream: Optional[Any] = None
        first_token_ns: Optional[int] = None
        response_id: Optional[str] = None
        completed_response: Optional[Any] = None
        raw_output = bytearray()
        refusal_output = bytearray()
        finished = False
        refusal = False
        provider_event_failure: Optional[ProviderFailureKind] = None
        oversized = False

        try:
            stream = await self._client.responses.create(**request_payload)
            async for event in stream:
                event_type = _field(event, "type")
                event_response = _field(event, "response")
                event_response_id = _field(event_response, "id")
                if isinstance(event_response_id, str) and event_response_id:
                    response_id = event_response_id

                if event_type == "response.output_text.delta":
                    delta = _field(event, "delta", "")
                    delta_bytes = _delta_bytes(delta)
                    if delta_bytes and first_token_ns is None:
                        first_token_ns = self._monotonic_ns()
                    oversized = _append_with_limit(
                        raw_output, delta_bytes, self._max_output_bytes
                    )
                    if oversized:
                        await _close_stream(stream)
                        break
                elif event_type in {"response.refusal.delta", "response.refusal.done"}:
                    if first_token_ns is None:
                        first_token_ns = self._monotonic_ns()
                    _append_with_limit(
                        refusal_output,
                        _delta_bytes(_field(event, "delta", "")),
                        self._max_output_bytes,
                    )
                    refusal = True
                elif event_type == "response.completed":
                    completed_response = event_response
                    finished = True
                elif event_type == "response.incomplete":
                    completed_response = event_response
                    finished = True
                elif event_type in {"response.failed", "error"}:
                    completed_response = event_response
                    provider_event_failure = ProviderFailureKind.ENDPOINT_ERROR
                    finished = True
        except asyncio.CancelledError:
            if stream is not None:
                await _close_stream(stream)
            raise
        except openai.OpenAIError as exc:
            completed_ns = self._monotonic_ns()
            response_id = _safe_response_id(exc)
            telemetry = _provider_telemetry(None, response_id)
            result = ProviderCallResult.failed(
                _failure_from_openai_exception(exc),
                telemetry=telemetry,
                first_token_monotonic_ns=first_token_ns,
            )
            self._record_audit(
                request=request,
                started_ns=started_ns,
                completed_ns=completed_ns,
                result=result,
                response_id=response_id,
                protected_raw_output=bytes(refusal_output or raw_output),
            )
            return result

        completed_ns = self._monotonic_ns()
        if completed_response is not None:
            completed_id = _field(completed_response, "id")
            if isinstance(completed_id, str) and completed_id:
                response_id = completed_id
            refusal = refusal or _response_has_refusal(completed_response)
            if not raw_output and not refusal:
                final_text = _field(completed_response, "output_text")
                if isinstance(final_text, str) and final_text:
                    raw_output.extend(final_text.encode("utf-8"))
                    first_token_ns = first_token_ns or completed_ns
        telemetry = _provider_telemetry(completed_response, response_id)

        if refusal:
            result = ProviderCallResult.failed(
                ProviderFailureKind.REFUSAL,
                telemetry=telemetry,
                first_token_monotonic_ns=first_token_ns,
            )
        elif provider_event_failure is not None:
            result = ProviderCallResult.failed(
                provider_event_failure,
                telemetry=telemetry,
                first_token_monotonic_ns=first_token_ns,
            )
        elif not finished and not oversized:
            result = ProviderCallResult.failed(
                ProviderFailureKind.TRANSPORT_DISCONNECT,
                telemetry=telemetry,
                first_token_monotonic_ns=first_token_ns,
            )
        else:
            # A byte over the cap is retained so the common validator classifies the response as
            # an oversized model envelope without buffering an unbounded stream.
            result = ProviderCallResult.success(
                bytes(raw_output),
                telemetry=telemetry,
                first_token_monotonic_ns=first_token_ns,
            )
        self._record_audit(
            request=request,
            started_ns=started_ns,
            completed_ns=completed_ns,
            result=result,
            response_id=response_id,
            protected_raw_output=bytes(refusal_output or raw_output),
        )
        return result

    def _record_audit(
        self,
        *,
        request: ProviderRequest,
        started_ns: int,
        completed_ns: int,
        result: ProviderCallResult,
        response_id: Optional[str],
        protected_raw_output: Optional[bytes] = None,
    ) -> None:
        if self._audit_sink is None:
            return
        self._audit_sink.record(
            OpenAIProviderAuditRecord(
                request=request,
                model=self._model,
                reasoning_effort=self._reasoning_effort,
                configured_service_tier=self._service_tier,
                started_monotonic_ns=started_ns,
                first_token_monotonic_ns=result.first_token_monotonic_ns,
                completed_monotonic_ns=completed_ns,
                raw_output=(
                    protected_raw_output
                    if protected_raw_output is not None
                    else result.raw_output or b""
                ),
                failure=result.failure,
                telemetry=result.telemetry,
                provider_response_id=response_id,
            )
        )


def _validate_adapter_configuration(
    *,
    model: str,
    reasoning_effort: Optional[str],
    service_tier: Optional[str],
    max_output_tokens: Optional[int],
    max_output_bytes: int,
) -> None:
    if not isinstance(model, str) or _SAFE_MODEL_RE.fullmatch(model) is None:
        raise OpenAIProviderConfigurationError("model must be a safe resolved model identifier")
    if reasoning_effort is not None and (
        not isinstance(reasoning_effort, str)
        or _SAFE_REASONING_RE.fullmatch(reasoning_effort) is None
    ):
        raise OpenAIProviderConfigurationError("reasoning_effort must be a safe frozen label")
    if service_tier is not None and (
        not isinstance(service_tier, str) or _SAFE_TIER_RE.fullmatch(service_tier) is None
    ):
        raise OpenAIProviderConfigurationError("service_tier must be a safe frozen label")
    if max_output_tokens is not None and (
        not isinstance(max_output_tokens, int)
        or isinstance(max_output_tokens, bool)
        or max_output_tokens < 1
    ):
        raise OpenAIProviderConfigurationError("max_output_tokens must be positive")
    if (
        not isinstance(max_output_bytes, int)
        or isinstance(max_output_bytes, bool)
        or max_output_bytes < 1
    ):
        raise OpenAIProviderConfigurationError("max_output_bytes must be positive")


def _exact_utf8_text(value: bytes, label: str) -> str:
    try:
        text = value.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise OpenAIProviderConfigurationError(f"{label} is not valid UTF-8") from exc
    if text.encode("utf-8") != value:
        raise OpenAIProviderConfigurationError(f"{label} did not round-trip exactly")
    return text


def _field(value: Any, name: str, default: Any = None) -> Any:
    if isinstance(value, Mapping):
        return value.get(name, default)
    return getattr(value, name, default)


def _delta_bytes(delta: Any) -> bytes:
    if isinstance(delta, str):
        return delta.encode("utf-8")
    if isinstance(delta, bytes):
        return delta
    return b""


def _append_with_limit(target: bytearray, delta: bytes, maximum: int) -> bool:
    if not delta:
        return False
    remaining = maximum + 1 - len(target)
    if remaining > 0:
        target.extend(delta[:remaining])
    return len(target) > maximum


async def _close_stream(stream: Any) -> None:
    close = getattr(stream, "close", None)
    if not callable(close):
        return
    outcome = close()
    if inspect.isawaitable(outcome):
        await outcome


def _response_has_refusal(response: Any) -> bool:
    for item in _field(response, "output", ()) or ():
        for content in _field(item, "content", ()) or ():
            if _field(content, "type") == "refusal":
                return True
    return False


def _safe_response_id(value: Any) -> Optional[str]:
    response_id = _field(value, "request_id") or _field(value, "response_id")
    if isinstance(response_id, str) and 0 < len(response_id) <= 512:
        return response_id
    return None


def _safe_non_negative_int(value: Any) -> Optional[int]:
    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
        return value
    return None


def _provider_telemetry(response: Any, response_id: Optional[str]) -> ProviderTelemetry:
    usage = _field(response, "usage")
    input_details = _field(usage, "input_tokens_details")
    service_tier = _field(response, "service_tier")
    if not isinstance(service_tier, str) or _SAFE_TIER_RE.fullmatch(service_tier) is None:
        service_tier = None
    request_digest = None
    if response_id is not None:
        request_digest = hashlib.sha256(response_id.encode("utf-8")).hexdigest()
    return ProviderTelemetry(
        input_tokens=_safe_non_negative_int(_field(usage, "input_tokens")),
        output_tokens=_safe_non_negative_int(_field(usage, "output_tokens")),
        cached_input_tokens=_safe_non_negative_int(_field(input_details, "cached_tokens")),
        service_tier=service_tier,
        provider_request_id_sha256=request_digest,
    )


def _failure_from_openai_exception(exc: openai.OpenAIError) -> ProviderFailureKind:
    if isinstance(exc, (openai.AuthenticationError, openai.PermissionDeniedError)):
        return ProviderFailureKind.CREDENTIAL_ERROR
    if isinstance(exc, openai.RateLimitError):
        if _contains_quota_code(_field(exc, "body")):
            return ProviderFailureKind.QUOTA_ERROR
        return ProviderFailureKind.RATE_LIMIT_ERROR
    if isinstance(exc, openai.APIConnectionError):
        return ProviderFailureKind.TRANSPORT_DISCONNECT
    return ProviderFailureKind.ENDPOINT_ERROR


def _contains_quota_code(value: Any) -> bool:
    if isinstance(value, Mapping):
        for key, child in value.items():
            if key in {"code", "type"} and isinstance(child, str):
                if child.lower() in {"insufficient_quota", "quota_exceeded", "billing_hard_limit"}:
                    return True
            if _contains_quota_code(child):
                return True
    elif isinstance(value, (list, tuple)):
        return any(_contains_quota_code(child) for child in value)
    return False
