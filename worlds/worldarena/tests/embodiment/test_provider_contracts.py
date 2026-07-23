from __future__ import annotations

import json
from dataclasses import fields

import pytest
from genesis_arena.embodiment.providers.contracts import ProviderAuditRecord, ProviderRequest


def _request(**overrides: object) -> ProviderRequest:
    observation = {
        "episode_id": "ep_provider_budget",
        "frame": None,
        "goal": "Turn toward the beacon.",
        "observation_seq": 0,
        "profile": "text-visible-v1",
    }
    values: dict[str, object] = {
        "episode_id": "ep_provider_budget",
        "participant_id": "participant_0",
        "observation_seq": 0,
        "deadline_monotonic_ns": 1,
        "model": "model-v1",
        "system_prompt": "Return one action.",
        "observation_json": json.dumps(
            observation, sort_keys=True, separators=(",", ":")
        ).encode("utf-8"),
        "action_schema_json": b'{"type":"object"}',
        "scratchpad_utf8": b"move left",
        "max_input_bytes": 8_388_608,
        "max_output_bytes": 4_096,
    }
    values.update(overrides)
    return ProviderRequest(**values)  # type: ignore[arg-type]


def test_provider_request_counts_the_exact_shared_input_material() -> None:
    request = _request()

    assert request.input_bytes == sum(
        (
            len(request.system_prompt.encode("utf-8")),
            len(request.observation_json),
            len(request.action_schema_json),
            len(request.scratchpad_utf8),
        )
    )


def test_provider_request_rejects_material_over_the_locked_input_ceiling() -> None:
    request = _request()

    with pytest.raises(ValueError, match="exceeds max_input_bytes"):
        _request(max_input_bytes=request.input_bytes - 1)


@pytest.mark.parametrize("value", [True, 0, 67_108_865])
def test_provider_request_rejects_invalid_input_ceiling(value: object) -> None:
    with pytest.raises(ValueError, match="max_input_bytes"):
        _request(max_input_bytes=value)


def test_provider_audit_types_cannot_represent_credentials_or_headers() -> None:
    forbidden = {"api_key", "authorization", "credential", "credentials", "headers"}

    assert forbidden.isdisjoint(field.name for field in fields(ProviderRequest))
    assert forbidden.isdisjoint(field.name for field in fields(ProviderAuditRecord))
    with pytest.raises(TypeError):
        ProviderAuditRecord(  # type: ignore[call-arg]
            provider="openai",
            request=_request(),
            result=None,
            started_monotonic_ns=1,
            completed_monotonic_ns=2,
            headers={"authorization": "forbidden"},
        )
