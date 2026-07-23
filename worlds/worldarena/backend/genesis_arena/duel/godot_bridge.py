"""Authenticated, fail-closed Godot/Gateway transport for WorldArena Duel.

This module is the concrete local boundary behind ``FixedAuthoritativeBridge`` and
``ContinuousAuthoritativeBridge``.  It intentionally does not run a model, interpret commands,
or mutate game state.  Godot remains authoritative; this bridge only authenticates canonical
frames, enforces the match protocol state machine, and converts already-validated runtime
requests into atomic wire messages.

The in-memory link is the reference transport used by tests and headless orchestration.  The
optional WebSocket adapter has the same byte contract and accepts loopback clients only.
"""

from __future__ import annotations

# ruff: noqa: UP045 -- Keep public annotations aligned with the repository's Python floor.
import asyncio
import hashlib
import hmac
import ipaddress
import re
from dataclasses import dataclass
from enum import Enum
from typing import (
    Awaitable,
    Callable,
    Dict,
    List,
    Literal,
    Mapping,
    Optional,
    Protocol,
    Tuple,
    Union,
)

from pydantic import Field, JsonValue, TypeAdapter, model_validator

from .canonical import DuelCanonicalError, canonical_json_bytes, strict_json_loads
from .continuous_runtime import (
    ContinuousApplyGateRequest,
    ContinuousAuthoritativeBridge,
    ContinuousOpportunityDisposition,
)
from .models import (
    ActionBatch,
    DuelModel,
    HashHex,
    MatchConfig,
    MatchId,
    ObservableEvent,
    ProtocolVersion,
)
from .runtime import FixedAuthoritativeBridge, FixedCommitRequest, FixedRevealRequest
from .timing import FailureClassification, FailureOwner
from .transport import MAX_TRANSPORT_FRAME_BYTES

MAX_GODOT_BRIDGE_FRAME_BYTES = MAX_TRANSPORT_FRAME_BYTES
FROZEN_GODOT_ENGINE_VERSION = "4.5.stable.official.876b29033"
SESSION_BOUNDARY_HASH = "0" * 64

BridgeRole = Literal["gateway", "godot"]
BridgeMessageType = Literal[
    "hello",
    "auth",
    "match_config",
    "config_accepted",
    "match_init",
    "observation_pair",
    "observation",
    "thinking_status",
    "batch_commit_hashes",
    "batch_commits_locked",
    "batch_reveal",
    "action_pair",
    "action",
    "action_receipts",
    "gateway_disposition",
    "gateway_disposition_accepted",
    "continuous_start",
    "continuous_start_accepted",
    "tick_events",
    "checkpoint",
    "terminal",
    "artifact_ready",
]
BridgeBoundaryKind = Literal[
    "session", "config", "protocol", "observation", "checkpoint", "result", "artifact"
]

_AUTH_DOMAIN = b"worldeval-rts/godot-gateway-frame/v1\x00"
_KEY_DOMAIN = b"worldeval-rts/godot-gateway-key/v1\x00"
_MESSAGE_BOUNDARY_KIND: Dict[str, str] = {
    "hello": "session",
    "auth": "session",
    "match_config": "config",
    "config_accepted": "config",
    "match_init": "protocol",
    "observation_pair": "checkpoint",
    "observation": "observation",
    "thinking_status": "observation",
    "batch_commit_hashes": "checkpoint",
    "batch_commits_locked": "checkpoint",
    "batch_reveal": "checkpoint",
    "action_pair": "checkpoint",
    "action": "checkpoint",
    "action_receipts": "checkpoint",
    "gateway_disposition": "checkpoint",
    "gateway_disposition_accepted": "checkpoint",
    "continuous_start": "checkpoint",
    "continuous_start_accepted": "checkpoint",
    "tick_events": "checkpoint",
    "checkpoint": "checkpoint",
    "terminal": "result",
    "artifact_ready": "artifact",
}
_PROVIDER_VISIBLE_TYPES = frozenset({"match_init", "observation"})
_HIDDEN_WORLD_HASH_KEYS = frozenset(
    {
        "checkpoint_hash",
        "final_state_hash",
        "omniscient_state_hash",
        "state_hash",
        "world_hash",
    }
)
_SAFE_DISPOSITION_CODE_RE = re.compile(r"^[a-z0-9][a-z0-9_.:-]{0,95}$")
_SAFE_PUBLIC_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_PRIVATE_REPLAY_KEY_MARKERS = (
    "api_key",
    "authorization",
    "credential",
    "hidden_reasoning",
    "prompt",
    "raw_output",
    "raw_response",
    "scratchpad",
    "secret",
    "token",
    "validation_trace",
    "working_memory",
)
_CONTINUOUS_TERMINAL_DISPOSITIONS = frozenset(
    {
        ContinuousOpportunityDisposition.TECHNICAL_FORFEIT_SLOT_0.value,
        ContinuousOpportunityDisposition.TECHNICAL_FORFEIT_SLOT_1.value,
        ContinuousOpportunityDisposition.DRAW_DOUBLE_TECHNICAL_FORFEIT.value,
        ContinuousOpportunityDisposition.VOID_INFRASTRUCTURE.value,
    }
)
_MODEL_FAILURE_THRESHOLD_CODE = "model_failure_threshold"


class GodotBridgePhase(str, Enum):
    AWAITING_HELLO = "awaiting_hello"
    AUTHENTICATED = "authenticated"
    AWAITING_CONFIG_ACCEPTED = "awaiting_config_accepted"
    RUNNING = "running"
    AWAITING_FIXED_LOCK = "awaiting_fixed_lock"
    AWAITING_FIXED_ACTION_PAIR = "awaiting_fixed_action_pair"
    AWAITING_CONTINUOUS_ACTION_PAIR = "awaiting_continuous_action_pair"
    TERMINAL = "terminal"
    COMPLETE = "complete"
    FAILED = "failed"
    CLOSED = "closed"


class GodotBridgeError(RuntimeError):
    """Base bridge error carrying a benchmark failure classification."""

    def __init__(self, code: str, message: str, classification: FailureClassification) -> None:
        super().__init__(message)
        self.code = code
        self.classification = classification


