from __future__ import annotations

import hashlib
import importlib.util
import json
import struct
import subprocess
import zlib
from argparse import Namespace
from pathlib import Path
from types import SimpleNamespace

import pytest
from genesis_arena.embodiment.protocol import EmbodimentProtocolPackage
from genesis_arena.embodiment.replay import ReplayLedger
from genesis_arena.embodiment.source_fingerprint import (
    SOURCE_FINGERPRINT_V2,
    SourceComponent,
    browser_runtime_source_fingerprint,
    certification_source_fingerprint,
)
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
SPEC = importlib.util.spec_from_file_location(
    "embodiment_mvp_certification", ROOT / "scripts/run_embodiment_mvp_certification.py"
)
assert SPEC is not None and SPEC.loader is not None
certification = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(certification)


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _json(path: Path, value: object) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")), encoding="utf-8")
    return path


def _png(path: Path, width: int, height: int) -> Path:
    def chunk(name: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + name
            + data
            + struct.pack(">I", zlib.crc32(name + data) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    rows = b"".join(b"\x00" + b"\x00" * (width * 3) for _ in range(height))
    payload = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(rows, 9))
        + chunk(b"IEND", b"")
    )
    path.write_bytes(payload)
    return path


def _sealed_golden_replay(path: Path) -> Path:
    transcript = json.loads(
        (ROOT / "game/embodiment_protocol/golden/stage-a-orientation-forward-v1.json").read_text()
    )
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    ledger = ReplayLedger(
        transcript["config"], transcript["config_sha256"], package.package_sha256
    )
    ledger.record_initial(
        observations=transcript["initial_boundary"]["observations"],
        state_hash=transcript["initial_boundary"]["state_hash"],
    )
    for step in transcript["steps"]:
        ledger.record_step(decision_window=step["decision_window"], result=step["result"])
    path.write_bytes(
        ledger.seal(
            final_terminal=transcript["terminal_boundary"]["terminal"],
            final_state_hash=transcript["terminal_boundary"]["state_hash"],
        )
    )
    return path


def _replay(
    path: Path,
    *,
    episode_id: str,
    mode: str,
    task_id: str,
    windows: int,
    final_state_hash: str,
) -> Path:
    return _json(
        path,
        {
            "config": {
                "episode_id": episode_id,
                "mode": mode,
                "observation_profile": "hybrid-visible-v1",
                "task_id": task_id,
            },
            "final_state_hash": final_state_hash,
            "final_terminal": {"ended": True, "outcome": "success", "reason": "goal"},
            "steps": [{} for _ in range(windows)],
        },
    )


def _browser_report(tmp_path: Path) -> Path:
    desktop = _png(tmp_path / "desktop.png", 1440, 900)
    mobile = _png(tmp_path / "mobile.png", 390, 844)
    return _json(
        tmp_path / "browser.json",
        {
            "base_url": "http://127.0.0.1:5173/",
            "browser_backend": "in-app-browser",
            "checks": {
                "console_health": True,
                "credential_leak_scan": True,
                "framework_overlay_absent": True,
                "interaction_proof": True,
                "not_blank": True,
                "page_identity": True,
            },
            "format": certification.BROWSER_REPORT_FORMAT,
            "source_fingerprint": certification._browser_source_fingerprint(),
            "screenshots": {
                "desktop": {
                    "height": 900,
                    "path": desktop.name,
                    "sha256": _sha(desktop),
                    "width": 1440,
                },
                "mobile": {
                    "height": 844,
                    "path": mobile.name,
                    "sha256": _sha(mobile),
                    "width": 390,
                },
            },
            "workflows": {
                "hybrid_solo": {"launched": True, "lifecycle_observed": True},
                "symmetric_two_leg_1v1": {
                    "launched": True,
                    "lifecycle_observed": True,
                },
            },
        },
    )


