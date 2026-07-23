from __future__ import annotations

import asyncio
from dataclasses import dataclass
from types import SimpleNamespace
from urllib.parse import urlsplit

import pytest
from genesis_arena.duel.godot_bridge import (
    GodotBridgeParticipantError,
    GodotBridgePhase,
    TerminalReport,
)
from genesis_arena.duel.live_match import LiveArtifactSeal
from genesis_arena.duel.match_service import (
    DuelCreateMatchRequest,
    DuelMatchNotFoundError,
    DuelMatchService,
    NoOpBaselineAdapterFactory,
    OpenAIResponsesAdapterFactory,
    ProviderAdapterConfig,
    RushBaselineAdapterFactory,
    SeededRandomBaselineAdapterFactory,
)
from genesis_arena.duel.provider_adapters import EndpointOwnership
from pydantic import SecretStr, ValidationError


class FakeProviderAdapter:
    endpoint_ownership = EndpointOwnership.ORGANIZER_HOSTED

    async def request(self, request):  # pragma: no cover - a fake runner never calls providers
        raise AssertionError(f"unexpected provider call: {request!r}")


class FakeProviderFactory:
    provider = "fake"
    adapter_id = "fake-duel-v1"

    def __init__(self) -> None:
        self.configs: list[ProviderAdapterConfig] = []
        self.credential_presence: list[bool] = []

    def build(
        self, config: ProviderAdapterConfig, *, credential: SecretStr | None
    ) -> FakeProviderAdapter:
        self.configs.append(config)
        self.credential_presence.append(credential is not None)
        return FakeProviderAdapter()


@dataclass
class FakeProcessHandle:
    stopped: bool = False

    async def stop(self) -> None:
        self.stopped = True


class FakeLauncher:
    def __init__(self, *, failure: Exception | None = None) -> None:
        self.failure = failure
        self.specs = []
        self.handles: list[FakeProcessHandle] = []

    async def launch(self, spec):
        self.specs.append(spec)
        if self.failure is not None:
            raise self.failure
        handle = FakeProcessHandle()
        self.handles.append(handle)
        return handle


class FakeBridge:
    def __init__(self, **kwargs) -> None:
        self.match_id = kwargs["match_id"]
        self.phase = GodotBridgePhase.AWAITING_HELLO
        self.disconnected = False

    def disconnect(self) -> None:
        self.disconnected = True
        if self.phase not in {GodotBridgePhase.COMPLETE, GodotBridgePhase.CLOSED}:
            self.phase = GodotBridgePhase.FAILED


class FakeWebSocket:
    def __init__(self, host: str = "127.0.0.1") -> None:
        self.client = SimpleNamespace(host=host)
        self.accepted = False
        self.close_codes: list[int] = []
        self.closed = asyncio.Event()

    async def accept(self) -> None:
        self.accepted = True

    async def close(self, *, code: int) -> None:
        self.close_codes.append(code)
        self.closed.set()


class FakeSocketAdapter:
    def __init__(self, bridge: FakeBridge, *, block_until_close: bool = False) -> None:
        self.bridge = bridge
        self.block_until_close = block_until_close

    async def handle(self, websocket: FakeWebSocket) -> None:
        await websocket.accept()
        self.bridge.phase = GodotBridgePhase.AUTHENTICATED
        if self.block_until_close:
            await websocket.closed.wait()
        else:
            await asyncio.sleep(0.03)


class FakeRunner:
    def __init__(self, owner: FakeRunnerFactory, kwargs) -> None:
        self.owner = owner
        self.kwargs = kwargs

    async def run(self):
        self.owner.started.set()
        if self.owner.block:
            await asyncio.Event().wait()
        if self.owner.failure is not None:
            raise self.owner.failure
        return SimpleNamespace(
            terminal=TerminalReport(
                disposition="victory",
                terminal_tick=731,
                result_hash="a" * 64,
                winner_slot=0,
                failure=None,
                body={},
            ),
            artifact=LiveArtifactSeal(
                artifact_hash="b" * 64,
                manifest={"credential": "must-not-reach-result-api"},
            ),
        )


class FakeRunnerFactory:
    def __init__(self, *, block: bool = False, failure: Exception | None = None) -> None:
        self.block = block
        self.failure = failure
        self.started = asyncio.Event()
        self.instances: list[FakeRunner] = []

    def __call__(self, **kwargs) -> FakeRunner:
        runner = FakeRunner(self, kwargs)
        self.instances.append(runner)
        return runner


class UnusedFinalizer:
    async def seal(self, trace):  # pragma: no cover - fake runners return a sealed result
        raise AssertionError(f"unexpected finalizer call: {trace!r}")


