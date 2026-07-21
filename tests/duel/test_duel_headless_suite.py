from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "run_duel_headless_suite.py"


def _module():
    spec = importlib.util.spec_from_file_location("run_duel_headless_suite", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def test_discovery_is_sorted_and_excludes_dedicated_harnesses() -> None:
    module = _module()
    names = [path.name for path in module.discover_runners()]

    assert names == sorted(names)
    assert "duel_core_headless_runner.gd" in names
    assert "duel_gateway_websocket_integration_runner.gd" not in names
    assert "duel_dedicated_stage_smoke_runner.gd" not in names
    assert "duel_presentation_capture_runner.gd" not in names


def test_selection_is_exact_deduplicated_and_fails_closed() -> None:
    module = _module()
    discovered = module.discover_runners()
    selected = module._select_runners(
        discovered,
        ["duel_core_headless_runner", "duel_core_headless_runner.gd"],
    )
    assert [path.name for path in selected] == ["duel_core_headless_runner.gd"]

    try:
        module._select_runners(discovered, ["duel_gateway_websocket_integration_runner"])
    except ValueError as exc:
        assert "unknown or dedicated-harness runner" in str(exc)
    else:
        raise AssertionError("dedicated WebSocket runner entered the generic suite")


def test_report_is_bounded_and_machine_readable(tmp_path: Path) -> None:
    module = _module()
    tail = module._bounded_tail("\n".join(f"line-{index}" for index in range(40)), lines=3)
    assert tail == "line-37\nline-38\nline-39"

    report = tmp_path / "report.json"
    result = module.RunnerResult(
        runner="duel_core_headless_runner.gd",
        status="passed",
        duration_ms=12,
        returncode=0,
        output_tail="DUEL_CORE_OK",
    )
    module._write_report(report, Path("/safe/godot"), [result])
    payload = json.loads(report.read_text(encoding="utf-8"))
    assert payload["format"] == "worldeval-duel-headless-certification/1.0.0"
    assert payload["summary"] == {"failed": 0, "passed": 1, "total": 1}
    assert payload["results"][0]["runner"] == "duel_core_headless_runner.gd"
