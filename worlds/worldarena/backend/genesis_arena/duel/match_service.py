"""Process-local launch and lifecycle control for WorldArena Duel matches.

This module is the pregame boundary between an API/UI and the already-frozen Duel runtime.  It
never writes participant credentials to disk, never chooses a model implicitly, and never exposes
the authenticated Godot attachment ticket.  Gameplay remains authoritative in Godot; this service
only assembles locked inputs, constructs provider adapters, launches the local authority, and
publishes a deliberately small lifecycle/result view.
"""

from __future__ import annotations

# ruff: noqa: UP045 -- Keep public annotations importable on the Python 3.9 floor.
import asyncio
import hashlib
import inspect
import ipaddress
import re
import secrets
import shutil
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import (
    Any,
    Callable,
    Dict,
    List,
    Literal,
    Mapping,
    Optional,
    Protocol,
    Sequence,
)
from urllib.parse import urlsplit

from pydantic import BaseModel, ConfigDict, Field, JsonValue, SecretStr, model_validator

from .baselines import (
    NoOpDuelProviderAdapter,
    RushHeuristicDuelProviderAdapter,
    SeededRandomDuelProviderAdapter,
)
from .canonical import strict_json_loads
from .godot_bridge import (
    GatewayGodotBridge,
    GodotBridgeError,
    GodotBridgePhase,
    LocalhostGodotWebSocketAdapter,
    WebSocketLike,
)
from .godot_process_launcher import (
    DuelGodotProcessLaunchError,
    GodotManagedProcessLauncher,
)
from .live_artifacts import DuelLiveArtifactFinalizer
from .live_match import (
    DuelLiveMatchRunner,
    LiveArtifactFinalizer,
    LiveMatchError,
    LiveMatchResult,
)
from .match_init import MatchInitAssembler, MatchInitAssembly
from .models import DecisionMode, MatchConfig, SpectatorConfig
from .openai_provider import InMemoryOpenAIProviderAuditLog, OpenAIResponsesDuelAdapter
from .provider_adapters import EndpointOwnership, ParticipantProviderAdapter
from .timing import FailureClassification, FailureOwner

FROZEN_DUEL_ENGINE_BUILD_ID = "godot-4.5.stable.official.876b29033"
FROZEN_DUEL_ENGINE_BUILD_SHA256 = (
    "39b904eb0014941330f6435796ae0a041979802047495eb6fb87d59f327de719"
)

_SAFE_PROVIDER_RE = re.compile(r"^[a-z0-9][a-z0-9_.:-]{0,95}$")
_SAFE_FAILURE_CODE_RE = re.compile(r"^[a-z0-9][a-z0-9_.:-]{0,95}$")
_CAPABILITY_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")
_OFFICIAL_CADENCE = {
    "fixed_simultaneous": (100, 45_000),
    "continuous_realtime": (50, 8_000),
}
_TERMINAL_STATES = frozenset({"completed", "failed", "cancelled"})

DuelMatchState = Literal[
    "launching", "awaiting_godot", "running", "completed", "failed", "cancelled"
]
DuelAttachmentState = Literal["pending", "connected", "closed", "revoked"]
ReasoningEffort = Literal["none", "low", "medium", "high", "xhigh", "max"]
AuthorityLaunchMode = Literal["managed_process", "caller_owned"]


class DuelServiceModel(BaseModel):
    model_config = ConfigDict(extra="forbid", validate_assignment=True, allow_inf_nan=False)


class DuelParticipantLaunchConfig(DuelServiceModel):
    """Explicit provider selection and process-memory credential for one canonical slot."""

    slot: int = Field(ge=0, le=1)
    provider: str = Field(min_length=1, max_length=96, pattern=_SAFE_PROVIDER_RE.pattern)
    model: str = Field(min_length=1, max_length=200)
    reasoning: ReasoningEffort
    credential: Optional[SecretStr] = Field(default=None, repr=False)
    endpoint_ownership: EndpointOwnership = EndpointOwnership.ORGANIZER_HOSTED
    service_tier: Optional[str] = Field(
        default=None, min_length=1, max_length=96, pattern=r"^[A-Za-z0-9][A-Za-z0-9_.:-]*$"
    )
    max_output_tokens: Optional[int] = Field(default=None, ge=1, le=1_000_000)

    @model_validator(mode="after")
    def validate_credential(self) -> DuelParticipantLaunchConfig:
        # SecretStr prevents repr/model-dump disclosure.  Length is checked here without placing
        # the credential value in the error text.
        if self.credential is not None:
            length = len(self.credential.get_secret_value())
            if length < 1 or length > 4096:
                raise ValueError("participant credential length is invalid")
        return self


class DuelCreateMatchRequest(DuelServiceModel):
    """Complete pregame selection; every benchmark-sensitive choice is explicit."""

    decision_mode: DecisionMode
    faction_preset_id: Literal[
        "vanguard-v1", "warhost-v1", "grove-v1", "crypt-v1"
    ]
    mirror_faction: Literal[True]
    map_id: Literal["crossroads-duel-v1"]
    seed: int = Field(ge=0, le=9_007_199_254_740_991)
    decision_period_ticks: int = Field(ge=1, le=10_000)
    response_deadline_ms: int = Field(ge=1, le=45_000)
    authority_launch_mode: AuthorityLaunchMode = "managed_process"
    players: List[DuelParticipantLaunchConfig] = Field(min_length=2, max_length=2)
    maximum_match_ticks: Literal[18_000] = 18_000
    memory_policy: Literal[
        "fresh-match-with-bounded-scratchpad", "adaptive-series"
    ] = "fresh-match-with-bounded-scratchpad"
    cadence_profile_id: Optional[str] = Field(
        default=None, min_length=1, max_length=96, pattern=r"^[a-z0-9][a-z0-9_.:-]*$"
    )
    spectator: Optional[SpectatorConfig] = None

    @model_validator(mode="after")
    def validate_official_profile(self) -> DuelCreateMatchRequest:
        if [player.slot for player in self.players] != [0, 1]:
            raise ValueError("players must be in canonical slot order [0, 1]")
        expected_ticks, expected_deadline = _OFFICIAL_CADENCE[self.decision_mode]
        if (
            self.decision_period_ticks != expected_ticks
            or self.response_deadline_ms != expected_deadline
        ):
            raise ValueError(
                "Duel launch requires the frozen official cadence/deadline for its mode"
            )
        return self