class GodotBridgeInfrastructureError(GodotBridgeError):
    """Organizer-owned local engine, framing, authentication, or timeout failure."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(
            code,
            message,
            FailureClassification(code, FailureOwner.ORGANIZER_INFRASTRUCTURE, False),
        )


class GodotBridgeParticipantError(GodotBridgeError):
    """A participant-owned endpoint failure explicitly reported by the authority."""

    def __init__(self, code: str, message: str, *, hard: bool = True) -> None:
        super().__init__(
            code,
            message,
            FailureClassification(code, FailureOwner.PARTICIPANT_ENDPOINT, hard),
        )


class GodotBridgeModelError(GodotBridgeError):
    """A model-owned failure explicitly reported by the authority."""

    def __init__(self, code: str, message: str, *, hard: bool = True) -> None:
        super().__init__(
            code,
            message,
            FailureClassification(code, FailureOwner.MODEL, hard),
        )


class AuthenticatedGodotFrame(DuelModel):
    """One complete canonical object on the local wire."""

    protocol_version: ProtocolVersion = "worldeval-rts/1.0.0"
    match_id: MatchId
    sender: BridgeRole
    sequence: int = Field(ge=0, le=9_007_199_254_740_991)
    message_type: BridgeMessageType
    boundary_hash_kind: BridgeBoundaryKind
    boundary_hash: HashHex
    body: Dict[str, JsonValue]
    auth_tag: HashHex

    @model_validator(mode="after")
    def validate_boundary(self) -> AuthenticatedGodotFrame:
        expected = _MESSAGE_BOUNDARY_KIND[self.message_type]
        if self.boundary_hash_kind != expected:
            raise ValueError(f"{self.message_type} requires {expected} boundary hash")
        if self.message_type in {"hello", "auth"} and self.boundary_hash != SESSION_BOUNDARY_HASH:
            raise ValueError("handshake frames require the zero session boundary hash")
        if self.message_type in _PROVIDER_VISIBLE_TYPES and _contains_hidden_world_hash(self.body):
            raise ValueError("provider-visible frame contains an omniscient world hash")
        return self

    def unsigned_dict(self) -> Dict[str, JsonValue]:
        value = self.model_dump(mode="json")
        del value["auth_tag"]
        return value


class AuthenticatedGodotCodec:
    """Independent per-direction sequence and HMAC state for one non-reconnectable peer."""

    def __init__(self, *, match_id: str, token: bytes, local_role: BridgeRole) -> None:
        if not isinstance(token, bytes) or len(token) < 32:
            raise ValueError("Godot bridge token must contain at least 32 random bytes")
        if local_role not in {"gateway", "godot"}:
            raise ValueError("local_role must be gateway or godot")
        self.match_id = _validated_match_id(match_id)
        self.local_role: BridgeRole = local_role
        self.remote_role: BridgeRole = "godot" if local_role == "gateway" else "gateway"
        self._keys = {
            role: hmac.new(token, _KEY_DOMAIN + role.encode("ascii"), hashlib.sha256).digest()
            for role in ("gateway", "godot")
        }
        self._outbound_sequence = 0
        self._inbound_sequence = 0
        self._failed = False
        self._closed = False

    @property
    def outbound_sequence(self) -> int:
        return self._outbound_sequence

    @property
    def inbound_sequence(self) -> int:
        return self._inbound_sequence

    @property
    def failed(self) -> bool:
        return self._failed

    def encode(
        self,
        message_type: BridgeMessageType,
        *,
        boundary_hash: str,
        body: Mapping[str, JsonValue],
    ) -> bytes:
        self._require_open()
        kind = _MESSAGE_BOUNDARY_KIND.get(message_type)
        if kind is None:
            return self._fail("unsupported_message_type", "outbound message type is unsupported")
        unsigned: Dict[str, JsonValue] = {
            "body": dict(body),
            "boundary_hash": boundary_hash,
            "boundary_hash_kind": kind,
            "match_id": self.match_id,
            "message_type": message_type,
            "protocol_version": "worldeval-rts/1.0.0",
            "sender": self.local_role,
            "sequence": self._outbound_sequence,
        }
        try:
            auth_tag = _frame_auth_tag(self._keys[self.local_role], unsigned)
            frame = AuthenticatedGodotFrame.model_validate({**unsigned, "auth_tag": auth_tag})
            payload = canonical_json_bytes(frame)
        except (DuelCanonicalError, TypeError, ValueError) as exc:
            self._failed = True
            raise GodotBridgeInfrastructureError(
                "outbound_frame_invalid", "outbound Godot bridge frame violates policy"
            ) from exc
        if len(payload) > MAX_GODOT_BRIDGE_FRAME_BYTES:
            return self._fail("frame_too_large", "outbound Godot bridge frame exceeds byte limit")
        self._outbound_sequence += 1
        return payload

    def decode(self, payload: bytes) -> AuthenticatedGodotFrame:
        self._require_open()
        if not isinstance(payload, bytes) or len(payload) > MAX_GODOT_BRIDGE_FRAME_BYTES:
            return self._fail("frame_too_large", "inbound Godot bridge frame exceeds byte limit")
        try:
            value = strict_json_loads(payload)
            if not isinstance(value, dict):
                raise ValueError("frame root is not an object")
            if canonical_json_bytes(value) != payload:
                raise ValueError("frame bytes are not canonical")
            frame = AuthenticatedGodotFrame.model_validate(value)
        except (DuelCanonicalError, TypeError, ValueError) as exc:
            self._failed = True
            raise GodotBridgeInfrastructureError(
                "inbound_frame_invalid", "inbound Godot bridge frame is invalid"
            ) from exc
        if frame.match_id != self.match_id:
            return self._fail("wrong_match", "inbound Godot bridge frame has wrong match")
        if frame.sender != self.remote_role:
            return self._fail("wrong_sender", "inbound Godot bridge frame has wrong sender role")
        if frame.sequence != self._inbound_sequence:
            return self._fail(
                "sequence_violation",
                f"expected inbound sequence {self._inbound_sequence}, got {frame.sequence}",
            )
        expected_tag = _frame_auth_tag(self._keys[self.remote_role], frame.unsigned_dict())
        if not hmac.compare_digest(frame.auth_tag, expected_tag):
            return self._fail("authentication_failed", "Godot bridge frame authentication failed")
        self._inbound_sequence += 1
        return frame

    def close(self) -> None:
        self._closed = True

    def _require_open(self) -> None:
        if self._failed:
            raise GodotBridgeInfrastructureError(
                "codec_failed_closed", "Godot bridge codec already failed closed"
            )
        if self._closed:
            raise GodotBridgeInfrastructureError("codec_closed", "Godot bridge codec is closed")

    def _fail(self, code: str, message: str):
        self._failed = True
        raise GodotBridgeInfrastructureError(code, message)

    def __repr__(self) -> str:
        return (
            "AuthenticatedGodotCodec("
            f"match_id={self.match_id!r}, local_role={self.local_role!r}, "
            f"inbound_sequence={self._inbound_sequence}, "
            f"outbound_sequence={self._outbound_sequence})"
        )


@dataclass(frozen=True)
class ProviderObservation:
    """A deliberately non-omniscient payload safe to hand to one provider adapter."""

    player_slot: int
    observation_seq: int
    tick: int
    observation_hash: str
    canonical_bytes: bytes


@dataclass(frozen=True)
class ProviderObservationPair:
    observation_seq: int
    tick: int
    observations: Tuple[ProviderObservation, ProviderObservation]

    def __post_init__(self) -> None:
        if tuple(value.player_slot for value in self.observations) != (0, 1):
            raise ValueError("provider observation pair must be in slot order")


@dataclass(frozen=True, repr=False)
class AcknowledgedActionBatch:
    """One protected replay input retained only after Godot accepted its application.

    ``canonical_batch_bytes`` is the exact canonical ActionBatch object sent across the
    authenticated boundary (with absent optional fields omitted).  It may contain the model's
    bounded ``working_memory`` and therefore has an intentionally redacted representation.
    """

    application_seq: int
    application_tick: int
    batch_digest: str
    batch_id: str
    canonical_batch_bytes: bytes
    decision_mode: str
    match_id: str
    observation_hash: str
    observation_seq: int
    observation_tick: int
    opportunity_id: str
    player_slot: int

    def __post_init__(self) -> None:
        if self.decision_mode not in {"fixed_simultaneous", "continuous_realtime"}:
            raise ValueError("acknowledged action batch decision mode is invalid")
        for name in ("application_seq", "application_tick", "observation_seq", "observation_tick"):
            value = getattr(self, name)
            if not _is_non_negative_integer(value):
                raise ValueError(f"acknowledged action batch {name} is invalid")
        if self.player_slot not in {0, 1}:
            raise ValueError("acknowledged action batch player slot is invalid")
        if _SAFE_PUBLIC_ID_RE.fullmatch(self.batch_id) is None:
            raise ValueError("acknowledged action batch ID is invalid")
        if _SAFE_PUBLIC_ID_RE.fullmatch(self.opportunity_id) is None:
            raise ValueError("acknowledged action opportunity ID is invalid")
        if re.fullmatch(r"[0-9a-f]{64}", self.batch_digest) is None:
            raise ValueError("acknowledged action batch digest is invalid")
        if re.fullmatch(r"[0-9a-f]{64}", self.observation_hash) is None:
            raise ValueError("acknowledged action observation hash is invalid")
        if not isinstance(self.canonical_batch_bytes, bytes):
            raise ValueError("acknowledged action batch bytes must be immutable")
        try:
            value = strict_json_loads(self.canonical_batch_bytes)
            batch = ActionBatch.model_validate(value)
        except (TypeError, ValueError) as exc:
            raise ValueError("acknowledged action batch bytes are invalid") from exc
        if canonical_json_bytes(value) != self.canonical_batch_bytes:
            raise ValueError("acknowledged action batch bytes are not canonical")
        if batch.model_dump(mode="json", exclude_none=True) != value:
            raise ValueError("acknowledged action batch contains non-wire fields")
        if batch.match_id != self.match_id:
            raise ValueError("acknowledged action batch has the wrong match ID")
        if batch.client_batch_id != self.batch_id:
            raise ValueError("acknowledged action batch has the wrong batch ID")
        if batch.observation_seq != self.observation_seq:
            raise ValueError("acknowledged action batch has the wrong observation sequence")
        if batch.based_on_observation_hash != self.observation_hash:
            raise ValueError("acknowledged action batch has the wrong observation hash")
        if hashlib.sha256(self.canonical_batch_bytes).hexdigest() != self.batch_digest:
            raise ValueError("acknowledged action batch digest does not match its bytes")

    def __repr__(self) -> str:
        return "AcknowledgedActionBatch(<protected>)"


@dataclass(frozen=True)
class TerminalReport:
    disposition: str
    terminal_tick: int
    result_hash: str
    winner_slot: Optional[int]
    failure: Optional[FailureClassification]
    body: Mapping[str, JsonValue]


@dataclass
class _PendingResponse:
    expected_type: BridgeMessageType
    boundary_hash: str
    identity: Mapping[str, JsonValue]
    future: asyncio.Future[AuthenticatedGodotFrame]


FrameSender = Callable[[bytes], Awaitable[None]]


class WebSocketLike(Protocol):
    client: object

    async def accept(self) -> None: ...

    async def close(self, *, code: int) -> None: ...

    async def send_text(self, data: str) -> None: ...

    async def receive(self) -> Mapping[str, object]: ...


class GatewayGodotBridge(FixedAuthoritativeBridge, ContinuousAuthoritativeBridge):
    """Gateway-side authenticated state machine and authoritative runtime bridge."""

    def __init__(
        self,
        *,
        match_id: str,
        token: bytes,
        response_timeout_s: float = 10.0,
        expected_engine_version: str = FROZEN_GODOT_ENGINE_VERSION,
    ) -> None:
        if response_timeout_s <= 0:
            raise ValueError("response_timeout_s must be positive")
        self.match_id = _validated_match_id(match_id)
        self._codec = AuthenticatedGodotCodec(
            match_id=self.match_id, token=token, local_role="gateway"
        )
        self._response_timeout_s = response_timeout_s
        self._expected_engine_version = expected_engine_version
        self._phase = GodotBridgePhase.AWAITING_HELLO
        self._sender: Optional[FrameSender] = None
        self._connection_id: Optional[str] = None
        self._config: Optional[MatchConfig] = None
        self._config_hash: Optional[str] = None
        self._checkpoint_hash: Optional[str] = None
        self._fixed_locked_boundary: Optional[str] = None
        self._fixed_locked_identity: Optional[Tuple[str, int, int]] = None
        self._pending: Optional[_PendingResponse] = None
        self._observation_pairs: asyncio.Queue[ProviderObservationPair] = asyncio.Queue()
        self._single_observations: asyncio.Queue[ProviderObservation] = asyncio.Queue()
        self._match_init: asyncio.Queue[bytes] = asyncio.Queue()
        self._action_receipts: asyncio.Queue[Mapping[str, JsonValue]] = asyncio.Queue()
        self._acknowledged_action_batches: asyncio.Queue[Tuple[AcknowledgedActionBatch, ...]] = (
            asyncio.Queue()
        )
        self._tick_events: asyncio.Queue[Mapping[str, JsonValue]] = asyncio.Queue()
        self._checkpoints: asyncio.Queue[Mapping[str, JsonValue]] = asyncio.Queue()
        self._terminal_future: Optional[asyncio.Future[TerminalReport]] = None
        self._terminal_report: Optional[TerminalReport] = None
        self._remote_failures: List[FailureClassification] = []
        self._continuous_disposition_body: Optional[Dict[str, JsonValue]] = None
        self._latest_observation_boundary: Optional[Tuple[int, int]] = None
        self._continuous_start_body: Optional[Dict[str, JsonValue]] = None
        self._continuous_clock_started = False
        self._next_application_seq = 0
        self._next_acknowledged_application_seq = 0
        self._next_tick_event_seq = 1
        self._last_application_tick = -1
        self._last_evidence_checkpoint_tick = -1
        self._last_checkpoint_tick = -1
        self._last_tick_event_tick = -1
        self._last_inbound_message_type: Optional[str] = None
        self._latest_checkpoint_body: Optional[Dict[str, JsonValue]] = None
        self._stop_event = asyncio.Event()
        self._stop_error: Optional[GodotBridgeError] = None

    @property
    def phase(self) -> GodotBridgePhase:
        return self._phase

    @property
    def decision_mode(self) -> Optional[str]:
        return self._config.decision_mode if self._config is not None else None

    @property
    def connection_id(self) -> Optional[str]:
        return self._connection_id

    @property
    def checkpoint_hash(self) -> Optional[str]:
        return self._checkpoint_hash

    @property
    def remote_failures(self) -> Tuple[FailureClassification, ...]:
        return tuple(self._remote_failures)

    @property
    def terminal_report(self) -> Optional[TerminalReport]:
        return self._terminal_report

    @property
    def continuous_clock_started(self) -> bool:
        return self._continuous_clock_started

    def bind_sender(self, sender: FrameSender) -> None:
        if self._sender is not None:
            raise GodotBridgeInfrastructureError(
                "connection_ambiguity", "Godot bridge sender is already bound"
            )
        if not callable(sender):
            raise ValueError("sender must be callable")
        self._sender = sender

    async def receive_frame(self, payload: bytes) -> None:
        """Validate and apply exactly one complete frame received from Godot."""

        if self._phase in {
            GodotBridgePhase.FAILED,
            GodotBridgePhase.CLOSED,
            GodotBridgePhase.COMPLETE,
        }:
            raise GodotBridgeInfrastructureError(
                "frame_after_close", "frame received after the Godot bridge stopped"
            )
        try:
            frame = self._codec.decode(payload)
            await self._dispatch_inbound(frame)
            self._last_inbound_message_type = frame.message_type
        except GodotBridgeError as exc:
            if self._phase not in {GodotBridgePhase.COMPLETE, GodotBridgePhase.CLOSED}:
                self._phase = GodotBridgePhase.FAILED
                self._signal_stopped(exc)
            raise
        except Exception as exc:
            error = GodotBridgeInfrastructureError(
                "bridge_dispatch_failed", "Godot bridge inbound dispatch failed"
            )
            self._fail_pending(error)
            self._phase = GodotBridgePhase.FAILED
            self._signal_stopped(error)
            raise error from exc

    async def configure(
        self, config: MatchConfig | Mapping[str, JsonValue], *, config_hash: Optional[str] = None
    ) -> AuthenticatedGodotFrame:
        """Send the frozen config and wait for Godot's exact acceptance acknowledgement."""

        self._require_phase(GodotBridgePhase.AUTHENTICATED)
        try:
            frozen = (
                config if isinstance(config, MatchConfig) else MatchConfig.model_validate(config)
            )
        except ValueError as exc:
            raise GodotBridgeInfrastructureError(
                "match_config_invalid", "gateway match config is invalid"
            ) from exc
        config_body = frozen.model_dump(mode="json")
        computed_hash = hashlib.sha256(canonical_json_bytes(config_body)).hexdigest()
        if config_hash is not None and config_hash != computed_hash:
            raise GodotBridgeInfrastructureError(
                "config_hash_mismatch", "supplied config hash does not match canonical config"
            )
        self._config = frozen
        self._config_hash = computed_hash
        identity: Dict[str, JsonValue] = {"config_hash": computed_hash}
        return await self._request_response(
            "match_config",
            boundary_hash=computed_hash,
            body={"config": config_body, "config_hash": computed_hash},
            expected_type="config_accepted",
            identity=identity,
            waiting_phase=GodotBridgePhase.AWAITING_CONFIG_ACCEPTED,
        )

    async def send_thinking_status(
        self,
        *,
        observation_hash: str,
        player_slot: int,
        status: Literal["thinking", "locked", "timeout", "ready"],
        observation_seq: int,
    ) -> None:
        self._require_running_or_waiting()
        if player_slot not in {0, 1} or observation_seq < 0:
            raise GodotBridgeInfrastructureError(
                "thinking_status_invalid", "thinking status identity is invalid"
            )
        await self._emit(
            "thinking_status",
            boundary_hash=observation_hash,
            body={
                "observation_seq": observation_seq,
                "player_slot": player_slot,
                "status": status,
            },
        )

    async def lock_batch_commits(self, request: FixedCommitRequest) -> None:
        self._require_mode("fixed_simultaneous")
        self._require_phase(GodotBridgePhase.RUNNING)
        self._require_request_match(request.match_id)
        if self._fixed_locked_boundary is not None:
            raise GodotBridgeInfrastructureError(
                "fixed_window_already_locked", "a fixed commit window is already locked"
            )
        boundary_hash = self._require_checkpoint_hash()
        body = _fixed_commit_body(request)
        await self._request_response(
            "batch_commit_hashes",
            boundary_hash=boundary_hash,
            body=body,
            expected_type="batch_commits_locked",
            identity={
                "boundary_tick": request.boundary_tick,
                "observation_seq": request.observation_seq,
                "opportunity_id": request.opportunity_id,
            },
            waiting_phase=GodotBridgePhase.AWAITING_FIXED_LOCK,
        )
        self._fixed_locked_boundary = boundary_hash
        self._fixed_locked_identity = (
            request.opportunity_id,
            request.observation_seq,
            request.boundary_tick,
        )

    async def reveal_batch_pair(self, request: FixedRevealRequest) -> None:
        self._require_mode("fixed_simultaneous")
        self._require_phase(GodotBridgePhase.RUNNING)
        self._require_request_match(request.match_id)
        expected_identity = (
            request.opportunity_id,
            request.observation_seq,
            request.boundary_tick,
        )
        if self._fixed_locked_boundary is None or self._fixed_locked_identity != expected_identity:
            raise GodotBridgeInfrastructureError(
                "fixed_reveal_without_lock",
                "fixed reveal does not match the atomically locked commit window",
            )
        boundary_hash = self._fixed_locked_boundary
        await self._request_response(
            "batch_reveal",
            boundary_hash=boundary_hash,
            body=_fixed_reveal_body(request),
            expected_type="action_pair",
            identity={
                "activation_tick": request.activation_tick,
                "mode": "fixed_simultaneous",
                "observation_seq": request.observation_seq,
                "opportunity_id": request.opportunity_id,
            },
            waiting_phase=GodotBridgePhase.AWAITING_FIXED_ACTION_PAIR,
        )
        evidence = tuple(
            _acknowledged_action_batch(
                application_seq=self._next_acknowledged_application_seq,
                application_tick=request.activation_tick,
                batch=reveal.batch,
                decision_mode="fixed_simultaneous",
                match_id=request.match_id,
                observation_tick=request.boundary_tick,
                opportunity_id=request.opportunity_id,
                player_slot=reveal.player_slot,
            )
            for reveal in sorted(request.reveals, key=lambda value: value.player_slot)
        )
        self._acknowledged_action_batches.put_nowait(evidence)
        self._next_acknowledged_application_seq += 1
        self._fixed_locked_boundary = None
        self._fixed_locked_identity = None

    async def apply_continuous_gate(self, request: ContinuousApplyGateRequest) -> None:
        self._require_mode("continuous_realtime")
        self._require_phase(GodotBridgePhase.RUNNING)
        if not self._continuous_clock_started:
            raise GodotBridgeInfrastructureError(
                "continuous_clock_not_started",
                "continuous applications require an acknowledged authority clock start",
            )
        self._require_request_match(request.match_id)
        boundary_hash = self._require_checkpoint_hash()
        await self._request_response(
            "action",
            boundary_hash=boundary_hash,
            body=_continuous_action_body(request),
            expected_type="action_pair",
            identity={
                "application_tick": request.application_tick,
                "mode": "continuous_realtime",
            },
            waiting_phase=GodotBridgePhase.AWAITING_CONTINUOUS_ACTION_PAIR,
        )
        evidence = tuple(
            _acknowledged_action_batch(
                application_seq=self._next_acknowledged_application_seq,
                application_tick=request.application_tick,
                batch=application.batch,
                decision_mode="continuous_realtime",
                match_id=request.match_id,
                observation_tick=application.observation_tick,
                opportunity_id=application.opportunity_id,
                player_slot=application.player_slot,
            )
            for application in sorted(
                request.applications,
                key=lambda value: (
                    value.player_slot,
                    value.observation_seq,
                    value.opportunity_id,
                ),
            )
        )
        self._acknowledged_action_batches.put_nowait(evidence)
        self._next_acknowledged_application_seq += 1

    async def start_continuous_clock(self) -> None:
        """Start Godot's real-time tick clock after the tick-zero observation arrived."""

        self._require_mode("continuous_realtime")
        self._require_phase(GodotBridgePhase.RUNNING)
        if self._continuous_start_body is not None:
            raise GodotBridgeInfrastructureError(
                "continuous_clock_already_started",
                "continuous authority clock start is single-use",
            )
        if self._latest_observation_boundary != (0, 0):
            raise GodotBridgeInfrastructureError(
                "continuous_start_boundary_invalid",
                "continuous authority clock requires the initial tick-zero observation",
            )
        boundary_hash = self._require_checkpoint_hash()
        body = _continuous_start_body(self.match_id)
        self._continuous_start_body = dict(body)
        await self._request_response(
            "continuous_start",
            boundary_hash=boundary_hash,
            body=body,
            expected_type="continuous_start_accepted",
            identity={
                "match_id": body["match_id"],
                "observation_seq": body["observation_seq"],
                "start_id": body["start_id"],
                "tick": body["tick"],
            },
            waiting_phase=GodotBridgePhase.AWAITING_CONTINUOUS_ACTION_PAIR,
        )

    async def declare_continuous_disposition(
        self,
        disposition: Union[ContinuousOpportunityDisposition, str],
        *,
        code: str,
    ) -> None:
        """Atomically terminate a running continuous match through the Godot authority.

        Only a stable, allow-listed disposition and a bounded public classification code cross
        the authority boundary.  The human-readable reason is derived locally, so raw model or
        provider text can never enter an authenticated terminal request.
        """

        self._require_mode("continuous_realtime")
        body = _continuous_disposition_body(self.match_id, disposition, code)
        previous = self._continuous_disposition_body
        if previous is not None:
            if previous != body:
                self._phase = GodotBridgePhase.FAILED
                error = GodotBridgeInfrastructureError(
                    "continuous_disposition_conflict",
                    "a different continuous disposition was already declared",
                )
                self._signal_stopped(error)
                raise error
            pending = self._pending
            if pending is not None and pending.expected_type == "gateway_disposition_accepted":
                await asyncio.shield(pending.future)
                return
            if self._phase in {GodotBridgePhase.RUNNING, GodotBridgePhase.TERMINAL}:
                return
            raise GodotBridgeInfrastructureError(
                "bridge_phase_invalid",
                "continuous disposition cannot be repeated in the current bridge phase",
            )

        self._require_phase(GodotBridgePhase.RUNNING)
        boundary_hash = self._require_checkpoint_hash()
        self._continuous_disposition_body = dict(body)
        await self._request_response(
            "gateway_disposition",
            boundary_hash=boundary_hash,
            body=body,
            expected_type="gateway_disposition_accepted",
            identity={
                "code": body["code"],
                "disposition": body["disposition"],
                "match_id": body["match_id"],
                "reason": body["reason"],
                "request_id": body["request_id"],
            },
            waiting_phase=GodotBridgePhase.AWAITING_CONTINUOUS_ACTION_PAIR,
        )

    async def mark_artifact_ready(
        self, *, artifact_hash: str, manifest: Mapping[str, JsonValue]
    ) -> None:
        self._require_phase(GodotBridgePhase.TERMINAL)
        if _contains_secret_key(manifest):
            raise GodotBridgeInfrastructureError(
                "artifact_secret_leak", "artifact-ready manifest contains a secret-like key"
            )
        await self._emit(
            "artifact_ready",
            boundary_hash=artifact_hash,
            body={"artifact_hash": artifact_hash, "manifest": dict(manifest)},
        )
        self._phase = GodotBridgePhase.COMPLETE
        self._codec.close()

    async def next_observation_pair(self) -> ProviderObservationPair:
        return await self._next_or_stopped(self._observation_pairs)

    async def next_observation(self) -> ProviderObservation:
        return await self._next_or_stopped(self._single_observations)

    async def next_match_init(self) -> bytes:
        return await self._next_or_stopped(self._match_init)

    async def next_action_receipts(self) -> Mapping[str, JsonValue]:
        """Return the next authenticated replay-safe application evidence frame."""

        return await self._next_or_stopped(self._action_receipts)

    async def next_acknowledged_action_batches(
        self,
    ) -> Tuple[AcknowledgedActionBatch, ...]:
        """Return one protected batch group created after an authenticated application ACK."""

        return await self._next_or_stopped(self._acknowledged_action_batches)

    async def next_tick_events(self) -> Mapping[str, JsonValue]:
        return await self._next_or_stopped(self._tick_events)

    async def next_checkpoint(self) -> Mapping[str, JsonValue]:
        return await self._next_or_stopped(self._checkpoints)

    async def wait_terminal(self) -> TerminalReport:
        if self._terminal_report is not None:
            return self._terminal_report
        if self._terminal_future is None:
            self._terminal_future = asyncio.get_running_loop().create_future()
        return await self._terminal_future

    def disconnect(self) -> None:
        """Close a completed session, or fail an ambiguous early disconnect."""

        if self._phase is GodotBridgePhase.COMPLETE:
            self._phase = GodotBridgePhase.CLOSED
            return
        if self._phase in {GodotBridgePhase.CLOSED, GodotBridgePhase.FAILED}:
            return
        error = GodotBridgeInfrastructureError(
            "connection_lost", "Godot bridge connection closed before artifact completion"
        )
        self._fail_pending(error)
        self._phase = GodotBridgePhase.FAILED
        self._signal_stopped(error)
        self._codec.close()

    async def _dispatch_inbound(self, frame: AuthenticatedGodotFrame) -> None:
        if self._phase is GodotBridgePhase.AWAITING_HELLO:
            await self._accept_hello(frame)
            return

        if frame.message_type in {
            "hello",
            "auth",
            "match_config",
            "continuous_start",
            "gateway_disposition",
            "artifact_ready",
        }:
            self._fail_protocol("unexpected_direction", "message has the wrong bridge direction")

        if frame.message_type == "config_accepted":
            self._accept_response(frame)
            return

        if self._config is None:
            self._fail_protocol("message_before_config", "runtime message arrived before config")

        if frame.message_type in {
            "batch_commits_locked",
            "action_pair",
            "continuous_start_accepted",
            "gateway_disposition_accepted",
        }:
            self._accept_response(frame)
            return

        if frame.message_type == "match_init":
            self._require_running_or_waiting()
            self._validate_provider_visible_body(frame.body)
            await self._match_init.put(canonical_json_bytes(frame.body))
            return
        if frame.message_type == "observation_pair":
            self._require_running_or_waiting()
            pair = _provider_observation_pair(frame)
            self._checkpoint_hash = frame.boundary_hash
            self._latest_observation_boundary = (pair.observation_seq, pair.tick)
            await self._observation_pairs.put(pair)
            return
        if frame.message_type == "observation":
            self._require_running_or_waiting()
            observation = _provider_observation(frame.body, frame.boundary_hash)
            await self._single_observations.put(observation)
            return
        if frame.message_type == "action_receipts":
            self._require_running_or_waiting()
            body = self._validated_action_receipts(frame)
            self._checkpoint_hash = frame.boundary_hash
            await self._action_receipts.put(body)
            return
        if frame.message_type == "tick_events":
            self._require_running_or_waiting()
            body = self._validated_tick_events(frame)
            self._checkpoint_hash = frame.boundary_hash
            await self._tick_events.put(body)
            return
        if frame.message_type == "checkpoint":
            self._require_running_or_waiting()
            body = self._validated_checkpoint(frame)
            self._checkpoint_hash = frame.boundary_hash
            await self._checkpoints.put(body)
            return
        if frame.message_type == "terminal":
            self._accept_terminal(frame)
            return
        self._fail_protocol("unexpected_message", "message is invalid for the current state")

    async def _accept_hello(self, frame: AuthenticatedGodotFrame) -> None:
        if frame.message_type != "hello":
            self._fail_protocol("hello_required", "first Godot frame must be hello")
        _require_exact_keys(
            frame.body,
            required={"connection_id", "engine_version"},
            optional={"build_id", "headless"},
            context="hello",
        )
        connection_id = frame.body["connection_id"]
        engine_version = frame.body["engine_version"]
        if not isinstance(connection_id, str) or not 1 <= len(connection_id) <= 128:
            self._fail_protocol("connection_id_invalid", "hello connection_id is invalid")
        if engine_version != self._expected_engine_version:
            self._fail_protocol("engine_version_mismatch", "Godot engine version is not frozen")
        self._connection_id = connection_id
        self._phase = GodotBridgePhase.AUTHENTICATED
        await self._emit(
            "auth",
            boundary_hash=SESSION_BOUNDARY_HASH,
            body={"accepted": True, "connection_id": connection_id},
        )

    def _accept_response(self, frame: AuthenticatedGodotFrame) -> None:
        pending = self._pending
        if pending is None or frame.message_type != pending.expected_type:
            self._fail_protocol("unexpected_response", "response has no matching pending request")
        assert pending is not None
        if frame.boundary_hash != pending.boundary_hash:
            self._fail_protocol("response_hash_mismatch", "response has wrong boundary hash")
        for key, expected in pending.identity.items():
            if frame.body.get(key) != expected:
                self._fail_protocol("response_identity_mismatch", f"response does not echo {key}")
        if frame.message_type == "config_accepted":
            _require_exact_keys(
                frame.body,
                required={"accepted", "config_hash"},
                optional={"failure"},
                context="config_accepted",
            )
            if frame.body["accepted"] is not True:
                error = _remote_failure_error(frame.body.get("failure"), "config_rejected")
                self._remote_failures.append(error.classification)
                self._fail_pending(error)
                self._phase = GodotBridgePhase.FAILED
                raise error
        elif frame.message_type == "batch_commits_locked":
            if frame.body.get("locked") is not True:
                error = _remote_failure_error(frame.body.get("failure"), "commit_lock_rejected")
                self._remote_failures.append(error.classification)
                self._fail_pending(error)
                self._phase = GodotBridgePhase.FAILED
                raise error
        elif frame.message_type == "action_pair":
            if frame.body.get("accepted") is not True:
                error = _remote_failure_error(frame.body.get("failure"), "action_pair_rejected")
                self._remote_failures.append(error.classification)
                self._fail_pending(error)
                self._phase = GodotBridgePhase.FAILED
                raise error
            _validate_canonical_slot_records(frame.body.get("actions"), required=False)
        elif frame.message_type == "gateway_disposition_accepted":
            _require_exact_keys(
                frame.body,
                required={
                    "accepted",
                    "code",
                    "disposition",
                    "match_id",
                    "reason",
                    "request_id",
                },
                optional=set(),
                context="gateway_disposition_accepted",
            )
            if frame.body["accepted"] is not True:
                self._fail_protocol(
                    "continuous_disposition_rejected",
                    "Godot rejected the continuous terminal disposition",
                )
        elif frame.message_type == "continuous_start_accepted":
            _require_exact_keys(
                frame.body,
                required={"accepted", "match_id", "observation_seq", "start_id", "tick"},
                optional=set(),
                context="continuous_start_accepted",
            )
            if frame.body["accepted"] is not True:
                self._fail_protocol(
                    "continuous_start_rejected",
                    "Godot rejected the continuous authority clock start",
                )
            self._continuous_clock_started = True

        if not pending.future.done():
            pending.future.set_result(frame)
        if frame.message_type == "config_accepted":
            self._phase = GodotBridgePhase.RUNNING
        else:
            self._phase = GodotBridgePhase.RUNNING

    def _accept_terminal(self, frame: AuthenticatedGodotFrame) -> None:
        self._require_running_or_waiting()
        _require_exact_keys(
            frame.body,
            required={"disposition", "result_hash", "terminal_tick", "winner_slot"},
            optional={"failure", "reason"},
            context="terminal",
        )
        if frame.body["result_hash"] != frame.boundary_hash:
            self._fail_protocol("terminal_hash_mismatch", "terminal result hash is inconsistent")
        disposition = frame.body["disposition"]
        terminal_tick = frame.body["terminal_tick"]
        winner_slot = frame.body["winner_slot"]
        if disposition not in {
            "victory",
            "draw",
            "technical_forfeit",
            "infrastructure_void",
        }:
            self._fail_protocol("terminal_disposition_invalid", "terminal disposition is invalid")
        if (
            not isinstance(terminal_tick, int)
            or isinstance(terminal_tick, bool)
            or terminal_tick < 0
        ):
            self._fail_protocol("terminal_tick_invalid", "terminal tick is invalid")
        if (
            self._last_inbound_message_type != "checkpoint"
            or self._latest_checkpoint_body is None
            or self._latest_checkpoint_body.get("tick") != terminal_tick
        ):
            self._fail_protocol(
                "terminal_checkpoint_missing",
                "terminal was not immediately preceded by its authoritative final checkpoint",
            )
        if winner_slot not in {0, 1, None}:
            self._fail_protocol("winner_slot_invalid", "terminal winner slot is invalid")
        failure: Optional[FailureClassification] = None
        if disposition in {"technical_forfeit", "infrastructure_void"}:
            error = _remote_failure_error(frame.body.get("failure"), str(disposition))
            failure = error.classification
            self._remote_failures.append(failure)
            if (
                disposition == "infrastructure_void"
                and failure.owner is not FailureOwner.ORGANIZER_INFRASTRUCTURE
            ):
                self._fail_protocol(
                    "terminal_failure_owner_invalid",
                    "infrastructure void must be organizer-owned",
                )
            if (
                disposition == "technical_forfeit"
                and failure.owner is FailureOwner.ORGANIZER_INFRASTRUCTURE
            ):
                self._fail_protocol(
                    "terminal_failure_owner_invalid",
                    "technical forfeit cannot be organizer-owned",
                )
        elif frame.body.get("failure") is not None:
            self._fail_protocol("terminal_failure_unexpected", "normal terminal has failure data")
        if self._continuous_disposition_body is not None:
            _validate_continuous_disposition_terminal(
                frame.body,
                self._continuous_disposition_body,
                failure,
            )
        report = TerminalReport(
            disposition=str(disposition),
            terminal_tick=terminal_tick,
            result_hash=frame.boundary_hash,
            winner_slot=winner_slot,
            failure=failure,
            body=dict(frame.body),
        )
        self._terminal_report = report
        self._phase = GodotBridgePhase.TERMINAL
        if self._pending is not None and not self._pending.future.done():
            error = GodotBridgeInfrastructureError(
                "terminal_during_request", "terminal arrived before an action acknowledgement"
            )
            self._pending.future.set_exception(error)
        if self._terminal_future is not None and not self._terminal_future.done():
            self._terminal_future.set_result(report)
        self._signal_stopped(
            GodotBridgeInfrastructureError(
                "match_terminal", "match reached an authoritative terminal result"
            )
        )

    async def _request_response(
        self,
        message_type: BridgeMessageType,
        *,
        boundary_hash: str,
        body: Mapping[str, JsonValue],
        expected_type: BridgeMessageType,
        identity: Mapping[str, JsonValue],
        waiting_phase: GodotBridgePhase,
    ) -> AuthenticatedGodotFrame:
        if self._pending is not None:
            raise GodotBridgeInfrastructureError(
                "concurrent_authoritative_request",
                "only one authoritative Godot request may be pending",
            )
        future: asyncio.Future[AuthenticatedGodotFrame] = asyncio.get_running_loop().create_future()
        pending = _PendingResponse(expected_type, boundary_hash, dict(identity), future)
        self._pending = pending
        self._phase = waiting_phase
        try:
            await self._emit(message_type, boundary_hash=boundary_hash, body=body)
            return await asyncio.wait_for(asyncio.shield(future), self._response_timeout_s)
        except asyncio.TimeoutError as exc:
            error = GodotBridgeInfrastructureError(
                "godot_response_timeout", f"Godot did not send {expected_type} before timeout"
            )
            self._fail_pending(error)
            self._phase = GodotBridgePhase.FAILED
            self._signal_stopped(error)
            raise error from exc
        except asyncio.CancelledError:
            error = GodotBridgeInfrastructureError(
                "authoritative_request_cancelled",
                "authoritative Godot request was cancelled with ambiguous state",
            )
            self._fail_pending(error)
            self._phase = GodotBridgePhase.FAILED
            self._signal_stopped(error)
            raise
        except GodotBridgeError as error:
            self._fail_pending(error)
            self._phase = GodotBridgePhase.FAILED
            self._signal_stopped(error)
            raise
        finally:
            if self._pending is pending:
                self._pending = None

    async def _emit(
        self,
        message_type: BridgeMessageType,
        *,
        boundary_hash: str,
        body: Mapping[str, JsonValue],
    ) -> None:
        if self._sender is None:
            raise GodotBridgeInfrastructureError(
                "sender_unbound", "Godot bridge has no attached transport sender"
            )
        payload = self._codec.encode(message_type, boundary_hash=boundary_hash, body=dict(body))
        try:
            await self._sender(payload)
        except GodotBridgeError:
            raise
        except Exception as exc:
            raise GodotBridgeInfrastructureError(
                "transport_send_failed", "local Godot transport send failed"
            ) from exc

    async def _next_or_stopped(self, queue: asyncio.Queue):
        if not queue.empty():
            return queue.get_nowait()
        if self._stop_event.is_set():
            assert self._stop_error is not None
            raise self._stop_error
        queue_task = asyncio.create_task(queue.get())
        stop_task = asyncio.create_task(self._stop_event.wait())
        tasks = {queue_task, stop_task}
        try:
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            if queue_task in done:
                return queue_task.result()
            assert self._stop_error is not None
            raise self._stop_error
        finally:
            unfinished = [task for task in tasks if not task.done()]
            for task in unfinished:
                task.cancel()
            if unfinished:
                await asyncio.gather(*unfinished, return_exceptions=True)

    def _signal_stopped(self, error: GodotBridgeError) -> None:
        if self._stop_error is None:
            self._stop_error = error
            self._stop_event.set()
            if (
                self._terminal_report is None
                and self._terminal_future is not None
                and not self._terminal_future.done()
            ):
                self._terminal_future.set_exception(error)

    def _validated_action_receipts(self, frame: AuthenticatedGodotFrame) -> Dict[str, JsonValue]:
        _require_exact_keys(
            frame.body,
            required={
                "application_seq",
                "application_tick",
                "checkpoint_hash",
                "checkpoint_tick",
                "decision_mode",
                "kind",
                "match_id",
                "records",
            },
            optional=set(),
            context="action_receipts",
        )
        _validate_matching_hash_field(frame, ("checkpoint_hash",))
        body = dict(frame.body)
        application_seq = body["application_seq"]
        application_tick = body["application_tick"]
        checkpoint_tick = body["checkpoint_tick"]
        if body["match_id"] != self.match_id:
            raise GodotBridgeInfrastructureError(
                "action_receipts_match_invalid", "action receipts have the wrong match identity"
            )
        if application_seq != self._next_application_seq:
            raise GodotBridgeInfrastructureError(
                "action_receipts_sequence_invalid",
                "action receipt application sequence is not contiguous",
            )
        if (
            not _is_non_negative_integer(application_tick)
            or application_tick < self._last_application_tick
            or not _is_non_negative_integer(checkpoint_tick)
            or checkpoint_tick < self._last_evidence_checkpoint_tick
            or checkpoint_tick > application_tick
        ):
            raise GodotBridgeInfrastructureError(
                "action_receipts_tick_invalid", "action receipt ticks are inconsistent"
            )
        if self._config is None or body["decision_mode"] != self._config.decision_mode:
            raise GodotBridgeInfrastructureError(
                "action_receipts_mode_invalid", "action receipts have the wrong decision mode"
            )
        expected_kind = (
            "fixed_pair"
            if self._config.decision_mode == "fixed_simultaneous"
            else "continuous_gate"
        )
        if body["kind"] != expected_kind:
            raise GodotBridgeInfrastructureError(
                "action_receipts_kind_invalid", "action receipts have the wrong application kind"
            )
        records = body["records"]
        expected_sizes = {2} if expected_kind == "fixed_pair" else {1, 2}
        if not isinstance(records, list) or len(records) not in expected_sizes:
            raise GodotBridgeInfrastructureError(
                "action_receipts_records_invalid", "action receipt record count is invalid"
            )
        slots: List[int] = []
        for record in records:
            if not isinstance(record, dict):
                raise GodotBridgeInfrastructureError(
                    "action_receipts_records_invalid", "action receipt record must be an object"
                )
            _require_exact_keys(
                record,
                required={
                    "batch_digest",
                    "batch_id",
                    "compiled_intents",
                    "player_slot",
                    "receipt",
                },
                optional=set(),
                context="action_receipt_record",
            )
            slot = record["player_slot"]
            batch_digest = record["batch_digest"]
            batch_id = record["batch_id"]
            if slot not in {0, 1}:
                raise GodotBridgeInfrastructureError(
                    "action_receipts_slot_invalid", "action receipt player slot is invalid"
                )
            if (
                not isinstance(batch_digest, str)
                or re.fullmatch(r"[0-9a-f]{64}", batch_digest) is None
            ):
                raise GodotBridgeInfrastructureError(
                    "action_receipts_digest_invalid", "action receipt batch digest is invalid"
                )
            if not isinstance(batch_id, str) or _SAFE_PUBLIC_ID_RE.fullmatch(batch_id) is None:
                raise GodotBridgeInfrastructureError(
                    "action_receipts_batch_invalid", "action receipt batch id is invalid"
                )
            if not isinstance(record["compiled_intents"], list) or not isinstance(
                record["receipt"], dict
            ):
                raise GodotBridgeInfrastructureError(
                    "action_receipts_records_invalid",
                    "compiled intents and action receipt must use canonical containers",
                )
            if _contains_private_replay_key(record):
                raise GodotBridgeInfrastructureError(
                    "action_receipts_private_data",
                    "action receipt evidence contains protected model material",
                )
            slots.append(slot)
        if slots != sorted(set(slots)) or (expected_kind == "fixed_pair" and slots != [0, 1]):
            raise GodotBridgeInfrastructureError(
                "action_receipts_order_invalid",
                "action receipt records are not in canonical unique slot order",
            )
        self._next_application_seq += 1
        self._last_application_tick = application_tick
        self._last_evidence_checkpoint_tick = checkpoint_tick
        return body

    def _validated_tick_events(self, frame: AuthenticatedGodotFrame) -> Dict[str, JsonValue]:
        _require_exact_keys(
            frame.body,
            required={
                "checkpoint_hash",
                "events",
                "first_event_seq",
                "last_event_seq",
                "match_id",
                "tick_from",
                "tick_through",
            },
            optional=set(),
            context="tick_events",
        )
        _validate_matching_hash_field(frame, ("checkpoint_hash",))
        body = dict(frame.body)
        if body["match_id"] != self.match_id:
            raise GodotBridgeInfrastructureError(
                "tick_events_match_invalid", "tick events have the wrong match identity"
            )
        events = body["events"]
        if not isinstance(events, list) or not events:
            raise GodotBridgeInfrastructureError(
                "tick_events_records_invalid", "tick event frame must contain records"
            )
        first_sequence = body["first_event_seq"]
        last_sequence = body["last_event_seq"]
        tick_from = body["tick_from"]
        tick_through = body["tick_through"]
        if (
            first_sequence != self._next_tick_event_seq
            or last_sequence != first_sequence + len(events) - 1
            or not _is_non_negative_integer(tick_from)
            or not _is_non_negative_integer(tick_through)
            or tick_from > tick_through
            or tick_from < self._last_tick_event_tick
        ):
            raise GodotBridgeInfrastructureError(
                "tick_events_sequence_invalid", "tick event frame range is inconsistent"
            )
        previous_tick = self._last_tick_event_tick
        for offset, event in enumerate(events):
            if not isinstance(event, dict):
                raise GodotBridgeInfrastructureError(
                    "tick_events_records_invalid", "tick event record must be an object"
                )
            try:
                validated = ObservableEvent.model_validate(event)
            except ValueError as exc:
                raise GodotBridgeInfrastructureError(
                    "tick_events_records_invalid",
                    "tick event violates the frozen observable event contract",
                ) from exc
            if validated.to_wire_dict() != event or validated.audience != "omniscient":
                raise GodotBridgeInfrastructureError(
                    "tick_events_records_invalid",
                    "tick event is not an exact omniscient public record",
                )
            expected_sequence = first_sequence + offset
            if (
                event.get("event_seq") != expected_sequence
                or not _is_non_negative_integer(event.get("tick"))
                or event["tick"] < previous_tick
            ):
                raise GodotBridgeInfrastructureError(
                    "tick_events_order_invalid", "tick events are not in canonical sequence order"
                )
            previous_tick = event["tick"]
        if events[0]["tick"] != tick_from or events[-1]["tick"] != tick_through:
            raise GodotBridgeInfrastructureError(
                "tick_events_tick_invalid", "tick event frame tick bounds are inconsistent"
            )
        self._next_tick_event_seq = last_sequence + 1
        self._last_tick_event_tick = tick_through
        return body

    def _validated_checkpoint(self, frame: AuthenticatedGodotFrame) -> Dict[str, JsonValue]:
        _require_exact_keys(
            frame.body,
            required={"checkpoint_hash", "reason", "tick"},
            optional=set(),
            context="checkpoint",
        )
        _validate_matching_hash_field(frame, ("checkpoint_hash",))
        body = dict(frame.body)
        tick = body["tick"]
        reason = body["reason"]
        if not _is_non_negative_integer(tick) or tick < self._last_checkpoint_tick:
            raise GodotBridgeInfrastructureError(
                "checkpoint_tick_invalid", "authoritative checkpoint ticks moved backwards"
            )
        if not isinstance(reason, str) or not reason or len(reason) > 96:
            raise GodotBridgeInfrastructureError(
                "checkpoint_reason_invalid", "authoritative checkpoint reason is invalid"
            )
        self._last_checkpoint_tick = tick
        self._latest_checkpoint_body = body
        return body

    def _validate_provider_visible_body(self, body: Mapping[str, JsonValue]) -> None:
        if _contains_hidden_world_hash(body):
            self._fail_protocol(
                "omniscient_hash_leak", "provider-visible payload contains world hash"
            )

    def _require_mode(self, expected: str) -> None:
        if self._config is None or self._config.decision_mode != expected:
            raise GodotBridgeInfrastructureError(
                "decision_mode_mismatch", f"bridge is not configured for {expected}"
            )

    def _require_checkpoint_hash(self) -> str:
        if self._checkpoint_hash is None:
            raise GodotBridgeInfrastructureError(
                "checkpoint_unavailable", "no authoritative decision boundary is frozen"
            )
        return self._checkpoint_hash

    def _require_request_match(self, match_id: str) -> None:
        if match_id != self.match_id:
            raise GodotBridgeInfrastructureError(
                "request_match_mismatch", "authoritative request has the wrong match ID"
            )

    def _require_phase(self, expected: GodotBridgePhase) -> None:
        if self._phase is not expected:
            raise GodotBridgeInfrastructureError(
                "bridge_phase_invalid",
                f"expected bridge phase {expected.value}, got {self._phase.value}",
            )

    def _require_running_or_waiting(self) -> None:
        if self._phase not in {
            GodotBridgePhase.RUNNING,
            GodotBridgePhase.AWAITING_FIXED_LOCK,
            GodotBridgePhase.AWAITING_FIXED_ACTION_PAIR,
            GodotBridgePhase.AWAITING_CONTINUOUS_ACTION_PAIR,
        }:
            raise GodotBridgeInfrastructureError(
                "bridge_phase_invalid", "runtime frame is invalid in the current bridge phase"
            )

    def _fail_protocol(self, code: str, message: str):
        error = GodotBridgeInfrastructureError(code, message)
        self._fail_pending(error)
        self._phase = GodotBridgePhase.FAILED
        raise error

    def _fail_pending(self, error: GodotBridgeError) -> None:
        if self._pending is not None and not self._pending.future.done():
            self._pending.future.set_exception(error)


