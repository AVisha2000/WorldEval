"""FastAPI control surface for process-local WorldArena Duel matches."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Body, HTTPException, Request, Response, WebSocket
from pydantic import ValidationError

from .match_service import (
    DuelCreateMatchRequest,
    DuelMatchConfigurationError,
    DuelMatchCreation,
    DuelMatchLaunchError,
    DuelMatchNotFoundError,
    DuelMatchResultNotReadyError,
    DuelMatchResultView,
    DuelMatchService,
    DuelMatchServiceError,
    DuelMatchStatus,
    GodotControllerLaunchFields,
)

router = APIRouter(tags=["WorldArena Duel"])
_JSON_BODY = Body(...)


def _service(scope: Request | WebSocket) -> DuelMatchService:
    service = getattr(scope.app.state, "duel_matches", None)
    if not isinstance(service, DuelMatchService):
        raise RuntimeError("Duel match service is not configured")
    return service


@router.post(
    "/api/duel/matches",
    response_model=DuelMatchCreation,
    status_code=202,
)
async def create_duel_match(
    request_scope: Request, response: Response, payload: Any = _JSON_BODY
) -> DuelMatchCreation:
    # Manual validation is intentional.  FastAPI's default 422 body can echo the invalid input;
    # this endpoint must never reflect a credential, even for a malformed request.
    try:
        request = DuelCreateMatchRequest.model_validate(payload)
    except ValidationError:
        raise HTTPException(
            status_code=422,
            detail={"code": "invalid_duel_match_request"},
        ) from None
    try:
        created = await _service(request_scope).create_match(request)
    except DuelMatchConfigurationError:
        raise HTTPException(
            status_code=422,
            detail={"code": "duel_configuration_invalid"},
        ) from None
    except DuelMatchLaunchError as exc:
        raise HTTPException(
            status_code=503,
            detail={"code": exc.code, "match_id": exc.match_id},
        ) from None
    except DuelMatchServiceError:
        raise HTTPException(
            status_code=503,
            detail={"code": "duel_service_unavailable"},
        ) from None
    response.headers["Cache-Control"] = "no-store"
    return created


@router.get(
    "/api/duel/matches/{match_id}",
    response_model=DuelMatchStatus,
)
async def get_duel_match(request: Request, match_id: str) -> DuelMatchStatus:
    try:
        return await _service(request).get_status(match_id)
    except DuelMatchNotFoundError:
        raise HTTPException(status_code=404, detail={"code": "duel_match_not_found"}) from None


@router.get(
    "/api/duel/matches/{match_id}/result",
    response_model=DuelMatchResultView,
)
async def get_duel_match_result(request: Request, match_id: str) -> DuelMatchResultView:
    try:
        return await _service(request).get_result(match_id)
    except DuelMatchNotFoundError:
        raise HTTPException(status_code=404, detail={"code": "duel_match_not_found"}) from None
    except DuelMatchResultNotReadyError:
        raise HTTPException(status_code=409, detail={"code": "duel_result_not_ready"}) from None


@router.post(
    "/api/duel/matches/{match_id}/cancel",
    response_model=DuelMatchStatus,
)
async def cancel_duel_match(request: Request, match_id: str) -> DuelMatchStatus:
    try:
        return await _service(request).cancel_match(match_id)
    except DuelMatchNotFoundError:
        raise HTTPException(status_code=404, detail={"code": "duel_match_not_found"}) from None


@router.post(
    "/api/duel/launch-claim",
    response_model=GodotControllerLaunchFields,
)
async def claim_duel_controller_launch(
    request: Request, response: Response, payload: Any = _JSON_BODY
) -> GodotControllerLaunchFields:
    # Keep a capability out of the URL and access log.  Invalid/non-loopback claimants receive the
    # same response so the endpoint cannot be used as a capability oracle.
    claim_token = payload.get("claim_token") if isinstance(payload, dict) else None
    if not isinstance(claim_token, str) or not claim_token:
        raise HTTPException(status_code=404, detail={"code": "duel_launch_claim_not_found"})
    client_host = request.client.host if request.client is not None else None
    try:
        fields = await _service(request).claim_controller_launch(
            claim_token, client_host=client_host
        )
    except DuelMatchNotFoundError:
        raise HTTPException(
            status_code=404, detail={"code": "duel_launch_claim_not_found"}
        ) from None
    response.headers["Cache-Control"] = "no-store"
    return fields


@router.websocket("/ws/duel/{ticket}")
async def duel_godot_socket(websocket: WebSocket, ticket: str) -> None:
    await _service(websocket).attach_websocket(ticket, websocket)


__all__ = ["router"]