class DuelProviderPublicConfig(DuelServiceModel):
    slot: int
    provider: str
    model: str
    reasoning: ReasoningEffort
    endpoint_ownership: EndpointOwnership
    service_tier: Optional[str] = None


class DuelMatchPublicConfig(DuelServiceModel):
    protocol_version: Literal["worldeval-rts/1.0.0"] = "worldeval-rts/1.0.0"
    decision_mode: DecisionMode
    faction_preset_id: str
    mirror_faction: Literal[True] = True
    map_id: str
    seed: int
    decision_period_ticks: int
    response_deadline_ms: int
    authority_launch_mode: AuthorityLaunchMode
    maximum_match_ticks: int
    memory_policy: str
    cadence_profile_id: Optional[str] = None
    players: List[DuelProviderPublicConfig]


class DuelFailureView(DuelServiceModel):
    code: str
    owner: FailureOwner
    hard_model_failure: bool


class DuelMatchStatus(DuelServiceModel):
    match_id: str
    state: DuelMatchState
    attachment: DuelAttachmentState
    config: DuelMatchPublicConfig
    created_at: datetime
    updated_at: datetime
    failure: Optional[DuelFailureView] = None


class DuelMatchCreation(DuelServiceModel):
    """Creation-only bootstrap; the optional claim is never persisted in public status."""

    status: DuelMatchStatus
    launch_claim_token: Optional[str] = Field(default=None, repr=False)


class DuelTerminalView(DuelServiceModel):
    disposition: str
    terminal_tick: int
    result_hash: str
    winner_slot: Optional[int] = None
    failure: Optional[DuelFailureView] = None


class DuelMatchResultView(DuelServiceModel):
    match_id: str
    state: Literal["completed", "failed", "cancelled"]
    terminal: Optional[DuelTerminalView] = None
    artifact_hash: Optional[str] = None
    failure: Optional[DuelFailureView] = None
    finished_at: datetime


class GodotAuthorityLaunchFields(DuelServiceModel):
    alias_salt_seat_0: List[int] = Field(repr=False)
    alias_salt_seat_1: List[int] = Field(repr=False)
    authoritative_hashes: Dict[str, str]
    scored: bool
    tie_key: List[int] = Field(repr=False)


class GodotControllerLaunchFields(DuelServiceModel):
    """JSON transport form of the exact ``DuelMatchController.configure_launch`` keys."""

    authority: GodotAuthorityLaunchFields = Field(repr=False)
    connection_id: str
    gateway_url: str = Field(repr=False)
    match_id: str
    match_init: Dict[str, JsonValue] = Field(repr=False)
    protocol_hash: str
    token: List[int] = Field(repr=False)


@dataclass(frozen=True)
class ProviderAdapterConfig:
    """Credential-free input supplied to a provider adapter factory."""

    slot: int
    provider: str
    model: str
    reasoning: ReasoningEffort
    endpoint_ownership: EndpointOwnership
    service_tier: Optional[str]
    max_output_tokens: Optional[int]
    match_seed: int


class DuelProviderAdapterFactory(Protocol):
    """Construct one participant adapter without persisting its credential elsewhere."""

    provider: str
    adapter_id: str

    def build(
        self, config: ProviderAdapterConfig, *, credential: Optional[SecretStr]
    ) -> ParticipantProviderAdapter: ...


class DuelArtifactFinalizerFactory(Protocol):
    """Construct an isolated artifact sealer after this match's secrets exist."""

    def __call__(
        self,
        *,
        match_id: str,
        config: MatchConfig,
        provider_tiers: Mapping[int, str],
        replay_authority_material: Mapping[str, bytes],
    ) -> LiveArtifactFinalizer: ...


class OpenAIResponsesAdapterFactory:
    """Production factory for the strict, retry-free OpenAI Responses Duel adapter."""

    provider = "openai"
    adapter_id = "openai-responses-v1"

    def __init__(self, *, audit_sink: Optional[Any] = None) -> None:
        self._audit_sink = audit_sink

    def build(
        self, config: ProviderAdapterConfig, *, credential: Optional[SecretStr]
    ) -> ParticipantProviderAdapter:
        if config.provider != self.provider:
            raise ValueError("provider factory mismatch")
        if credential is None:
            raise ValueError("OpenAI credential is required")
        # The plain string exists only for this constructor call.  The resulting SDK client owns
        # the process-local credential for the active match; no config/status object receives it.
        return OpenAIResponsesDuelAdapter(
            model=config.model,
            reasoning_effort=config.reasoning,
            service_tier=config.service_tier,
            max_output_tokens=config.max_output_tokens,
            endpoint_ownership=config.endpoint_ownership,
            api_key=credential.get_secret_value(),
            audit_sink=self._audit_sink,
        )


class _BaselineAdapterFactory:
    """Credential-free factory with a fixed public identity for calibration controls."""

    provider: str
    adapter_id: str

    def build(
        self, config: ProviderAdapterConfig, *, credential: Optional[SecretStr]
    ) -> ParticipantProviderAdapter:
        if config.provider != self.provider or config.model != self.adapter_id:
            raise ValueError("baseline provider/model identity mismatch")
        if config.reasoning != "none":
            raise ValueError("baseline adapters require reasoning=none")
        if credential is not None:
            raise ValueError("baseline adapters do not accept credentials")
        if config.service_tier is not None or config.max_output_tokens is not None:
            raise ValueError("baseline adapters do not accept hosted-provider options")
        return self._adapter(config)

    def _adapter(self, config: ProviderAdapterConfig) -> ParticipantProviderAdapter:
        raise NotImplementedError


