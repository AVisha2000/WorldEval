from __future__ import annotations

import asyncio
import hashlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Mapping

import pytest
from genesis_arena.duel.canonical import canonical_json_bytes, strict_json_loads
from genesis_arena.duel.continuous_runtime import (
    ContinuousApplyGateRequest,
    ContinuousOpportunityDisposition,
)
from genesis_arena.duel.godot_bridge import (
    AcknowledgedActionBatch,
    ProviderObservation,
    ProviderObservationPair,
    TerminalReport,
)
from genesis_arena.duel.live_match import (
    DuelLiveMatchRunner,
    LiveArtifactSeal,
    LiveMatchInfrastructureError,
    LiveMatchTrace,
    build_continuous_live_opportunity,
    build_fixed_live_opportunity,
)
from genesis_arena.duel.match_init import MatchInitAssembler, MatchInitAssembly
from genesis_arena.duel.models import MatchConfig
from genesis_arena.duel.protocol import ProtocolPackage
from genesis_arena.duel.provider_adapters import (
    EndpointOwnership,
    ProviderCallResult,
    ProviderFailureKind,
    ProviderRequest,
)
from genesis_arena.duel.runtime import FixedCommitRequest, FixedRevealRequest

ROOT = Path(__file__).resolve().parents[2]
MATCH_ID = "m_live-match"
ENGINE_BUILD_ID = "godot-4.5.stable.official.876b29033"
ENGINE_BUILD_SHA256 = "39b904eb0014941330f6435796ae0a041979802047495eb6fb87d59f327de719"
START_NS = 40_000_000_000


def _config(mode: str) -> MatchConfig:
    return MatchConfig(
        decision_mode=mode,
        faction_preset_id="vanguard-v1",
        seed=17_091,
        decision_period_ticks=100 if mode == "fixed_simultaneous" else 50,
        response_deadline_ms=45_000 if mode == "fixed_simultaneous" else 8_000,
        players=[
            {
                "slot": 0,
                "model": "model-zero-snapshot",
                "reasoning": "frozen",
                "provider_adapter": "scripted-zero",
            },
            {
                "slot": 1,
                "model": "model-one-snapshot",
                "reasoning": "frozen",
                "provider_adapter": "scripted-one",
            },
        ],
    )


@pytest.fixture(scope="module")
def assemblies() -> Dict[str, MatchInitAssembly]:
    assembler = MatchInitAssembler(ProtocolPackage(ROOT / "game" / "duel_protocol"))
    return {
        mode: assembler.assemble(
            _config(mode),
            match_id=MATCH_ID,
            engine_build_id=ENGINE_BUILD_ID,
            engine_build_sha256=ENGINE_BUILD_SHA256,
        )
        for mode in ("fixed_simultaneous", "continuous_realtime")
    }


def _observation_pair(mode: str, *, sequence: int = 0, tick: int = 0) -> ProviderObservationPair:
    values = []
    for slot in (0, 1):
        payload: Dict[str, Any] = {
            "decision": {
                "commands_apply_tick": tick + 1 if mode == "fixed_simultaneous" else None,
                "mode": mode,
                "observation_tick": tick,
                "opportunity_skipped": False,
                "response_deadline_ms": 45_000 if mode == "fixed_simultaneous" else 8_000,
                "valid_until_tick": tick + (1 if mode == "fixed_simultaneous" else 100),
            },
            "heroes": [],
            "match_id": MATCH_ID,
            "message_type": "observation",
            "observation_seq": sequence,
            "owned_entities": [
                {
                    "entity_id": f"e_transport{slot}",
                    "passenger_ids": [f"e_passenger{slot}a", f"e_passenger{slot}b"],
                }
            ],
            "owned_structures": [],
            "protocol_version": "worldeval-rts/1.0.0",
            "squads": [
                {
                    "member_ids": [f"e_member{slot}a", f"e_member{slot}b"],
                    "squad_id": f"squad.slot{slot}",
                }
            ],
            "tick": tick,
        }
        digest = hashlib.sha256(canonical_json_bytes(payload)).hexdigest()
        payload["observation_hash"] = digest
        values.append(
            ProviderObservation(
                player_slot=slot,
                observation_seq=sequence,
                tick=tick,
                observation_hash=digest,
                canonical_bytes=canonical_json_bytes(payload),
            )
        )
    return ProviderObservationPair(sequence, tick, tuple(values))  # type: ignore[arg-type]


