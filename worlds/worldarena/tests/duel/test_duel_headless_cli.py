from __future__ import annotations

import hashlib
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest
from backend.genesis_arena.duel.artifacts import (
    decode_canonical_jsonl,
    decode_canonical_transcript,
)
from backend.genesis_arena.duel.canonical import canonical_json_bytes, strict_json_loads
from backend.genesis_arena.duel.match_init import MatchInitAssembler
from backend.genesis_arena.duel.models import MatchConfig
from backend.genesis_arena.duel.replay import (
    _public_events,
    _verify_checkpoint_contract,
    _verify_compiled_sources,
)
from backend.genesis_arena.duel.schema_validation import DuelSchemaValidator
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
CLI_SCRIPT = "res://scripts/duel/match/duel_headless_cli.gd"


@dataclass(frozen=True)
class HeadlessCase:
    root: Path
    input_path: Path
    transcript_path: Path
    input_sha256: str
    output_a: Path
    output_b: Path
    run_a: subprocess.CompletedProcess[str]
    run_b: subprocess.CompletedProcess[str]


def _config() -> MatchConfig:
    return MatchConfig(
        decision_mode="fixed_simultaneous",
        faction_preset_id="vanguard-v1",
        seed=12_345,
        decision_period_ticks=100,
        response_deadline_ms=45_000,
        players=[
            {
                "slot": 0,
                "model": "offline-model-a",
                "reasoning": "benchmark",
                "provider_adapter": "offline",
            },
            {
                "slot": 1,
                "model": "offline-model-b",
                "reasoning": "benchmark",
                "provider_adapter": "offline",
            },
        ],
    )


def _headless_spec(*, transcript: list[dict[str, Any]]) -> dict[str, Any]:
    config = _config()
    config_value = config.model_dump(mode="json")
    match_init = MatchInitAssembler().assemble(
        config,
        match_id="m_headless-certification",
        engine_build_id="godot-4.5.stable.official.876b29033",
        engine_build_sha256=(
            "39b904eb0014941330f6435796ae0a041979802047495eb6fb87d59f327de719"
        ),
    ).message.model_dump(mode="json")
    return {
        "authority": {
            "alias_salt_seat_0_hex": "20" * 32,
            "alias_salt_seat_1_hex": "30" * 32,
            "default_commit_salt_seat_0_hex": "40" * 32,
            "default_commit_salt_seat_1_hex": "50" * 32,
            "tie_key_hex": "10" * 32,
        },
        "completion": {
            "fill_missing_with_noop": True,
            "post_first_application_disposition": "technical_forfeit_slot_1",
        },
        "locks": {
            "match_config_sha256": hashlib.sha256(
                canonical_json_bytes(config_value)
            ).hexdigest(),
            "match_init_sha256": hashlib.sha256(
                canonical_json_bytes(match_init)
            ).hexdigest(),
            "transcript_sha256": hashlib.sha256(
                canonical_json_bytes(transcript)
            ).hexdigest(),
        },
        "match_config": config_value,
        "match_init": match_init,
        "schema_version": "worldeval-rts/headless-run/1.0.0",
    }


def _launch(
    input_path: Path,
    input_sha256: str,
    output_dir: Path,
    *,
    transcript_path: Path | None,
    environment_only: bool = False,
) -> subprocess.CompletedProcess[str]:
    base = [str(GODOT), "--headless", "--path", str(ROOT / "godot"), "--script", CLI_SCRIPT]
    env = os.environ.copy()
    if environment_only:
        env.update(
            {
                "WORLDARENA_DUEL_HEADLESS_INPUT": str(input_path),
                "WORLDARENA_DUEL_HEADLESS_INPUT_SHA256": input_sha256,
                "WORLDARENA_DUEL_HEADLESS_OUTPUT_DIR": str(output_dir),
            }
        )
        if transcript_path is not None:
            env["WORLDARENA_DUEL_HEADLESS_TRANSCRIPT"] = str(transcript_path)
        command = base
    else:
        command = [
            *base,
            "--",
            f"--input={input_path}",
            f"--expected-input-sha256={input_sha256}",
            f"--output-dir={output_dir}",
        ]
        if transcript_path is not None:
            command.append(f"--transcript={transcript_path}")
    return subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        check=False,
        capture_output=True,
        text=True,
        timeout=180,
    )


@pytest.fixture(scope="module")
def completed_case(tmp_path_factory: pytest.TempPathFactory) -> HeadlessCase:
    if not GODOT.is_file():
        pytest.skip("pinned Godot 4.5 binary is not installed")
    root = tmp_path_factory.mktemp("duel-headless-cli")
    transcript: list[dict[str, Any]] = []
    spec = _headless_spec(transcript=transcript)
    input_bytes = canonical_json_bytes(spec)
    input_path = root / "headless-run.json"
    transcript_path = root / "actions.json"
    input_path.write_bytes(input_bytes)
    transcript_path.write_bytes(canonical_json_bytes(transcript))
    digest = hashlib.sha256(input_bytes).hexdigest()
    output_a = root / "output-a"
    output_b = root / "output-b"
    run_a = _launch(input_path, digest, output_a, transcript_path=transcript_path)
    # The omitted transcript path is canonical [] and exercises the documented env-only launch.
    run_b = _launch(
        input_path,
        digest,
        output_b,
        transcript_path=None,
        environment_only=True,
    )
    assert run_a.returncode == 0, run_a.stdout + run_a.stderr
    assert run_b.returncode == 0, run_b.stdout + run_b.stderr
    return HeadlessCase(
        root=root,
        input_path=input_path,
        transcript_path=transcript_path,
        input_sha256=digest,
        output_a=output_a,
        output_b=output_b,
        run_a=run_a,
        run_b=run_b,
    )