class NoOpBaselineAdapterFactory(_BaselineAdapterFactory):
    provider = "baseline.noop"
    adapter_id = "baseline-noop-v1"

    def _adapter(self, config: ProviderAdapterConfig) -> ParticipantProviderAdapter:
        del config
        return NoOpDuelProviderAdapter()


class SeededRandomBaselineAdapterFactory(_BaselineAdapterFactory):
    provider = "baseline.seeded_random"
    adapter_id = "baseline-seeded-random-v1"

    def _adapter(self, config: ProviderAdapterConfig) -> ParticipantProviderAdapter:
        return SeededRandomDuelProviderAdapter(seed=config.match_seed)


class RushBaselineAdapterFactory(_BaselineAdapterFactory):
    provider = "baseline.rush"
    adapter_id = "baseline-rush-v1"

    def _adapter(self, config: ProviderAdapterConfig) -> ParticipantProviderAdapter:
        del config
        return RushHeuristicDuelProviderAdapter()


@dataclass(frozen=True)
class GodotDuelLaunchSpec:
    """Protected one-shot launch material handed only to the local process launcher."""

    match_id: str
    connection_id: str
    protocol_hash: str
    authoritative_hashes: Mapping[str, str]
    scored: bool
    attachment_ticket: str = field(repr=False)
    gateway_url: str = field(repr=False)
    session_secret: bytearray = field(repr=False)
    match_init_json: bytearray = field(repr=False)
    tie_key: bytearray = field(repr=False)
    alias_salt_seat_0: bytearray = field(repr=False)
    alias_salt_seat_1: bytearray = field(repr=False)

    def controller_fields(self) -> GodotControllerLaunchFields:
        match_init = strict_json_loads(self.match_init_json)
        if not isinstance(match_init, dict):
            raise DuelMatchConfigurationError("MATCH_INIT root is invalid")
        return GodotControllerLaunchFields(
            authority=GodotAuthorityLaunchFields(
                alias_salt_seat_0=list(self.alias_salt_seat_0),
                alias_salt_seat_1=list(self.alias_salt_seat_1),
                authoritative_hashes=dict(self.authoritative_hashes),
                scored=self.scored,
                tie_key=list(self.tie_key),
            ),
            connection_id=self.connection_id,
            gateway_url=self.gateway_url,
            match_id=self.match_id,
            match_init=match_init,
            protocol_hash=self.protocol_hash,
            token=list(self.session_secret),
        )

    def scrub_protected_bytes(self) -> None:
        """Best-effort zero and release of this one-use IPC copy."""

        for value in (
            self.session_secret,
            self.match_init_json,
            self.tie_key,
            self.alias_salt_seat_0,
            self.alias_salt_seat_1,
        ):
            if isinstance(value, bytearray):
                if value:
                    value[:] = b"\x00" * len(value)
                value.clear()


class GodotProcessHandle(Protocol):
    async def stop(self) -> None:
        """Stop and reap the launched authority process, idempotently."""


class GodotProcessLauncher(Protocol):
    async def launch(self, spec: GodotDuelLaunchSpec) -> GodotProcessHandle: ...


class DuelGodotLauncherUnavailable(RuntimeError):
    """A deployment explicitly disabled unattended Godot authority launch."""


class UnavailableGodotProcessLauncher:
    """Explicit fail-closed launcher for disabled/test deployments."""

    async def launch(self, spec: GodotDuelLaunchSpec) -> GodotProcessHandle:
        del spec
        raise DuelGodotLauncherUnavailable("Duel Godot process launcher is unavailable")


class DuelMatchServiceError(RuntimeError):
    """Base error for the pregame control surface."""


class DuelMatchConfigurationError(DuelMatchServiceError, ValueError):
    """A launch request cannot be mapped to installed local dependencies."""


class DuelMatchNotFoundError(DuelMatchServiceError):
    pass


class DuelMatchResultNotReadyError(DuelMatchServiceError):
    pass


class DuelMatchLaunchError(DuelMatchServiceError):
    def __init__(self, match_id: str, code: str) -> None:
        super().__init__("Duel authority launch failed")
        self.match_id = match_id
        self.code = code


RunnerFactory = Callable[..., DuelLiveMatchRunner]
BridgeFactory = Callable[..., GatewayGodotBridge]
SocketAdapterFactory = Callable[[GatewayGodotBridge], LocalhostGodotWebSocketAdapter]
NowFactory = Callable[[], datetime]


@dataclass
class _MatchEntry:
    match_id: str
    config: DuelMatchPublicConfig
    state: DuelMatchState
    attachment: DuelAttachmentState
    created_at: datetime
    updated_at: datetime
    bridge: Optional[GatewayGodotBridge] = field(default=None, repr=False)
    socket_adapter: Optional[LocalhostGodotWebSocketAdapter] = field(default=None, repr=False)
    runner: Optional[DuelLiveMatchRunner] = field(default=None, repr=False)
    adapters: Dict[int, ParticipantProviderAdapter] = field(default_factory=dict, repr=False)
    process: Optional[GodotProcessHandle] = field(default=None, repr=False)
    run_task: Optional[asyncio.Task[None]] = field(default=None, repr=False)
    websocket: Optional[WebSocketLike] = field(default=None, repr=False)
    result: Optional[DuelMatchResultView] = None
    failure: Optional[DuelFailureView] = None