class ImmediateAdapter:
    endpoint_ownership = EndpointOwnership.PARTICIPANT_HOSTED

    def __init__(self, slot: int, mode: str) -> None:
        self.slot = slot
        self.mode = mode
        self.requests: list[ProviderRequest] = []

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        self.requests.append(request)
        return ProviderCallResult.success(
            canonical_json_bytes(
                {
                    "based_on_observation_hash": (
                        strict_observation_hash(request.observation_json)
                    ),
                    "client_batch_id": (f"batch.{self.mode}.{request.observation_seq}.{self.slot}"),
                    "commands": [],
                    "match_id": request.match_id,
                    "message_type": "action_batch",
                    "observation_seq": request.observation_seq,
                    "protocol_version": "worldeval-rts/1.0.0",
                    "valid_until_tick": request.boundary_tick
                    + (1 if self.mode == "fixed_simultaneous" else 100),
                    "working_memory": f"protected memory slot {self.slot}",
                }
            )
        )


class RefusingAdapter:
    endpoint_ownership = EndpointOwnership.PARTICIPANT_HOSTED

    def __init__(self) -> None:
        self.requests: list[ProviderRequest] = []

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        self.requests.append(request)
        return ProviderCallResult.failed(ProviderFailureKind.REFUSAL)


def strict_observation_hash(payload: bytes) -> str:
    value = strict_json_loads(payload)
    assert isinstance(value, dict)
    result = value["observation_hash"]
    assert isinstance(result, str)
    return result


@dataclass
class FakeClock:
    value: int = START_NS

    def __call__(self) -> int:
        return self.value

    async def sleep(self, seconds: float) -> None:
        self.value += round(seconds * 1_000_000_000)
        await asyncio.sleep(0)


@dataclass
class RecordingFinalizer:
    traces: list[LiveMatchTrace] = field(default_factory=list)
    fail: bool = False

    async def seal(self, trace: LiveMatchTrace) -> LiveArtifactSeal:
        self.traces.append(trace)
        if self.fail:
            raise RuntimeError("injected artifact failure")
        return LiveArtifactSeal(
            artifact_hash="a" * 64,
            manifest={"format": "worldeval-duel-replay-v1", "match_id": trace.match_id},
        )


