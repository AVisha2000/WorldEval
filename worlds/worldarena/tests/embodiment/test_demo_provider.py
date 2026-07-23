from __future__ import annotations

import hashlib

import pytest
from genesis_arena.embodiment.demo_provider import DemoPolicyLock, DemoProvider
from genesis_arena.embodiment.protocol import canonical_json_bytes, strict_json_loads
from genesis_arena.embodiment.providers import (
    ProviderCallResult,
    ProviderFailureKind,
    ProviderRequest,
    ProviderTelemetry,
)
from genesis_arena.embodiment.scripted_construction_demo import (
    ScriptedConstructionDemoProvider,
)
from genesis_arena.embodiment.scripted_solo_demo import ScriptedSoloDemoProvider

FIXTURE = b"demo-fixture-v1"


def _lock(**overrides: object) -> DemoPolicyLock:
    values: dict[str, object] = {
        "scenario_id": "orientation-v0",
        "policy_id": "steady-visible-v1",
        "fixture_sha256": hashlib.sha256(FIXTURE).hexdigest(),
        "seed": 42,
        "participant_id": "participant_0",
        "model": "demo-model-v1",
        "total_decision_budget": 2,
    }
    values.update(overrides)
    return DemoPolicyLock(**values)  # type: ignore[arg-type]


def _request(**overrides: object) -> ProviderRequest:
    observation_seq = overrides.get("observation_seq", 0)
    episode_id = overrides.get("episode_id", "ep_demo_provider")
    observation = {
        "episode_id": episode_id,
        "frame": None,
        "goal": "Turn toward the visible beacon.",
        "observation_seq": observation_seq,
        "profile": "text-visible-v1",
    }
    values: dict[str, object] = {
        "episode_id": episode_id,
        "participant_id": "participant_0",
        "observation_seq": observation_seq,
        "deadline_monotonic_ns": 10_000,
        "model": "demo-model-v1",
        "system_prompt": "Return one strict action object.",
        "observation_json": canonical_json_bytes(observation),
        "action_schema_json": b'{"type":"object"}',
    }
    values.update(overrides)
    return ProviderRequest(**values)  # type: ignore[arg-type]


def test_policy_lock_is_canonical_hash_bound_and_strict() -> None:
    lock = _lock()

    assert lock.sha256 == hashlib.sha256(canonical_json_bytes(lock.as_dict())).hexdigest()
    assert lock.as_dict() == {
        "scenario_id": "orientation-v0",
        "policy_id": "steady-visible-v1",
        "fixture_sha256": hashlib.sha256(FIXTURE).hexdigest(),
        "seed": 42,
        "participant_id": "participant_0",
        "model": "demo-model-v1",
        "total_decision_budget": 2,
    }

    for changes, message in (
        ({"scenario_id": "bad id"}, "scenario_id"),
        ({"fixture_sha256": "0" * 63}, "fixture_sha256"),
        ({"seed": True}, "seed"),
        ({"total_decision_budget": 0}, "total_decision_budget"),
    ):
        with pytest.raises(ValueError, match=message):
            _lock(**changes)


def test_provider_optionally_verifies_the_locked_fixture_material() -> None:
    DemoProvider(_lock(), fixture_bytes=FIXTURE)
    with pytest.raises(ValueError, match="fixture_bytes"):
        DemoProvider(_lock(), fixture_bytes=b"different")
    with pytest.raises(TypeError, match="immutable bytes"):
        DemoProvider(_lock(), fixture_bytes="not-bytes")  # type: ignore[arg-type]


@pytest.mark.asyncio
async def test_default_demo_policy_emits_canonical_neutral_raw_output() -> None:
    provider = DemoProvider(_lock(), monotonic_ns=lambda: 1)

    result = await provider.request(_request())

    assert result.failure is None
    assert result.raw_output is not None
    assert canonical_json_bytes(strict_json_loads(result.raw_output)) == result.raw_output
    assert strict_json_loads(result.raw_output) == {
        "action_id": "demo_000000",
        "control": {
            "buttons": {
                "ability_1": False,
                "ability_2": False,
                "cancel": False,
                "cycle_item": False,
                "dash": False,
                "guard": False,
                "interact": False,
                "primary": False,
            },
            "duration_ticks": 1,
            "look_x": 0,
            "look_y": 0,
            "move_x": 0,
            "move_y": 0,
        },
        "episode_id": "ep_demo_provider",
        "intent_label": "Demo: wait",
        "memory_update": "",
        "observation_seq": 0,
        "protocol_version": "llm-controller/0.1.0",
    }
    assert provider.decision_count == 1


@pytest.mark.asyncio
async def test_demo_provider_enforces_participant_model_and_decision_budget() -> None:
    provider = DemoProvider(_lock(total_decision_budget=1), monotonic_ns=lambda: 1)

    with pytest.raises(ValueError, match="participant"):
        await provider.request(_request(participant_id="participant_1"))
    with pytest.raises(ValueError, match="model"):
        await provider.request(_request(model="other-model"))
    assert provider.decision_count == 0

    assert (await provider.request(_request())).failure is None
    exhausted = await provider.request(_request(observation_seq=1))
    assert exhausted.failure is ProviderFailureKind.INVALID_RESPONSE
    assert provider.decision_count == 1
    assert len(provider.audit_log.drain_episode("ep_demo_provider")) == 2