class DuelMatchService:
    """In-memory registry and one-shot launch coordinator for authenticated Duel matches."""

    def __init__(
        self,
        *,
        provider_factories: Mapping[str, DuelProviderAdapterFactory],
        godot_launcher: GodotProcessLauncher,
        gateway_base_url: str,
        artifact_finalizer: Optional[LiveArtifactFinalizer] = None,
        artifact_finalizer_factory: Optional[DuelArtifactFinalizerFactory] = None,
        match_init_assembler: Optional[MatchInitAssembler] = None,
        engine_build_id: str = FROZEN_DUEL_ENGINE_BUILD_ID,
        engine_build_sha256: str = FROZEN_DUEL_ENGINE_BUILD_SHA256,
        runner_factory: RunnerFactory = DuelLiveMatchRunner,
        bridge_factory: BridgeFactory = GatewayGodotBridge,
        socket_adapter_factory: SocketAdapterFactory = LocalhostGodotWebSocketAdapter,
        attachment_auth_timeout_s: float = 10.0,
        now: NowFactory = lambda: datetime.now(timezone.utc),
    ) -> None:
        if attachment_auth_timeout_s <= 0:
            raise ValueError("attachment_auth_timeout_s must be positive")
        if (artifact_finalizer is None) == (artifact_finalizer_factory is None):
            raise ValueError(
                "configure exactly one artifact finalizer or artifact finalizer factory"
            )
        self._gateway_base_url = _validated_loopback_gateway_base(gateway_base_url)
        self._provider_factories = dict(provider_factories)
        for provider, factory in self._provider_factories.items():
            if (
                _SAFE_PROVIDER_RE.fullmatch(provider) is None
                or factory.provider != provider
                or _SAFE_PROVIDER_RE.fullmatch(factory.adapter_id) is None
            ):
                raise ValueError("provider factory registry is invalid")
        self._godot_launcher = godot_launcher
        self._artifact_finalizer = artifact_finalizer
        self._artifact_finalizer_factory = artifact_finalizer_factory
        self._assembler = match_init_assembler or MatchInitAssembler()
        self._engine_build_id = engine_build_id
        self._engine_build_sha256 = engine_build_sha256
        self._runner_factory = runner_factory
        self._bridge_factory = bridge_factory
        self._socket_adapter_factory = socket_adapter_factory
        self._attachment_auth_timeout_s = attachment_auth_timeout_s
        self._now = now
        self._entries: Dict[str, _MatchEntry] = {}
        self._attachments: Dict[str, str] = {}
        self._launch_claims: Dict[str, GodotDuelLaunchSpec] = {}
        self._lock = asyncio.Lock()
        self._closed = False

    async def create_match(self, request: DuelCreateMatchRequest) -> DuelMatchCreation:
        """Build and launch one match without retaining its credential-bearing request."""

        if not isinstance(request, DuelCreateMatchRequest):
            raise TypeError("request must be a DuelCreateMatchRequest")
        if self._closed:
            raise DuelMatchServiceError("Duel match service is closed")

        adapter_configs, adapters, adapter_ids = self._build_adapters(
            request.players, match_seed=request.seed
        )
        match_id = f"m_{uuid.uuid4().hex}"
        match_config = MatchConfig(
            decision_mode=request.decision_mode,
            faction_preset_id=request.faction_preset_id,
            mirror_faction=True,
            map_id=request.map_id,
            seed=request.seed,
            decision_period_ticks=request.decision_period_ticks,
            response_deadline_ms=request.response_deadline_ms,
            maximum_match_ticks=request.maximum_match_ticks,
            memory_policy=request.memory_policy,
            cadence_profile_id=request.cadence_profile_id,
            spectator=request.spectator,
            players=[
                {
                    "slot": config.slot,
                    "model": config.model,
                    "reasoning": config.reasoning,
                    "provider_adapter": adapter_ids[config.slot],
                }
                for config in adapter_configs
            ],
        )
        try:
            assembly = self._assembler.assemble(
                match_config,
                match_id=match_id,
                engine_build_id=self._engine_build_id,
                engine_build_sha256=self._engine_build_sha256,
            )
        except Exception as exc:
            adapters.clear()
            raise DuelMatchConfigurationError(
                "locked Duel match inputs could not be assembled"
            ) from exc

        session_secret = secrets.token_bytes(32)
        tie_key = secrets.token_bytes(32)
        alias_salt_0 = secrets.token_bytes(32)
        alias_salt_1 = secrets.token_bytes(32)
        while alias_salt_1 == alias_salt_0:
            alias_salt_1 = secrets.token_bytes(32)
        protected_hashes = _authoritative_hashes(assembly, tie_key=tie_key)
        try:
            artifact_finalizer = self._artifact_finalizer
            if self._artifact_finalizer_factory is not None:
                artifact_finalizer = self._artifact_finalizer_factory(
                    match_id=match_id,
                    config=match_config,
                    provider_tiers={
                        config.slot: config.service_tier
                        for config in adapter_configs
                        if config.service_tier is not None
                    },
                    replay_authority_material={
                        "tie_key": tie_key,
                        "alias_salt_seat_0": alias_salt_0,
                        "alias_salt_seat_1": alias_salt_1,
                    },
                )
            if artifact_finalizer is None or not callable(
                getattr(artifact_finalizer, "seal", None)
            ):
                raise TypeError("artifact finalizer does not expose seal(trace)")
        except Exception:
            adapters.clear()
            raise DuelMatchConfigurationError(
                "Duel artifact finalizer configuration failed"
            ) from None
        bridge = self._bridge_factory(
            match_id=match_id,
            token=session_secret,
            response_timeout_s=max(10.0, request.response_deadline_ms / 1_000 + 5.0),
        )
        socket_adapter = self._socket_adapter_factory(bridge)
        runner = self._runner_factory(
            config=match_config,
            match_init=assembly,
            adapters=adapters,
            bridge=bridge,
            artifact_finalizer=artifact_finalizer,
        )
        public_config = _public_config(request)
        timestamp = self._timestamp()
        entry = _MatchEntry(
            match_id=match_id,
            config=public_config,
            state="launching",
            attachment="pending",
            created_at=timestamp,
            updated_at=timestamp,
            bridge=bridge,
            socket_adapter=socket_adapter,
            runner=runner,
            adapters=adapters,
        )

        async with self._lock:
            ticket = self._new_attachment_ticket()
            self._entries[match_id] = entry
            self._attachments[ticket] = match_id

        launch_spec = GodotDuelLaunchSpec(
            match_id=match_id,
            connection_id=f"godot-{match_id[2:]}",
            protocol_hash=protected_hashes["protocol_hash"],
            authoritative_hashes=protected_hashes,
            scored=True,
            attachment_ticket=ticket,
            gateway_url=f"{self._gateway_base_url}/ws/duel/{ticket}",
            session_secret=bytearray(session_secret),
            match_init_json=bytearray(assembly.canonical_bytes),
            tie_key=bytearray(tie_key),
            alias_salt_seat_0=bytearray(alias_salt_0),
            alias_salt_seat_1=bytearray(alias_salt_1),
        )
        if request.authority_launch_mode == "caller_owned":
            async with self._lock:
                claim_token = self._new_launch_claim_token()
                self._launch_claims[claim_token] = launch_spec
                if entry.state == "launching":
                    entry.state = "awaiting_godot"
                    entry.updated_at = self._timestamp()
                status = self._status(entry)
            return DuelMatchCreation(status=status, launch_claim_token=claim_token)

        try:
            try:
                process = await self._godot_launcher.launch(launch_spec)
                if process is None or not callable(getattr(process, "stop", None)):
                    raise TypeError("Godot launcher returned an invalid process handle")
            finally:
                launch_spec.scrub_protected_bytes()
        except Exception as exc:
            if isinstance(exc, DuelGodotProcessLaunchError):
                code = exc.code
            elif isinstance(exc, DuelGodotLauncherUnavailable):
                code = "duel_launcher_unavailable"
            else:
                code = "godot_launch_failed"
            await self._fail_entry(
                entry,
                FailureClassification(
                    code=code,
                    owner=FailureOwner.ORGANIZER_INFRASTRUCTURE,
                    hard_model_failure=False,
                ),
            )
            raise DuelMatchLaunchError(match_id, code) from None

        async with self._lock:
            should_stop = entry.state in _TERMINAL_STATES
            if not should_stop:
                entry.process = process
            if entry.state == "launching":
                entry.state = "awaiting_godot"
                entry.updated_at = self._timestamp()
            status = self._status(entry)
        if should_stop:
            await _stop_process(process)
        return DuelMatchCreation(status=status)

    async def get_status(self, match_id: str) -> DuelMatchStatus:
        async with self._lock:
            return self._status(self._require_entry(match_id))

    async def get_result(self, match_id: str) -> DuelMatchResultView:
        async with self._lock:
            entry = self._require_entry(match_id)
            if entry.result is None:
                raise DuelMatchResultNotReadyError("Duel match result is not ready")
            return entry.result.model_copy(deep=True)

    async def cancel_match(self, match_id: str) -> DuelMatchStatus:
        """Idempotently revoke attachment and stop every active local runtime reference."""

        async with self._lock:
            entry = self._require_entry(match_id)
            if entry.state in _TERMINAL_STATES:
                return self._status(entry)
            failure = DuelFailureView(
                code="cancelled_by_operator",
                owner=FailureOwner.ORGANIZER_INFRASTRUCTURE,
                hard_model_failure=False,
            )
            entry.state = "cancelled"
            entry.attachment = "revoked"
            entry.failure = failure
            entry.updated_at = self._timestamp()
            entry.result = DuelMatchResultView(
                match_id=entry.match_id,
                state="cancelled",
                failure=failure,
                finished_at=entry.updated_at,
            )
            self._revoke_attachment_locked(entry.match_id)
            task = entry.run_task
            process = entry.process
            bridge = entry.bridge
            websocket = entry.websocket
            entry.adapters.clear()
            entry.runner = None
            entry.process = None
            entry.bridge = None
            entry.socket_adapter = None
            status = self._status(entry)

        if bridge is not None:
            bridge.disconnect()
        if task is not None and task is not asyncio.current_task() and not task.done():
            task.cancel()
            await _drain_task(task)
        if websocket is not None:
            try:
                await websocket.close(code=1012)
            except Exception:
                pass
        await _stop_process(process)
        return status

    async def claim_controller_launch(
        self, claim_token: str, *, client_host: object
    ) -> GodotControllerLaunchFields:
        """Atomically return caller-owned controller inputs to one loopback claimant."""

        if not _is_loopback_host(client_host):
            raise DuelMatchNotFoundError("Duel launch claim not found")
        if not isinstance(claim_token, str) or _CAPABILITY_RE.fullmatch(claim_token) is None:
            raise DuelMatchNotFoundError("Duel launch claim not found")
        async with self._lock:
            spec = self._launch_claims.pop(claim_token, None)
            if spec is None:
                raise DuelMatchNotFoundError("Duel launch claim not found")
            entry = self._entries.get(spec.match_id)
            if entry is None or entry.state != "awaiting_godot":
                spec.scrub_protected_bytes()
                raise DuelMatchNotFoundError("Duel launch claim not found")
        try:
            return spec.controller_fields()
        finally:
            spec.scrub_protected_bytes()

    async def attach_websocket(self, ticket: str, websocket: WebSocketLike) -> bool:
        """Consume one ticket and bind exactly one loopback Godot connection."""

        client = getattr(websocket, "client", None)
        host = getattr(client, "host", None)
        if not _is_loopback_host(host):
            await websocket.close(code=4403)
            return False
        if not isinstance(ticket, str) or _CAPABILITY_RE.fullmatch(ticket) is None:
            await websocket.close(code=4404)
            return False

        async with self._lock:
            match_id = self._attachments.pop(ticket, None)
            entry = self._entries.get(match_id) if match_id is not None else None
            if entry is None or entry.state not in {"launching", "awaiting_godot"}:
                entry = None
            else:
                entry.attachment = "connected"
                entry.updated_at = self._timestamp()
                entry.websocket = websocket
                entry.run_task = asyncio.create_task(
                    self._run_after_authentication(entry),
                    name=f"duel-match-{entry.match_id}",
                )
        if entry is None:
            await websocket.close(code=4404)
            return False

        adapter = entry.socket_adapter
        if adapter is None:
            await websocket.close(code=4410)
            await self._fail_entry(
                entry,
                FailureClassification(
                    "godot_attachment_unavailable",
                    FailureOwner.ORGANIZER_INFRASTRUCTURE,
                    False,
                ),
            )
            return False
        try:
            await adapter.handle(websocket)
        except asyncio.CancelledError:
            raise
        except Exception:
            await self._fail_entry(
                entry,
                FailureClassification(
                    "godot_socket_failed",
                    FailureOwner.ORGANIZER_INFRASTRUCTURE,
                    False,
                ),
            )
        finally:
            process: Optional[GodotProcessHandle] = None
            async with self._lock:
                if entry.websocket is websocket:
                    entry.websocket = None
                if entry.attachment == "connected":
                    entry.attachment = "closed"
                if entry.state in _TERMINAL_STATES:
                    entry.bridge = None
                    entry.socket_adapter = None
                    process = entry.process
                    entry.process = None
                entry.updated_at = self._timestamp()
            await _stop_process(process)
        return True

    async def aclose(self) -> None:
        """Stop all active matches and make the registry reject future launches."""

        async with self._lock:
            if self._closed:
                return
            self._closed = True
            active = [
                entry.match_id
                for entry in self._entries.values()
                if entry.state not in _TERMINAL_STATES
            ]
        for match_id in active:
            await self.cancel_match(match_id)
        async with self._lock:
            remaining_processes = [
                entry.process for entry in self._entries.values() if entry.process is not None
            ]
            for entry in self._entries.values():
                entry.process = None
            self._attachments.clear()
            self._launch_claims.clear()
        for process in remaining_processes:
            await _stop_process(process)

    async def _run_after_authentication(self, entry: _MatchEntry) -> None:
        bridge = entry.bridge
        runner = entry.runner
        if bridge is None or runner is None:
            await self._fail_entry(
                entry,
                FailureClassification(
                    "duel_runtime_unavailable",
                    FailureOwner.ORGANIZER_INFRASTRUCTURE,
                    False,
                ),
            )
            return
        try:
            await self._wait_for_authenticated_bridge(entry, bridge)
            async with self._lock:
                if entry.state in _TERMINAL_STATES:
                    return
                entry.state = "running"
                entry.updated_at = self._timestamp()
            result = await runner.run()
            await self._complete_entry(entry, result)
        except asyncio.CancelledError:
            if entry.state != "cancelled":
                await self._fail_entry(
                    entry,
                    FailureClassification(
                        "duel_runtime_cancelled",
                        FailureOwner.ORGANIZER_INFRASTRUCTURE,
                        False,
                    ),
                )
            raise
        except GodotBridgeError as exc:
            await self._fail_entry(entry, exc.classification)
        except _AuthenticationTimeout:
            await self._fail_entry(
                entry,
                FailureClassification(
                    "godot_authentication_timeout",
                    FailureOwner.ORGANIZER_INFRASTRUCTURE,
                    False,
                ),
            )
        except DuelMatchServiceError:
            await self._fail_entry(
                entry,
                FailureClassification(
                    "godot_authentication_failed",
                    FailureOwner.ORGANIZER_INFRASTRUCTURE,
                    False,
                ),
            )
        except LiveMatchError:
            await self._fail_entry(
                entry,
                FailureClassification(
                    "duel_live_match_failed",
                    FailureOwner.ORGANIZER_INFRASTRUCTURE,
                    False,
                ),
            )
        except Exception:
            await self._fail_entry(
                entry,
                FailureClassification(
                    "duel_runtime_failed",
                    FailureOwner.ORGANIZER_INFRASTRUCTURE,
                    False,
                ),
            )
        finally:
            current = asyncio.current_task()
            async with self._lock:
                if entry.run_task is current:
                    entry.run_task = None
                if entry.state in _TERMINAL_STATES and entry.websocket is None:
                    entry.bridge = None
                    entry.socket_adapter = None

    async def _wait_for_authenticated_bridge(
        self, entry: _MatchEntry, bridge: GatewayGodotBridge
    ) -> None:
        loop = asyncio.get_running_loop()
        deadline = loop.time() + self._attachment_auth_timeout_s
        while True:
            if entry.state in _TERMINAL_STATES:
                raise asyncio.CancelledError
            if bridge.phase is GodotBridgePhase.AUTHENTICATED:
                return
            if bridge.phase in {
                GodotBridgePhase.FAILED,
                GodotBridgePhase.CLOSED,
                GodotBridgePhase.COMPLETE,
            }:
                raise DuelMatchServiceError("Godot authentication failed")
            if loop.time() >= deadline:
                bridge.disconnect()
                raise _AuthenticationTimeout
            await asyncio.sleep(0.01)

    async def _complete_entry(self, entry: _MatchEntry, result: LiveMatchResult) -> None:
        terminal_failure = (
            _failure_view(result.terminal.failure)
            if result.terminal.failure is not None
            else None
        )
        terminal = DuelTerminalView(
            disposition=result.terminal.disposition,
            terminal_tick=result.terminal.terminal_tick,
            result_hash=result.terminal.result_hash,
            winner_slot=result.terminal.winner_slot,
            failure=terminal_failure,
        )
        async with self._lock:
            if entry.state in _TERMINAL_STATES:
                return
            entry.state = "completed"
            entry.failure = terminal_failure
            entry.updated_at = self._timestamp()
            entry.result = DuelMatchResultView(
                match_id=entry.match_id,
                state="completed",
                terminal=terminal,
                artifact_hash=result.artifact.artifact_hash,
                failure=terminal_failure,
                finished_at=entry.updated_at,
            )
            self._revoke_attachment_locked(entry.match_id)
            entry.adapters.clear()
            entry.runner = None
            entry.bridge = None
            entry.socket_adapter = None

    async def _fail_entry(
        self, entry: _MatchEntry, classification: FailureClassification
    ) -> None:
        safe = DuelFailureView(
            code=_safe_failure_code(classification.code),
            owner=classification.owner,
            hard_model_failure=classification.hard_model_failure,
        )
        async with self._lock:
            if entry.state in _TERMINAL_STATES:
                return
            entry.state = "failed"
            entry.attachment = "revoked"
            entry.failure = safe
            entry.updated_at = self._timestamp()
            entry.result = DuelMatchResultView(
                match_id=entry.match_id,
                state="failed",
                failure=safe,
                finished_at=entry.updated_at,
            )
            self._revoke_attachment_locked(entry.match_id)
            process = entry.process
            websocket = entry.websocket
            entry.adapters.clear()
            entry.runner = None
            entry.process = None
            entry.bridge = None
            entry.socket_adapter = None
        if websocket is not None:
            try:
                await websocket.close(code=1011)
            except Exception:
                pass
        await _stop_process(process)

    def _build_adapters(
        self,
        players: Sequence[DuelParticipantLaunchConfig],
        *,
        match_seed: int,
    ) -> tuple[
        List[ProviderAdapterConfig],
        Dict[int, ParticipantProviderAdapter],
        Dict[int, str],
    ]:
        configs: List[ProviderAdapterConfig] = []
        adapters: Dict[int, ParticipantProviderAdapter] = {}
        adapter_ids: Dict[int, str] = {}
        try:
            for player in players:
                factory = self._provider_factories.get(player.provider)
                if factory is None:
                    raise DuelMatchConfigurationError(
                        "requested Duel provider is not installed"
                    )
                config = ProviderAdapterConfig(
                    slot=player.slot,
                    provider=player.provider,
                    model=player.model,
                    reasoning=player.reasoning,
                    endpoint_ownership=player.endpoint_ownership,
                    service_tier=player.service_tier,
                    max_output_tokens=player.max_output_tokens,
                    match_seed=match_seed,
                )
                adapter = factory.build(config, credential=player.credential)
                if getattr(adapter, "endpoint_ownership", None) is not config.endpoint_ownership:
                    raise ValueError("provider adapter ownership does not match launch config")
                configs.append(config)
                adapters[player.slot] = adapter
                adapter_ids[player.slot] = factory.adapter_id
        except DuelMatchConfigurationError:
            adapters.clear()
            raise
        except Exception:
            adapters.clear()
            raise DuelMatchConfigurationError(
                "Duel provider adapter configuration failed"
            ) from None
        return configs, adapters, adapter_ids

    def _new_attachment_ticket(self) -> str:
        while True:
            ticket = secrets.token_urlsafe(32)
            if ticket not in self._attachments:
                return ticket

    def _new_launch_claim_token(self) -> str:
        while True:
            token = secrets.token_urlsafe(32)
            if token not in self._launch_claims:
                return token

    def _require_entry(self, match_id: str) -> _MatchEntry:
        entry = self._entries.get(match_id)
        if entry is None:
            raise DuelMatchNotFoundError("Duel match not found")
        return entry

    def _revoke_attachment_locked(self, match_id: str) -> None:
        for ticket, attached_match_id in tuple(self._attachments.items()):
            if attached_match_id == match_id:
                del self._attachments[ticket]
        for token, spec in tuple(self._launch_claims.items()):
            if spec.match_id == match_id:
                spec.scrub_protected_bytes()
                del self._launch_claims[token]

    def _status(self, entry: _MatchEntry) -> DuelMatchStatus:
        return DuelMatchStatus(
            match_id=entry.match_id,
            state=entry.state,
            attachment=entry.attachment,
            config=entry.config.model_copy(deep=True),
            created_at=entry.created_at,
            updated_at=entry.updated_at,
            failure=entry.failure.model_copy(deep=True) if entry.failure else None,
        )

    def _timestamp(self) -> datetime:
        value = self._now()
        if value.tzinfo is None or value.utcoffset() is None:
            raise RuntimeError("Duel service clock must return a timezone-aware datetime")
        return value


