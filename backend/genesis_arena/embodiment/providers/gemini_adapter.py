"""Retry-free Gemini adapter for participant-scoped hybrid observations."""

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
class GeminiHTTPResponse:
    """Small SDK-independent response boundary used by injected transports."""

    status_code: int
    body: Mapping[str, Any]
    headers: Mapping[str, str]


GeminiTransport = Callable[..., Union[GeminiHTTPResponse, Awaitable[GeminiHTTPResponse]]]


class GeminiAdapter:
    """Call Gemini once, bounded by the authority-owned absolute deadline."""

    provider_name = "gemini"
    endpoint_root = "https://generativelanguage.googleapis.com/v1beta/models"

    def __init__(
        self,
        *,
        api_key: str,
        transport: GeminiTransport,
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
            return self._finish(request, started_ns, ProviderFailureKind.TIMEOUT)
        try:
            body = _request_body(request)
        except (UnicodeDecodeError, json.JSONDecodeError, TypeError, ValueError):
            return self._finish(
                request,
                started_ns,
                ProviderFailureKind.INVALID_RESPONSE,
            )

        headers = {"content-type": "application/json", "x-goog-api-key": self._api_key}
        timeout_s = remaining_ns / 1_000_000_000
        url = f"{self.endpoint_root}/{request.model}:generateContent"
        try:
            pending = self._transport(
                url=url,
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
        if not isinstance(response, GeminiHTTPResponse):
            return self._finish(request, started_ns, ProviderFailureKind.INVALID_RESPONSE)
        failure = _status_failure(response.status_code)
        if failure is not None:
            return self._finish(request, started_ns, failure, response=response)
        try:
            raw_output = _extract_json_output(response.body)
        except _ProviderRefusal:
            return self._finish(
                request,
                started_ns,
                ProviderFailureKind.REFUSAL,
                response=response,
            )
        except (json.JSONDecodeError, KeyError, TypeError, ValueError, UnicodeEncodeError):
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
        try:
            parsed_output = strict_json_loads(raw_output)
            if not isinstance(parsed_output, dict):
                raise TypeError("response JSON must be an object")
        except (TypeError, ValueError):
            return self._finish(
                request,
                started_ns,
                ProviderFailureKind.INVALID_RESPONSE,
                response=response,
            )
        return self._finish(request, started_ns, None, raw_output, response)

    def _finish(
        self,
        request: ProviderRequest,
        started_ns: int,
        failure: ProviderFailureKind | None,
        raw_output: bytes | None = None,
        response: GeminiHTTPResponse | None = None,
    ) -> ProviderCallResult:
        completed_ns = max(started_ns, self._monotonic_ns())
        telemetry = ProviderTelemetry(
            latency_ms=(completed_ns - started_ns) // 1_000_000,
            input_tokens=_usage_integer(response, "promptTokenCount"),
            output_tokens=_usage_integer(response, "candidatesTokenCount"),
            cached_input_tokens=_usage_integer(response, "cachedContentTokenCount"),
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
GeminiProviderAdapter = GeminiAdapter


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
    parts: list[dict[str, Any]] = []
    if request.frame_png is not None:
        parts.append(
            {
                "inlineData": {
                    "mimeType": "image/png",
                    "data": base64.b64encode(request.frame_png).decode("ascii"),
                }
            }
        )
    player_payload = {
        "observation": observation,
        "scratchpad": request.scratchpad_utf8.decode("utf-8", errors="strict"),
    }
    parts.append({"text": json.dumps(player_payload, sort_keys=True, separators=(",", ":"))})
    return {
        "systemInstruction": {"parts": [{"text": request.system_prompt}]},
        "contents": [{"role": "user", "parts": parts}],
        "generationConfig": {
            "maxOutputTokens": 2048,
            "responseMimeType": "application/json",
            "responseJsonSchema": action_schema,
        },
    }


def _extract_json_output(body: Mapping[str, Any]) -> bytes:
    prompt_feedback = body.get("promptFeedback")
    if isinstance(prompt_feedback, Mapping) and prompt_feedback.get("blockReason"):
        raise _ProviderRefusal
    candidates = body.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        raise TypeError("candidates must be non-empty")
    candidate = candidates[0]
    if not isinstance(candidate, Mapping):
        raise TypeError("candidate must be an object")
    refusal_reasons = {
        "SAFETY",
        "RECITATION",
        "BLOCKLIST",
        "PROHIBITED_CONTENT",
        "SPII",
    }
    if candidate.get("finishReason") in refusal_reasons:
        raise _ProviderRefusal
    if candidate.get("finishReason") != "STOP":
        raise ValueError("candidate did not complete")
    content = candidate.get("content")
    if not isinstance(content, Mapping):
        raise TypeError("content must be an object")
    parts = content.get("parts")
    if not isinstance(parts, list):
        raise TypeError("parts must be a list")
    text_parts = [part.get("text") for part in parts if isinstance(part, Mapping)]
    if not text_parts or not all(isinstance(text, str) for text in text_parts):
        raise TypeError("text response missing")
    # Preserve exact model text for the shared strict parser and byte ceiling. Do not repair,
    # normalize, or canonicalize provider output at this boundary.
    return "".join(text_parts).encode("utf-8")


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


def _usage_integer(response: GeminiHTTPResponse | None, field: str) -> int | None:
    if response is None:
        return None
    usage = response.body.get("usageMetadata")
    if not isinstance(usage, Mapping):
        return None
    value = usage.get(field)
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def _request_id_hash(response: GeminiHTTPResponse | None) -> str | None:
    if response is None:
        return None
    request_id = response.headers.get("x-goog-request-id") or response.headers.get("x-request-id")
    if not isinstance(request_id, str) or not request_id:
        return None
    return hashlib.sha256(request_id.encode("utf-8")).hexdigest()


def _reject_non_json_number(value: str) -> None:
    raise ValueError(f"non-JSON number {value}")
