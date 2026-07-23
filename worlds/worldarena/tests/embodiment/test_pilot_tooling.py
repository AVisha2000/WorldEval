from __future__ import annotations

import argparse
import hashlib
import json
import struct
import zlib
from pathlib import Path

from scripts import build_embodiment_browser_qa_report as browser
from scripts import intake_mixamo_y_bot as intake
from scripts import promote_embodiment_mvp_release as promotion
from scripts import run_embodiment_live_provider_pilot as providers
from scripts import run_embodiment_mvp_certification as certification


def _png_header(path: Path, width: int, height: int) -> None:
    def chunk(name: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + name
            + data
            + struct.pack(">I", zlib.crc32(name + data) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    rows = b"".join(b"\x00" + b"\x00" * (width * 3) for _ in range(height))
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(rows, 9))
        + chunk(b"IEND", b"")
    )


def test_provider_preflight_reports_names_without_secret_values(
    tmp_path: Path, monkeypatch
) -> None:
    godot = tmp_path / "Godot"
    godot.write_bytes(b"binary")
    monkeypatch.setattr(providers, "GODOT", godot)
    for names in providers._KEY_ENV.values():
        for name in names:
            monkeypatch.delenv(name, raising=False)
    models = {name: f"{name}-model" for name in providers.PROVIDERS}
    missing = providers.pilot_preflight(models)
    assert "OPENAI_API_KEY" in "/".join(missing)
    monkeypatch.setenv("OPENAI_API_KEY", "must-never-appear")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "must-never-appear")
    monkeypatch.setenv("GEMINI_API_KEY", "must-never-appear")
    assert providers.pilot_preflight(models) == ()
    assert "must-never-appear" not in repr(providers.pilot_preflight(models))


def test_provider_preflight_can_scope_a_noncertifying_single_provider_pilot(
    tmp_path: Path, monkeypatch
) -> None:
    godot = tmp_path / "Godot"
    godot.write_bytes(b"binary")
    monkeypatch.setattr(providers, "GODOT", godot)
    for names in providers._KEY_ENV.values():
        for name in names:
            monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("OPENAI_API_KEY", "must-never-appear")
    models = {"openai": "gpt-test", "anthropic": None, "gemini": None}
    assert providers.pilot_preflight(models, ("openai",)) == ()
    missing = providers.pilot_preflight(models)
    assert "ANTHROPIC_API_KEY" in "/".join(missing)
    assert "GEMINI_API_KEY" in "/".join(missing)
    assert "must-never-appear" not in repr(missing)


def test_accepted_action_count_uses_only_authority_decisions() -> None:
    replay = {
        "steps": [
            {
                "decision_window": {
                    "decisions": {
                        "participant_0": {"action": {"action_id": "a"}, "disposition": "accepted"}
                    }
                }
            },
            {
                "decision_window": {
                    "decisions": {
                        "participant_0": {"action": None, "disposition": "no_input"}
                    }
                }
            },
        ]
    }
    assert providers._accepted_actions(replay) == 1


def test_browser_report_requires_all_explicit_confirmations(tmp_path: Path) -> None:
    desktop = tmp_path / "desktop.png"
    mobile = tmp_path / "mobile.png"
    _png_header(desktop, 1440, 900)
    _png_header(mobile, 390, 844)
    values = {
        "base_url": "http://127.0.0.1:8000/",
        "confirm_hybrid_solo": True,
        "confirm_symmetric_duel": True,
        "desktop": desktop,
        "mobile": mobile,
        "output": tmp_path / "report.json",
        **{f"confirm_{name}": True for name in browser.CHECKS},
    }
    report = browser.build_report(argparse.Namespace(**values), source_fingerprint="a" * 64)
    assert report["format"] == browser.REPORT_FORMAT
    assert report["source_fingerprint"] == "a" * 64
    assert report["screenshots"]["desktop"]["sha256"] == hashlib.sha256(
        desktop.read_bytes()
    ).hexdigest()
    values["confirm_console_health"] = False
    try:
        browser.build_report(argparse.Namespace(**values), source_fingerprint="a" * 64)
    except ValueError as error:
        assert "explicit reviewer confirmation" in str(error)
    else:
        raise AssertionError("missing confirmation was accepted")
    desktop.write_bytes(desktop.read_bytes()[:-1])
    values["confirm_console_health"] = True
    try:
        browser.build_report(argparse.Namespace(**values), source_fingerprint="a" * 64)
    except ValueError as error:
        assert "PNG" in str(error)
    else:
        raise AssertionError("truncated PNG evidence was accepted")


