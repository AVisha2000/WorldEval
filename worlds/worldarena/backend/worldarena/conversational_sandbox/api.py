from typing import Any, Mapping

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field

from .service import (
    ConversationSandboxService,
    ConversationSessionConflict,
    ConversationSessionNotFound,
)

router = APIRouter(prefix="/api/worldeval/conversation-sandbox", tags=["conversational-sandbox"])


class SessionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)
    scenario_id: str = Field(alias="scenarioId", min_length=1, max_length=128)


class MessageRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    text: str = Field(min_length=1, max_length=2000)


class AcknowledgeRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)
    clarification_id: str = Field(alias="clarificationId")
    binding_id: str = Field(alias="bindingId")


def _service(request: Request) -> ConversationSandboxService:
    value = getattr(request.app.state, "conversation_sandbox", None)
    if not isinstance(value, ConversationSandboxService):
        raise HTTPException(503, "Conversational Sandbox is unavailable")
    return value


@router.get("")
def catalog(request: Request) -> Mapping[str, Any]:
    return _service(request).catalog()


@router.post("/sessions", status_code=201)
def create(request: Request, value: SessionRequest) -> Mapping[str, Any]:
    try:
        return _service(request).create_session(value.scenario_id)
    except ConversationSessionConflict as error:
        raise HTTPException(422, "unknown conversational scenario") from error


@router.get("/sessions/{session_id}")
def get(request: Request, session_id: str) -> Mapping[str, Any]:
    try:
        return _service(request).get_session(session_id)
    except ConversationSessionNotFound as error:
        raise HTTPException(404, "conversational session not found") from error


@router.post("/sessions/{session_id}/messages")
def message(request: Request, session_id: str, value: MessageRequest) -> Mapping[str, Any]:
    try:
        return _service(request).send_message(session_id, value.text)
    except ConversationSessionNotFound as error:
        raise HTTPException(404, "conversational session not found") from error


@router.post("/sessions/{session_id}/acknowledge")
def acknowledge(request: Request, session_id: str, value: AcknowledgeRequest) -> Mapping[str, Any]:
    try:
        return _service(request).acknowledge(session_id, value.clarification_id, value.binding_id)
    except ConversationSessionNotFound as error:
        raise HTTPException(404, "conversational session not found") from error
    except ConversationSessionConflict as error:
        raise HTTPException(409, "clarification is stale or unavailable") from error