class _AuthenticationTimeout(DuelMatchServiceError):
    pass


def default_duel_match_service(
    *,
    port: int,
    runs_dir: Optional[Path] = None,
    godot_executable: Optional[Path] = None,
    godot_project_path: Optional[Path] = None,
) -> DuelMatchService:
    """Build credential-safe app wiring; matches launch only when explicitly created."""

    provider_audit_log = InMemoryOpenAIProviderAuditLog()
    artifact_root = Path(runs_dir or "runs") / "duel_artifacts"

    def artifact_finalizer_factory(
        *,
        match_id: str,
        config: MatchConfig,
        provider_tiers: Mapping[int, str],
        replay_authority_material: Mapping[str, bytes],
    ) -> LiveArtifactFinalizer:
        del match_id, config
        return DuelLiveArtifactFinalizer(
            artifact_root,
            provider_tiers=provider_tiers,
            provider_audit_sources=(provider_audit_log,),
            replay_authority_material=replay_authority_material,
        )

    repository_root = Path(__file__).resolve().parents[3]
    if godot_executable is None:
        conventional = Path("/Applications/Godot.app/Contents/MacOS/Godot")
        discovered = shutil.which("godot") or shutil.which("Godot")
        godot_executable = (
            conventional
            if conventional.is_file()
            else Path(discovered) if discovered else conventional
        )
    if godot_project_path is None:
        godot_project_path = repository_root / "godot"

    return DuelMatchService(
        provider_factories={
            "openai": OpenAIResponsesAdapterFactory(audit_sink=provider_audit_log),
            "baseline.noop": NoOpBaselineAdapterFactory(),
            "baseline.seeded_random": SeededRandomBaselineAdapterFactory(),
            "baseline.rush": RushBaselineAdapterFactory(),
        },
        godot_launcher=GodotManagedProcessLauncher(
            executable=godot_executable,
            project_path=godot_project_path,
        ),
        gateway_base_url=f"ws://127.0.0.1:{port}",
        artifact_finalizer_factory=artifact_finalizer_factory,
    )


