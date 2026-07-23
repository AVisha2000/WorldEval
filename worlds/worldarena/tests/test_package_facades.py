from __future__ import annotations

import sys

from genesis_arena.main import app as legacy_app
from worldarena.main import app as public_app
from worldarena.main import run as public_run


def test_worldarena_facade_preserves_the_legacy_application_identity() -> None:
    assert public_app is legacy_app


def test_application_keeps_legacy_and_worldeval_routes() -> None:
    paths = {route.path for route in public_app.routes}
    assert "/health" in paths
    assert "/api/replays" in paths
    assert "/api/worldeval/sandbox" in paths
    assert "/api/worldeval/sandbox/runs" in paths
    assert "/api/worldeval/replays" in paths
    assert "/api/simulations" in paths


def test_worldarena_command_help_does_not_start_the_server(
    monkeypatch,
    capsys,
) -> None:
    monkeypatch.setattr(sys, "argv", ["worldarena", "--help"])

    public_run()

    output = capsys.readouterr().out
    assert output.startswith("usage: worldarena")
    assert "WorldEval workspace" in output
