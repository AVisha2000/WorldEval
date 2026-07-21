"""Credential-safe local FastAPI surface for live embodiment episodes."""

from __future__ import annotations

from typing import Any, Mapping

from fastapi import APIRouter, Body, HTTPException, Request, Response

from .duel.service import (
    DuelSeriesEvidenceNotReadyError,
    DuelSeriesNotFoundError,
    DuelSeriesService,
)
from .episode_service import (
    EpisodeNotFoundError,
    EpisodeReplayNotReadyError,
    EpisodeResultNotReadyError,
    EpisodeService,
)
from .readiness import PilotReadinessStore

router = APIRouter(tags=["LLM Controller"])
_BODY = Body(...)
_CREATE_FIELDS = frozenset(
    {
        "api_key",
        "maximum_episode_ticks",
        "model",
        "observation_profile",
        "provider",
        "seed",
        "task_id",
    }
)


def _service(request: Request) -> EpisodeService:
    service = getattr(request.app.state, "embodiment_episodes", None)
    if not isinstance(service, EpisodeService):
        raise RuntimeError("Embodiment episode service is not configured")
    return service


def _series_service(request: Request) -> DuelSeriesService:
    service = getattr(request.app.state, "embodiment_series", None)
    if not isinstance(service, DuelSeriesService):
        raise RuntimeError("Embodiment duel series service is not configured")
    return service


def _readiness(request: Request) -> PilotReadinessStore:
    store = getattr(request.app.state, "embodiment_readiness", None)
    if not isinstance(store, PilotReadinessStore):
        raise RuntimeError("Embodiment readiness store is not configured")
    return store


@router.get("/api/embodiment/certification/readiness")
async def get_certification_readiness(request: Request, response: Response) -> Mapping[str, Any]:
    response.headers["Cache-Control"] = "no-store"
    return _readiness(request).read()


@router.post("/api/embodiment/episodes", status_code=202)
async def create_episode(
    request: Request, response: Response, payload: Any = _BODY
) -> Mapping[str, Any]:
    # Manual validation prevents FastAPI/Pydantic error details from reflecting malformed keys.
    values = _validate_create_payload(payload)
    try:
        created = await _service(request).create(**values)
    except (TypeError, ValueError):
        raise HTTPException(
            status_code=422, detail={"code": "invalid_embodiment_episode_request"}
        ) from None
    response.headers["Cache-Control"] = "no-store"
    return created


@router.get("/api/embodiment/episodes/{episode_id}")
async def get_episode(request: Request, response: Response, episode_id: str) -> Mapping[str, Any]:
    response.headers["Cache-Control"] = "no-store"
    return await _not_found(lambda: _service(request).status(episode_id))


@router.get("/api/embodiment/episodes/{episode_id}/timeline")
async def get_episode_timeline(
    request: Request, response: Response, episode_id: str
) -> Mapping[str, Any]:
    response.headers["Cache-Control"] = "no-store"
    timeline = await _not_found(lambda: _service(request).timeline(episode_id))
    return {"episode_id": episode_id, "events": timeline}


@router.get("/api/embodiment/episodes/{episode_id}/frame")
async def get_episode_frame(request: Request, episode_id: str) -> Response:
    try:
        view = await _service(request).frame(episode_id)
    except EpisodeNotFoundError:
        raise HTTPException(
            status_code=404, detail={"code": "embodiment_episode_not_found"}
        ) from None
    headers = {
        "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'none'; sandbox",
        "X-Content-Type-Options": "nosniff",
        "X-Frame-State": view.state,
    }
    if view.snapshot is None:
        return Response(status_code=204, headers=headers)
    headers.update(
        {
            "X-Content-SHA256": view.snapshot.sha256,
            "X-Observation-Seq": str(view.snapshot.observation_seq),
        }
    )
    return Response(content=view.snapshot.png, media_type="image/png", headers=headers)


@router.get("/api/embodiment/episodes/{episode_id}/result")
async def get_episode_result(
    request: Request, response: Response, episode_id: str
) -> Mapping[str, Any]:
    response.headers["Cache-Control"] = "no-store"
    try:
        return await _service(request).result(episode_id)
    except EpisodeNotFoundError:
        raise HTTPException(
            status_code=404, detail={"code": "embodiment_episode_not_found"}
        ) from None
    except EpisodeResultNotReadyError:
        raise HTTPException(
            status_code=409, detail={"code": "embodiment_episode_result_not_ready"}
        ) from None


@router.get("/api/embodiment/episodes/{episode_id}/replay")
async def get_episode_replay(request: Request, episode_id: str) -> Response:
    try:
        bundle = await _service(request).replay(episode_id)
    except EpisodeNotFoundError:
        raise HTTPException(
            status_code=404, detail={"code": "embodiment_episode_not_found"}
        ) from None
    except EpisodeReplayNotReadyError:
        raise HTTPException(
            status_code=409, detail={"code": "embodiment_episode_replay_not_ready"}
        ) from None
    return Response(
        content=bundle.bundle_bytes,
        media_type="application/json",
        headers={"Cache-Control": "no-store", "X-Content-SHA256": bundle.content_sha256},
    )


