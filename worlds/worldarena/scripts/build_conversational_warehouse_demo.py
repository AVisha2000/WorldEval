#!/usr/bin/env python3
"""Build the checked-in, provider-free conversational warehouse replay."""

from __future__ import annotations

from worldarena.conversational_sandbox.godot import GodotConversationWarehouseRunner
from worldarena.conversational_sandbox.service import ConversationSandboxService, SCENARIO_ID
from worldarena.paths import WORLDARENA_GAMES_ROOT, WORLDARENA_GODOT_ROOT, WORLDARENA_ROOT
from worldarena.replay_verifiers import default_godot_executable


def main() -> None:
    destination = WORLDARENA_ROOT / "demos" / "conversational-warehouse-pickup" / "1.0.0"
    service = ConversationSandboxService(
        runner=GodotConversationWarehouseRunner(
            executable=default_godot_executable(),
            project_path=WORLDARENA_GODOT_ROOT,
            scenario_path=WORLDARENA_GAMES_ROOT / "conversational-warehouse" / "scenario.json",
        ),
        replay_root=destination.parent,
    )
    session = service.create_session(SCENARIO_ID)
    internal = service._session(session["sessionId"])
    internal.run_id = "1.0.0"
    service.send_message(session["sessionId"], "Pick up that blue box and take it to loading bay B.")
    result = service.acknowledge(session["sessionId"], "clarification-001", "binding-blue-large")
    assert result["status"] == "completed" and result["replay"]["verified"]
    print(f"CONVERSATIONAL_WAREHOUSE_DEMO_READY {destination}")


if __name__ == "__main__":
    main()
