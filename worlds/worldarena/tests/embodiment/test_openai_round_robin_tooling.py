from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
from typing import Mapping, Sequence

import pytest
from genesis_arena.embodiment.protocol import canonical_json_bytes, strict_json_loads
from scripts import run_embodiment_openai_round_robin as tournament


@pytest.fixture(autouse=True)
def _accept_synthetic_pair_evidence(monkeypatch: pytest.MonkeyPatch) -> None:
    """Keep orchestration fixtures small while production calls the complete validator."""

    monkeypatch.setattr(
        tournament,
        "validate_live_duel_report",
        lambda _: {"passed": True, "report_sha256": "0" * 64},
    )


def _arguments(tmp_path: Path, **changes: object) -> argparse.Namespace:
    godot = tmp_path / "Godot"
    python = tmp_path / "python"
    godot.write_bytes(b"godot")
    python.write_bytes(b"python")
    values: dict[str, object] = {
        "confirm_aggregate_max_live_provider_calls": 2160,
        "execute_live": True,
        "godot_executable": godot,
        "luna_model": "gpt-luna",
        "output_dir": tmp_path / "round-robin",
        "preflight": False,
        "provider_timeout_s": 1.0,
        "python_executable": python,
        "seed": 100,
        "series_timeout_s": 2.0,
        "sol_model": "gpt-sol",
        "terra_model": "gpt-terra",
    }
    values.update(changes)
    return argparse.Namespace(**values)


def _environment(secret: str = "session-only-openai-key") -> dict[str, str]:
    return {
        "PATH": "/usr/bin:/bin",
        "OPENAI_API_KEY": secret,
        "UNRELATED_SERVICE_TOKEN": "must-not-reach-child",
    }


def _option(command: Sequence[str], name: str) -> str:
    return command[command.index(name) + 1]


def _write_pair_report(command: Sequence[str]) -> None:
    output = Path(_option(command, "--output-dir"))
    output.mkdir(parents=True)
    public_bytes = canonical_json_bytes({"layer": "public"})
    protected_bytes = canonical_json_bytes({"layer": "protected"})
    (output / "series.public.json").write_bytes(public_bytes)
    (output / "series.protected.json").write_bytes(protected_bytes)
    seed = int(_option(command, "--seed"))
    report = {
        "format": tournament.DUEL_REPORT_FORMAT,
        "series": {
            "bundles": {
                "protected": {
                    "path": "series.protected.json",
                    "sha256": hashlib.sha256(protected_bytes).hexdigest(),
                },
                "public": {
                    "path": "series.public.json",
                    "sha256": hashlib.sha256(public_bytes).hexdigest(),
                },
            },
            "draws": 0,
            "entrant_wins": [2, 0],
            "entrants": [
                {
                    "entrant_id": "entrant_0",
                    "model": _option(command, "--model-a"),
                    "provider": "openai",
                },
                {
                    "entrant_id": "entrant_1",
                    "model": _option(command, "--model-b"),
                    "provider": "openai",
                },
            ],
            "legs": [{"provider_failures": 0}, {"provider_failures": 0}],
            "max_live_provider_calls": 720,
            "mode": "model-duel-v0",
            "seed": seed,
            "series_id": f"series_{seed}",
            "status": "complete",
            "total_verified_provider_calls": 720,
            "winner_entrant_id": "entrant_0",
        },
    }
    (output / "live-duel-report.json").write_bytes(canonical_json_bytes(report))


def test_preflight_is_network_free_and_reports_names_not_values(tmp_path: Path) -> None:
    arguments = _arguments(tmp_path)
    secret = "never-print-this-key"
    missing = tournament.tournament_preflight(arguments, environ={})
    assert "OPENAI_API_KEY" in "/".join(missing)
    assert secret not in repr(missing)
    assert tournament.tournament_preflight(arguments, environ=_environment(secret)) == ()


@pytest.mark.parametrize(
    ("changes", "expected"),
    [
        ({"seed": 9_007_199_254_740_988}, "valid_three_pair_seed_range"),
        ({"provider_timeout_s": float("nan")}, "positive_timeouts"),
        ({"series_timeout_s": float("inf")}, "positive_timeouts"),
    ],
)
def test_preflight_rejects_invalid_derived_seeds_and_nonfinite_timeouts(
    tmp_path: Path, changes: dict[str, object], expected: str
) -> None:
    missing = tournament.tournament_preflight(
        _arguments(tmp_path, **changes), environ=_environment()
    )
    assert expected in missing


@pytest.mark.asyncio
async def test_exact_aggregate_confirmation_is_checked_before_any_child(
    tmp_path: Path,
) -> None:
    arguments = _arguments(tmp_path, confirm_aggregate_max_live_provider_calls=2159)
    calls = 0

    async def runner(_: Sequence[str], __: Mapping[str, str]) -> int:
        nonlocal calls
        calls += 1
        return 0

    with pytest.raises(tournament.TournamentError, match="preflight_failed"):
        await tournament.run_tournament(arguments, environ=_environment(), runner=runner)
    assert calls == 0
    assert not arguments.output_dir.exists()