@router.post("/api/embodiment/episodes/{episode_id}/cancel")
async def cancel_episode(
    request: Request, response: Response, episode_id: str
) -> Mapping[str, Any]:
    response.headers["Cache-Control"] = "no-store"
    return await _not_found(lambda: _service(request).cancel(episode_id))


@router.post("/api/embodiment/series", status_code=202)
async def create_series(
    request: Request, response: Response, payload: Any = _BODY
) -> Mapping[str, Any]:
    try:
        values = _validate_series_payload(payload)
        created = await _series_service(request).create(**values)
    except (TypeError, ValueError):
        raise HTTPException(
            status_code=422, detail={"code": "invalid_embodiment_series_request"}
        ) from None
    response.headers["Cache-Control"] = "no-store"
    return created


@router.get("/api/embodiment/series/{series_id}")
async def get_series(request: Request, response: Response, series_id: str) -> Mapping[str, Any]:
    response.headers["Cache-Control"] = "no-store"
    try:
        return await _series_service(request).status(series_id)
    except DuelSeriesNotFoundError:
        raise HTTPException(
            status_code=404, detail={"code": "embodiment_series_not_found"}
        ) from None


@router.get("/api/embodiment/series/{series_id}/result")
async def get_series_result(
    request: Request, response: Response, series_id: str
) -> Mapping[str, Any]:
    response.headers["Cache-Control"] = "no-store"
    try:
        return await _series_service(request).result(series_id)
    except DuelSeriesNotFoundError:
        raise HTTPException(
            status_code=404, detail={"code": "embodiment_series_not_found"}
        ) from None
    except RuntimeError:
        raise HTTPException(
            status_code=409, detail={"code": "embodiment_series_result_not_ready"}
        ) from None


@router.get("/api/embodiment/series/{series_id}/replay")
async def get_series_replay(request: Request, series_id: str) -> Response:
    try:
        bundle = await _series_service(request).replay(series_id)
    except DuelSeriesNotFoundError:
        raise HTTPException(
            status_code=404,
            detail={"code": "embodiment_series_not_found"},
            headers={"Cache-Control": "no-store"},
        ) from None
    except DuelSeriesEvidenceNotReadyError:
        raise HTTPException(
            status_code=409,
            detail={"code": "embodiment_series_evidence_not_ready"},
            headers={"Cache-Control": "no-store"},
        ) from None
    return Response(
        content=bundle.bundle_bytes,
        media_type="application/json",
        headers={"Cache-Control": "no-store", "X-Content-SHA256": bundle.content_sha256},
    )


@router.post("/api/embodiment/series/{series_id}/cancel")
async def cancel_series(request: Request, response: Response, series_id: str) -> Mapping[str, Any]:
    response.headers["Cache-Control"] = "no-store"
    try:
        return await _series_service(request).cancel(series_id)
    except DuelSeriesNotFoundError:
        raise HTTPException(
            status_code=404, detail={"code": "embodiment_series_not_found"}
        ) from None


def _validate_create_payload(payload: Any) -> dict[str, Any]:
    invalid = HTTPException(status_code=422, detail={"code": "invalid_embodiment_episode_request"})
    if not isinstance(payload, dict) or not set(payload) <= _CREATE_FIELDS:
        raise invalid
    required = {"api_key", "model", "provider", "seed", "task_id"}
    if not required <= set(payload):
        raise invalid
    if any(not isinstance(payload[name], str) or not payload[name] for name in required - {"seed"}):
        raise invalid
    if isinstance(payload["seed"], bool) or not isinstance(payload["seed"], int):
        raise invalid
    maximum = payload.get("maximum_episode_ticks", 1800)
    if isinstance(maximum, bool) or not isinstance(maximum, int):
        raise invalid
    return {
        "api_key": payload["api_key"],
        "maximum_episode_ticks": maximum,
        "model": payload["model"],
        "observation_profile": payload.get("observation_profile", "hybrid-visible-v1"),
        "provider": payload["provider"],
        "seed": payload["seed"],
        "task_id": payload["task_id"],
    }


def _validate_series_payload(payload: Any) -> dict[str, Any]:
    if (
        not isinstance(payload, dict)
        or not {"entrants", "seed"} <= set(payload)
        or not set(payload) <= {"entrants", "seed", "max_live_provider_calls"}
    ):
        raise ValueError("invalid series payload")
    entrants = payload["entrants"]
    if not isinstance(entrants, list) or len(entrants) != 2:
        raise ValueError("invalid series entrants")
    normalized = []
    for entrant in entrants:
        if not isinstance(entrant, dict):
            raise ValueError("invalid series entrant")
        expected = (
            {"provider", "model"}
            if entrant.get("provider") == "scripted"
            else {"provider", "model", "api_key"}
        )
        if set(entrant) != expected:
            raise ValueError("invalid series entrant")
        normalized.append(dict(entrant))
    return {
        "entrants": (normalized[0], normalized[1]),
        "seed": payload["seed"],
        "max_live_provider_calls": payload.get("max_live_provider_calls", 2160),
    }


async def _not_found(call: Any) -> Any:
    try:
        return await call()
    except EpisodeNotFoundError:
        raise HTTPException(
            status_code=404, detail={"code": "embodiment_episode_not_found"}
        ) from None


__all__ = ["router"]
