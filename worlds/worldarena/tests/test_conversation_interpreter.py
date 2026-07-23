from __future__ import annotations

from worldarena.conversational_sandbox.interpreter import DemoVisibleReferentInterpreter


def test_demo_interpreter_returns_only_visible_matching_referents() -> None:
    visible = [
        {
            "object_id": "box-blue-large-1",
            "type_id": "box",
            "traits": {"color": "blue", "size": "large"},
            "state": {"visible": True},
        },
        {
            "object_id": "box-blue-small-1",
            "type_id": "box",
            "traits": {"color": "blue", "size": "small"},
            "state": {"visible": True},
        },
        {
            "object_id": "box-red-large-1",
            "type_id": "box",
            "traits": {"color": "red", "size": "large"},
            "state": {"visible": False},
        },
    ]
    interpreter = DemoVisibleReferentInterpreter()
    assert interpreter.candidates(text="pick up the blue box", visible_objects=visible) == (
        "box-blue-large-1",
        "box-blue-small-1",
    )
    assert interpreter.candidates(text="pick up the large blue box", visible_objects=visible) == (
        "box-blue-large-1",
    )