class CapturingFinalizerFactory:
    def __init__(self) -> None:
        self.calls = []
        self.finalizers: list[UnusedFinalizer] = []

    def __call__(
        self,
        *,
        match_id,
        config,
        provider_tiers,
        replay_authority_material,
    ):
        finalizer = UnusedFinalizer()
        self.finalizers.append(finalizer)
        self.calls.append(
            {
                "match_id": match_id,
                "config": config,
                "provider_tiers": dict(provider_tiers),
                "replay_authority_material": dict(replay_authority_material),
            }
        )
        return finalizer


def _request(
    *,
    mode: str = "fixed_simultaneous",
    authority_launch_mode: str = "managed_process",
    faction: str = "vanguard-v1",
    credential: str = "super-secret-participant-key",
) -> DuelCreateMatchRequest:
    ticks, deadline = (100, 45_000) if mode == "fixed_simultaneous" else (50, 8_000)
    return DuelCreateMatchRequest.model_validate(
        {
            "decision_mode": mode,
            "faction_preset_id": faction,
            "mirror_faction": True,
            "map_id": "crossroads-duel-v1",
            "seed": 91_339,
            "decision_period_ticks": ticks,
            "response_deadline_ms": deadline,
            "authority_launch_mode": authority_launch_mode,
            "players": [
                {
                    "slot": 0,
                    "provider": "fake",
                    "model": "explicit-model-a",
                    "reasoning": "medium",
                    "credential": credential,
                },
                {
                    "slot": 1,
                    "provider": "fake",
                    "model": "explicit-model-b",
                    "reasoning": "high",
                    "credential": credential,
                },
            ],
        }
    )


def _service(
    *,
    runner: FakeRunnerFactory | None = None,
    launcher: FakeLauncher | None = None,
    block_socket: bool = False,
    factories=None,
    finalizer_factory=None,
):
    provider = FakeProviderFactory()
    selected_factories = factories or {"fake": provider}
    selected_runner = runner or FakeRunnerFactory()
    selected_launcher = launcher or FakeLauncher()
    finalizer_options = (
        {"artifact_finalizer": UnusedFinalizer()}
        if finalizer_factory is None
        else {"artifact_finalizer_factory": finalizer_factory}
    )
    service = DuelMatchService(
        provider_factories=selected_factories,
        godot_launcher=selected_launcher,
        gateway_base_url="ws://127.0.0.1:8000",
        runner_factory=selected_runner,
        bridge_factory=FakeBridge,
        socket_adapter_factory=lambda bridge: FakeSocketAdapter(
            bridge, block_until_close=block_socket
        ),
        **finalizer_options,
    )
    return service, provider, selected_runner, selected_launcher


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("mode", "ticks", "deadline"),
    [
        ("fixed_simultaneous", 100, 45_000),
        ("continuous_realtime", 50, 8_000),
    ],
)
async def test_create_assembles_explicit_fixed_and_continuous_matches(
    mode: str, ticks: int, deadline: int
) -> None:
    service, provider, runner_factory, launcher = _service()
    created = await service.create_match(_request(mode=mode, faction="crypt-v1"))

    assert created.status.state == "awaiting_godot"
    assert created.status.config.decision_mode == mode
    assert created.status.config.faction_preset_id == "crypt-v1"
    assert created.status.config.mirror_faction is True
    assert created.status.config.decision_period_ticks == ticks
    assert created.status.config.response_deadline_ms == deadline
    assert [row.model for row in created.status.config.players] == [
        "explicit-model-a",
        "explicit-model-b",
    ]
    assert [row.model for row in provider.configs] == [
        "explicit-model-a",
        "explicit-model-b",
    ]
    assert provider.credential_presence == [True, True]
    config = runner_factory.instances[0].kwargs["config"]
    assert config.mirror_faction is True
    assert [player.provider_adapter for player in config.players] == [
        "fake-duel-v1",
        "fake-duel-v1",
    ]
    launch = launcher.specs[0]
    assert launch.scored is True
    assert launch.protocol_hash == launch.authoritative_hashes["protocol_hash"]
    assert launch.authoritative_hashes["tie_key_commitment"]
    await service.aclose()