class InMemoryGodotTransport:
    """Network-free, byte-exact peer harness for a ``GatewayGodotBridge``."""

    def __init__(self, bridge: GatewayGodotBridge, *, token: bytes) -> None:
        self.bridge = bridge
        self._godot_codec = AuthenticatedGodotCodec(
            match_id=bridge.match_id, token=token, local_role="godot"
        )
        self._gateway_frames: asyncio.Queue[bytes] = asyncio.Queue()
        bridge.bind_sender(self._capture_gateway_frame)

    async def _capture_gateway_frame(self, payload: bytes) -> None:
        await self._gateway_frames.put(payload)

    async def send_from_godot(
        self,
        message_type: BridgeMessageType,
        *,
        boundary_hash: str,
        body: Mapping[str, JsonValue],
    ) -> None:
        payload = self._godot_codec.encode(
            message_type, boundary_hash=boundary_hash, body=dict(body)
        )
        await self.bridge.receive_frame(payload)

    async def receive_at_godot(self) -> AuthenticatedGodotFrame:
        return self._godot_codec.decode(await self._gateway_frames.get())

    async def hello(
        self,
        *,
        connection_id: str = "godot-headless-1",
        engine_version: str = FROZEN_GODOT_ENGINE_VERSION,
    ) -> AuthenticatedGodotFrame:
        await self.send_from_godot(
            "hello",
            boundary_hash=SESSION_BOUNDARY_HASH,
            body={"connection_id": connection_id, "engine_version": engine_version},
        )
        return await self.receive_at_godot()


