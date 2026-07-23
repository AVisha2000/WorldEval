from __future__ import annotations

import asyncio
import stat
import subprocess
import sys
from dataclasses import replace
from pathlib import Path

import pytest
from genesis_arena.duel.canonical import canonical_json_bytes, strict_json_loads
from genesis_arena.duel.godot_process_launcher import (
    MANAGED_AUTHORITY_SCHEMA_VERSION,
    DuelGodotProcessLaunchError,
    GodotManagedProcessLauncher,
)
from genesis_arena.duel.match_init import MatchInitAssembler
from genesis_arena.duel.match_service import (
    FROZEN_DUEL_ENGINE_BUILD_ID,
    FROZEN_DUEL_ENGINE_BUILD_SHA256,
    GodotDuelLaunchSpec,
)
from genesis_arena.duel.models import MatchConfig

ROOT = Path(__file__).resolve().parents[2]
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
PROJECT = ROOT / "godot"


def _spec() -> GodotDuelLaunchSpec:
    match_id = "m_0123456789abcdef0123456789abcdef"
    config = MatchConfig(
        decision_mode="fixed_simultaneous",
        faction_preset_id="vanguard-v1",
        seed=42,
        decision_period_ticks=100,
        response_deadline_ms=45_000,
        players=[
            {
                "slot": 0,
                "model": "managed-test-a",
                "reasoning": "none",
                "provider_adapter": "baseline-noop-v1",
            },
            {
                "slot": 1,
                "model": "managed-test-b",
                "reasoning": "none",
                "provider_adapter": "baseline-noop-v1",
            },
        ],
    )
    assembly = MatchInitAssembler().assemble(
        config,
        match_id=match_id,
        engine_build_id=FROZEN_DUEL_ENGINE_BUILD_ID,
        engine_build_sha256=FROZEN_DUEL_ENGINE_BUILD_SHA256,
    )
    match_init = strict_json_loads(assembly.canonical_bytes)
    artifacts = match_init["artifacts"]
    tie_key = bytearray(range(32))
    hashes = {
        "engine_build_hash": artifacts["engine_build"]["sha256"],
        "faction_hash": match_init["faction"]["sha256"],
        "helper_hash": artifacts["helper"]["sha256"],
        "item_hash": artifacts["items"]["sha256"],
        "map_hash": match_init["map"]["sha256"],
        "neutral_hash": artifacts["neutrals"]["sha256"],
        "prompt_hash": artifacts["prompt"]["sha256"],
        "protocol_hash": artifacts["protocol"]["sha256"],
        "ruleset_hash": match_init["ruleset"]["sha256"],
        # The managed bootstrap only transports this value. The session validates it after the
        # authenticated match config arrives, outside these launcher-focused tests.
        "tie_key_commitment": "a" * 64,
    }
    ticket = "A" * 43
    return GodotDuelLaunchSpec(
        match_id=match_id,
        connection_id="godot-managed-test",
        protocol_hash=hashes["protocol_hash"],
        authoritative_hashes=hashes,
        scored=True,
        attachment_ticket=ticket,
        gateway_url=f"ws://127.0.0.1:9/ws/duel/{ticket}",
        session_secret=bytearray(range(32, 64)),
        match_init_json=bytearray(assembly.canonical_bytes),
        tie_key=tie_key,
        alias_salt_seat_0=bytearray(range(64, 96)),
        alias_salt_seat_1=bytearray(range(96, 128)),
    )


