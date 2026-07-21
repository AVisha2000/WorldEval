"""Credential-safe local FastAPI surface for live embodiment episodes."""

from __future__ import annotations

from typing import Any, Mapping

from fastapi import (
    APIRouter,
    Body,
    HTTPException,
    Query,
    Request,
    Response,
    WebSocket,
    WebSocketDisconnect,
)
from fastapi.responses import FileResponse

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
from .scripted_construction_demo import (
    SCRIPTED_CONSTRUCTION_PROVIDER,
)
from .scripted_solo_demo import is_scripted_solo_demo

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


def _service(request: Request | WebSocket) -> EpisodeService:
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


@router.websocket("/api/embodiment/episodes/{episode_id}/preview")
async def stream_episode_preview(websocket: WebSocket, episode_id: str) -> None:
    """Newest-frame-only participant-pixel preview; no JSON is sent on this channel."""
    try:
        token, queue, initial = await _service(websocket).preview_subscription(episode_id)
    except EpisodeNotFoundError:
        await websocket.close(code=4404)
        return
    await websocket.accept()
    try:
        if initial is not None:
            await websocket.send_bytes(initial.png)
        while True:
            await websocket.send_bytes((await queue.get()).png)
    except WebSocketDisconnect:
        pass
    finally:
        await _service(websocket).unsubscribe_preview(episode_id, token)


@router.websocket("/api/embodiment/episodes/{episode_id}/preview-live")
async def stream_live_episode_preview(websocket: WebSocket, episode_id: str) -> None:
    """Direct Godot presentation pixels only; canonical snapshot/replay traffic stays separate."""

    try:
        token, queue, initial = await _service(websocket).live_preview_subscription(episode_id)
    except EpisodeNotFoundError:
        await websocket.close(code=4404)
        return
    await websocket.accept()
    try:
        if initial is not None:
            await websocket.send_bytes(initial.png)
        while True:
            await websocket.send_bytes((await queue.get()).png)
    except WebSocketDisconnect:
        pass
    finally:
        await _service(websocket).unsubscribe_live_preview(episode_id, token)


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


@router.get("/api/embodiment/replays")
async def list_saved_replays(
    request: Request, response: Response, limit: int = Query(default=50, ge=1, le=100)
) -> Mapping[str, Any]:
    """List durable participant-video replays, never their protected authority inputs."""

    response.headers["Cache-Control"] = "no-store"
    replays = await _service(request).saved_replays(limit=limit)
    return {"replays": [replay.public_dict() for replay in replays]}


@router.get("/api/embodiment/replays/{replay_id}")
async def get_saved_replay(
    request: Request, response: Response, replay_id: str
) -> Mapping[str, Any]:
    response.headers["Cache-Control"] = "no-store"
    replay = await _service(request).saved_replay(replay_id)
    if replay is None:
        raise HTTPException(status_code=404, detail={"code": "embodiment_saved_replay_not_found"})
    return replay.public_dict()


@router.api_route("/api/embodiment/replays/{replay_id}/video", methods=["GET", "HEAD"])
async def get_saved_replay_video(request: Request, replay_id: str) -> Response:
    """Return only a local participant-pixel MP4; raw replay bytes have no API route."""

    target = await _service(request).saved_replay_video_path(replay_id)
    if target is None:
        raise HTTPException(status_code=404, detail={"code": "embodiment_saved_replay_not_found"})
    return FileResponse(
        target,
        media_type="video/mp4",
        headers={
            "Cache-Control": "no-store",
            "Content-Security-Policy": "default-src 'none'; sandbox",
            "X-Content-Type-Options": "nosniff",
        },
    )


@router.get("/api/embodiment/replays/{replay_id}/bundle")
async def get_saved_replay_public_bundle(request: Request, replay_id: str) -> Response:
    """The same public evidence bundle retained beside the participant video."""

    target = await _service(request).saved_replay_public_bundle_path(replay_id)
    if target is None:
        raise HTTPException(status_code=404, detail={"code": "embodiment_saved_replay_not_found"})
    try:
        payload = target.read_bytes()
    except OSError:
        raise HTTPException(
            status_code=404, detail={"code": "embodiment_saved_replay_not_found"}
        ) from None
    return Response(
        content=payload,
        media_type="application/json",
        headers={"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"},
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
    required = {"model", "provider", "seed", "task_id"}
    if not required <= set(payload):
        raise invalid
    if any(not isinstance(payload[name], str) or not payload[name] for name in required - {"seed"}):
        raise invalid
    if isinstance(payload["seed"], bool) or not isinstance(payload["seed"], int):
        raise invalid
    maximum = payload.get("maximum_episode_ticks", 1800)
    if isinstance(maximum, bool) or not isinstance(maximum, int):
        raise invalid
    provider = payload["provider"]
    if provider == SCRIPTED_CONSTRUCTION_PROVIDER:
        if "api_key" in payload or not is_scripted_solo_demo(
            provider=provider, model=payload["model"], task_id=payload["task_id"]
        ):
            raise invalid
        api_key: str | None = None
    else:
        api_key = payload.get("api_key")
        if not isinstance(api_key, str) or not api_key:
            raise invalid
    return {
        "api_key": api_key,
        "maximum_episode_ticks": maximum,
        "model": payload["model"],
        "observation_profile": payload.get("observation_profile", "hybrid-visible-v1"),
        "provider": provider,
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
