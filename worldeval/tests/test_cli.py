from __future__ import annotations

from worldeval.cli import main


def test_worldeval_help_describes_the_feature_workflow(capsys) -> None:
    assert main(["--help"]) == 0
    captured = capsys.readouterr()
    assert "usage: worldeval <command>" in captured.out
    assert "worldeval feature --help" in captured.out
    assert captured.err == ""


def test_worldeval_unknown_command_fails_with_usage(capsys) -> None:
    assert main(["unknown"]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "usage: worldeval <command>" in captured.err