def _provider_report(tmp_path: Path) -> Path:
    episodes = []
    for index, provider in enumerate(sorted(certification.REQUIRED_PROVIDERS), 1):
        episode_id = f"ep_live_{provider}"
        state_hash = f"{index:064x}"
        replay = _replay(
            tmp_path / f"{provider}.replay.json",
            episode_id=episode_id,
            mode="solo-curriculum-v0",
            task_id="construction-v0",
            windows=2,
            final_state_hash=state_hash,
        )
        episodes.append(
            {
                "accepted_provider_actions": 2,
                "episode_id": episode_id,
                "final_state_hash": state_hash,
                "managed_process": True,
                "mode": "solo-curriculum-v0",
                "model": f"{provider}-certification-model",
                "observation_profile": "hybrid-visible-v1",
                "provider": provider,
                "provider_calls": 2,
                "provider_failures": 0,
                "replay_path": replay.name,
                "replay_sha256": _sha(replay),
                "replay_verified": True,
                "task_id": "construction-v0",
                "terminal_outcome": "success",
                "windows": 2,
            }
        )
    return _json(
        tmp_path / "providers.json",
        {"episodes": episodes, "format": certification.PROVIDER_REPORT_FORMAT},
    )


def _duel_report(tmp_path: Path) -> Path:
    public = tmp_path / "series.public.json"
    protected = tmp_path / "series.protected.json"
    public.write_bytes(b"public-bundle")
    protected.write_bytes(b"protected-bundle")
    replay_hashes = [hashlib.sha256(f"replay-{index}".encode()).hexdigest() for index in range(2)]
    return _json(
        tmp_path / "live-duel-report.json",
        {
            "format": certification.LIVE_DUEL_REPORT_FORMAT,
            "series": {
                "bundles": {
                    "protected": {"path": protected.name, "sha256": _sha(protected)},
                    "public": {"path": public.name, "sha256": _sha(public)},
                },
                "decision_ticks": 10,
                "draws": 2,
                "entrant_wins": [0, 0],
                "entrants": [
                    {
                        "entrant_id": "entrant_0",
                        "model": "gpt-test-a",
                        "provider": "openai",
                        "verified_provider_calls": 4,
                    },
                    {
                        "entrant_id": "entrant_1",
                        "model": "gpt-test-b",
                        "provider": "openai",
                        "verified_provider_calls": 4,
                    },
                ],
                "fairness_lock_sha256": "b" * 64,
                "legs": [
                    {
                        "episode_id": f"ep_series_test_{index}",
                        "final_state_hash": f"{index + 1:064x}",
                        "leg_index": index,
                        "outcome": "draw",
                        "provider_calls": 4,
                        "provider_failures": 0,
                        "replay_sha256": replay_hashes[index],
                        "windows": 2,
                    }
                    for index in range(2)
                ],
                "max_live_provider_calls": 8,
                "mode": "model-duel-v0",
                "observation_profile": "hybrid-visible-v1",
                "plan_sha256": "a" * 64,
                "rerun_occurred": False,
                "seed": 7,
                "series_id": "series_test",
                "status": "complete",
                "task_id": "central-relay-v0",
                "total_verified_provider_calls": 8,
                "winner_entrant_id": None,
            },
        },
    )


def _y_bot_fixture(tmp_path: Path) -> tuple[Path, Path, Path, Path]:
    repository = tmp_path / "repository"
    asset_dir = repository / "godot/assets/external/mixamo"
    asset_dir.mkdir(parents=True)
    base = asset_dir / "y-bot.fbx"
    base.write_bytes(b"reviewed-y-bot-base")
    clips = {}
    for name in certification.REQUIRED_Y_BOT_CLIPS:
        clip = asset_dir / f"{name}.fbx"
        clip.write_bytes(f"reviewed-{name}".encode())
        clips[name] = {
            "animation_only": True,
            "path": clip.relative_to(repository).as_posix(),
            "sha256": _sha(clip),
        }
    final_scene = repository / "godot/scenes/embodiment/y_bot_operator.tscn"
    final_scene.parent.mkdir(parents=True)
    clip_names = "\n".join(sorted(certification.REQUIRED_Y_BOT_CLIPS))
    final_scene.write_text(
        "AnimationTree\nres://assets/external/mixamo/y-bot.fbx\n" + clip_names,
        encoding="utf-8",
    )
    integration_script = repository / "presentation.gd"
    integration_script.write_text(
        'const YBot := preload("res://scenes/embodiment/y_bot_operator.tscn")\n',
        encoding="utf-8",
    )
    integration_scene = repository / "presentation.tscn"
    integration_scene.write_text("[gd_scene format=3]\n", encoding="utf-8")
    manifest = _json(
        asset_dir / "approved-y-bot.manifest.json",
        {
            "asset_identity": "mixamo-y-bot",
            "base": {
                "path": base.relative_to(repository).as_posix(),
                "sha256": _sha(base),
            },
            "clips": clips,
            "format": certification.Y_BOT_FORMAT,
            "human_approved": True,
            "presentation_scene": {
                "path": final_scene.relative_to(repository).as_posix(),
                "sha256": _sha(final_scene),
            },
            "review": {
                "downloaded_at": "2026-07-20T00:00:00Z",
                "export_settings": {
                    "character": "Y Bot",
                    "clips_without_skin": True,
                    "format": "FBX Binary",
                    "pose": "T-pose",
                    "with_skin": True,
                },
                "license_terms": "Reviewed Mixamo account terms for this local intake.",
                "reviewed_at": "2026-07-20T00:05:00Z",
                "reviewer": "human-reviewer",
                "source_url": "https://www.mixamo.com/#/?page=1&type=Character",
            },
        },
    )
    return manifest, repository, integration_script, integration_scene