class LocalhostGodotWebSocketAdapter:
    """Optional FastAPI/Starlette socket adapter restricted to one loopback connection."""

    def __init__(self, bridge: GatewayGodotBridge) -> None:
        self.bridge = bridge
        self._claimed = False

    async def handle(self, websocket: WebSocketLike) -> None:
        if self._claimed:
            await websocket.close(code=4409)
            return
        client = getattr(websocket, "client", None)
        host = getattr(client, "host", None)
        if not _is_loopback_host(host):
            await websocket.close(code=4403)
            return
        self._claimed = True
        await websocket.accept()

        async def send(payload: bytes) -> None:
            await websocket.send_text(payload.decode("utf-8"))

        self.bridge.bind_sender(send)
        try:
            while True:
                message = await websocket.receive()
                message_type = message.get("type")
                if message_type == "websocket.disconnect":
                    break
                if message_type != "websocket.receive" or message.get("text") is None:
                    await websocket.close(code=4400)
                    break
                await self.bridge.receive_frame(message["text"].encode("utf-8"))
        finally:
            self.bridge.disconnect()


def _frame_auth_tag(key: bytes, unsigned: Mapping[str, JsonValue]) -> str:
    return hmac.new(
        key,
        _AUTH_DOMAIN + canonical_json_bytes(dict(unsigned)),
        hashlib.sha256,
    ).hexdigest()


