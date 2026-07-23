"""Controller Lab API for replay-first Primitive Sandbox demos."""

from __future__ import annotations

from typing import Any, Mapping, Union

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field

from .configuration import SCENARIOS, sandbox_catalog
from .service import (
    PrimitiveSandboxService,
    PrimitiveSandboxServiceError,
    PrimitiveSandboxSessionConflict,
    PrimitiveSandboxSessionNotFound,
)


class SandboxRunRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    scenario_id: str = Field(alias="scenarioId", min_length=1, max_length=128)


class SandboxSessionRequest(SandboxRunRequest):
    pass


class SandboxAcknowledgementRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    initialization_hash: str = Field(
        alias="initializationHash",
        pattern=r"^sha256:[0-9a-f]{64}$",
    )


class SandboxDecisionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    decision: Any = None


router = APIRouter(prefix="/api/worldeval/sandbox", tags=["primitive-sandbox"])


def _service(request: Request) -> PrimitiveSandboxService:
    service = getattr(request.app.state, "primitive_sandbox", None)
    if not isinstance(service, PrimitiveSandboxService):
        raise HTTPException(status_code=503, detail="Primitive Sandbox is unavailable")
    return service


@router.get("")
def get_sandbox_catalog() -> Mapping[str, object]:
    return sandbox_catalog()


@router.post("/runs")
def create_sandbox_run(
    request: Request,
    value: SandboxRunRequest,
) -> Mapping[str, object]:
    if value.scenario_id not in SCENARIOS:
        raise HTTPException(status_code=422, detail="unknown Primitive Sandbox scenario")
    try:
        return _service(request).run(value.scenario_id).projection
    except PrimitiveSandboxServiceError as error:
        raise HTTPException(
            status_code=500,
            detail="Primitive Sandbox replay was not saved",
        ) from error


@router.get("/runs/{run_id}")
def get_sandbox_run(request: Request, run_id: str) -> Mapping[str, object]:
    try:
        result = _service(request).get(run_id)
    except PrimitiveSandboxServiceError as error:
        raise HTTPException(status_code=409, detail="saved sandbox replay is invalid") from error
    if result is None:
        raise HTTPException(status_code=404, detail="sandbox run not found")
    return result.projection


@router.post("/sessions", status_code=201)
def create_sandbox_session(
    request: Request,
    value: SandboxSessionRequest,
) -> Mapping[str, Any]:
    if value.scenario_id not in SCENARIOS:
        raise HTTPException(status_code=422, detail="unknown Primitive Sandbox scenario")
    try:
        return _service(request).create_session(value.scenario_id).projection
    except PrimitiveSandboxServiceError as error:
        raise HTTPException(
            status_code=500,
            detail="Primitive Sandbox session could not be initialized",
        ) from error


@router.get("/sessions/{session_id}")
def get_sandbox_session(request: Request, session_id: str) -> Mapping[str, Any]:
    try:
        return _service(request).get_session(session_id).projection
    except PrimitiveSandboxSessionNotFound as error:
        raise HTTPException(status_code=404, detail="sandbox session not found") from error


@router.post("/sessions/{session_id}/acknowledge")
def acknowledge_sandbox_session(
    request: Request,
    session_id: str,
    value: SandboxAcknowledgementRequest,
) -> Mapping[str, Any]:
    try:
        return _service(request).acknowledge_session(
            session_id,
            value.initialization_hash,
        ).projection
    except PrimitiveSandboxSessionNotFound as error:
        raise HTTPException(status_code=404, detail="sandbox session not found") from error
    except PrimitiveSandboxSessionConflict as error:
        raise HTTPException(
            status_code=409,
            detail="initialization acknowledgement was rejected",
        ) from error


@router.post("/sessions/{session_id}/decisions")
def submit_sandbox_decision(
    request: Request,
    session_id: str,
    value: Union[SandboxDecisionRequest, None] = None,
) -> Mapping[str, Any]:
    input_present = value is not None and "decision" in value.model_fields_set
    try:
        return _service(request).submit_decision(
            session_id,
            decision=None if value is None else value.decision,
            input_present=input_present,
        ).projection
    except PrimitiveSandboxSessionNotFound as error:
        raise HTTPException(status_code=404, detail="sandbox session not found") from error
    except PrimitiveSandboxSessionConflict as error:
        raise HTTPException(
            status_code=409,
            detail="sandbox decision is not allowed in the current session state",
        ) from error
    except PrimitiveSandboxServiceError as error:
        raise HTTPException(
            status_code=500,
            detail="Primitive Sandbox decision boundary failed",
        ) from error


__all__ = [
    "SandboxAcknowledgementRequest",
    "SandboxDecisionRequest",
    "SandboxRunRequest",
    "SandboxSessionRequest",
    "router",
]
