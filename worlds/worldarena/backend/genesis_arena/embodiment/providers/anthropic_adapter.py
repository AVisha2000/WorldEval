"""Retry-free Anthropic Messages adapter for participant-scoped hybrid observations."""

from __future__ import annotations

import asyncio
import base64
import hashlib
import inspect
import json
import time
from dataclasses import dataclass
from typing import Any, Awaitable, Callable, Mapping, Union

from ..protocol import strict_json_loads
from .contracts import (
    InMemoryProviderAuditLog,
    ProviderAuditRecord,
    ProviderCallResult,
    ProviderFailureKind,
    ProviderRequest,
    ProviderTelemetry,
)


@dataclass(frozen=True)
class AnthropicHTTPResponse:
    """Small SDK-independent response boundary used by injected transports."""

    status_code: int
    body: Mapping[str, Any] | bytes
    headers: Mapping[str, str]


AnthropicTransport = Callable[
    ...,
    Union[AnthropicHTTPResponse, Awaitable[AnthropicHTTPResponse]],
]


class AnthropicAdapter:
    """Call Anthropic once, bounded by the authority-owned absolute deadline."""

    provider_name = "anthropic"
    endpoint = "https://api.anthropic.com/v1/messages"

    def __init__(
        self,
        *,
        api_key: str,
        transport: AnthropicTransport,
        audit_log: InMemoryProviderAuditLog | None = None,
        monotonic_ns: Callable[[], int] = time.monotonic_ns,
    ) -> None:
        if not isinstance(api_key, str) or not api_key:
            raise ValueError("api_key is required")
        if not callable(transport):
            raise TypeError("transport must be callable")
        self._api_key = api_key
        self._transport = transport
        self._audit_log = audit_log or InMemoryProviderAuditLog()
        self._monotonic_ns = monotonic_ns

    @property
    def audit_log(self) -> InMemoryProviderAuditLog:
        return self._audit_log

    async def aclose(self) -> None:
        """Erase the session-only credential retained for HTTP requests."""

        self._api_key = ""

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        if not isinstance(request, ProviderRequest):
            raise TypeError("request must be ProviderRequest")
        started_ns = self._monotonic_ns()
        remaining_ns = request.deadline_monotonic_ns - started_ns
        if remaining_ns <= 0:
            return self._finish(
                request,
                started_ns,
                ProviderFailureKind.TIMEOUT,
            )

        try:
            body = _request_body(request)
        except (UnicodeDecodeError, json.JSONDecodeError, TypeError, ValueError):
            return self._finish(
                request,
                started_ns,
                ProviderFailureKind.INVALID_RESPONSE,
            )

        headers = {
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
            "x-api-key": self._api_key,
        }
        timeout_s = remaining_ns / 1_000_000_000
        try:
            pending = self._transport(
                url=self.endpoint,
                headers=headers,
                json=body,
                timeout=timeout_s,
            )
            if inspect.isawaitable(pending):
                response = await asyncio.wait_for(pending, timeout=timeout_s)
            else:
                response = pending
        except (TimeoutError, asyncio.TimeoutError):
            return self._finish(request, started_ns, ProviderFailureKind.TIMEOUT)
        except Exception:
            return self._finish(request, started_ns, ProviderFailureKind.TRANSPORT)

        if self._monotonic_ns() >= request.deadline_monotonic_ns:
            return self._finish(request, started_ns, ProviderFailureKind.TIMEOUT)
        if not isinstance(response, AnthropicHTTPResponse):
            return self._finish(request, started_ns, ProviderFailureKind.INVALID_RESPONSE)
        failure = _status_failure(response.status_code)
        if failure is not None:
            return self._finish(request, started_ns, failure, response=response)
        try:
            response = _strict_response(response)
        except (TypeError, ValueError):
            return self._finish(
                request,
                started_ns,
                ProviderFailureKind.INVALID_RESPONSE,
                response=response,
            )

        try:
            raw_output = _extract_tool_output(response.body)
        except _ProviderRefusal:
            return self._finish(
                request,
                started_ns,
                ProviderFailureKind.REFUSAL,
                response=response,
            )
        except (KeyError, TypeError, ValueError):
            return self._finish(
                request,
                started_ns,
                ProviderFailureKind.INVALID_RESPONSE,
                response=response,
            )
        if len(raw_output) > request.max_output_bytes:
            return self._finish(
                request,
                started_ns,
                ProviderFailureKind.OUTPUT_TOO_LARGE,
                response=response,
            )
        return self._finish(request, started_ns, None, raw_output, response)

    def _finish(
        self,
        request: ProviderRequest,
        started_ns: int,
        failure: ProviderFailureKind | None,
        raw_output: bytes | None = None,
        response: AnthropicHTTPResponse | None = None,
    ) -> ProviderCallResult:
        completed_ns = max(started_ns, self._monotonic_ns())
        telemetry = ProviderTelemetry(
            latency_ms=(completed_ns - started_ns) // 1_000_000,
            input_tokens=_usage_integer(response, "input_tokens"),
            output_tokens=_usage_integer(response, "output_tokens"),
            cached_input_tokens=_usage_integer(response, "cache_read_input_tokens"),
            request_id_sha256=_request_id_hash(response),
        )
        result = (
            ProviderCallResult.success(raw_output, telemetry)
            if failure is None and raw_output is not None
            else ProviderCallResult.failed(failure or ProviderFailureKind.INTERNAL, telemetry)
        )
        self._audit_log.record(
            ProviderAuditRecord(
                provider=self.provider_name,
                request=request,
                result=result,
                started_monotonic_ns=started_ns,
                completed_monotonic_ns=completed_ns,
            )
        )
        return result


