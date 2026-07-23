from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any, Mapping

import pytest
from genesis_arena.embodiment.protocol import canonical_json_bytes, strict_json_loads
from scripts import run_embodiment_live_duel_pilot as pilot


def _arguments(tmp_path: Path, **changes: object) -> argparse.Namespace:
    godot = tmp_path / "Godot"
    godot.write_bytes(b"binary")
    values: dict[str, object] = {
        "confirm_max_live_provider_calls": 8,
        "execute_live": True,
        "godot_executable": godot,
        "max_live_provider_calls": 8,
        "model_a": "gpt-test-a",
        "model_b": "gpt-test-b",
        "output_dir": tmp_path / "published",
        "preflight": False,
        "provider_a": "openai",
        "provider_b": "openai",
        "provider_timeout_s": 1.0,
        "reuse_entrant_a_key": False,
        "seed": 7,
        "series_timeout_s": 1.0,
    }
    values.update(changes)
    return argparse.Namespace(**values)


class _FakeGateway:
    port = 12345
    endpoint = object()

    async def __aenter__(self) -> _FakeGateway:
        return self

    async def __aexit__(self, *_: object) -> None:
        return None


class _FakeService:
    def __init__(self) -> None:
        self.created: Mapping[str, Any] | None = None
        self.closed = False

    async def create(self, **values: Any) -> Mapping[str, object]:
        self.created = values
        return {"series_id": "series_test"}

    async def status(self, _: str) -> Mapping[str, object]:
        return {"state": "completed"}

    async def result(self, _: str) -> Mapping[str, object]:
        return {"config": {}, "result": {}, "series_id": "series_test", "state": "completed"}

    async def aclose(self) -> None:
        self.closed = True


def test_preflight_is_env_only_and_never_reports_secret_values(tmp_path: Path) -> None:
    secret = "secret-value-that-must-never-appear"
    arguments = _arguments(tmp_path)
    missing = pilot.pilot_preflight(arguments, environ={})
    assert pilot._KEY_ENV["a"] in missing
    assert pilot._KEY_ENV["b"] in missing
    assert secret not in repr(missing)

    ready = pilot.pilot_preflight(
        arguments,
        environ={pilot._KEY_ENV["a"]: secret, pilot._KEY_ENV["b"]: secret},
    )
    assert ready == ()
    assert secret not in repr(ready)


def test_live_execution_requires_exact_budget_acknowledgement(tmp_path: Path) -> None:
    arguments = _arguments(tmp_path, confirm_max_live_provider_calls=7)
    missing = pilot.pilot_preflight(
        arguments,
        environ={pilot._KEY_ENV["a"]: "a", pilot._KEY_ENV["b"]: "b"},
    )
    assert "matching_provider_call_budget_acknowledgement" in missing


def test_key_reuse_is_forbidden_across_providers(tmp_path: Path) -> None:
    arguments = _arguments(
        tmp_path,
        provider_a="openai",
        provider_b="anthropic",
        reuse_entrant_a_key=True,
    )
    missing = pilot.pilot_preflight(
        arguments,
        environ={pilot._KEY_ENV["a"]: "openai-session-key"},
    )
    assert "same_provider_required_for_key_reuse" in missing


@pytest.mark.asyncio
async def test_success_is_atomic_canonical_and_credentials_are_not_persisted(
    tmp_path: Path,
) -> None:
    arguments = _arguments(tmp_path)
    service = _FakeService()
    secret_a = "live-secret-a"
    secret_b = "live-secret-b"

    async def collect(*_: object) -> tuple[dict[str, Any], bytes, bytes]:
        assert not arguments.output_dir.exists()
        return (
            {
                "series_id": "series_test",
                "status": "complete",
                "total_verified_provider_calls": 8,
            },
            canonical_json_bytes({"layer": "public"}),
            canonical_json_bytes({"layer": "protected"}),
        )

    output = await pilot.run_pilot(
        arguments,
        environ={pilot._KEY_ENV["a"]: secret_a, pilot._KEY_ENV["b"]: secret_b},
        service_factory=lambda **_: service,
        gateway_factory=_FakeGateway,
        evidence_collector=collect,
    )

    assert output == arguments.output_dir.resolve()
    assert service.closed is True
    assert service.created is not None
    entrants = service.created["entrants"]
    assert entrants[0]["api_key"] == secret_a
    assert entrants[1]["api_key"] == secret_b
    assert service.created["max_live_provider_calls"] == 8
    report_bytes = (output / "live-duel-report.json").read_bytes()
    report = strict_json_loads(report_bytes)
    assert canonical_json_bytes(report) == report_bytes
    all_bytes = b"".join(path.read_bytes() for path in output.iterdir())
    assert secret_a.encode() not in all_bytes
    assert secret_b.encode() not in all_bytes
    assert report["format"] == pilot.REPORT_FORMAT


@pytest.mark.asyncio
async def test_failed_evidence_collection_publishes_nothing(tmp_path: Path) -> None:
    arguments = _arguments(tmp_path)
    service = _FakeService()

    async def reject(*_: object) -> tuple[dict[str, Any], bytes, bytes]:
        raise pilot.PilotError("evidence_rejected")

    with pytest.raises(pilot.PilotError, match="evidence_rejected"):
        await pilot.run_pilot(
            arguments,
            environ={pilot._KEY_ENV["a"]: "a", pilot._KEY_ENV["b"]: "b"},
            service_factory=lambda **_: service,
            gateway_factory=_FakeGateway,
            evidence_collector=reject,
        )

    assert not arguments.output_dir.exists()
    assert not tuple(tmp_path.glob(".published.staging-*"))
    assert service.closed is True


@pytest.mark.asyncio
async def test_reused_key_is_an_explicit_single_environment_source(tmp_path: Path) -> None:
    arguments = _arguments(tmp_path, reuse_entrant_a_key=True)
    service = _FakeService()

    async def collect(*_: object) -> tuple[dict[str, Any], bytes, bytes]:
        return ({"series_id": "series_test"}, b"public", b"protected")

    await pilot.run_pilot(
        arguments,
        environ={pilot._KEY_ENV["a"]: "one-session-key"},
        service_factory=lambda **_: service,
        gateway_factory=_FakeGateway,
        evidence_collector=collect,
    )
    assert service.created is not None
    entrants = service.created["entrants"]
    assert entrants[0]["api_key"] == entrants[1]["api_key"] == "one-session-key"