def test_unknown_only_name_is_rejected_before_any_step(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        certification,
        "_certification_source_fingerprint",
        lambda: pytest.fail("unknown selection must fail before fingerprinting"),
    )
    with pytest.raises(ValueError, match="unknown certification step"):
        certification.run_certification(only=frozenset({"does-not-exist"}))


def test_dashboard_lint_is_a_selectable_fingerprinted_step() -> None:
    assert "dashboard-lint" in certification._available_step_names(None)
    fingerprint = certification._step_fingerprint(
        "dashboard-lint", ["pnpm", "lint"], ROOT / "dashboard", "a" * 64
    )
    assert certification._valid_sha(fingerprint)


def test_source_fingerprint_ignores_generated_python_and_godot_cache_files(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source_root = tmp_path / "source"
    source_root.mkdir()
    source = source_root / "authority.py"
    source.write_text("VALUE = 1\n", encoding="utf-8")
    cache = source_root / "__pycache__"
    cache.mkdir()
    bytecode = cache / "authority.cpython-39.pyc"
    bytecode.write_bytes(b"first-cache")
    uid = source_root / "authority.gd.uid"
    uid.write_text("uid://first", encoding="utf-8")
    monkeypatch.setattr(certification, "ROOT", tmp_path)
    monkeypatch.setattr(
        certification,
        "_SOURCE_COMPONENTS",
        (SourceComponent("test.authority", "source", "tree"),),
    )

    first = certification._certification_source_fingerprint()
    bytecode.write_bytes(b"changed-cache")
    uid.write_text("uid://changed", encoding="utf-8")
    assert certification._certification_source_fingerprint() == first
    source.write_text("VALUE = 2\n", encoding="utf-8")
    assert certification._certification_source_fingerprint() != first


def test_new_certification_reports_bind_the_v2_algorithm_explicitly() -> None:
    plan: dict[str, str] = {}
    report = certification.run_certification(fingerprint_plan=plan)

    assert plan
    assert report["format"] == certification.REPORT_FORMAT
    assert certification.REPORT_FORMAT != certification.REPORT_FORMAT_V1
    assert report["source_fingerprint_version"] == SOURCE_FINGERPRINT_V2
    assert report["source_fingerprint"] == certification._certification_source_fingerprint()


def test_browser_fingerprint_excludes_release_overlay_but_tracks_runtime(tmp_path: Path) -> None:
    runtime = tmp_path / "dashboard/src/App.tsx"
    runtime.parent.mkdir(parents=True)
    runtime.write_text("export default 1\n", encoding="utf-8")
    before_browser = browser_runtime_source_fingerprint(tmp_path)
    before_full = certification_source_fingerprint(tmp_path)

    release = tmp_path / "game/embodiment_release/worldarena.release.json"
    release.parent.mkdir(parents=True)
    release.write_text("{}\n", encoding="utf-8")
    assert browser_runtime_source_fingerprint(tmp_path) == before_browser
    assert certification_source_fingerprint(tmp_path) != before_full

    marketing = tmp_path / "dashboard/src/marketing/site.tsx"
    marketing.parent.mkdir(parents=True)
    marketing.write_text("export default 1\n", encoding="utf-8")
    assert browser_runtime_source_fingerprint(tmp_path) == before_browser

    runtime.write_text("export default 2\n", encoding="utf-8")
    assert browser_runtime_source_fingerprint(tmp_path) != before_browser


def test_browser_report_requires_both_workflows_checks_and_real_screenshots(tmp_path: Path) -> None:
    report = _browser_report(tmp_path)
    assert certification.validate_browser_qa_report(report)["passed"] is True

    value = json.loads(report.read_text())
    value["checks"]["credential_leak_scan"] = False
    _json(report, value)
    rejected = certification.validate_browser_qa_report(report)
    assert rejected == {"passed": False, "code": "browser_checks_failed"}


def test_browser_report_rejects_stale_source_fingerprint(tmp_path: Path) -> None:
    report = _browser_report(tmp_path)
    value = json.loads(report.read_text())
    value["source_fingerprint"] = "0" * 64
    _json(report, value)
    assert certification.validate_browser_qa_report(report) == {
        "passed": False,
        "code": "browser_source_fingerprint_mismatch",
    }


def test_final_seal_exit_codes_and_argument_requirements(tmp_path: Path) -> None:
    passing = {"selected_steps_passed": True, "mvp_certified": True}
    incomplete = {"selected_steps_passed": True, "mvp_certified": False}
    failing = {"selected_steps_passed": False, "mvp_certified": False}
    assert certification._exit_code(passing, final_seal=True) == 0
    assert certification._exit_code(incomplete, final_seal=False) == 0
    assert certification._exit_code(incomplete, final_seal=True) == 2
    assert certification._exit_code(failing, final_seal=True) == 1

    arguments = Namespace(
        browser_qa_report=None,
        final_seal=True,
        final_video=None,
        live_provider_report=None,
        live_duel_report=None,
        readiness_report=None,
        only=[],
        report=tmp_path / "report.json",
        resume=False,
    )
    error = certification._argument_error(arguments)
    assert error is not None and "--browser-qa-report" in error
    arguments.only = ["python-static"]
    assert certification._argument_error(arguments) == (
        "--final-seal cannot be combined with --only"
    )


def test_passing_final_seal_projects_all_six_readiness_gates(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        certification,
        "validate_offline_certification_report",
        lambda _: {"passed": True, "report_sha256": "a" * 64},
    )
    external = {
        name: {"passed": True}
        for name in (
            "approved_mixamo_y_bot",
            "browser_visual_qa",
            "certified_runtime_capabilities",
            "final_native_video",
            "live_model_paired_duel",
            "live_provider_managed_solo",
        )
    }
    readiness = certification._final_readiness_report(
        {
            "external_gates": external,
            "source_fingerprint": "b" * 64,
            "source_fingerprint_version": SOURCE_FINGERPRINT_V2,
        },
        certification_report=tmp_path / "final.json",
    )
    assert readiness["format"] == certification.READINESS_REPORT_FORMAT
    assert readiness["source_fingerprint_version"] == SOURCE_FINGERPRINT_V2
    assert readiness["ready_for_promotion"] is True
    assert set(readiness["gates"]) == {
        "offline",
        "approved_mixamo_y_bot",
        "browser_visual_qa",
        "final_native_video",
        "live_model_paired_duel",
        "live_provider_managed_solo",
    }
    assert readiness["runtime_capabilities"] == {"passed": True}


def test_live_provider_report_requires_three_unique_managed_hybrid_replays(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        certification,
        "_verify_replay_file",
        lambda path, maximum: json.loads(path.read_text(encoding="utf-8")),
    )
    report = _provider_report(tmp_path)
    accepted = certification.validate_live_provider_report(report)
    assert accepted["passed"] is True
    assert accepted["providers"] == ["anthropic", "gemini", "openai"]

    value = json.loads(report.read_text())
    value["episodes"].pop()
    _json(report, value)
    assert certification.validate_live_provider_report(report) == {
        "passed": False,
        "code": "live_provider_coverage_invalid",
    }


def test_live_duel_report_requires_both_matching_verified_layers(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    report = _duel_report(tmp_path)
    value = json.loads(report.read_text())
    series = value["series"]
    replay_bytes = tuple(f"replay-{index}".encode() for index in range(2))
    locked_entrants = [
        {
            "entrant_id": entrant["entrant_id"],
            "model": entrant["model"],
            "provider": entrant["provider"],
        }
        for entrant in series["entrants"]
    ]
    telemetry_bytes = tuple(
        certification.canonical_json_bytes(
            {
                "fairness_lock": {"entrants": locked_entrants, "seed": series["seed"]},
                "leg_plan": {
                    "assignments": [
                        {"entrant_id": "entrant_0", "participant_id": "participant_0"},
                        {"entrant_id": "entrant_1", "participant_id": "participant_1"},
                    ],
                    "decision_ticks": 10,
                    "leg_index": index,
                    "series_id": series["series_id"],
                },
                "provider_audits": [
                    {"entrant_id": f"entrant_{call % 2}", "result": {"failure": None}}
                    for call in range(4)
                ],
                "verification": {
                    "outcome": "draw",
                    "winner_participant_id": None,
                },
            }
        )
        for index in range(2)
    )

    class FakeBundle:
        @staticmethod
        def verify(payload: bytes) -> SimpleNamespace:
            layer = "public" if payload == b"public-bundle" else "protected"
            legs = tuple(
                SimpleNamespace(
                    read=lambda name, child=child, telemetry=telemetry: (
                        child if name == "authority_replay" else telemetry
                    )
                )
                for child, telemetry in zip(replay_bytes, telemetry_bytes)
            )
            return SimpleNamespace(
                fairness_lock_sha256=series["fairness_lock_sha256"],
                layer=layer,
                legs=legs,
                plan_sha256=series["plan_sha256"],
                series_id=series["series_id"],
            )

    monkeypatch.setattr(certification, "DuelSeriesEvidenceBundle", FakeBundle)
    monkeypatch.setattr(
        certification,
        "verify_offline_paired_duel",
        lambda *_args, **_kwargs: tuple(
            {
                "config": {"episode_id": f"ep_series_test_{index}"},
                "final_state_hash": f"{index + 1:064x}",
            }
            for index in range(2)
        ),
    )

    assert certification.validate_live_duel_report(report)["passed"] is True
    value["series"]["entrants"][0]["model"] = "tampered-model"
    _json(report, value)
    assert certification.validate_live_duel_report(report) == {
        "passed": False,
        "code": "live_duel_counts_invalid",
    }
    value["series"]["entrants"][0]["model"] = "gpt-test-a"
    value["series"]["entrant_wins"] = [1, 1]
    value["series"]["draws"] = 0
    _json(report, value)
    assert certification.validate_live_duel_report(report) == {
        "passed": False,
        "code": "live_duel_counts_invalid",
    }
    value["series"]["entrant_wins"] = [0, 0]
    value["series"]["draws"] = 2
    value["series"]["legs"][0]["provider_calls"] = 3
    _json(report, value)
    assert certification.validate_live_duel_report(report) == {
        "passed": False,
        "code": "live_duel_leg_invalid",
    }
    value["series"]["legs"][0]["provider_calls"] = 4
    _json(report, value)
    failed_telemetry = json.loads(telemetry_bytes[0])
    failed_telemetry["provider_audits"][0]["result"]["failure"] = "transport_error"
    telemetry_bytes = (
        certification.canonical_json_bytes(failed_telemetry),
        telemetry_bytes[1],
    )
    assert certification.validate_live_duel_report(report) == {
        "passed": False,
        "code": "live_duel_leg_invalid",
    }


def test_external_replay_evidence_is_independently_verified(tmp_path: Path) -> None:
    replay = _sealed_golden_replay(tmp_path / "verified.replay.json")
    assert certification._verify_replay_file(replay, 16 * 1024 * 1024)["steps"]

    value = json.loads(replay.read_text(encoding="utf-8"))
    value["final_state_hash"] = "0" * 64
    _json(replay, value)
    with pytest.raises(certification.EvidenceValidationError, match="verification"):
        certification._verify_replay_file(replay, 16 * 1024 * 1024)


def test_y_bot_intake_validates_metadata_hashes_clips_and_placeholder_replacement(
    tmp_path: Path,
) -> None:
    manifest, repository, integration_script, integration_scene = _y_bot_fixture(tmp_path)
    accepted = certification.validate_y_bot_intake(
        manifest,
        repository_root=repository,
        presentation_script=integration_script,
        presentation_scene=integration_scene,
    )
    assert accepted["passed"] is True

    integration_script.write_text(
        'const YBot := preload("res://scenes/embodiment/y_bot_operator.tscn")\n'
        '_operator.set_meta("asset_identity", "procedural_operator_placeholder")\n',
        encoding="utf-8",
    )
    rejected = certification.validate_y_bot_intake(
        manifest,
        repository_root=repository,
        presentation_script=integration_script,
        presentation_scene=integration_scene,
    )
    assert rejected == {"passed": False, "code": "y_bot_placeholder_still_active"}


def test_y_bot_intake_rejects_a_clip_whose_file_no_longer_matches(tmp_path: Path) -> None:
    manifest, repository, integration_script, integration_scene = _y_bot_fixture(tmp_path)
    value = json.loads(manifest.read_text())
    clip = repository / value["clips"]["idle"]["path"]
    clip.write_bytes(b"changed-after-approval")
    rejected = certification.validate_y_bot_intake(
        manifest,
        repository_root=repository,
        presentation_script=integration_script,
        presentation_scene=integration_scene,
    )
    assert rejected == {"passed": False, "code": "y_bot_clip_invalid"}


def test_release_capabilities_must_be_explicitly_promoted_after_external_gates(
    tmp_path: Path,
) -> None:
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    package_sha256 = package.package_sha256
    current = certification.validate_release_capabilities(tmp_path / "missing-release.json")
    assert current == {"passed": False, "code": "runtime_capabilities_not_released"}

    manifest = {
        "capabilities": certification.RELEASE_CAPABILITIES,
        "environment_id": certification.RELEASE_ENVIRONMENT_ID,
        "format": certification.RELEASE_FORMAT,
        "protocol_package_sha256": package_sha256,
        "protocol_version": certification.RELEASE_PROTOCOL_VERSION,
    }
    promoted = tmp_path / "worldarena.release.json"
    promoted.write_bytes(certification.canonical_json_bytes(manifest) + b"\n")
    assert certification.validate_release_capabilities(promoted)["passed"] is True
    assert EmbodimentProtocolPackage.from_repository(ROOT).package_sha256 == package_sha256

    manifest["protocol_package_sha256"] = "0" * 64
    promoted.write_bytes(certification.canonical_json_bytes(manifest) + b"\n")
    assert certification.validate_release_capabilities(promoted) == {
        "passed": False,
        "code": "runtime_capabilities_not_released",
    }


def test_final_video_requires_sidecar_y_bot_and_exact_verified_replay_set(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        certification,
        "_verify_replay_file",
        lambda path, maximum: json.loads(path.read_text(encoding="utf-8")),
    )
    manifest, repository, integration_script, integration_scene = _y_bot_fixture(tmp_path)
    y_bot = certification.validate_y_bot_intake(
        manifest,
        repository_root=repository,
        presentation_script=integration_script,
        presentation_scene=integration_scene,
    )
    video = tmp_path / "worldarena-final.mp4"
    video.write_bytes(b"\x00\x00\x00\x18ftypisom00000000moov-video-mdat-payload")
    replays = [
        (
            "stage-c",
            _replay(
                tmp_path / "stage-c.replay.json",
                episode_id="ep_stage_c",
                mode="solo-curriculum-v0",
                task_id="construction-v0",
                windows=2,
                final_state_hash="1" * 64,
            ),
        ),
        (
            "duel-leg-a",
            _replay(
                tmp_path / "duel-a.replay.json",
                episode_id="ep_duel_a",
                mode="model-duel-v0",
                task_id="central-relay-v0",
                windows=2,
                final_state_hash="2" * 64,
            ),
        ),
        (
            "duel-leg-b",
            _replay(
                tmp_path / "duel-b.replay.json",
                episode_id="ep_duel_b",
                mode="model-duel-v0",
                task_id="central-relay-v0",
                windows=2,
                final_state_hash="3" * 64,
            ),
        ),
    ]
    evidence = video.with_suffix(video.suffix + ".evidence.json")
    _json(
        evidence,
        {
            "format": certification.FINAL_VIDEO_FORMAT,
            "placeholder": False,
            "renderer": "godot-movie-maker+ffmpeg",
            "replays": [
                {"path": replay.name, "role": role, "sha256": _sha(replay), "verified": True}
                for role, replay in replays
            ],
            "video": {
                "audio_codec": "aac",
                "faststart": True,
                "fps": 30,
                "height": 1080,
                "path": video.name,
                "pixel_format": "yuv420p",
                "sha256": _sha(video),
                "video_codec": "h264",
                "width": 1920,
            },
            "y_bot_manifest_sha256": y_bot["manifest_sha256"],
        },
    )
    accepted = certification.validate_final_video(video, y_bot)
    assert accepted["passed"] is True
    assert accepted["video_sha256"] == _sha(video)

    value = json.loads(evidence.read_text())
    value["replays"].pop()
    _json(evidence, value)
    assert certification.validate_final_video(video, y_bot) == {
        "passed": False,
        "code": "final_video_replays_invalid",
    }


def test_resume_requires_exact_command_and_source_fingerprint_and_drops_old_output() -> None:
    fingerprint = certification._step_fingerprint(
        "python-static", ["ruff", "check"], ROOT, "a" * 64
    )
    prior = {
        "diagnostics": ["api_key=must-not-survive"],
        "duration_ms": 9,
        "fingerprint": fingerprint,
        "name": "python-static",
        "passed": True,
        "returncode": 0,
        "tail": ["A" * 500],
    }
    resumed = certification._matching_prior_result(prior, "python-static", fingerprint)
    assert resumed == {
        "duration_ms": 9,
        "fingerprint": fingerprint,
        "name": "python-static",
        "passed": True,
        "resumed": True,
        "returncode": 0,
    }
    assert certification._matching_prior_result(prior, "python-static", "b" * 64) is None
    changed = certification._step_fingerprint(
        "python-static", ["ruff", "check", "new-source"], ROOT, "a" * 64
    )
    assert changed != fingerprint


def test_diagnostics_never_retain_sensitive_or_base64_output() -> None:
    secret = "sk-sensitive-value"
    bare_secret = "sk-ant-api03-very-sensitive-value"
    encoded = "A" * 300
    diagnostics = certification._safe_diagnostics(
        f"normal failure\napi_key={secret}\nrequest failed: {bare_secret}\n"
        f"observation={encoded}\n"
    )
    combined = "\n".join(diagnostics)
    assert "normal failure" in combined
    assert secret not in combined
    assert bare_secret not in combined
    assert encoded not in combined
    assert "[redacted-sensitive-line]" in diagnostics
    assert "[redacted-long-or-base64-line]" in diagnostics


def test_failed_step_report_stores_only_scrubbed_diagnostics(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    secret = "sk-ant-api03-never-store-this-value"
    encoded = "Q" * 300

    def completed(*_args, **_kwargs):
        return subprocess.CompletedProcess(
            ["test-command"], 1, stdout=f"failure\n{secret}\nframe={encoded}\n"
        )

    monkeypatch.setattr(certification.subprocess, "run", completed)
    results = []
    certification._step(
        results,
        "python-static",
        ["test-command"],
        fingerprint="a" * 64,
    )
    assert len(results) == 1
    assert "tail" not in results[0]
    encoded_result = json.dumps(results[0])
    assert secret not in encoded_result
    assert encoded not in encoded_result
    assert results[0]["diagnostics"] == [
        "failure",
        "[redacted-sensitive-line]",
        "[redacted-long-or-base64-line]",
    ]


def test_mvp_certification_requires_every_structured_external_gate() -> None:
    gates = {
        "browser": {"passed": True},
        "providers": {"passed": True},
        "video": {"passed": True},
        "y_bot": {"passed": True},
    }
    assert certification._mvp_certified(True, gates)
    gates["video"] = {"passed": False, "code": "missing"}
    assert not certification._mvp_certified(True, gates)