class FakeLiveBridge:
    def __init__(
        self,
        *,
        mode: str,
        assembly: MatchInitAssembly,
        match_init_override: bytes | None = None,
    ) -> None:
        self.match_id = MATCH_ID
        self.mode = mode
        self.assembly = assembly
        self.match_init_override = match_init_override
        self.terminal_report: TerminalReport | None = None
        self.configs: list[MatchConfig] = []
        self.statuses: list[Mapping[str, object]] = []
        self.fixed_commits: list[FixedCommitRequest] = []
        self.fixed_reveals: list[FixedRevealRequest] = []
        self.continuous_requests: list[ContinuousApplyGateRequest] = []
        self.dispositions: list[tuple[ContinuousOpportunityDisposition, str]] = []
        self.artifacts: list[LiveArtifactSeal] = []
        self.continuous_clock_starts = 0
        self.observations: asyncio.Queue[ProviderObservationPair] = asyncio.Queue()
        self.receipts: asyncio.Queue[Mapping[str, object]] = asyncio.Queue()
        self.acknowledged_batches: asyncio.Queue[tuple[AcknowledgedActionBatch, ...]] = (
            asyncio.Queue()
        )
        self.events: asyncio.Queue[Mapping[str, object]] = asyncio.Queue()
        self.checkpoints: asyncio.Queue[Mapping[str, object]] = asyncio.Queue()
        self._terminal = asyncio.Event()
        self.observations.put_nowait(_observation_pair(mode))

    async def configure(self, config: MatchConfig) -> object:
        self.configs.append(config)
        return object()

    async def next_match_init(self) -> bytes:
        return self.match_init_override or self.assembly.canonical_bytes

    async def next_observation_pair(self) -> ProviderObservationPair:
        return await self.observations.get()

    async def next_action_receipts(self) -> Mapping[str, object]:
        return await self.receipts.get()

    async def next_acknowledged_action_batches(
        self,
    ) -> tuple[AcknowledgedActionBatch, ...]:
        return await self.acknowledged_batches.get()

    async def next_tick_events(self) -> Mapping[str, object]:
        return await self.events.get()

    async def next_checkpoint(self) -> Mapping[str, object]:
        return await self.checkpoints.get()

    async def wait_terminal(self) -> TerminalReport:
        await self._terminal.wait()
        assert self.terminal_report is not None
        return self.terminal_report

    async def start_continuous_clock(self) -> None:
        self.continuous_clock_starts += 1

    async def send_thinking_status(
        self,
        *,
        observation_hash: str,
        player_slot: int,
        status: str,
        observation_seq: int,
    ) -> None:
        if self.terminal_report is not None:
            raise RuntimeError("status after terminal")
        self.statuses.append(
            {
                "observation_hash": observation_hash,
                "observation_seq": observation_seq,
                "player_slot": player_slot,
                "status": status,
            }
        )

    async def lock_batch_commits(self, request: FixedCommitRequest) -> None:
        self.fixed_commits.append(request)

    async def reveal_batch_pair(self, request: FixedRevealRequest) -> None:
        self.fixed_reveals.append(request)
        evidence = tuple(
            self._evidence(
                application_tick=request.activation_tick,
                batch=reveal.batch,
                observation_tick=request.boundary_tick,
                opportunity_id=request.opportunity_id,
                player_slot=reveal.player_slot,
            )
            for reveal in request.reveals
        )
        self.acknowledged_batches.put_nowait(evidence)
        self._finish("victory", winner=0, tick=request.activation_tick, evidence=evidence)

    async def apply_continuous_gate(self, request: ContinuousApplyGateRequest) -> None:
        self.continuous_requests.append(request)
        evidence = tuple(
            self._evidence(
                application_tick=request.application_tick,
                batch=application.batch,
                observation_tick=application.observation_tick,
                opportunity_id=application.opportunity_id,
                player_slot=application.player_slot,
            )
            for application in request.applications
        )
        self.acknowledged_batches.put_nowait(evidence)
        self._finish("victory", winner=1, tick=request.application_tick, evidence=evidence)

    async def declare_continuous_disposition(
        self, disposition: ContinuousOpportunityDisposition, *, code: str
    ) -> None:
        self.dispositions.append((disposition, code))
        if disposition is ContinuousOpportunityDisposition.DRAW_DOUBLE_TECHNICAL_FORFEIT:
            self._finish("draw", winner=None, tick=1)
        elif disposition is ContinuousOpportunityDisposition.TECHNICAL_FORFEIT_SLOT_0:
            self._finish("technical_forfeit", winner=1, tick=1)
        elif disposition is ContinuousOpportunityDisposition.TECHNICAL_FORFEIT_SLOT_1:
            self._finish("technical_forfeit", winner=0, tick=1)
        else:
            self._finish("infrastructure_void", winner=None, tick=1)

    async def mark_artifact_ready(
        self, *, artifact_hash: str, manifest: Mapping[str, object]
    ) -> None:
        self.artifacts.append(LiveArtifactSeal(artifact_hash, manifest))

    def _evidence(
        self,
        *,
        application_tick: int,
        batch,
        observation_tick: int,
        opportunity_id: str,
        player_slot: int,
    ) -> AcknowledgedActionBatch:
        canonical = canonical_json_bytes(batch.model_dump(mode="json", exclude_none=True))
        return AcknowledgedActionBatch(
            application_seq=0,
            application_tick=application_tick,
            batch_digest=hashlib.sha256(canonical).hexdigest(),
            batch_id=batch.client_batch_id,
            canonical_batch_bytes=canonical,
            decision_mode=self.mode,
            match_id=self.match_id,
            observation_hash=batch.based_on_observation_hash,
            observation_seq=batch.observation_seq,
            observation_tick=observation_tick,
            opportunity_id=opportunity_id,
            player_slot=player_slot,
        )

    def _finish(
        self,
        disposition: str,
        *,
        winner: int | None,
        tick: int,
        evidence: tuple[AcknowledgedActionBatch, ...] = (),
    ) -> None:
        if disposition == "victory":
            self.receipts.put_nowait(
                {
                    "application_seq": 0,
                    "application_tick": tick,
                    "checkpoint_hash": "e" * 64,
                    "checkpoint_tick": tick,
                    "decision_mode": self.mode,
                    "kind": (
                        "fixed_pair" if self.mode == "fixed_simultaneous" else "continuous_gate"
                    ),
                    "match_id": self.match_id,
                    "records": [
                        {
                            "batch_digest": item.batch_digest,
                            "batch_id": item.batch_id,
                            "compiled_intents": [],
                            "player_slot": item.player_slot,
                            "receipt": {
                                "apply_tick": tick,
                                "batch_id": item.batch_id,
                                "batch_status": "no_op",
                                "code": None,
                                "commands": [],
                                "observation_seq": item.observation_seq,
                                "received_tick": max(0, tick - 1),
                            },
                        }
                        for item in evidence
                    ],
                }
            )
        self.terminal_report = TerminalReport(
            disposition=disposition,
            terminal_tick=tick,
            result_hash="f" * 64,
            winner_slot=winner,
            failure=None,
            body={
                "disposition": disposition,
                "result_hash": "f" * 64,
                "terminal_tick": tick,
                "winner_slot": winner,
            },
        )
        self._terminal.set()