def _validated_match_id(match_id: str) -> str:
    try:
        validated = TypeAdapter(MatchId).validate_python(match_id)
    except ValueError as exc:
        raise ValueError("match_id is invalid") from exc
    return validated


def _continuous_start_body(match_id: str) -> Dict[str, JsonValue]:
    core: Dict[str, JsonValue] = {
        "match_id": match_id,
        "observation_seq": 0,
        "tick": 0,
    }
    return {
        **core,
        "start_id": hashlib.sha256(canonical_json_bytes(core)).hexdigest(),
    }


def _continuous_disposition_body(
    match_id: str,
    disposition: Union[ContinuousOpportunityDisposition, str],
    code: str,
) -> Dict[str, JsonValue]:
    normalized = (
        disposition.value
        if isinstance(disposition, ContinuousOpportunityDisposition)
        else disposition
    )
    if normalized not in _CONTINUOUS_TERMINAL_DISPOSITIONS:
        raise GodotBridgeInfrastructureError(
            "continuous_disposition_invalid",
            "continuous disposition is not an accepted terminal disposition",
        )
    if not isinstance(code, str) or _SAFE_DISPOSITION_CODE_RE.fullmatch(code) is None:
        raise GodotBridgeInfrastructureError(
            "continuous_disposition_code_invalid",
            "continuous disposition code must be a bounded public identifier",
        )
    if (
        normalized != ContinuousOpportunityDisposition.VOID_INFRASTRUCTURE.value
        and code != _MODEL_FAILURE_THRESHOLD_CODE
    ):
        raise GodotBridgeInfrastructureError(
            "continuous_disposition_code_invalid",
            "technical dispositions require the frozen model failure threshold code",
        )
    reasons = {
        ContinuousOpportunityDisposition.TECHNICAL_FORFEIT_SLOT_0.value: "model_failure",
        ContinuousOpportunityDisposition.TECHNICAL_FORFEIT_SLOT_1.value: "model_failure",
        ContinuousOpportunityDisposition.DRAW_DOUBLE_TECHNICAL_FORFEIT.value: (
            "double_technical_forfeit"
        ),
        ContinuousOpportunityDisposition.VOID_INFRASTRUCTURE.value: (
            "gateway_infrastructure_failure"
        ),
    }
    core: Dict[str, JsonValue] = {
        "code": code,
        "disposition": normalized,
        "match_id": match_id,
        "reason": reasons[normalized],
    }
    return {
        **core,
        "request_id": hashlib.sha256(canonical_json_bytes(core)).hexdigest(),
    }