def test_headless_cli_emits_schema_valid_authority_evidence(completed_case: HeadlessCase) -> None:
    output = completed_case.output_a
    assert {path.name for path in output.iterdir()} == {
        "accepted-actions.ndjson",
        "action-receipts.ndjson",
        "compiled-orders.ndjson",
        "public-events.ndjson",
        "replay-manifest.json",
        "state-checkpoints.json",
        "terminal-result.json",
    }
    manifest = strict_json_loads((output / "replay-manifest.json").read_bytes())
    assert isinstance(manifest, dict)
    DuelSchemaValidator().validate("replay-manifest.v1.schema.json", manifest)
    assert manifest["terminal"] == {
        "reason": "model_failure",
        "result": "technical_forfeit",
        "tick": 1,
        "winner_player_id": "player_a",
    }
    assert manifest["aggregate_usage"]["player_a"]["requests"] == 0
    assert manifest["aggregate_usage"]["player_b"]["requests"] == 0
    assert manifest["players"][0]["provider_tier"] == "offline-transcript"

    for descriptor in manifest["files"]:
        payload = (output / descriptor["path"]).read_bytes()
        assert len(payload) == descriptor["bytes"]
        assert hashlib.sha256(payload).hexdigest() == descriptor["sha256"]
    for event in decode_canonical_jsonl((output / "public-events.ndjson").read_bytes()):
        DuelSchemaValidator().validate("event.v1.schema.json", event)

    accepted = decode_canonical_transcript((output / "accepted-actions.ndjson").read_bytes())
    compiled = decode_canonical_transcript((output / "compiled-orders.ndjson").read_bytes())
    events = _public_events((output / "public-events.ndjson").read_bytes())
    _verify_compiled_sources(accepted, compiled)
    _verify_checkpoint_contract(
        checkpoints=manifest["checkpoints"],
        accepted=accepted,
        compiled=compiled,
        events=events,
        terminal_tick=manifest["terminal"]["tick"],
        final_state_sha256=manifest["final_state_sha256"],
    )
    assert len(accepted) == 2
    assert not compiled
    assert all(row["receipt"]["batch_status"] == "no_op" for row in accepted)
    public_bytes = b"".join(path.read_bytes() for path in sorted(output.iterdir()))
    for secret in (b"10" * 32, b"20" * 32, b"30" * 32, b"40" * 32, b"50" * 32):
        assert secret not in public_bytes


def test_headless_cli_is_byte_deterministic_for_same_locked_run(
    completed_case: HeadlessCase,
) -> None:
    names_a = sorted(path.name for path in completed_case.output_a.iterdir())
    names_b = sorted(path.name for path in completed_case.output_b.iterdir())
    assert names_a == names_b
    for name in names_a:
        assert (completed_case.output_a / name).read_bytes() == (
            completed_case.output_b / name
        ).read_bytes()


@pytest.mark.parametrize(
    "corruption",
    [
        "engine_build",
        "input_hash",
        "match_config_lock",
        "player_metadata",
        "transcript_lock",
    ],
)
def test_headless_cli_fails_closed_before_output_on_locked_input_corruption(
    tmp_path: Path, corruption: str
) -> None:
    if not GODOT.is_file():
        pytest.skip("pinned Godot 4.5 binary is not installed")
    transcript: list[dict[str, Any]] = []
    spec = _headless_spec(transcript=transcript)
    if corruption == "match_config_lock":
        spec["match_config"]["seed"] += 1
    if corruption == "player_metadata":
        spec["match_config"]["players"][0]["model"] = "m" * 201
        spec["locks"]["match_config_sha256"] = hashlib.sha256(
            canonical_json_bytes(spec["match_config"])
        ).hexdigest()
    if corruption == "engine_build":
        spec["match_init"]["artifacts"]["engine_build"] = {
            "id": "godot-4.5.stable.official.tampered",
            "sha256": "a" * 64,
        }
        spec["locks"]["match_init_sha256"] = hashlib.sha256(
            canonical_json_bytes(spec["match_init"])
        ).hexdigest()
    if corruption == "transcript_lock":
        transcript = [{"tampered": True}]
    input_bytes = canonical_json_bytes(spec)
    input_path = tmp_path / "input.json"
    transcript_path = tmp_path / "transcript.json"
    input_path.write_bytes(input_bytes)
    transcript_path.write_bytes(canonical_json_bytes(transcript))
    digest = hashlib.sha256(input_bytes).hexdigest()
    if corruption == "input_hash":
        digest = "f" * 64
    output = tmp_path / "output"
    run = _launch(input_path, digest, output, transcript_path=transcript_path)
    assert run.returncode in {2, 3}
    assert not output.exists()
    assert "worldarena_duel_headless_error" in run.stdout


def test_headless_cli_rejects_continuous_mode_instead_of_inventing_arrival_timing(
    tmp_path: Path,
) -> None:
    if not GODOT.is_file():
        pytest.skip("pinned Godot 4.5 binary is not installed")
    transcript: list[dict[str, Any]] = []
    spec = _headless_spec(transcript=transcript)
    spec["match_config"]["decision_mode"] = "continuous_realtime"
    spec["match_config"]["response_deadline_ms"] = 8_000
    spec["locks"]["match_config_sha256"] = hashlib.sha256(
        canonical_json_bytes(spec["match_config"])
    ).hexdigest()
    input_bytes = canonical_json_bytes(spec)
    input_path = tmp_path / "input.json"
    input_path.write_bytes(input_bytes)
    output = tmp_path / "output"
    run = _launch(
        input_path,
        hashlib.sha256(input_bytes).hexdigest(),
        output,
        transcript_path=None,
    )
    assert run.returncode == 3
    assert not output.exists()
    assert "fixed headless runner" in run.stdout