def test_live_opportunity_builders_derive_private_budget_context(
    assemblies: Dict[str, MatchInitAssembly],
) -> None:
    fixed = build_fixed_live_opportunity(
        pair=_observation_pair("fixed_simultaneous", sequence=4, tick=400),
        config=_config("fixed_simultaneous"),
        match_init=assemblies["fixed_simultaneous"],
    )
    context = fixed.player_inputs[0].validation_context
    assert context.squad_sizes == {"squad.slot0": 2}
    assert context.transport_passenger_counts == {"e_transport0": 2}
    assert context.application_tick == context.controller_valid_until_tick == 401

    continuous = build_continuous_live_opportunity(
        pair=_observation_pair("continuous_realtime", sequence=1, tick=50),
        config=_config("continuous_realtime"),
        match_init=assemblies["continuous_realtime"],
        dispatch_order=(1, 0),
    )
    assert continuous.dispatch_order == (1, 0)
    assert continuous.player_inputs[1].validation_context.controller_valid_until_tick == 150


def test_builder_rejects_observation_validity_tamper(
    assemblies: Dict[str, MatchInitAssembly],
) -> None:
    pair = _observation_pair("fixed_simultaneous")
    raw = __import__("json").loads(pair.observations[0].canonical_bytes)
    raw["decision"]["valid_until_tick"] = 2
    tampered = ProviderObservation(
        player_slot=0,
        observation_seq=0,
        tick=0,
        observation_hash=pair.observations[0].observation_hash,
        canonical_bytes=canonical_json_bytes(raw),
    )
    bad_pair = ProviderObservationPair(0, 0, (tampered, pair.observations[1]))
    with pytest.raises(LiveMatchInfrastructureError, match="validity ceiling"):
        build_fixed_live_opportunity(
            pair=bad_pair,
            config=_config("fixed_simultaneous"),
            match_init=assemblies["fixed_simultaneous"],
        )