def _validate_continuous_disposition_terminal(
    terminal: Mapping[str, JsonValue],
    request: Mapping[str, JsonValue],
    failure: Optional[FailureClassification],
) -> None:
    requested = request["disposition"]
    expected_disposition: str
    expected_winner: Optional[int]
    if requested == ContinuousOpportunityDisposition.TECHNICAL_FORFEIT_SLOT_0.value:
        expected_disposition, expected_winner = "technical_forfeit", 1
    elif requested == ContinuousOpportunityDisposition.TECHNICAL_FORFEIT_SLOT_1.value:
        expected_disposition, expected_winner = "technical_forfeit", 0
    elif requested == ContinuousOpportunityDisposition.DRAW_DOUBLE_TECHNICAL_FORFEIT.value:
        expected_disposition, expected_winner = "draw", None
    else:
        expected_disposition, expected_winner = "infrastructure_void", None

    if (
        terminal.get("disposition") != expected_disposition
        or terminal.get("winner_slot") != expected_winner
        or terminal.get("reason") != request["reason"]
    ):
        raise GodotBridgeInfrastructureError(
            "continuous_terminal_mismatch",
            "terminal result does not match the acknowledged continuous disposition",
        )
    if requested == ContinuousOpportunityDisposition.DRAW_DOUBLE_TECHNICAL_FORFEIT.value:
        if failure is not None:
            raise GodotBridgeInfrastructureError(
                "continuous_terminal_mismatch",
                "double technical forfeit must terminate as a failure-free draw record",
            )
        return
    expected_owner = (
        FailureOwner.ORGANIZER_INFRASTRUCTURE
        if requested == ContinuousOpportunityDisposition.VOID_INFRASTRUCTURE.value
        else FailureOwner.MODEL
    )
    if (
        failure is None
        or failure.code != request["code"]
        or failure.owner is not expected_owner
        or failure.hard_model_failure != (expected_owner is FailureOwner.MODEL)
    ):
        raise GodotBridgeInfrastructureError(
            "continuous_terminal_mismatch",
            "terminal failure classification does not match the acknowledged disposition",
        )