@pytest.mark.asyncio
async def test_finalizer_factory_receives_isolated_per_match_audit_material() -> None:
    factory = CapturingFinalizerFactory()
    service, _, runner_factory, _ = _service(finalizer_factory=factory)
    raw = _request(authority_launch_mode="caller_owned").model_dump(mode="json")
    raw["players"][0]["service_tier"] = "priority"
    raw["players"][1]["service_tier"] = "flex"
    request = DuelCreateMatchRequest.model_validate(raw)

    first = await service.create_match(request)
    second = await service.create_match(request)

    assert [call["match_id"] for call in factory.calls] == [
        first.status.match_id,
        second.status.match_id,
    ]
    assert all(call["provider_tiers"] == {0: "priority", 1: "flex"} for call in factory.calls)
    for call in factory.calls:
        material = call["replay_authority_material"]
        assert set(material) == {"tie_key", "alias_salt_seat_0", "alias_salt_seat_1"}
        assert all(len(value) == 32 for value in material.values())
        assert material["alias_salt_seat_0"] != material["alias_salt_seat_1"]
    assert factory.calls[0]["replay_authority_material"] != factory.calls[1][
        "replay_authority_material"
    ]
    assert [instance.kwargs["artifact_finalizer"] for instance in runner_factory.instances] == (
        factory.finalizers
    )
    for created in (first, second):
        public_text = created.status.model_dump_json()
        for secret_value in factory.calls[
            0 if created is first else 1
        ]["replay_authority_material"].values():
            assert secret_value.hex() not in public_text
    await service.aclose()


def test_request_rejects_asymmetry_noncanonical_slots_and_nonofficial_cadence() -> None:
    raw = _request().model_dump(mode="json")
    raw["mirror_faction"] = False
    with pytest.raises(ValidationError):
        DuelCreateMatchRequest.model_validate(raw)

    raw = _request().model_dump(mode="json")
    raw["players"] = list(reversed(raw["players"]))
    with pytest.raises(ValidationError):
        DuelCreateMatchRequest.model_validate(raw)

    raw = _request().model_dump(mode="json")
    raw["decision_period_ticks"] = 50
    with pytest.raises(ValidationError):
        DuelCreateMatchRequest.model_validate(raw)


@pytest.mark.asyncio
async def test_credentials_and_launch_secrets_are_redacted_from_repr_status_and_result() -> None:
    secret = "sk-test-this-must-never-be-returned"
    request = _request(credential=secret)
    service, _, _, launcher = _service()
    created = await service.create_match(request)

    assert secret not in repr(request)
    assert secret not in repr(created)
    assert secret not in created.model_dump_json()
    assert secret not in repr(launcher.specs[0])
    assert launcher.specs[0].session_secret == bytearray()
    assert launcher.specs[0].tie_key == bytearray()
    status = await service.get_status(created.status.match_id)
    assert secret not in status.model_dump_json()
    assert "credential" not in status.model_dump_json()

    websocket = FakeWebSocket()
    attached = await service.attach_websocket(launcher.specs[0].attachment_ticket, websocket)
    assert attached is True
    result = await service.get_result(created.status.match_id)
    assert result.state == "completed"
    assert result.artifact_hash == "b" * 64
    assert "must-not-reach" not in result.model_dump_json()
    await service.aclose()


@pytest.mark.asyncio
async def test_caller_owned_launch_claim_is_loopback_only_single_use_and_exact() -> None:
    service, _, _, launcher = _service()
    created = await service.create_match(_request(authority_launch_mode="caller_owned"))
    assert launcher.specs == []
    assert created.launch_claim_token is not None
    assert created.launch_claim_token not in created.status.model_dump_json()

    with pytest.raises(DuelMatchNotFoundError):
        await service.claim_controller_launch(
            created.launch_claim_token, client_host="203.0.113.8"
        )
    fields = await service.claim_controller_launch(
        created.launch_claim_token, client_host="127.0.0.1"
    )
    assert set(fields.model_dump()) == {
        "authority",
        "connection_id",
        "gateway_url",
        "match_id",
        "match_init",
        "protocol_hash",
        "token",
    }
    assert set(fields.authority.model_dump()) == {
        "alias_salt_seat_0",
        "alias_salt_seat_1",
        "authoritative_hashes",
        "scored",
        "tie_key",
    }
    assert len(fields.token) == 32
    assert len(fields.authority.alias_salt_seat_0) == 32
    assert fields.match_init["match_id"] == created.status.match_id
    with pytest.raises(DuelMatchNotFoundError):
        await service.claim_controller_launch(
            created.launch_claim_token, client_host="127.0.0.1"
        )
    await service.aclose()


@pytest.mark.asyncio
async def test_websocket_attachment_ticket_binds_once() -> None:
    service, _, _, launcher = _service()
    created = await service.create_match(_request())
    ticket = launcher.specs[0].attachment_ticket
    first = FakeWebSocket()
    second = FakeWebSocket()

    first_task = asyncio.create_task(service.attach_websocket(ticket, first))
    await asyncio.sleep(0)
    assert await service.attach_websocket(ticket, second) is False
    assert second.close_codes == [4404]
    assert await first_task is True
    assert (await service.get_status(created.status.match_id)).state == "completed"
    await service.aclose()