@pytest.mark.asyncio
async def test_fixed_live_runner_seals_only_after_commit_reveal_terminal(
    assemblies: Dict[str, MatchInitAssembly],
) -> None:
    mode = "fixed_simultaneous"
    bridge = FakeLiveBridge(mode=mode, assembly=assemblies[mode])
    adapters = {slot: ImmediateAdapter(slot, mode) for slot in (0, 1)}
    finalizer = RecordingFinalizer()
    runner = DuelLiveMatchRunner(
        config=_config(mode),
        match_init=assemblies[mode],
        adapters=adapters,
        bridge=bridge,
        artifact_finalizer=finalizer,
    )

    result = await runner.run()

    assert result.terminal.disposition == "victory"
    assert len(bridge.fixed_commits) == len(bridge.fixed_reveals) == 1
    assert [row["status"] for row in bridge.statuses] == ["thinking", "thinking"]
    assert len(result.trace.fixed_opportunities) == 1
    assert len(result.trace.action_receipts) == 1
    assert len(result.trace.acknowledged_action_batches) == 2
    protected_batch = strict_json_loads(
        result.trace.acknowledged_action_batches[0].canonical_batch_bytes
    )
    assert protected_batch["working_memory"] == "protected memory slot 0"
    assert "protected memory slot 0" not in repr(result.trace)
    assert result.trace.action_receipts[0]["application_tick"] == 1
    assert result.trace.continuous_gates == ()
    assert finalizer.traces == [result.trace]
    assert bridge.artifacts == [result.artifact]
    assert len(adapters[0].requests) == len(adapters[1].requests) == 1


@pytest.mark.asyncio
async def test_continuous_live_runner_quantizes_and_applies_before_terminal(
    assemblies: Dict[str, MatchInitAssembly],
) -> None:
    mode = "continuous_realtime"
    clock = FakeClock()
    bridge = FakeLiveBridge(mode=mode, assembly=assemblies[mode])
    adapters = {slot: ImmediateAdapter(slot, mode) for slot in (0, 1)}
    runner = DuelLiveMatchRunner(
        config=_config(mode),
        match_init=assemblies[mode],
        adapters=adapters,
        bridge=bridge,
        artifact_finalizer=RecordingFinalizer(),
        monotonic_ns=clock,
        sleep=clock.sleep,
    )

    result = await runner.run()

    assert result.terminal.winner_slot == 1
    assert result.trace.match_start_monotonic_ns == START_NS
    assert len(result.trace.continuous_dispatches) == 1
    assert len(result.trace.continuous_gates) == 1
    assert len(result.trace.action_receipts) == 1
    assert len(result.trace.acknowledged_action_batches) == 2
    assert all(
        value.decision_mode == "continuous_realtime"
        for value in result.trace.acknowledged_action_batches
    )
    assert result.trace.continuous_gates[0].gate_tick == 1
    assert len(bridge.continuous_requests) == 1
    request = bridge.continuous_requests[0]
    assert request.application_tick == 1
    assert [value.player_slot for value in request.applications] == [0, 1]
    assert bridge.dispositions == []
    assert bridge.continuous_clock_starts == 1
    assert [row["status"] for row in bridge.statuses] == ["thinking", "thinking"]
    assert bridge.artifacts == [result.artifact]