def _write_fake_godot(path: Path, body: str) -> None:
    path.write_text(f"#!{sys.executable}\n{body}", encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


@pytest.mark.asyncio
async def test_launcher_uses_only_stdin_and_scrubs_one_use_material(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    executable = tmp_path / "fake-godot"
    _write_fake_godot(
        executable,
        """import json, os, sys, time
raw = sys.stdin.buffer.read()
value = json.loads(raw)
canonical = json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()
assert raw == canonical
assert value["schema_version"] == "worldeval-rts/managed-authority-launch/1.0.0"
launch = value["launch"]
argv = json.dumps(sys.argv)
environment = json.dumps(dict(os.environ))
assert launch["gateway_url"] not in argv and launch["gateway_url"] not in environment
assert launch["match_id"] not in argv and launch["match_id"] not in environment
assert "OPENAI_API_KEY" not in os.environ
print(json.dumps({
    "kind": "worldarena_duel_managed_started",
    "match_id": launch["match_id"],
    "schema_version": "worldeval-rts/managed-authority-launch/1.0.0",
}, separators=(",", ":"), sort_keys=True), flush=True)
time.sleep(30)
""",
    )
    monkeypatch.setenv("OPENAI_API_KEY", "must-not-enter-godot")
    spec = _spec()
    launcher = GodotManagedProcessLauncher(
        executable=executable,
        project_path=PROJECT,
        startup_timeout_s=3,
        shutdown_timeout_s=1,
    )

    handle = await launcher.launch(spec)
    assert handle.pid is not None
    assert spec.session_secret == bytearray()
    assert spec.match_init_json == bytearray()
    assert spec.tie_key == bytearray()
    assert spec.alias_salt_seat_0 == bytearray()
    assert spec.alias_salt_seat_1 == bytearray()
    await handle.stop()
    await handle.stop()


@pytest.mark.asyncio
async def test_launcher_rejects_non_loopback_before_spawn_and_still_scrubs() -> None:
    spec = replace(
        _spec(),
        gateway_url=f"ws://203.0.113.7:8000/ws/duel/{'A' * 43}",
    )
    launcher = GodotManagedProcessLauncher(
        executable=Path(sys.executable),
        project_path=PROJECT,
    )

    with pytest.raises(DuelGodotProcessLaunchError) as caught:
        await launcher.launch(spec)
    assert caught.value.code == "duel_godot_gateway_not_loopback"
    assert spec.session_secret == bytearray()
    assert spec.tie_key == bytearray()


@pytest.mark.asyncio
async def test_launcher_maps_bootstrap_rejection_to_stable_code(tmp_path: Path) -> None:
    executable = tmp_path / "rejecting-godot"
    _write_fake_godot(
        executable,
        """import json, sys
sys.stdin.buffer.read()
print(json.dumps({
    "code": "duel_godot_engine_mismatch",
    "kind": "worldarena_duel_managed_error",
    "schema_version": "worldeval-rts/managed-authority-launch/1.0.0",
}, separators=(",", ":"), sort_keys=True), flush=True)
""",
    )
    spec = _spec()
    launcher = GodotManagedProcessLauncher(
        executable=executable,
        project_path=PROJECT,
        startup_timeout_s=3,
        shutdown_timeout_s=1,
    )

    with pytest.raises(DuelGodotProcessLaunchError) as caught:
        await launcher.launch(spec)
    assert caught.value.code == "duel_godot_engine_mismatch"
    assert str(caught.value) == "duel_godot_engine_mismatch"
    assert spec.session_secret == bytearray()


@pytest.mark.asyncio
async def test_cancelled_stop_keeps_bounded_kill_and_reap_running(tmp_path: Path) -> None:
    if sys.platform == "win32":
        pytest.skip("SIGTERM escalation test is POSIX-specific")
    executable = tmp_path / "term-ignoring-godot"
    _write_fake_godot(
        executable,
        """import json, signal, sys, time
value = json.loads(sys.stdin.buffer.read())
signal.signal(signal.SIGTERM, signal.SIG_IGN)
print(json.dumps({
    "kind": "worldarena_duel_managed_started",
    "match_id": value["launch"]["match_id"],
    "schema_version": "worldeval-rts/managed-authority-launch/1.0.0",
}, separators=(",", ":"), sort_keys=True), flush=True)
time.sleep(30)
""",
    )
    spec = _spec()
    launcher = GodotManagedProcessLauncher(
        executable=executable,
        project_path=PROJECT,
        startup_timeout_s=3,
        shutdown_timeout_s=0.1,
    )
    handle = await launcher.launch(spec)

    first_stop = asyncio.create_task(handle.stop())
    await asyncio.sleep(0.01)
    first_stop.cancel()
    with pytest.raises(asyncio.CancelledError):
        await first_stop
    await asyncio.wait_for(handle.stop(), timeout=1)


@pytest.mark.asyncio
async def test_pinned_godot_accepts_real_pipe_bootstrap_and_is_owned() -> None:
    if not GODOT.is_file():
        pytest.skip("pinned Godot 4.5 binary is not installed")
    spec = _spec()
    expected_match_id = spec.match_id
    launcher = GodotManagedProcessLauncher(
        executable=GODOT,
        project_path=PROJECT,
        startup_timeout_s=10,
        shutdown_timeout_s=2,
    )

    handle = await launcher.launch(spec)
    assert expected_match_id not in repr(handle)
    assert spec.session_secret == bytearray()
    await handle.stop()


def test_managed_schema_constant_is_locked() -> None:
    assert MANAGED_AUTHORITY_SCHEMA_VERSION == "worldeval-rts/managed-authority-launch/1.0.0"
    assert canonical_json_bytes(
        {"launch": {}, "schema_version": MANAGED_AUTHORITY_SCHEMA_VERSION}
    ).startswith(b'{"launch":{}')


def test_pinned_godot_rejects_malformed_pipe_without_echoing_it() -> None:
    if not GODOT.is_file():
        pytest.skip("pinned Godot 4.5 binary is not installed")
    protected_marker = "must-never-be-printed-by-managed-bootstrap"
    run = subprocess.run(
        [
            str(GODOT),
            "--no-header",
            "--headless",
            "--path",
            str(PROJECT),
            "--script",
            "res://scripts/duel/match/duel_managed_authority_cli.gd",
        ],
        input=canonical_json_bytes({"unknown_protected_field": protected_marker}),
        check=False,
        capture_output=True,
        timeout=10,
    )

    output = (run.stdout + run.stderr).decode("utf-8", errors="replace")
    assert run.returncode == 2
    assert "duel_godot_bootstrap_input_rejected" in output
    assert protected_marker not in output


def test_project_disables_persistent_godot_file_logging() -> None:
    project = (PROJECT / "project.godot").read_text(encoding="utf-8")
    assert "file_logging/enable_file_logging=false" in project
    assert "file_logging/enable_file_logging.pc=false" in project