@pytest.mark.asyncio
async def test_cancellation_stops_process_revokes_tickets_and_cleans_runtime() -> None:
    runner = FakeRunnerFactory(block=True)
    launcher = FakeLauncher()
    service, _, _, _ = _service(
        runner=runner, launcher=launcher, block_socket=True
    )
    created = await service.create_match(_request())
    ticket = launcher.specs[0].attachment_ticket
    websocket = FakeWebSocket()
    socket_task = asyncio.create_task(service.attach_websocket(ticket, websocket))
    await asyncio.wait_for(runner.started.wait(), 1)

    status = await service.cancel_match(created.status.match_id)
    assert status.state == "cancelled"
    assert status.attachment == "revoked"
    assert status.failure is not None
    assert status.failure.code == "cancelled_by_operator"
    assert launcher.handles[0].stopped is True
    assert 1012 in websocket.close_codes
    assert await socket_task is True
    result = await service.get_result(created.status.match_id)
    assert result.state == "cancelled"

    late = FakeWebSocket()
    assert await service.attach_websocket(ticket, late) is False
    assert late.close_codes == [4404]
    await service.aclose()


@pytest.mark.asyncio
async def test_bridge_failure_classification_is_preserved_without_exception_text() -> None:
    runner = FakeRunnerFactory(
        failure=GodotBridgeParticipantError(
            "credential_error", "raw provider exception contains a secret", hard=True
        )
    )
    service, _, _, launcher = _service(runner=runner)
    created = await service.create_match(_request())
    websocket = FakeWebSocket()
    await service.attach_websocket(launcher.specs[0].attachment_ticket, websocket)

    status = await service.get_status(created.status.match_id)
    assert status.state == "failed"
    assert status.failure is not None
    assert status.failure.model_dump(mode="json") == {
        "code": "credential_error",
        "owner": "participant_endpoint",
        "hard_model_failure": True,
    }
    assert "raw provider" not in status.model_dump_json()
    assert (await service.get_result(created.status.match_id)).state == "failed"
    await service.aclose()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("provider_name", "model_id", "factory_type"),
    [
        ("baseline.noop", "baseline-noop-v1", NoOpBaselineAdapterFactory),
        (
            "baseline.seeded_random",
            "baseline-seeded-random-v1",
            SeededRandomBaselineAdapterFactory,
        ),
        ("baseline.rush", "baseline-rush-v1", RushBaselineAdapterFactory),
    ],
)
async def test_credential_free_baseline_factories_have_explicit_adapter_ids(
    provider_name: str, model_id: str, factory_type
) -> None:
    factories = {provider_name: factory_type()}
    service, _, runner, _ = _service(factories=factories)
    raw = _request(authority_launch_mode="caller_owned").model_dump(mode="json")
    for slot, player in enumerate(raw["players"]):
        player.update(
            slot=slot,
            provider=provider_name,
            model=model_id,
            reasoning="none",
            credential=None,
        )
    created = await service.create_match(DuelCreateMatchRequest.model_validate(raw))
    config = runner.instances[0].kwargs["config"]
    assert [player.provider_adapter for player in config.players] == [model_id, model_id]
    assert created.launch_claim_token is not None
    await service.aclose()


def test_attachment_ticket_is_embedded_only_in_protected_launch_url() -> None:
    # This small pure check documents the controller-to-WebSocket handoff contract.
    example = "ws://127.0.0.1:8000/ws/duel/opaque-ticket"
    assert urlsplit(example).path.rsplit("/", 1)[-1] == "opaque-ticket"


def test_openai_factory_uses_exact_explicit_model_reasoning_and_credential(monkeypatch) -> None:
    captured = {}

    def fake_openai_adapter(**kwargs):
        captured.update(kwargs)
        return FakeProviderAdapter()

    monkeypatch.setattr(
        "genesis_arena.duel.match_service.OpenAIResponsesDuelAdapter",
        fake_openai_adapter,
    )
    config = ProviderAdapterConfig(
        slot=0,
        provider="openai",
        model="explicit-openai-model",
        reasoning="xhigh",
        endpoint_ownership=EndpointOwnership.PARTICIPANT_HOSTED,
        service_tier="priority",
        max_output_tokens=2_048,
        match_seed=7,
    )
    adapter = OpenAIResponsesAdapterFactory().build(
        config, credential=SecretStr("process-memory-key")
    )

    assert isinstance(adapter, FakeProviderAdapter)
    assert captured == {
        "model": "explicit-openai-model",
        "reasoning_effort": "xhigh",
        "service_tier": "priority",
        "max_output_tokens": 2_048,
        "endpoint_ownership": EndpointOwnership.PARTICIPANT_HOSTED,
        "api_key": "process-memory-key",
        "audit_sink": None,
    }
    assert "process-memory-key" not in repr(config)