# Consistent public spelling with the other embodiment provider adapters.
AnthropicProviderAdapter = AnthropicAdapter


class _ProviderRefusal(Exception):
    pass


def _request_body(request: ProviderRequest) -> dict[str, Any]:
    observation = json.loads(
        request.observation_json.decode("utf-8", errors="strict"),
        parse_constant=_reject_non_json_number,
    )
    action_schema = json.loads(
        request.action_schema_json.decode("utf-8", errors="strict"),
        parse_constant=_reject_non_json_number,
    )
    if not isinstance(action_schema, dict):
        raise TypeError("action schema must be an object")
    content: list[dict[str, Any]] = []
    if request.frame_png is not None:
        content.append(
            {
                "type": "image",
                "source": {
                    "type": "base64",
                    "media_type": "image/png",
                    "data": base64.b64encode(request.frame_png).decode("ascii"),
                },
            }
        )
    player_payload = {
        "observation": observation,
        "scratchpad": request.scratchpad_utf8.decode("utf-8", errors="strict"),
    }
    content.append(
        {
            "type": "text",
            "text": json.dumps(player_payload, sort_keys=True, separators=(",", ":")),
        }
    )
    return {
        "model": request.model,
        "max_tokens": 2048,
        "system": request.system_prompt,
        "messages": [{"role": "user", "content": content}],
        "tools": [
            {
                "name": "submit_action",
                "description": "Submit the next WorldArena action.",
                "input_schema": action_schema,
            }
        ],
        "tool_choice": {"type": "tool", "name": "submit_action"},
    }


def _extract_tool_output(body: Mapping[str, Any]) -> bytes:
    if body.get("stop_reason") in {"refusal", "safety"}:
        raise _ProviderRefusal
    if body.get("stop_reason") != "tool_use":
        raise ValueError("tool response did not complete")
    content = body.get("content")
    if not isinstance(content, list):
        raise TypeError("content must be a list")
    for item in content:
        if not isinstance(item, Mapping):
            continue
        if item.get("type") in {"refusal", "safety"}:
            raise _ProviderRefusal
        if item.get("type") == "tool_use" and item.get("name") == "submit_action":
            value = item.get("input")
            if not isinstance(value, dict):
                raise TypeError("tool input must be an object")
            return json.dumps(
                value,
                allow_nan=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
    raise ValueError("submit_action tool output missing")


def _strict_response(response: AnthropicHTTPResponse) -> AnthropicHTTPResponse:
    """Parse production response bytes without losing duplicate-key evidence."""

    if isinstance(response.body, bytes):
        body = strict_json_loads(response.body)
        if not isinstance(body, dict):
            raise TypeError("provider response body must be an object")
        return AnthropicHTTPResponse(response.status_code, body, response.headers)
    if not isinstance(response.body, Mapping):
        raise TypeError("provider response body must be bytes or a mapping")
    return response


def _status_failure(status_code: int) -> ProviderFailureKind | None:
    if isinstance(status_code, bool) or not isinstance(status_code, int):
        return ProviderFailureKind.INVALID_RESPONSE
    if 200 <= status_code < 300:
        return None
    if status_code in {401, 403}:
        return ProviderFailureKind.CREDENTIAL
    if status_code == 429:
        return ProviderFailureKind.RATE_LIMIT
    return ProviderFailureKind.TRANSPORT


def _usage_integer(response: AnthropicHTTPResponse | None, field: str) -> int | None:
    if response is None or not isinstance(response.body, Mapping):
        return None
    usage = response.body.get("usage")
    if not isinstance(usage, Mapping):
        return None
    value = usage.get(field)
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def _request_id_hash(response: AnthropicHTTPResponse | None) -> str | None:
    if response is None:
        return None
    request_id = response.headers.get("request-id") or response.headers.get("x-request-id")
    if not isinstance(request_id, str) or not request_id:
        return None
    return hashlib.sha256(request_id.encode("utf-8")).hexdigest()


def _reject_non_json_number(value: str) -> None:
    raise ValueError(f"non-JSON number {value}")