def _fixed_commit_body(request: FixedCommitRequest) -> Dict[str, JsonValue]:
    commits = sorted(request.commits, key=lambda value: value.player_slot)
    if [value.player_slot for value in commits] != [0, 1]:
        raise GodotBridgeInfrastructureError(
            "fixed_slots_invalid", "fixed commit request must contain slots 0 and 1"
        )
    return {
        "boundary_tick": request.boundary_tick,
        "commits": [
            {"commit_hash": value.commit_hash, "player_slot": value.player_slot}
            for value in commits
        ],
        "match_id": request.match_id,
        "observation_seq": request.observation_seq,
        "opportunity_id": request.opportunity_id,
    }


def _fixed_reveal_body(request: FixedRevealRequest) -> Dict[str, JsonValue]:
    reveals = sorted(request.reveals, key=lambda value: value.player_slot)
    if [value.player_slot for value in reveals] != [0, 1]:
        raise GodotBridgeInfrastructureError(
            "fixed_slots_invalid", "fixed reveal request must contain slots 0 and 1"
        )
    return {
        "activation_tick": request.activation_tick,
        "boundary_tick": request.boundary_tick,
        "disposition": request.disposition.value,
        "match_id": request.match_id,
        "mode": "fixed_simultaneous",
        "observation_seq": request.observation_seq,
        "opportunity_id": request.opportunity_id,
        "reveals": [
            {
                "batch": value.batch.model_dump(mode="json", exclude_none=True),
                "player_slot": value.player_slot,
                "salt_hex": value.salt_hex,
            }
            for value in reveals
        ],
    }