@pytest.mark.asyncio
async def test_demo_fixture_sequence_can_exercise_raw_and_sanitized_failures() -> None:
    stale = canonical_json_bytes({"episode_id": "ep_demo_provider", "observation_seq": 0})
    fixtures = (
        b"{malformed",
        stale,
        ProviderFailureKind.REFUSAL,
        ProviderFailureKind.TIMEOUT,
    )
    provider = DemoProvider(
        _lock(total_decision_budget=len(fixtures)),
        behavior=lambda _request, _lock, index: fixtures[index],
        monotonic_ns=lambda: 1,
    )

    results = [
        await provider.request(_request(observation_seq=index))
        for index in range(len(fixtures))
    ]

    assert results[0].raw_output == b"{malformed"
    assert results[1].raw_output == stale
    assert results[2].failure is ProviderFailureKind.REFUSAL
    assert results[3].failure is ProviderFailureKind.TIMEOUT


@pytest.mark.asyncio
async def test_oversized_fixture_and_expired_deadline_fail_without_sleeping() -> None:
    calls: list[int] = []
    provider = DemoProvider(
        _lock(total_decision_budget=2),
        behavior=lambda _request, _lock, index: calls.append(index) or b"x" * 5,
        monotonic_ns=lambda: 10,
    )

    oversized = await provider.request(_request(max_output_bytes=4))
    expired = await provider.request(_request(observation_seq=1, deadline_monotonic_ns=10))

    assert oversized.failure is ProviderFailureKind.OUTPUT_TOO_LARGE
    assert expired.failure is ProviderFailureKind.TIMEOUT
    assert calls == [0]
    assert provider.decision_count == 2


@pytest.mark.asyncio
async def test_injected_result_and_fixture_exception_stay_inside_provider_boundary() -> None:
    injected = ProviderCallResult.failed(
        ProviderFailureKind.TRANSPORT, ProviderTelemetry(latency_ms=0)
    )
    provider = DemoProvider(
        _lock(),
        behavior=lambda _request, _lock, index: injected
        if index == 0
        else (_ for _ in ()).throw(RuntimeError("fixture detail must not escape")),
        monotonic_ns=lambda: 1,
    )

    assert await provider.request(_request()) is injected
    failed = await provider.request(_request(observation_seq=1))
    assert failed.failure is ProviderFailureKind.INTERNAL


@pytest.mark.asyncio
async def test_local_scripted_delegate_uses_the_same_bounded_provider_boundary() -> None:
    delegate = ScriptedSoloDemoProvider("orientation-v0")
    lock = _lock(model=delegate.model)
    provider = DemoProvider(lock, delegate=delegate, monotonic_ns=lambda: 1)
    result = await provider.request(_request(model=delegate.model))
    # The deliberately minimal observation fails inside the real scripted policy, proving its
    # result crossed the ordinary provider boundary without substituting fixture output.
    assert result.failure is ProviderFailureKind.INVALID_RESPONSE

    with pytest.raises(ValueError, match="either behavior or delegate"):
        DemoProvider(lock, delegate=delegate, behavior=lambda *_args: b"{}")
    with pytest.raises(ValueError, match="exact trusted scripted"):
        DemoProvider(_lock(), delegate=object())


def test_spoofed_and_subclassed_scripted_delegates_are_rejected() -> None:
    class Spoof:
        provider_name = "scripted"

        async def request(self, _request: ProviderRequest) -> ProviderCallResult:
            return ProviderCallResult.success(b"{}", ProviderTelemetry(0))

    class ScriptedSubclass(ScriptedSoloDemoProvider):
        pass

    for delegate in (Spoof(), ScriptedSubclass("orientation-v0")):
        with pytest.raises(ValueError, match="exact trusted scripted"):
            DemoProvider(_lock(), delegate=delegate)


@pytest.mark.parametrize(
    "delegate",
    (
        ScriptedSoloDemoProvider("orientation-v0"),
        ScriptedConstructionDemoProvider(),
    ),
)
def test_only_exact_repository_scripted_provider_types_are_trusted(delegate: object) -> None:
    model = getattr(delegate, "model", "construction-demo-v1")
    DemoProvider(_lock(model=model), delegate=delegate)


@pytest.mark.asyncio
async def test_default_demo_evidence_is_identical_across_repeat_providers() -> None:
    first = DemoProvider(_lock())
    second = DemoProvider(_lock())
    first_result = await first.request(_request())
    second_result = await second.request(_request())

    assert first_result == second_result
    assert first_result.telemetry == ProviderTelemetry(latency_ms=0)
    assert first.audit_log.drain_episode("ep_demo_provider") == second.audit_log.drain_episode(
        "ep_demo_provider"
    )