def _public_config(request: DuelCreateMatchRequest) -> DuelMatchPublicConfig:
    return DuelMatchPublicConfig(
        decision_mode=request.decision_mode,
        faction_preset_id=request.faction_preset_id,
        map_id=request.map_id,
        seed=request.seed,
        decision_period_ticks=request.decision_period_ticks,
        response_deadline_ms=request.response_deadline_ms,
        authority_launch_mode=request.authority_launch_mode,
        maximum_match_ticks=request.maximum_match_ticks,
        memory_policy=request.memory_policy,
        cadence_profile_id=request.cadence_profile_id,
        players=[
            DuelProviderPublicConfig(
                slot=player.slot,
                provider=player.provider,
                model=player.model,
                reasoning=player.reasoning,
                endpoint_ownership=player.endpoint_ownership,
                service_tier=player.service_tier,
            )
            for player in request.players
        ],
    )


def _authoritative_hashes(
    assembly: MatchInitAssembly, *, tie_key: bytes
) -> Dict[str, str]:
    value = strict_json_loads(assembly.canonical_bytes)
    if not isinstance(value, dict):
        raise DuelMatchConfigurationError("MATCH_INIT root is invalid")
    try:
        artifacts = value["artifacts"]
        return {
            "engine_build_hash": artifacts["engine_build"]["sha256"],
            "faction_hash": value["faction"]["sha256"],
            "helper_hash": artifacts["helper"]["sha256"],
            "item_hash": artifacts["items"]["sha256"],
            "map_hash": value["map"]["sha256"],
            "neutral_hash": artifacts["neutrals"]["sha256"],
            "prompt_hash": artifacts["prompt"]["sha256"],
            "protocol_hash": artifacts["protocol"]["sha256"],
            "ruleset_hash": value["ruleset"]["sha256"],
            "tie_key_commitment": hashlib.sha256(tie_key).hexdigest(),
        }
    except (KeyError, TypeError) as exc:
        raise DuelMatchConfigurationError(
            "MATCH_INIT cannot produce authoritative launch hashes"
        ) from exc