def test_y_bot_manifest_builder_hashes_only_repository_files(
    tmp_path: Path, monkeypatch
) -> None:
    monkeypatch.setattr(intake, "ROOT", tmp_path)
    asset_dir = tmp_path / "godot/assets/external/mixamo"
    scene_dir = tmp_path / "godot/scenes/embodiment"
    asset_dir.mkdir(parents=True)
    scene_dir.mkdir(parents=True)
    base = asset_dir / "y-bot.fbx"
    base.write_bytes(b"base")
    scene = scene_dir / "y_bot_operator.tscn"
    scene.write_text("AnimationTree", encoding="utf-8")
    clips = []
    for name in sorted(intake.REQUIRED_Y_BOT_CLIPS):
        path = asset_dir / f"{name}.fbx"
        path.write_bytes(name.encode())
        clips.append(f"{name}={path}")
    arguments = argparse.Namespace(
        base=str(base),
        clip=clips,
        presentation_scene=str(scene),
        downloaded_at="2026-07-20T00:00:00Z",
        reviewed_at="2026-07-20T00:01:00Z",
        reviewer="reviewer",
        source_url="https://www.mixamo.com/",
        license_terms="Reviewed account terms.",
    )
    manifest = intake.build_manifest(arguments)
    assert manifest["base"]["sha256"] == hashlib.sha256(b"base").hexdigest()
    assert set(manifest["clips"]) == intake.REQUIRED_Y_BOT_CLIPS


def test_offline_promotion_gate_rejects_stale_report(tmp_path: Path, monkeypatch) -> None:
    del monkeypatch
    report = tmp_path / "offline.json"
    report.write_text(
        json.dumps(
            {
                "format": certification.REPORT_FORMAT,
                "offline_certification_passed": True,
                "source_fingerprint": "b" * 64,
                "results": [{"passed": True}],
            }
        ),
        encoding="utf-8",
    )
    assert promotion._offline_gate(report) == {
        "passed": False,
        "code": "offline_report_stale_or_invalid",
    }


def test_offline_promotion_gate_requires_exact_current_matrix(tmp_path: Path) -> None:
    expected = certification._expected_step_fingerprints()
    results = [
        {
            "duration_ms": 1,
            "fingerprint": fingerprint,
            "name": name,
            "passed": True,
            "resumed": False,
            "returncode": 0,
        }
        for name, fingerprint in sorted(expected.items())
    ]
    report = tmp_path / "offline.json"
    value = {
        "external_gates": {},
        "format": certification.REPORT_FORMAT,
        "mvp_certified": False,
        "offline_certification_passed": True,
        "results": results,
        "selected_steps_passed": True,
        "source_fingerprint": certification._certification_source_fingerprint(),
        "source_fingerprint_version": certification.SOURCE_FINGERPRINT_V2,
    }
    report.write_bytes(certification.canonical_json_bytes(value) + b"\n")
    assert promotion._offline_gate(report)["passed"] is True

    value.pop("source_fingerprint_version")
    report.write_bytes(certification.canonical_json_bytes(value) + b"\n")
    assert promotion._offline_gate(report) == {
        "passed": False,
        "code": "offline_report_stale_or_invalid",
    }

    value["source_fingerprint_version"] = certification.SOURCE_FINGERPRINT_V2
    value["results"].pop()
    report.write_bytes(certification.canonical_json_bytes(value) + b"\n")
    assert promotion._offline_gate(report) == {
        "passed": False,
        "code": "offline_report_stale_or_invalid",
    }


def test_readiness_report_is_fail_closed(monkeypatch) -> None:
    monkeypatch.setattr(promotion, "_certification_source_fingerprint", lambda: "c" * 64)
    monkeypatch.setattr(
        promotion,
        "validate_release_capabilities",
        lambda _: {"passed": False, "code": "not_released"},
    )
    report = promotion.readiness_report(
        {
            "offline": {"passed": True},
            "browser_visual_qa": {"passed": False, "code": "missing"},
        }
    )
    assert report["ready_for_promotion"] is False
    assert report["format"] == certification.READINESS_REPORT_FORMAT
    assert report["source_fingerprint"] == "c" * 64
    assert (
        report["source_fingerprint_version"]
        == certification.SOURCE_FINGERPRINT_V2
    )


def test_promotion_writes_package_bound_overlay_without_mutating_protocol(
    tmp_path: Path, monkeypatch
) -> None:
    release = tmp_path / "game/embodiment_release/worldarena.release.json"
    protocol_root = promotion.ROOT / "game/embodiment_protocol"
    protected = {
        path: path.read_bytes()
        for path in (
            protocol_root / "worldarena.environment.json",
            protocol_root / "protocol-lock.json",
            promotion.ROOT
            / "godot/scripts/embodiment/protocol/embodiment_protocol_package_identity.gd",
        )
    }
    monkeypatch.setattr(promotion, "RELEASE_MANIFEST", release)

    promotion._promote()
    first = release.read_bytes()
    promotion._promote()
    assert release.read_bytes() == first
    assert all(path.read_bytes() == payload for path, payload in protected.items())
    assert promotion.validate_release_capabilities(release)["passed"] is True

    release.write_text("{}\n", encoding="utf-8")
    try:
        promotion._promote()
    except ValueError as error:
        assert "incompatible release overlay" in str(error)
    else:
        raise AssertionError("conflicting release overlay was overwritten")
