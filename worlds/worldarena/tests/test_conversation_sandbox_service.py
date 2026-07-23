from __future__ import annotations

from pathlib import Path

import pytest
from worldarena.conversational_sandbox.godot import GodotConversationWarehouseRunner
from worldarena.conversational_sandbox.service import (
    SCENARIO_ID,
    ConversationSandboxService,
)
from worldarena.paths import WORLDARENA_GAMES_ROOT, WORLDARENA_GODOT_ROOT
from worldarena.replay_verifiers import default_godot_executable


@pytest.fixture
def service(tmp_path: Path) -> ConversationSandboxService:
    return ConversationSandboxService(
        runner=GodotConversationWarehouseRunner(
            executable=default_godot_executable(),
            project_path=WORLDARENA_GODOT_ROOT,
            scenario_path=(WORLDARENA_GAMES_ROOT / "conversational-warehouse/scenario.json"),
        ),
        replay_root=tmp_path,
    )


def _ambiguous_session(service: ConversationSandboxService) -> str:
    session = service.create_session(SCENARIO_ID)
    result = service.send_message(
        session["sessionId"], "Pick up that blue box and take it to loading bay B."
    )
    assert result["status"] == "clarification_required"
    assert len(result["grounding"]["clarification"]["options"]) == 2
    return session["sessionId"]


def test_large_box_delivery_is_replay_verified(service: ConversationSandboxService) -> None:
    session_id = _ambiguous_session(service)
    result = service.acknowledge(session_id, "clarification-001", "binding-blue-large")
    assert result["status"] == "completed"
    assert result["replay"]["verified"] is True
    assert any(
        receipt["label"] == "movement blocked" and receipt["state"] == "suspended"
        for receipt in result["receipts"]
    )


def test_wrong_explicit_binding_is_a_terminal_replay_failure(
    service: ConversationSandboxService,
) -> None:
    session_id = _ambiguous_session(service)
    result = service.acknowledge(session_id, "clarification-001", "binding-blue-small")
    assert result["status"] == "failed"
    assert result["replay"]["verified"] is True
    assert "failure" in result["messages"][-1]["text"]