def _failure_view(classification: FailureClassification) -> DuelFailureView:
    return DuelFailureView(
        code=_safe_failure_code(classification.code),
        owner=classification.owner,
        hard_model_failure=classification.hard_model_failure,
    )


def _safe_failure_code(code: str) -> str:
    if isinstance(code, str) and _SAFE_FAILURE_CODE_RE.fullmatch(code) is not None:
        return code
    return "duel_failure_unclassified"


def _validated_loopback_gateway_base(value: str) -> str:
    parsed = urlsplit(value)
    if (
        parsed.scheme not in {"ws", "wss"}
        or not _is_loopback_host(parsed.hostname)
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
    ):
        raise ValueError("gateway_base_url must be an explicit loopback WebSocket origin")
    try:
        _ = parsed.port
    except ValueError as exc:
        raise ValueError("gateway_base_url port is invalid") from exc
    return value.rstrip("/")


def _is_loopback_host(host: object) -> bool:
    if not isinstance(host, str) or not host:
        return False
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


async def _drain_task(task: asyncio.Task[Any]) -> None:
    try:
        await task
    except (asyncio.CancelledError, Exception):
        pass


async def _stop_process(process: Optional[GodotProcessHandle]) -> None:
    if process is None:
        return
    try:
        result = process.stop()
        if inspect.isawaitable(result):
            await result
    except Exception:
        pass