@pytest.mark.asyncio
async def test_runs_exact_three_unordered_pairs_and_atomically_publishes(
    tmp_path: Path,
) -> None:
    arguments = _arguments(tmp_path)
    secret = "session-only-openai-key"
    calls: list[tuple[tuple[str, ...], dict[str, str]]] = []

    async def runner(command: Sequence[str], env: Mapping[str, str]) -> int:
        calls.append((tuple(command), dict(env)))
        assert secret not in command
        assert env[tournament._DUEL_KEY_ENV_A] == secret
        assert "OPENAI_API_KEY" not in env
        assert "UNRELATED_SERVICE_TOKEN" not in env
        assert not arguments.output_dir.exists()
        _write_pair_report(command)
        return 0

    output = await tournament.run_tournament(
        arguments, environ=_environment(secret), runner=runner
    )

    assert len(calls) == 3
    assert [
        (_option(command, "--model-a"), _option(command, "--model-b"))
        for command, _ in calls
    ] == [("gpt-sol", "gpt-terra"), ("gpt-sol", "gpt-luna"), ("gpt-terra", "gpt-luna")]
    for command, _ in calls:
        assert _option(command, "--max-live-provider-calls") == "720"
        assert _option(command, "--confirm-max-live-provider-calls") == "720"
        assert "--reuse-entrant-a-key" in command
    report_bytes = (output / "round-robin-report.json").read_bytes()
    report = strict_json_loads(report_bytes)
    assert canonical_json_bytes(report) == report_bytes
    assert report["format"] == tournament.REPORT_FORMAT
    assert report["aggregate_max_live_provider_calls"] == 2160
    assert report["total_verified_provider_calls"] == 2160
    assert [value["pair_id"] for value in report["pairings"]] == [
        "sol-vs-terra",
        "sol-vs-luna",
        "terra-vs-luna",
    ]
    manifest_bytes = (output / "tournament.manifest.json").read_bytes()
    manifest = strict_json_loads(manifest_bytes)
    assert canonical_json_bytes(manifest) == manifest_bytes
    assert manifest == {
        "format": tournament.MANIFEST_FORMAT,
        "report": {
            "path": "round-robin-report.json",
            "sha256": hashlib.sha256(report_bytes).hexdigest(),
        },
        "status": "complete",
    }
    persisted = b"".join(path.read_bytes() for path in output.rglob("*") if path.is_file())
    assert secret.encode() not in persisted


@pytest.mark.asyncio
async def test_child_failure_removes_all_staged_pair_outputs(tmp_path: Path) -> None:
    arguments = _arguments(tmp_path)
    calls = 0

    async def runner(command: Sequence[str], _: Mapping[str, str]) -> int:
        nonlocal calls
        calls += 1
        if calls == 2:
            return 7
        _write_pair_report(command)
        return 0

    with pytest.raises(tournament.TournamentError, match="pair_execution_failed:sol-vs-luna"):
        await tournament.run_tournament(arguments, environ=_environment(), runner=runner)
    assert calls == 2
    assert not arguments.output_dir.exists()
    assert not tuple(tmp_path.glob(".round-robin.staging-*"))


@pytest.mark.asyncio
async def test_invalid_child_report_fails_closed(tmp_path: Path) -> None:
    arguments = _arguments(tmp_path)

    async def runner(command: Sequence[str], _: Mapping[str, str]) -> int:
        _write_pair_report(command)
        report = Path(_option(command, "--output-dir")) / "live-duel-report.json"
        report.write_bytes(b"{}")
        return 0

    with pytest.raises(tournament.TournamentError, match="pair_series_invalid"):
        await tournament.run_tournament(arguments, environ=_environment(), runner=runner)
    assert not arguments.output_dir.exists()
    assert not tuple(tmp_path.glob(".round-robin.staging-*"))


@pytest.mark.asyncio
async def test_full_pair_certification_failure_publishes_nothing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    arguments = _arguments(tmp_path)
    calls = 0

    async def runner(command: Sequence[str], _: Mapping[str, str]) -> int:
        nonlocal calls
        calls += 1
        _write_pair_report(command)
        return 0

    monkeypatch.setattr(
        tournament,
        "validate_live_duel_report",
        lambda _: {"passed": False, "code": "live_duel_protected_evidence_invalid"},
    )
    with pytest.raises(
        tournament.TournamentError,
        match=(
            "pair_certification_validation_failed:"
            "live_duel_protected_evidence_invalid"
        ),
    ):
        await tournament.run_tournament(
            arguments, environ=_environment(), runner=runner
        )
    assert calls == 1
    assert not arguments.output_dir.exists()
    assert not tuple(tmp_path.glob(".round-robin.staging-*"))