@pytest.mark.asyncio
async def test_fixed_live_runner_retains_acknowledged_deterministic_fallback_no_op(
    assemblies: Dict[str, MatchInitAssembly],
) -> None:
    mode = "fixed_simultaneous"
    bridge = FakeLiveBridge(mode=mode, assembly=assemblies[mode])
    runner = DuelLiveMatchRunner(
        config=_config(mode),
        match_init=assemblies[mode],
        adapters={0: RefusingAdapter(), 1: ImmediateAdapter(1, mode)},
        bridge=bridge,
        artifact_finalizer=RecordingFinalizer(),
    )

    result = await runner.run()

    fallback = result.trace.acknowledged_action_batches[0]
    body = strict_json_loads(fallback.canonical_batch_bytes)
    assert result.trace.fixed_opportunities[0].player_results[0].used_fallback
    assert body["client_batch_id"].startswith("gateway_noop_0_0_")
    assert body["commands"] == []
    assert body["based_on_observation_hash"] == fallback.observation_hash


@pytest.mark.asyncio
async def test_match_init_byte_mismatch_fails_before_any_provider_dispatch(
    assemblies: Dict[str, MatchInitAssembly],
) -> None:
    mode = "fixed_simultaneous"
    bridge = FakeLiveBridge(
        mode=mode,
        assembly=assemblies[mode],
        match_init_override=b'{"message_type":"match_init"}',
    )
    adapters = {slot: ImmediateAdapter(slot, mode) for slot in (0, 1)}
    finalizer = RecordingFinalizer()
    runner = DuelLiveMatchRunner(
        config=_config(mode),
        match_init=assemblies[mode],
        adapters=adapters,
        bridge=bridge,
        artifact_finalizer=finalizer,
    )

    with pytest.raises(LiveMatchInfrastructureError, match="MATCH_INIT bytes"):
        await runner.run()

    assert adapters[0].requests == adapters[1].requests == []
    assert finalizer.traces == []
    assert bridge.artifacts == []


@pytest.mark.asyncio
async def test_continuous_double_failure_threshold_is_declared_to_authority(
    assemblies: Dict[str, MatchInitAssembly],
) -> None:
    mode = "continuous_realtime"
    clock = FakeClock()
    bridge = FakeLiveBridge(mode=mode, assembly=assemblies[mode])
    scheduled = {
        50: _observation_pair(mode, sequence=1, tick=50),
        100: _observation_pair(mode, sequence=2, tick=100),
    }

    async def sleep_with_observations(seconds: float) -> None:
        await clock.sleep(seconds)
        completed_tick = (clock.value - START_NS) // 100_000_000
        for tick in sorted(tuple(scheduled)):
            if tick <= completed_tick:
                bridge.observations.put_nowait(scheduled.pop(tick))
        await asyncio.sleep(0)

    runner = DuelLiveMatchRunner(
        config=_config(mode),
        match_init=assemblies[mode],
        adapters={0: RefusingAdapter(), 1: RefusingAdapter()},
        bridge=bridge,
        artifact_finalizer=RecordingFinalizer(),
        monotonic_ns=clock,
        sleep=sleep_with_observations,
    )

    result = await runner.run()

    assert result.terminal.disposition == "draw"
    assert bridge.dispositions == [
        (
            ContinuousOpportunityDisposition.DRAW_DOUBLE_TECHNICAL_FORFEIT,
            "model_failure_threshold",
        )
    ]
    assert len(result.trace.continuous_dispatches) == 3
    assert all(len(adapter.requests) == 3 for adapter in runner.adapters.values())
    assert result.trace.continuous_gates[-1].gate_tick >= 181


@pytest.mark.asyncio
async def test_artifact_failure_never_acknowledges_match_completion(
    assemblies: Dict[str, MatchInitAssembly],
) -> None:
    mode = "fixed_simultaneous"
    bridge = FakeLiveBridge(mode=mode, assembly=assemblies[mode])
    runner = DuelLiveMatchRunner(
        config=_config(mode),
        match_init=assemblies[mode],
        adapters={slot: ImmediateAdapter(slot, mode) for slot in (0, 1)},
        bridge=bridge,
        artifact_finalizer=RecordingFinalizer(fail=True),
    )

    with pytest.raises(LiveMatchInfrastructureError, match="artifact sealing"):
        await runner.run()
    assert bridge.artifacts == []