def _continuous_action_body(request: ContinuousApplyGateRequest) -> Dict[str, JsonValue]:
    applications = sorted(
        request.applications,
        key=lambda value: (value.player_slot, value.observation_seq, value.opportunity_id),
    )
    return {
        "actions": [
            {
                "batch": value.batch.model_dump(mode="json", exclude_none=True),
                "observation_seq": value.observation_seq,
                "observation_tick": value.observation_tick,
                "opportunity_id": value.opportunity_id,
                "player_slot": value.player_slot,
                "timing": {
                    "application_gate_monotonic_ns": value.timing.application_gate_monotonic_ns,
                    "application_tick": value.timing.application_tick,
                    "completion_monotonic_ns": value.timing.completion_monotonic_ns,
                    "deadline_monotonic_ns": value.timing.deadline_monotonic_ns,
                    "dispatch_monotonic_ns": value.timing.dispatch_monotonic_ns,
                    "first_token_monotonic_ns": value.timing.first_token_monotonic_ns,
                    "parse_completed_monotonic_ns": value.timing.parse_completed_monotonic_ns,
                    "parse_started_monotonic_ns": value.timing.parse_started_monotonic_ns,
                    "ready_monotonic_ns": value.timing.ready_monotonic_ns,
                },
            }
            for value in applications
        ],
        "application_tick": request.application_tick,
        "match_id": request.match_id,
        "mode": "continuous_realtime",
    }


def _acknowledged_action_batch(
    *,
    application_seq: int,
    application_tick: int,
    batch: ActionBatch,
    decision_mode: str,
    match_id: str,
    observation_tick: int,
    opportunity_id: str,
    player_slot: int,
) -> AcknowledgedActionBatch:
    canonical = canonical_json_bytes(batch.model_dump(mode="json", exclude_none=True))
    return AcknowledgedActionBatch(
        application_seq=application_seq,
        application_tick=application_tick,
        batch_digest=hashlib.sha256(canonical).hexdigest(),
        batch_id=batch.client_batch_id,
        canonical_batch_bytes=canonical,
        decision_mode=decision_mode,
        match_id=match_id,
        observation_hash=batch.based_on_observation_hash,
        observation_seq=batch.observation_seq,
        observation_tick=observation_tick,
        opportunity_id=opportunity_id,
        player_slot=player_slot,
    )


def _provider_observation_pair(frame: AuthenticatedGodotFrame) -> ProviderObservationPair:
    _require_exact_keys(
        frame.body,
        required={"checkpoint_hash", "observation_seq", "observations", "tick"},
        optional=set(),
        context="observation_pair",
    )
    if frame.body["checkpoint_hash"] != frame.boundary_hash:
        raise GodotBridgeInfrastructureError(
            "checkpoint_hash_mismatch", "observation pair checkpoint hash is inconsistent"
        )
    sequence = frame.body["observation_seq"]
    tick = frame.body["tick"]
    if not _is_non_negative_integer(sequence) or not _is_non_negative_integer(tick):
        raise GodotBridgeInfrastructureError(
            "observation_identity_invalid", "observation pair identity is invalid"
        )
    raw = frame.body["observations"]
    if not isinstance(raw, list) or len(raw) != 2:
        raise GodotBridgeInfrastructureError(
            "observation_pair_invalid", "observation pair must contain exactly two slots"
        )
    observations = sorted(
        (_provider_observation(value, None) for value in raw), key=lambda value: value.player_slot
    )
    if [value.player_slot for value in observations] != [0, 1]:
        raise GodotBridgeInfrastructureError(
            "observation_slots_invalid", "observation pair must contain slots 0 and 1"
        )
    if any(value.observation_seq != sequence or value.tick != tick for value in observations):
        raise GodotBridgeInfrastructureError(
            "observation_identity_mismatch", "paired observation identity is inconsistent"
        )
    return ProviderObservationPair(sequence, tick, tuple(observations))  # type: ignore[arg-type]


def _provider_observation(value: object, boundary_hash: Optional[str]) -> ProviderObservation:
    if not isinstance(value, dict):
        raise GodotBridgeInfrastructureError(
            "observation_invalid", "provider observation must be an object"
        )
    _require_exact_keys(
        value,
        required={"observation", "observation_hash", "observation_seq", "player_slot", "tick"},
        optional=set(),
        context="observation",
    )
    slot = value["player_slot"]
    sequence = value["observation_seq"]
    tick = value["tick"]
    observation_hash = value["observation_hash"]
    observation = value["observation"]
    if (
        slot not in {0, 1}
        or not _is_non_negative_integer(sequence)
        or not _is_non_negative_integer(tick)
    ):
        raise GodotBridgeInfrastructureError(
            "observation_identity_invalid", "provider observation identity is invalid"
        )
    if not isinstance(observation_hash, str) or len(observation_hash) != 64:
        raise GodotBridgeInfrastructureError(
            "observation_hash_invalid", "provider observation hash is invalid"
        )
    if boundary_hash is not None and observation_hash != boundary_hash:
        raise GodotBridgeInfrastructureError(
            "observation_hash_mismatch", "observation frame hash is inconsistent"
        )
    if not isinstance(observation, dict) or _contains_hidden_world_hash(observation):
        raise GodotBridgeInfrastructureError(
            "omniscient_hash_leak", "provider observation contains an omniscient world hash"
        )
    hash_payload = dict(observation)
    embedded_hash = hash_payload.pop("observation_hash", observation_hash)
    if embedded_hash != observation_hash:
        raise GodotBridgeInfrastructureError(
            "observation_hash_mismatch", "embedded observation hash is inconsistent"
        )
    canonical = canonical_json_bytes(observation)
    if hashlib.sha256(canonical_json_bytes(hash_payload)).hexdigest() != observation_hash:
        raise GodotBridgeInfrastructureError(
            "observation_content_hash_mismatch", "provider observation content hash is invalid"
        )
    return ProviderObservation(slot, sequence, tick, observation_hash, canonical)


def _validate_matching_hash_field(frame: AuthenticatedGodotFrame, names: Tuple[str, ...]) -> None:
    present = [name for name in names if name in frame.body]
    if not present or any(frame.body[name] != frame.boundary_hash for name in present):
        raise GodotBridgeInfrastructureError(
            "checkpoint_hash_mismatch", "trusted frame checkpoint hash is inconsistent"
        )


def _validate_canonical_slot_records(value: object, *, required: bool) -> None:
    if value is None and not required:
        return
    if not isinstance(value, list):
        raise GodotBridgeInfrastructureError(
            "action_pair_invalid", "action pair records must be an array"
        )
    slots = [item.get("player_slot") for item in value if isinstance(item, dict)]
    if len(slots) != len(value) or slots != sorted(slots):
        raise GodotBridgeInfrastructureError(
            "action_pair_order_invalid", "action pair records are not in canonical slot order"
        )


def _remote_failure_error(value: object, fallback_code: str) -> GodotBridgeError:
    if not isinstance(value, dict):
        return GodotBridgeInfrastructureError(
            "remote_failure_invalid", "authority rejection omitted a valid failure classification"
        )
    if set(value) != {"code", "hard_model_failure", "owner"}:
        return GodotBridgeInfrastructureError(
            "remote_failure_invalid", "authority failure classification has invalid fields"
        )
    code = value["code"]
    owner = value["owner"]
    hard = value["hard_model_failure"]
    if not isinstance(code, str) or not code:
        code = fallback_code
    if not isinstance(hard, bool):
        return GodotBridgeInfrastructureError(
            "remote_failure_invalid", "authority failure hardness is invalid"
        )
    if owner == FailureOwner.MODEL.value:
        return GodotBridgeModelError(code, "authority reported a model-owned failure", hard=hard)
    if owner == FailureOwner.PARTICIPANT_ENDPOINT.value:
        return GodotBridgeParticipantError(
            code, "authority reported a participant-owned failure", hard=hard
        )
    if owner == FailureOwner.ORGANIZER_INFRASTRUCTURE.value:
        return GodotBridgeInfrastructureError(code, "authority reported infrastructure failure")
    return GodotBridgeInfrastructureError(
        "remote_failure_invalid", "authority failure owner is invalid"
    )


def _require_exact_keys(
    value: Mapping[str, object],
    *,
    required: set[str],
    optional: set[str],
    context: str,
) -> None:
    keys = set(value)
    if not required <= keys or keys - required - optional:
        raise GodotBridgeInfrastructureError(
            f"{context}_schema_invalid", f"{context} body has invalid fields"
        )


def _contains_hidden_world_hash(value: object) -> bool:
    if isinstance(value, dict):
        if any(key in _HIDDEN_WORLD_HASH_KEYS for key in value):
            return True
        return any(_contains_hidden_world_hash(child) for child in value.values())
    if isinstance(value, list):
        return any(_contains_hidden_world_hash(child) for child in value)
    return False


def _contains_secret_key(value: object) -> bool:
    if isinstance(value, dict):
        for key, child in value.items():
            lowered = key.lower()
            if any(marker in lowered for marker in ("api_key", "authorization", "secret", "token")):
                return True
            if _contains_secret_key(child):
                return True
    elif isinstance(value, list):
        return any(_contains_secret_key(child) for child in value)
    return False


def _contains_private_replay_key(value: object) -> bool:
    if isinstance(value, dict):
        for key, child in value.items():
            lowered = key.lower()
            if any(marker in lowered for marker in _PRIVATE_REPLAY_KEY_MARKERS):
                return True
            if _contains_private_replay_key(child):
                return True
    elif isinstance(value, list):
        return any(_contains_private_replay_key(child) for child in value)
    return False


def _is_non_negative_integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _is_loopback_host(value: object) -> bool:
    if not isinstance(value, str):
        return False
    if value == "localhost":
        return True
    try:
        return ipaddress.ip_address(value).is_loopback
    except ValueError:
        return False
