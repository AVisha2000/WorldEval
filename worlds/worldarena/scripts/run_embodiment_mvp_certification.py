#!/usr/bin/env python3
"""Run the provider-safe LLM Controller × WorldArena MVP certification matrix."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import tempfile
import time
import zlib
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping, Sequence
from urllib.parse import urlparse

from genesis_arena.embodiment.duel.evidence import (
    DuelSeriesEvidenceBundle,
    verify_offline_paired_duel,
)
from genesis_arena.embodiment.protocol import (
    EmbodimentProtocolPackage,
    canonical_json_bytes,
    strict_json_loads,
)
from genesis_arena.embodiment.replay import verify_replay_bytes
from genesis_arena.embodiment.source_fingerprint import (
    SOURCE_COMPONENTS_V2 as _SOURCE_COMPONENTS,
)
from genesis_arena.embodiment.source_fingerprint import (
    SOURCE_FINGERPRINT_V2,
    browser_runtime_source_fingerprint,
    component_source_fingerprint,
)
from worldeval.workspace import find_workspace

WORKSPACE = find_workspace(__file__)
WORKSPACE_ROOT = WORKSPACE.root
ROOT = WORKSPACE.path("worldarena")
WEB_ROOT = WORKSPACE.path("worldeval_web")
VENV_BIN = WORKSPACE_ROOT / ".venv/bin"
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
NODE_BIN = Path("/Users/arlind/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin")
PNPM_BIN = Path(
    "/Users/arlind/.cache/codex-runtimes/codex-primary-runtime/dependencies/bin/fallback"
)
Y_BOT_MANIFEST = ROOT / "godot/assets/external/mixamo/approved-y-bot.manifest.json"
ENVIRONMENT_MANIFEST = ROOT / "game/embodiment_protocol/worldarena.environment.json"
RELEASE_MANIFEST = ROOT / "game/embodiment_release/worldarena.release.json"
PRESENTATION_SCRIPT = (
    ROOT / "godot/scripts/embodiment/presentation/scene/embodiment_presentation_scene.gd"
)
PRESENTATION_SCENE = ROOT / "godot/scenes/embodiment/embodiment_presentation_scene.tscn"

REPORT_FORMAT_V1 = "llm-controller-worldarena-mvp-certification/1.1.0"
REPORT_FORMAT = "llm-controller-worldarena-mvp-certification/1.2.0"
BROWSER_REPORT_FORMAT = "llm-controller/browser-qa/1.1.0"
PROVIDER_REPORT_FORMAT = "llm-controller/live-provider-managed-solo/1.0.0"
LIVE_DUEL_REPORT_FORMAT = "llm-controller/live-paired-duel/1.0.0"
Y_BOT_FORMAT = "worldarena/mixamo-y-bot-intake/1.0.0"
FINAL_VIDEO_FORMAT = "llm-controller/final-video-evidence/1.0.0"
RELEASE_FORMAT = "llm-controller/worldarena-release-capabilities/1.0.0"
READINESS_REPORT_FORMAT = "llm-controller/embodiment-pilot-readiness/1.2.0"
RELEASE_ENVIRONMENT_ID = "worldarena-embodiment-v0"
RELEASE_PROTOCOL_VERSION = EmbodimentProtocolPackage.PROTOCOL_VERSION
RELEASE_CAPABILITIES = {
    "implemented_modes": [
        "solo-curriculum-v0",
        "scripted-duel-v0",
        "model-duel-v0",
    ],
    "implemented_observation_profiles": ["hybrid-visible-v1"],
    "implemented_tasks": [
        "orientation-v0",
        "interaction-v0",
        "construction-v0",
        "neutral-encounter-v0",
        "central-relay-v0",
    ],
    "certified_modes": [
        "solo-curriculum-v0",
        "scripted-duel-v0",
        "model-duel-v0",
    ],
    "certified_observation_profiles": ["hybrid-visible-v1"],
    "scored_observation_profiles": ["hybrid-visible-v1"],
}
REQUIRED_PROVIDERS = frozenset(("openai", "anthropic", "gemini"))
REQUIRED_Y_BOT_CLIPS = frozenset(
    ("idle", "walk", "run", "attack", "guard", "gather", "build", "hit", "celebrate", "defeat")
)
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$")
_BASE64 = re.compile(r"[A-Za-z0-9+/]{160,}={0,2}")
_SENSITIVE = re.compile(
    r"api[_ -]?key|authorization|bearer|credential|secret|access[_ -]?token|refresh[_ -]?token",
    re.IGNORECASE,
)
_SECRET_VALUE = re.compile(
    r"(?:sk-(?:ant-)?[A-Za-z0-9_-]{8,}|AIza[0-9A-Za-z_-]{20,}|"
    r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})"
)


class EvidenceValidationError(ValueError):
    """An external certification artifact failed its fail-closed contract."""


def run_certification(
    *,
    preview_video: Path | None = None,
    browser_qa_report: Path | None = None,
    live_provider_report: Path | None = None,
    live_duel_report: Path | None = None,
    final_video: Path | None = None,
    only: frozenset[str] = frozenset(),
    prior_results: Sequence[dict] = (),
    fingerprint_plan: dict[str, str] | None = None,
) -> dict:
    available = _available_step_names(preview_video)
    unknown = sorted(only - available)
    if unknown:
        raise ValueError(f"unknown certification step(s): {', '.join(unknown)}")

    source_fingerprint = _certification_source_fingerprint()
    prior_by_name = _prior_results_by_name(prior_results)
    results: list[dict] = []
    completed: set[str] = set()
    expected: set[str] = set()
    offline_env = dict(os.environ)
    for secret_name in (
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "GEMINI_API_KEY",
        "GOOGLE_API_KEY",
        "WORLDARENA_OPENAI_API_KEY",
        "WORLDARENA_ANTHROPIC_API_KEY",
        "WORLDARENA_GEMINI_API_KEY",
    ):
        offline_env.pop(secret_name, None)

    def step(name: str, command: Sequence[str], *, cwd: Path = ROOT, env=None) -> None:
        expected.add(name)
        fingerprint = _step_fingerprint(name, command, cwd, source_fingerprint)
        if fingerprint_plan is not None:
            fingerprint_plan[name] = fingerprint
            return
        resumed = _matching_prior_result(prior_by_name.get(name), name, fingerprint)
        if only and name not in only:
            if resumed is not None:
                results.append(resumed)
                completed.add(name)
            return
        if resumed is not None:
            results.append(resumed)
            completed.add(name)
            return
        _step(
            results,
            name,
            command,
            fingerprint=fingerprint,
            cwd=cwd,
            env=offline_env if env is None else env,
        )
        completed.add(name)

    step(
        "python-static",
        [
            str(VENV_BIN / "ruff"),
            "check",
            "backend/genesis_arena/embodiment",
            "tests/embodiment",
            "scripts/build_embodiment_demo_replays.py",
            "scripts/build_embodiment_browser_qa_report.py",
            "scripts/intake_mixamo_y_bot.py",
            "scripts/promote_embodiment_mvp_release.py",
            "scripts/render_embodiment_mvp_demo.py",
            "scripts/run_embodiment_live_provider_pilot.py",
            "scripts/run_embodiment_live_duel_pilot.py",
            "scripts/run_embodiment_openai_round_robin.py",
            "scripts/run_embodiment_managed_soak.py",
            "scripts/run_embodiment_mvp_certification.py",
        ],
    )
    step(
        "protocol-lock",
        [
            str(VENV_BIN / "python"),
            "scripts/build_embodiment_protocol_lock.py",
            "--check",
        ],
    )
    step(
        "golden-fixtures",
        [
            str(VENV_BIN / "python"),
            "scripts/build_embodiment_golden_fixtures.py",
            "--check",
        ],
    )
    step(
        "python-embodiment",
        [str(VENV_BIN / "python"), "-m", "pytest", "tests/embodiment", "-q"],
    )
    step(
        "managed-process-soak",
        [
            str(VENV_BIN / "python"),
            "scripts/run_embodiment_managed_soak.py",
            "--iterations",
            "32",
            "--godot",
            str(GODOT),
        ],
    )
    for runner in sorted((ROOT / "godot/tests/embodiment").glob("*_runner.gd")):
        step(
            f"godot-{runner.stem}",
            [
                str(GODOT),
                "--no-header",
                "--headless",
                "--audio-driver",
                "Dummy",
                "--path",
                str(ROOT / "godot"),
                "--script",
                f"res://tests/embodiment/{runner.name}",
            ],
        )
    step(
        "frozen-duel-python-core",
        [
            str(VENV_BIN / "python"),
            "-m",
            "pytest",
            "tests/duel",
            "-q",
            "--ignore",
            "tests/duel/test_duel_official_replay.py",
        ],
    )
    step(
        "frozen-duel-official-replay",
        [
            str(VENV_BIN / "python"),
            "-m",
            "pytest",
            "tests/duel/test_duel_official_replay.py",
            "-q",
        ],
    )
    dashboard_env = dict(offline_env)
    dashboard_env["PATH"] = os.pathsep.join(
        (str(NODE_BIN), str(PNPM_BIN), dashboard_env.get("PATH", ""))
    )
    step(
        "dashboard-lint",
        [str(PNPM_BIN / "pnpm"), "lint"],
        cwd=WEB_ROOT,
        env=dashboard_env,
    )
    step(
        "dashboard-tests",
        [str(PNPM_BIN / "pnpm"), "test", "--", "--run"],
        cwd=WEB_ROOT,
        env=dashboard_env,
    )
    step(
        "dashboard-build",
        [str(PNPM_BIN / "pnpm"), "build"],
        cwd=WEB_ROOT,
        env=dashboard_env,
    )
    if preview_video is not None:
        step(
            "native-placeholder-preview",
            [
                str(VENV_BIN / "python"),
                "scripts/render_embodiment_mvp_demo.py",
                "--allow-placeholder",
                "--output",
                str(Path(preview_video).resolve()),
            ],
        )

    y_bot = validate_y_bot_intake(Y_BOT_MANIFEST)
    external_gates = {
        "approved_mixamo_y_bot": y_bot,
        "browser_visual_qa": validate_browser_qa_report(browser_qa_report),
        "certified_runtime_capabilities": validate_release_capabilities(RELEASE_MANIFEST),
        "live_provider_managed_solo": validate_live_provider_report(live_provider_report),
        "live_model_paired_duel": validate_live_duel_report(live_duel_report),
        "final_native_video": validate_final_video(final_video, y_bot),
    }
    result_by_name = {str(result["name"]): result for result in results}
    selected_names = only if only else expected
    selected_passed = (
        bool(selected_names)
        and selected_names <= completed
        and all(bool(result_by_name[name]["passed"]) for name in selected_names)
    )
    offline_passed = (
        not only and completed >= expected and all(bool(result["passed"]) for result in results)
    )
    return {
        "format": REPORT_FORMAT,
        "source_fingerprint": source_fingerprint,
        "source_fingerprint_version": SOURCE_FINGERPRINT_V2,
        "offline_certification_passed": offline_passed,
        "selected_steps_passed": selected_passed,
        "mvp_certified": _mvp_certified(offline_passed, external_gates),
        "external_gates": external_gates,
        "results": results,
    }


def _available_step_names(preview_video: Path | None) -> frozenset[str]:
    names = {
        "python-static",
        "protocol-lock",
        "golden-fixtures",
        "managed-process-soak",
        "python-embodiment",
        "frozen-duel-python-core",
        "frozen-duel-official-replay",
        "dashboard-lint",
        "dashboard-tests",
        "dashboard-build",
    }
    names.update(
        f"godot-{runner.stem}" for runner in (ROOT / "godot/tests/embodiment").glob("*_runner.gd")
    )
    if preview_video is not None:
        names.add("native-placeholder-preview")
    return frozenset(names)


def _expected_step_fingerprints() -> Mapping[str, str]:
    plan: dict[str, str] = {}
    run_certification(fingerprint_plan=plan)
    return plan


def validate_offline_certification_report(path: Path) -> dict[str, object]:
    """Require an exact current full-matrix report before release promotion."""

    try:
        value, report_sha256 = _load_json_file(path, 8 * 1024 * 1024)
        _require_exact(
            value,
            {
                "external_gates",
                "format",
                "mvp_certified",
                "offline_certification_passed",
                "results",
                "selected_steps_passed",
                "source_fingerprint",
                "source_fingerprint_version",
            },
            "offline_report_shape_invalid",
        )
        if (
            value["format"] != REPORT_FORMAT
            or value["source_fingerprint_version"] != SOURCE_FINGERPRINT_V2
            or value["source_fingerprint"] != _certification_source_fingerprint()
            or value["offline_certification_passed"] is not True
            or value["selected_steps_passed"] is not True
            or not isinstance(value["results"], list)
        ):
            raise EvidenceValidationError("offline_report_stale_or_invalid")
        expected = _expected_step_fingerprints()
        results: dict[str, Mapping[str, object]] = {}
        fields = {"duration_ms", "fingerprint", "name", "passed", "resumed", "returncode"}
        for result in value["results"]:
            _require_exact(result, fields, "offline_result_shape_invalid")
            name = result["name"]
            if not isinstance(name, str) or name in results or name not in expected:
                raise EvidenceValidationError("offline_result_coverage_invalid")
            if (
                result["passed"] is not True
                or result["returncode"] != 0
                or not isinstance(result["resumed"], bool)
                or isinstance(result["duration_ms"], bool)
                or not isinstance(result["duration_ms"], int)
                or result["duration_ms"] < 0
                or result["fingerprint"] != expected[name]
            ):
                raise EvidenceValidationError("offline_result_invalid")
            results[name] = result
        if set(results) != set(expected):
            raise EvidenceValidationError("offline_result_coverage_invalid")
        return {"passed": True, "report_sha256": report_sha256}
    except (EvidenceValidationError, OSError, UnicodeError, json.JSONDecodeError):
        return _failed_gate("offline_report_stale_or_invalid")


def _mvp_certified(offline_passed: bool, gates: Mapping[str, Mapping[str, object]]) -> bool:
    return (
        offline_passed
        and bool(gates)
        and all(gate.get("passed") is True for gate in gates.values())
    )


def _prior_results_by_name(prior_results: Sequence[dict]) -> dict[str, dict]:
    output: dict[str, dict] = {}
    duplicates: set[str] = set()
    for value in prior_results:
        if not isinstance(value, dict) or not isinstance(value.get("name"), str):
            continue
        name = value["name"]
        if name in output:
            duplicates.add(name)
        else:
            output[name] = value
    for name in duplicates:
        output.pop(name, None)
    return output


def _matching_prior_result(value: object, name: str, fingerprint: str) -> dict | None:
    required = {"name", "passed", "returncode", "fingerprint"}
    if (
        not isinstance(value, dict)
        or not required <= set(value)
        or value.get("name") != name
        or value.get("passed") is not True
        or isinstance(value.get("returncode"), bool)
        or not isinstance(value.get("returncode"), int)
        or value.get("returncode") != 0
        or value.get("fingerprint") != fingerprint
    ):
        return None
    duration = value.get("duration_ms", 0)
    if isinstance(duration, bool) or not isinstance(duration, int) or duration < 0:
        duration = 0
    return {
        "duration_ms": duration,
        "fingerprint": fingerprint,
        "name": name,
        "passed": True,
        "resumed": True,
        "returncode": 0,
    }


def _step_fingerprint(
    name: str,
    command: Sequence[str],
    cwd: Path,
    source_fingerprint: str,
    *,
    source_fingerprint_version: str = SOURCE_FINGERPRINT_V2,
) -> str:
    material = {
        "command": list(command),
        "cwd": str(Path(cwd).resolve()),
        "name": name,
        "source_fingerprint": source_fingerprint,
        "source_fingerprint_version": source_fingerprint_version,
    }
    return hashlib.sha256(
        json.dumps(material, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def _certification_source_fingerprint() -> str:
    return component_source_fingerprint(
        ROOT,
        components=_SOURCE_COMPONENTS,
    )


def _browser_source_fingerprint() -> str:
    return browser_runtime_source_fingerprint(ROOT)


def _step(
    results: list[dict],
    name: str,
    command: Sequence[str],
    *,
    fingerprint: str,
    cwd: Path = ROOT,
    env: dict[str, str] | None = None,
) -> None:
    started = time.monotonic()
    stream_output = name in {"frozen-duel-python-core", "frozen-duel-official-replay"}
    if stream_output:
        process = subprocess.Popen(list(command), cwd=cwd, env=env)
        while process.poll() is None:
            print(f"RUNNING {name}", flush=True)
            time.sleep(20)
        returncode = process.wait()
        output = ""
    else:
        completed = subprocess.run(
            list(command),
            cwd=cwd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        returncode = completed.returncode
        output = completed.stdout
    result = {
        "duration_ms": round((time.monotonic() - started) * 1000),
        "fingerprint": fingerprint,
        "name": name,
        "passed": returncode == 0,
        "resumed": False,
        "returncode": returncode,
    }
    diagnostics = _safe_diagnostics(output) if returncode != 0 else []
    if diagnostics:
        result["diagnostics"] = diagnostics
    results.append(result)
    print(f"{'PASS' if result['passed'] else 'FAIL'} {name} ({result['duration_ms']} ms)")
    for line in diagnostics:
        print(line)


def _safe_diagnostics(output: str) -> list[str]:
    safe: list[str] = []
    for raw_line in output.splitlines()[-40:]:
        line = raw_line.strip()
        if not line:
            continue
        if len(line) > 512 or _BASE64.search(line):
            line = "[redacted-long-or-base64-line]"
        elif _SENSITIVE.search(line) or _SECRET_VALUE.search(line):
            line = "[redacted-sensitive-line]"
        safe.append(line[:512])
    return safe[-20:]


def validate_browser_qa_report(path: Path | None) -> dict:
    if path is None:
        return _failed_gate("browser_report_missing")
    try:
        value, report_sha = _load_json_file(path, 1_048_576)
        _require_exact(
            value,
            {
                "format",
                "browser_backend",
                "base_url",
                "checks",
                "screenshots",
                "source_fingerprint",
                "workflows",
            },
            "browser_report_shape_invalid",
        )
        if value["format"] != BROWSER_REPORT_FORMAT:
            raise EvidenceValidationError("browser_report_format_invalid")
        if (
            not isinstance(value["source_fingerprint"], str)
            or _SHA256.fullmatch(value["source_fingerprint"]) is None
            or value["source_fingerprint"] != _browser_source_fingerprint()
        ):
            raise EvidenceValidationError("browser_source_fingerprint_mismatch")
        if value["browser_backend"] != "in-app-browser":
            raise EvidenceValidationError("browser_backend_invalid")
        parsed_url = urlparse(value["base_url"] if isinstance(value["base_url"], str) else "")
        if parsed_url.scheme != "http" or parsed_url.hostname not in {"127.0.0.1", "localhost"}:
            raise EvidenceValidationError("browser_base_url_invalid")
        required_checks = {
            "console_health",
            "credential_leak_scan",
            "framework_overlay_absent",
            "interaction_proof",
            "not_blank",
            "page_identity",
        }
        _require_exact(value["checks"], required_checks, "browser_checks_invalid")
        if any(value["checks"][name] is not True for name in required_checks):
            raise EvidenceValidationError("browser_checks_failed")
        _require_exact(
            value["workflows"],
            {"hybrid_solo", "symmetric_two_leg_1v1"},
            "browser_workflows_invalid",
        )
        for workflow in value["workflows"].values():
            _require_exact(workflow, {"launched", "lifecycle_observed"}, "browser_workflow_invalid")
            if workflow["launched"] is not True or workflow["lifecycle_observed"] is not True:
                raise EvidenceValidationError("browser_workflow_failed")
        _require_exact(value["screenshots"], {"desktop", "mobile"}, "browser_screenshots_invalid")
        dimensions = {}
        for name, screenshot in value["screenshots"].items():
            _require_exact(screenshot, {"path", "sha256", "width", "height"}, "screenshot_invalid")
            screenshot_path = _report_file(Path(path), screenshot["path"])
            payload = screenshot_path.read_bytes()
            if (
                len(payload) > 20 * 1024 * 1024
                or _file_sha256(screenshot_path) != screenshot["sha256"]
            ):
                raise EvidenceValidationError("screenshot_digest_invalid")
            width, height = _png_dimensions(payload)
            if (screenshot["width"], screenshot["height"]) != (width, height):
                raise EvidenceValidationError("screenshot_dimensions_invalid")
            dimensions[name] = (width, height)
        if dimensions["desktop"][0] < 1024 or dimensions["desktop"][1] < 720:
            raise EvidenceValidationError("desktop_viewport_invalid")
        if not 320 <= dimensions["mobile"][0] <= 768 or dimensions["mobile"][1] < 568:
            raise EvidenceValidationError("mobile_viewport_invalid")
        return {"passed": True, "report_sha256": report_sha}
    except (EvidenceValidationError, OSError, UnicodeError, json.JSONDecodeError) as error:
        return _failed_gate(_evidence_code(error, "browser_report_invalid"))


def validate_live_provider_report(path: Path | None) -> dict:
    if path is None:
        return _failed_gate("live_provider_report_missing")
    try:
        value, report_sha = _load_json_file(path, 2 * 1024 * 1024)
        _require_exact(value, {"format", "episodes"}, "live_provider_report_shape_invalid")
        if value["format"] != PROVIDER_REPORT_FORMAT or not isinstance(value["episodes"], list):
            raise EvidenceValidationError("live_provider_report_format_invalid")
        if len(value["episodes"]) != len(REQUIRED_PROVIDERS):
            raise EvidenceValidationError("live_provider_coverage_invalid")
        providers: set[str] = set()
        episode_ids: set[str] = set()
        replay_hashes: set[str] = set()
        fields = {
            "accepted_provider_actions",
            "episode_id",
            "final_state_hash",
            "managed_process",
            "mode",
            "model",
            "observation_profile",
            "provider",
            "provider_calls",
            "provider_failures",
            "replay_path",
            "replay_sha256",
            "replay_verified",
            "task_id",
            "terminal_outcome",
            "windows",
        }
        for episode in value["episodes"]:
            _require_exact(episode, fields, "live_provider_episode_shape_invalid")
            provider = episode["provider"]
            if provider not in REQUIRED_PROVIDERS or provider in providers:
                raise EvidenceValidationError("live_provider_coverage_invalid")
            providers.add(provider)
            if not _valid_identifier(episode["model"]) or not _valid_identifier(
                episode["episode_id"]
            ):
                raise EvidenceValidationError("live_provider_identity_invalid")
            episode_ids.add(episode["episode_id"])
            if (
                episode["mode"] != "solo-curriculum-v0"
                or episode["task_id"]
                not in {
                    "orientation-v0",
                    "interaction-v0",
                    "construction-v0",
                    "neutral-encounter-v0",
                }
                or episode["observation_profile"] != "hybrid-visible-v1"
                or episode["managed_process"] is not True
                or episode["terminal_outcome"] != "success"
                or episode["replay_verified"] is not True
            ):
                raise EvidenceValidationError("live_provider_episode_not_certifiable")
            for count_name in (
                "accepted_provider_actions",
                "provider_calls",
                "provider_failures",
                "windows",
            ):
                _require_integer(episode[count_name], 0, 1_000_000, "live_provider_counts_invalid")
            if (
                episode["windows"] < 1
                or episode["provider_calls"] < 1
                or episode["accepted_provider_actions"] < 1
                or episode["accepted_provider_actions"] > episode["provider_calls"]
                or episode["provider_failures"] != 0
            ):
                raise EvidenceValidationError("live_provider_counts_invalid")
            if not _valid_sha(episode["replay_sha256"]) or not _valid_sha(
                episode["final_state_hash"]
            ):
                raise EvidenceValidationError("live_provider_digest_invalid")
            replay_path = _report_file(Path(path), episode["replay_path"])
            if _file_sha256(replay_path) != episode["replay_sha256"]:
                raise EvidenceValidationError("live_provider_replay_digest_invalid")
            replay = _verify_replay_file(replay_path, 16 * 1024 * 1024)
            _validate_replay_summary(replay, episode)
            replay_hashes.add(episode["replay_sha256"])
        if providers != REQUIRED_PROVIDERS or len(episode_ids) != 3 or len(replay_hashes) != 3:
            raise EvidenceValidationError("live_provider_coverage_invalid")
        return {
            "passed": True,
            "providers": sorted(providers),
            "report_sha256": report_sha,
        }
    except (EvidenceValidationError, OSError, UnicodeError, json.JSONDecodeError) as error:
        return _failed_gate(_evidence_code(error, "live_provider_report_invalid"))


def validate_live_duel_report(path: Path | None) -> dict:
    """Verify a complete two-model, two-leg duel and both retained evidence layers."""

    if path is None:
        return _failed_gate("live_duel_report_missing")
    try:
        report_path = Path(path)
        value, report_sha = _load_json_file(report_path, 2 * 1024 * 1024)
        _require_exact(value, {"format", "series"}, "live_duel_report_shape_invalid")
        if value["format"] != LIVE_DUEL_REPORT_FORMAT:
            raise EvidenceValidationError("live_duel_report_format_invalid")
        series = value["series"]
        fields = {
            "bundles",
            "decision_ticks",
            "draws",
            "entrant_wins",
            "entrants",
            "fairness_lock_sha256",
            "legs",
            "max_live_provider_calls",
            "mode",
            "observation_profile",
            "plan_sha256",
            "rerun_occurred",
            "seed",
            "series_id",
            "status",
            "task_id",
            "total_verified_provider_calls",
            "winner_entrant_id",
        }
        _require_exact(series, fields, "live_duel_series_shape_invalid")
        if (
            series["status"] != "complete"
            or series["mode"] != "model-duel-v0"
            or series["task_id"] != "central-relay-v0"
            or series["observation_profile"] != "hybrid-visible-v1"
            or series["decision_ticks"] != 10
            or not isinstance(series["rerun_occurred"], bool)
            or not _valid_identifier(series["series_id"])
            or not _valid_sha(series["plan_sha256"])
            or not _valid_sha(series["fairness_lock_sha256"])
        ):
            raise EvidenceValidationError("live_duel_identity_invalid")
        for name, lower, upper in (
            ("seed", 0, 2**63 - 1),
            ("draws", 0, 2),
            ("max_live_provider_calls", 4, 720),
            ("total_verified_provider_calls", 4, 720),
        ):
            _require_integer(series[name], lower, upper, "live_duel_counts_invalid")
        if series["total_verified_provider_calls"] > series["max_live_provider_calls"]:
            raise EvidenceValidationError("live_duel_counts_invalid")

        entrants = series["entrants"]
        if not isinstance(entrants, list) or len(entrants) != 2:
            raise EvidenceValidationError("live_duel_entrants_invalid")
        entrant_ids: set[str] = set()
        verified_calls = 0
        for entrant in entrants:
            _require_exact(
                entrant,
                {"entrant_id", "model", "provider", "verified_provider_calls"},
                "live_duel_entrant_shape_invalid",
            )
            if (
                entrant["provider"] not in REQUIRED_PROVIDERS
                or not _valid_identifier(entrant["entrant_id"])
                or not _valid_identifier(entrant["model"])
                or entrant["entrant_id"] in entrant_ids
            ):
                raise EvidenceValidationError("live_duel_entrants_invalid")
            _require_integer(
                entrant["verified_provider_calls"], 2, 360, "live_duel_counts_invalid"
            )
            entrant_ids.add(entrant["entrant_id"])
            verified_calls += entrant["verified_provider_calls"]
        if verified_calls != series["total_verified_provider_calls"]:
            raise EvidenceValidationError("live_duel_counts_invalid")

        wins = series["entrant_wins"]
        if not isinstance(wins, list) or len(wins) != 2:
            raise EvidenceValidationError("live_duel_outcome_invalid")
        for count in wins:
            _require_integer(count, 0, 2, "live_duel_outcome_invalid")
        if sum(wins) + series["draws"] != 2:
            raise EvidenceValidationError("live_duel_outcome_invalid")
        winner = series["winner_entrant_id"]
        if winner is not None and winner not in entrant_ids:
            raise EvidenceValidationError("live_duel_outcome_invalid")

        bundles = series["bundles"]
        _require_exact(bundles, {"protected", "public"}, "live_duel_bundles_invalid")
        bundle_values: dict[str, bytes] = {}
        for layer in ("public", "protected"):
            descriptor = bundles[layer]
            _require_exact(descriptor, {"path", "sha256"}, "live_duel_bundle_invalid")
            bundle_path = _report_file(report_path, descriptor["path"])
            payload = bundle_path.read_bytes()
            if len(payload) > 64 * 1024 * 1024 or _file_sha256(bundle_path) != descriptor["sha256"]:
                raise EvidenceValidationError("live_duel_bundle_digest_invalid")
            bundle_values[layer] = payload
        public_pair = DuelSeriesEvidenceBundle.verify(bundle_values["public"])
        protected_pair = DuelSeriesEvidenceBundle.verify(bundle_values["protected"])
        identity = (
            series["series_id"],
            series["plan_sha256"],
            series["fairness_lock_sha256"],
        )
        if (
            public_pair.layer != "public"
            or protected_pair.layer != "protected"
            or (public_pair.series_id, public_pair.plan_sha256, public_pair.fairness_lock_sha256)
            != identity
            or (
                protected_pair.series_id,
                protected_pair.plan_sha256,
                protected_pair.fairness_lock_sha256,
            )
            != identity
        ):
            raise EvidenceValidationError("live_duel_bundle_identity_invalid")
        verified_replays = verify_offline_paired_duel(
            bundle_values["protected"],
            package=EmbodimentProtocolPackage.from_repository(ROOT),
        )

        legs = series["legs"]
        if not isinstance(legs, list) or len(legs) != 2 or len(verified_replays) != 2:
            raise EvidenceValidationError("live_duel_leg_coverage_invalid")
        total_leg_calls = 0
        evidence_entrants: list[dict[str, object]] | None = None
        evidence_calls: dict[str, int] = {}
        evidence_wins: list[int] = [0, 0]
        evidence_draws = 0
        for index, (leg, replay) in enumerate(zip(legs, verified_replays)):
            replay_bytes = protected_pair.legs[index].read("authority_replay")
            telemetry = strict_json_loads(protected_pair.legs[index].read("telemetry"))
            if not isinstance(telemetry, dict):
                raise EvidenceValidationError("live_duel_protected_evidence_invalid")
            fairness_lock = telemetry.get("fairness_lock")
            leg_plan = telemetry.get("leg_plan")
            verification = telemetry.get("verification")
            audits = telemetry.get("provider_audits")
            if (
                not isinstance(fairness_lock, dict)
                or not isinstance(leg_plan, dict)
                or not isinstance(verification, dict)
                or not isinstance(audits, list)
                or not isinstance(fairness_lock.get("entrants"), list)
                or not isinstance(leg_plan.get("assignments"), list)
            ):
                raise EvidenceValidationError("live_duel_protected_evidence_invalid")
            locked_entrants = fairness_lock["entrants"]
            current_entrants = []
            for locked in locked_entrants:
                if not isinstance(locked, dict):
                    raise EvidenceValidationError("live_duel_protected_evidence_invalid")
                current_entrants.append(
                    {
                        "entrant_id": locked.get("entrant_id"),
                        "model": locked.get("model"),
                        "provider": locked.get("provider"),
                    }
                )
            if evidence_entrants is None:
                evidence_entrants = current_entrants
                evidence_calls = {
                    str(entrant["entrant_id"]): 0 for entrant in evidence_entrants
                }
            if (
                current_entrants != evidence_entrants
                or fairness_lock.get("seed") != series["seed"]
                or leg_plan.get("series_id") != series["series_id"]
                or leg_plan.get("leg_index") != index
                or leg_plan.get("decision_ticks") != 10
            ):
                raise EvidenceValidationError("live_duel_protected_identity_invalid")
            failures = 0
            for audit in audits:
                if not isinstance(audit, dict) or not isinstance(audit.get("result"), dict):
                    raise EvidenceValidationError("live_duel_protected_evidence_invalid")
                audit_entrant = audit.get("entrant_id")
                if audit_entrant not in evidence_calls:
                    raise EvidenceValidationError("live_duel_protected_identity_invalid")
                evidence_calls[str(audit_entrant)] += 1
                if audit["result"].get("failure") is not None:
                    failures += 1
            outcome = verification.get("outcome")
            winner_participant = verification.get("winner_participant_id")
            winner_entrant: str | None = None
            if outcome == "draw":
                evidence_draws += 1
            elif outcome == "win":
                assignments = {
                    assignment.get("participant_id"): assignment.get("entrant_id")
                    for assignment in leg_plan["assignments"]
                    if isinstance(assignment, dict)
                }
                winner_entrant = assignments.get(winner_participant)
                if winner_entrant not in evidence_calls:
                    raise EvidenceValidationError("live_duel_protected_outcome_invalid")
                entrant_order = [str(value["entrant_id"]) for value in evidence_entrants]
                evidence_wins[entrant_order.index(winner_entrant)] += 1
            else:
                raise EvidenceValidationError("live_duel_protected_outcome_invalid")
            _require_exact(
                leg,
                {
                    "episode_id",
                    "final_state_hash",
                    "leg_index",
                    "outcome",
                    "provider_calls",
                    "provider_failures",
                    "replay_sha256",
                    "windows",
                },
                "live_duel_leg_shape_invalid",
            )
            if (
                leg["leg_index"] != index
                or not _valid_identifier(leg["episode_id"])
                or leg["outcome"] != outcome
                or leg["provider_failures"] != failures
                or failures != 0
                or leg["episode_id"] != replay.get("config", {}).get("episode_id")
                or leg["replay_sha256"] != hashlib.sha256(replay_bytes).hexdigest()
                or leg["final_state_hash"] != replay.get("final_state_hash")
            ):
                raise EvidenceValidationError("live_duel_leg_invalid")
            _require_integer(leg["windows"], 1, 180, "live_duel_leg_invalid")
            _require_integer(leg["provider_calls"], 2, 360, "live_duel_leg_invalid")
            if leg["provider_calls"] != len(audits) or leg["provider_calls"] != leg["windows"] * 2:
                raise EvidenceValidationError("live_duel_leg_invalid")
            total_leg_calls += leg["provider_calls"]
        assert evidence_entrants is not None
        expected_entrants = [
            {
                **entrant,
                "verified_provider_calls": evidence_calls[str(entrant["entrant_id"])],
            }
            for entrant in evidence_entrants
        ]
        evidence_winner = None
        if evidence_wins[0] != evidence_wins[1]:
            evidence_winner = evidence_entrants[
                0 if evidence_wins[0] > evidence_wins[1] else 1
            ]["entrant_id"]
        if (
            entrants != expected_entrants
            or wins != evidence_wins
            or series["draws"] != evidence_draws
            or winner != evidence_winner
            or total_leg_calls != series["total_verified_provider_calls"]
            or total_leg_calls != sum(evidence_calls.values())
        ):
            raise EvidenceValidationError("live_duel_counts_invalid")
        return {
            "passed": True,
            "providers": sorted({entrant["provider"] for entrant in entrants}),
            "report_sha256": report_sha,
        }
    except (
        EvidenceValidationError,
        OSError,
        UnicodeError,
        json.JSONDecodeError,
        ValueError,
    ) as error:
        return _failed_gate(_evidence_code(error, "live_duel_report_invalid"))


def validate_y_bot_intake(
    path: Path,
    *,
    repository_root: Path = ROOT,
    presentation_script: Path = PRESENTATION_SCRIPT,
    presentation_scene: Path = PRESENTATION_SCENE,
) -> dict:
    try:
        value, manifest_sha = _load_json_file(path, 262_144)
        _require_exact(
            value,
            {
                "format",
                "asset_identity",
                "human_approved",
                "review",
                "base",
                "clips",
                "presentation_scene",
            },
            "y_bot_manifest_shape_invalid",
        )
        if (
            value["format"] != Y_BOT_FORMAT
            or value["asset_identity"] != "mixamo-y-bot"
            or value["human_approved"] is not True
        ):
            raise EvidenceValidationError("y_bot_approval_invalid")
        review = value["review"]
        _require_exact(
            review,
            {
                "reviewer",
                "reviewed_at",
                "downloaded_at",
                "source_url",
                "license_terms",
                "export_settings",
            },
            "y_bot_review_invalid",
        )
        if not _valid_identifier(review["reviewer"]):
            raise EvidenceValidationError("y_bot_reviewer_invalid")
        if not _utc_timestamp(review["reviewed_at"]) or not _utc_timestamp(review["downloaded_at"]):
            raise EvidenceValidationError("y_bot_timestamp_invalid")
        source = urlparse(review["source_url"] if isinstance(review["source_url"], str) else "")
        if (
            source.scheme != "https"
            or not source.hostname
            or not source.hostname.endswith("mixamo.com")
        ):
            raise EvidenceValidationError("y_bot_source_invalid")
        if (
            not isinstance(review["license_terms"], str)
            or not 1 <= len(review["license_terms"]) <= 4096
        ):
            raise EvidenceValidationError("y_bot_license_invalid")
        expected_export = {
            "character": "Y Bot",
            "clips_without_skin": True,
            "format": "FBX Binary",
            "pose": "T-pose",
            "with_skin": True,
        }
        if review["export_settings"] != expected_export:
            raise EvidenceValidationError("y_bot_export_settings_invalid")
        base_path = _validate_hashed_repository_file(
            value["base"], repository_root, {"path", "sha256"}, "y_bot_base_invalid"
        )
        if (
            not base_path.relative_to(repository_root.resolve())
            .as_posix()
            .startswith("godot/assets/external/mixamo/")
        ):
            raise EvidenceValidationError("y_bot_base_location_invalid")
        if not isinstance(value["clips"], dict) or set(value["clips"]) != REQUIRED_Y_BOT_CLIPS:
            raise EvidenceValidationError("y_bot_clips_invalid")
        for clip in value["clips"].values():
            _require_exact(clip, {"path", "sha256", "animation_only"}, "y_bot_clip_invalid")
            if clip["animation_only"] is not True:
                raise EvidenceValidationError("y_bot_clip_skin_invalid")
            clip_path = _validate_hashed_repository_file(
                {"path": clip["path"], "sha256": clip["sha256"]},
                repository_root,
                {"path", "sha256"},
                "y_bot_clip_invalid",
            )
            if (
                not clip_path.relative_to(repository_root.resolve())
                .as_posix()
                .startswith("godot/assets/external/mixamo/")
            ):
                raise EvidenceValidationError("y_bot_clip_location_invalid")
        scene_path = _validate_hashed_repository_file(
            value["presentation_scene"],
            repository_root,
            {"path", "sha256"},
            "y_bot_presentation_scene_invalid",
        )
        scene_relative = scene_path.relative_to(repository_root.resolve()).as_posix()
        if (
            not scene_relative.startswith("godot/scenes/embodiment/")
            or scene_path.suffix != ".tscn"
        ):
            raise EvidenceValidationError("y_bot_presentation_scene_invalid")
        scene_text = scene_path.read_text(encoding="utf-8")
        base_resource = _godot_resource_path(base_path, repository_root)
        if "AnimationTree" not in scene_text or base_resource not in scene_text:
            raise EvidenceValidationError("y_bot_animation_tree_invalid")
        if any(clip_name not in scene_text for clip_name in REQUIRED_Y_BOT_CLIPS):
            raise EvidenceValidationError("y_bot_animation_mapping_invalid")
        integration = presentation_script.read_text(
            encoding="utf-8"
        ) + presentation_scene.read_text(encoding="utf-8")
        final_resource = _godot_resource_path(scene_path, repository_root)
        if final_resource not in integration:
            raise EvidenceValidationError("y_bot_presentation_not_integrated")
        if "procedural_operator_placeholder" in integration or re.search(
            r"presentation_placeholder[^\n]{0,64}\btrue\b", integration
        ):
            raise EvidenceValidationError("y_bot_placeholder_still_active")
        return {"passed": True, "manifest_sha256": manifest_sha}
    except (EvidenceValidationError, OSError, UnicodeError, json.JSONDecodeError) as error:
        return _failed_gate(_evidence_code(error, "y_bot_manifest_invalid"))


def validate_release_capabilities(path: Path) -> dict:
    """Validate a release overlay bound to the immutable authority package."""

    if not Path(path).is_file():
        return _failed_gate("runtime_capabilities_not_released")

    try:
        release_path = Path(path)
        manifest, digest = _load_json_file(release_path, 1_048_576)
        _require_exact(
            manifest,
            {
                "capabilities",
                "environment_id",
                "format",
                "protocol_package_sha256",
                "protocol_version",
            },
            "runtime_capabilities_overlay_invalid",
        )
        if release_path.read_bytes() != canonical_json_bytes(manifest) + b"\n":
            raise EvidenceValidationError("runtime_capabilities_overlay_noncanonical")
        package_sha256 = EmbodimentProtocolPackage.from_repository(ROOT).package_sha256
        if (
            manifest["format"] != RELEASE_FORMAT
            or manifest["environment_id"] != RELEASE_ENVIRONMENT_ID
            or manifest["protocol_version"] != RELEASE_PROTOCOL_VERSION
            or manifest["protocol_package_sha256"] != package_sha256
            or manifest["capabilities"] != RELEASE_CAPABILITIES
        ):
            raise EvidenceValidationError("runtime_capabilities_not_released")
        return {
            "passed": True,
            "manifest_sha256": digest,
            "protocol_package_sha256": package_sha256,
        }
    except (EvidenceValidationError, OSError, UnicodeError, json.JSONDecodeError) as error:
        return _failed_gate(_evidence_code(error, "runtime_capabilities_invalid"))


def validate_final_video(path: Path | None, y_bot_gate: Mapping[str, object]) -> dict:
    if path is None:
        return _failed_gate("final_video_missing")
    if y_bot_gate.get("passed") is not True:
        return _failed_gate("final_video_y_bot_unverified")
    try:
        video_path = Path(path).resolve()
        if not video_path.is_file() or "preview" in video_path.name.lower():
            raise EvidenceValidationError("final_video_path_invalid")
        with video_path.open("rb") as handle:
            prefix = handle.read(8 * 1024 * 1024)
        if len(prefix) < 32 or b"ftyp" not in prefix[:32]:
            raise EvidenceValidationError("final_video_container_invalid")
        moov, mdat = prefix.find(b"moov"), prefix.find(b"mdat")
        if moov < 0 or mdat < 0 or moov > mdat:
            raise EvidenceValidationError("final_video_faststart_invalid")
        video_sha = _file_sha256(video_path)
        evidence_path = video_path.with_suffix(video_path.suffix + ".evidence.json")
        value, evidence_sha = _load_json_file(evidence_path, 1_048_576)
        _require_exact(
            value,
            {"format", "renderer", "placeholder", "y_bot_manifest_sha256", "video", "replays"},
            "final_video_evidence_shape_invalid",
        )
        if (
            value["format"] != FINAL_VIDEO_FORMAT
            or value["renderer"] != "godot-movie-maker+ffmpeg"
            or value["placeholder"] is not False
            or value["y_bot_manifest_sha256"] != y_bot_gate.get("manifest_sha256")
        ):
            raise EvidenceValidationError("final_video_evidence_invalid")
        video = value["video"]
        _require_exact(
            video,
            {
                "path",
                "sha256",
                "width",
                "height",
                "fps",
                "video_codec",
                "pixel_format",
                "audio_codec",
                "faststart",
            },
            "final_video_metadata_invalid",
        )
        if _report_file(evidence_path, video["path"]) != video_path:
            raise EvidenceValidationError("final_video_path_mismatch")
        if video != {
            "path": video["path"],
            "sha256": video_sha,
            "width": 1920,
            "height": 1080,
            "fps": 30,
            "video_codec": "h264",
            "pixel_format": "yuv420p",
            "audio_codec": "aac",
            "faststart": True,
        }:
            raise EvidenceValidationError("final_video_metadata_invalid")
        if not isinstance(value["replays"], list) or len(value["replays"]) != 3:
            raise EvidenceValidationError("final_video_replays_invalid")
        replay_fields = {"role", "path", "sha256", "verified"}
        by_role: dict[str, tuple[dict, dict]] = {}
        for replay_evidence in value["replays"]:
            _require_exact(replay_evidence, replay_fields, "final_video_replay_invalid")
            role = replay_evidence["role"]
            if role in by_role or role not in {"stage-c", "duel-leg-a", "duel-leg-b"}:
                raise EvidenceValidationError("final_video_replays_invalid")
            if replay_evidence["verified"] is not True or not _valid_sha(replay_evidence["sha256"]):
                raise EvidenceValidationError("final_video_replay_invalid")
            replay_path = _report_file(evidence_path, replay_evidence["path"])
            if _file_sha256(replay_path) != replay_evidence["sha256"]:
                raise EvidenceValidationError("final_video_replay_digest_invalid")
            replay = _verify_replay_file(replay_path, 16 * 1024 * 1024)
            by_role[role] = (replay_evidence, replay)
        if set(by_role) != {"stage-c", "duel-leg-a", "duel-leg-b"}:
            raise EvidenceValidationError("final_video_replays_invalid")
        stage_config = _replay_config(by_role["stage-c"][1])
        if (
            stage_config.get("mode") != "solo-curriculum-v0"
            or stage_config.get("task_id") != "construction-v0"
            or stage_config.get("observation_profile") != "hybrid-visible-v1"
        ):
            raise EvidenceValidationError("final_video_stage_c_invalid")
        duel_configs = [_replay_config(by_role[role][1]) for role in ("duel-leg-a", "duel-leg-b")]
        if (
            duel_configs[0].get("mode") not in {"scripted-duel-v0", "model-duel-v0"}
            or duel_configs[1].get("mode") != duel_configs[0].get("mode")
            or any(config.get("task_id") != "central-relay-v0" for config in duel_configs)
            or any(
                config.get("observation_profile") != "hybrid-visible-v1" for config in duel_configs
            )
            or duel_configs[0].get("episode_id") == duel_configs[1].get("episode_id")
        ):
            raise EvidenceValidationError("final_video_duel_pair_invalid")
        return {
            "passed": True,
            "evidence_sha256": evidence_sha,
            "video_sha256": video_sha,
        }
    except (EvidenceValidationError, OSError, UnicodeError, json.JSONDecodeError) as error:
        return _failed_gate(_evidence_code(error, "final_video_invalid"))


def _validate_replay_summary(replay: object, episode: Mapping[str, object]) -> None:
    config = _replay_config(replay)
    if (
        config.get("episode_id") != episode["episode_id"]
        or config.get("mode") != episode["mode"]
        or config.get("task_id") != episode["task_id"]
        or config.get("observation_profile") != episode["observation_profile"]
    ):
        raise EvidenceValidationError("live_provider_replay_config_invalid")
    if not isinstance(replay, dict):
        raise EvidenceValidationError("replay_invalid")
    terminal = replay.get("final_terminal")
    steps = replay.get("steps")
    if (
        not isinstance(terminal, dict)
        or terminal.get("ended") is not True
        or terminal.get("outcome") != episode["terminal_outcome"]
        or replay.get("final_state_hash") != episode["final_state_hash"]
        or not isinstance(steps, list)
        or len(steps) != episode["windows"]
    ):
        raise EvidenceValidationError("live_provider_replay_result_invalid")


def _replay_config(replay: object) -> dict:
    if not isinstance(replay, dict) or not isinstance(replay.get("config"), dict):
        raise EvidenceValidationError("replay_invalid")
    return replay["config"]


def _verify_replay_file(path: Path, maximum_bytes: int) -> dict:
    payload = Path(path).read_bytes()
    if not payload or len(payload) > maximum_bytes:
        raise EvidenceValidationError("replay_file_invalid")
    try:
        package = EmbodimentProtocolPackage.from_repository(ROOT)
        replay = verify_replay_bytes(payload, package=package)
    except Exception as error:
        raise EvidenceValidationError("replay_verification_failed") from error
    if not isinstance(replay, dict):
        raise EvidenceValidationError("replay_verification_failed")
    return replay


def _load_json_file(path: Path, maximum_bytes: int) -> tuple[dict, str]:
    resolved = Path(path).resolve()
    if not resolved.is_file() or resolved.stat().st_size > maximum_bytes:
        raise EvidenceValidationError("evidence_file_invalid")
    payload = resolved.read_bytes()
    value = json.loads(payload.decode("utf-8"), object_pairs_hook=_reject_duplicate_keys)
    if not isinstance(value, dict):
        raise EvidenceValidationError("evidence_root_invalid")
    return value, hashlib.sha256(payload).hexdigest()


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict:
    output = {}
    for key, value in pairs:
        if key in output:
            raise EvidenceValidationError("duplicate_json_key")
        output[key] = value
    return output


def _require_exact(value: object, fields: set[str], code: str) -> None:
    if not isinstance(value, dict) or set(value) != fields:
        raise EvidenceValidationError(code)


def _require_integer(value: object, minimum: int, maximum: int, code: str) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise EvidenceValidationError(code)


def _report_file(report_path: Path, value: object) -> Path:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise EvidenceValidationError("evidence_path_invalid")
    candidate = Path(value)
    resolved = (
        candidate.resolve()
        if candidate.is_absolute()
        else (report_path.parent / candidate).resolve()
    )
    if not resolved.is_file():
        raise EvidenceValidationError("evidence_path_invalid")
    return resolved


def _validate_hashed_repository_file(
    value: object,
    repository_root: Path,
    fields: set[str],
    code: str,
) -> Path:
    _require_exact(value, fields, code)
    assert isinstance(value, dict)
    if not isinstance(value["path"], str) or not _valid_sha(value["sha256"]):
        raise EvidenceValidationError(code)
    relative = Path(value["path"])
    if relative.is_absolute() or ".." in relative.parts:
        raise EvidenceValidationError(code)
    root = repository_root.resolve()
    resolved = (root / relative).resolve()
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise EvidenceValidationError(code) from error
    if not resolved.is_file() or _file_sha256(resolved) != value["sha256"]:
        raise EvidenceValidationError(code)
    return resolved


def _godot_resource_path(path: Path, repository_root: Path) -> str:
    relative = path.resolve().relative_to(repository_root.resolve()).as_posix()
    if not relative.startswith("godot/"):
        raise EvidenceValidationError("godot_resource_path_invalid")
    return "res://" + relative.removeprefix("godot/")


def _png_dimensions(payload: bytes) -> tuple[int, int]:
    if len(payload) < 57 or payload[:8] != b"\x89PNG\r\n\x1a\n":
        raise EvidenceValidationError("screenshot_png_invalid")
    offset = 8
    dimensions: tuple[int, int] | None = None
    saw_idat = False
    saw_iend = False
    chunk_index = 0
    while offset + 12 <= len(payload):
        length = int.from_bytes(payload[offset : offset + 4], "big")
        chunk_type = payload[offset + 4 : offset + 8]
        data_start = offset + 8
        data_end = data_start + length
        crc_end = data_end + 4
        if length > 20 * 1024 * 1024 or crc_end > len(payload):
            raise EvidenceValidationError("screenshot_png_invalid")
        expected_crc = int.from_bytes(payload[data_end:crc_end], "big")
        if zlib.crc32(chunk_type + payload[data_start:data_end]) & 0xFFFFFFFF != expected_crc:
            raise EvidenceValidationError("screenshot_png_invalid")
        if chunk_index == 0:
            if chunk_type != b"IHDR" or length != 13:
                raise EvidenceValidationError("screenshot_png_invalid")
            width = int.from_bytes(payload[data_start : data_start + 4], "big")
            height = int.from_bytes(payload[data_start + 4 : data_start + 8], "big")
            if width < 1 or height < 1:
                raise EvidenceValidationError("screenshot_png_invalid")
            dimensions = (width, height)
        elif chunk_type == b"IHDR":
            raise EvidenceValidationError("screenshot_png_invalid")
        if chunk_type == b"IDAT":
            saw_idat = True
        if chunk_type == b"IEND":
            if length != 0 or crc_end != len(payload):
                raise EvidenceValidationError("screenshot_png_invalid")
            saw_iend = True
            break
        offset = crc_end
        chunk_index += 1
    if dimensions is None or not saw_idat or not saw_iend:
        raise EvidenceValidationError("screenshot_png_invalid")
    return dimensions


def _utc_timestamp(value: object) -> bool:
    if not isinstance(value, str) or not value.endswith("Z"):
        return False
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        return False
    return parsed.tzinfo == timezone.utc


def _valid_identifier(value: object) -> bool:
    return isinstance(value, str) and _IDENTIFIER.fullmatch(value) is not None


def _valid_sha(value: object) -> bool:
    return isinstance(value, str) and _SHA256.fullmatch(value) is not None


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _failed_gate(code: str) -> dict:
    return {"passed": False, "code": code}


def _evidence_code(error: Exception, fallback: str) -> str:
    if isinstance(error, EvidenceValidationError) and str(error):
        return str(error)
    return fallback


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--preview-video", type=Path)
    parser.add_argument("--browser-qa-report", type=Path)
    parser.add_argument("--live-provider-report", type=Path)
    parser.add_argument("--live-duel-report", type=Path)
    parser.add_argument(
        "--readiness-report",
        type=Path,
        help="Credential-free dashboard readiness output written only by a passing final seal.",
    )
    parser.add_argument(
        "--final-video",
        type=Path,
        help="Final MP4 accompanied by <name>.mp4.evidence.json",
    )
    parser.add_argument("--only", action="append", default=[])
    parser.add_argument("--resume", action="store_true")
    parser.add_argument(
        "--final-seal",
        action="store_true",
        help="Exit nonzero unless every offline and external MVP gate passes.",
    )
    return parser


def _argument_error(arguments: argparse.Namespace) -> str | None:
    if arguments.resume and arguments.report is None:
        return "--resume requires --report"
    if not arguments.final_seal:
        return None
    if arguments.only:
        return "--final-seal cannot be combined with --only"
    required = {
        "--report": arguments.report,
        "--readiness-report": arguments.readiness_report,
        "--browser-qa-report": arguments.browser_qa_report,
        "--live-provider-report": arguments.live_provider_report,
        "--live-duel-report": arguments.live_duel_report,
        "--final-video": arguments.final_video,
    }
    missing = [name for name, value in required.items() if value is None]
    if missing:
        return "--final-seal requires " + ", ".join(missing)
    return None


def _exit_code(report: Mapping[str, Any], *, final_seal: bool) -> int:
    if report.get("selected_steps_passed") is not True:
        return 1
    if final_seal and report.get("mvp_certified") is not True:
        return 2
    return 0


def _final_readiness_report(
    report: Mapping[str, Any], *, certification_report: Path
) -> dict[str, object]:
    if report.get("source_fingerprint_version") != SOURCE_FINGERPRINT_V2:
        raise ValueError("final certification source fingerprint version is invalid")
    external = report.get("external_gates")
    if not isinstance(external, dict):
        raise ValueError("final certification external gates are invalid")
    gates = {
        "offline": validate_offline_certification_report(certification_report),
        "approved_mixamo_y_bot": external.get("approved_mixamo_y_bot"),
        "live_provider_managed_solo": external.get("live_provider_managed_solo"),
        "live_model_paired_duel": external.get("live_model_paired_duel"),
        "browser_visual_qa": external.get("browser_visual_qa"),
        "final_native_video": external.get("final_native_video"),
    }
    runtime = external.get("certified_runtime_capabilities")
    if (
        any(not isinstance(gate, dict) or gate.get("passed") is not True for gate in gates.values())
        or not isinstance(runtime, dict)
        or runtime.get("passed") is not True
    ):
        raise ValueError("final certification cannot produce a passing readiness report")
    return {
        "format": READINESS_REPORT_FORMAT,
        "gates": gates,
        "ready_for_promotion": True,
        "runtime_capabilities": runtime,
        "source_fingerprint": report["source_fingerprint"],
        "source_fingerprint_version": SOURCE_FINGERPRINT_V2,
    }


def _atomic_write(path: Path, payload: bytes) -> None:
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            dir=destination.parent,
            prefix=f".{destination.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary = Path(handle.name)
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> int:
    parser = _parser()
    arguments = parser.parse_args()
    if error := _argument_error(arguments):
        parser.error(error)
    prior_results = ()
    if arguments.resume and arguments.report.is_file():
        try:
            prior_report, _ = _load_json_file(arguments.report, 8 * 1024 * 1024)
            prior_results = tuple(prior_report.get("results", ()))
        except (EvidenceValidationError, OSError, UnicodeError, json.JSONDecodeError):
            parser.error("resume report is invalid")
    try:
        report = run_certification(
            preview_video=arguments.preview_video,
            browser_qa_report=arguments.browser_qa_report,
            live_provider_report=arguments.live_provider_report,
            live_duel_report=arguments.live_duel_report,
            final_video=arguments.final_video,
            only=frozenset(arguments.only),
            prior_results=prior_results,
        )
    except ValueError as error:
        parser.error(str(error))
    encoded = json.dumps(report, sort_keys=True, separators=(",", ":")) + "\n"
    if arguments.report is not None:
        _atomic_write(arguments.report, encoded.encode("utf-8"))
    print(encoded, end="")
    exit_code = _exit_code(report, final_seal=arguments.final_seal)
    if exit_code == 0 and arguments.final_seal:
        assert arguments.report is not None and arguments.readiness_report is not None
        readiness = _final_readiness_report(report, certification_report=arguments.report)
        _atomic_write(
            arguments.readiness_report,
            canonical_json_bytes(readiness) + b"\n",
        )
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