__all__ = [
    "AuthorityLaunchMode",
    "DuelAttachmentState",
    "DuelCreateMatchRequest",
    "DuelFailureView",
    "DuelGodotLauncherUnavailable",
    "DuelGodotProcessLaunchError",
    "DuelMatchConfigurationError",
    "DuelMatchLaunchError",
    "DuelMatchCreation",
    "DuelMatchNotFoundError",
    "DuelMatchResultNotReadyError",
    "DuelMatchResultView",
    "DuelMatchService",
    "DuelMatchState",
    "DuelMatchStatus",
    "DuelParticipantLaunchConfig",
    "DuelArtifactFinalizerFactory",
    "DuelProviderAdapterFactory",
    "DuelProviderPublicConfig",
    "FROZEN_DUEL_ENGINE_BUILD_ID",
    "FROZEN_DUEL_ENGINE_BUILD_SHA256",
    "GodotAuthorityLaunchFields",
    "GodotControllerLaunchFields",
    "GodotDuelLaunchSpec",
    "GodotManagedProcessLauncher",
    "GodotProcessHandle",
    "GodotProcessLauncher",
    "OpenAIResponsesAdapterFactory",
    "NoOpBaselineAdapterFactory",
    "ProviderAdapterConfig",
    "RushBaselineAdapterFactory",
    "SeededRandomBaselineAdapterFactory",
    "UnavailableGodotProcessLauncher",
    "default_duel_match_service",
]
