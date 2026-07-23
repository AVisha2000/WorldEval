from __future__ import annotations

import pytest
from genesis_arena.catalog import ActionCatalog, ActionValidationError
from genesis_arena.models import ActionCommand, ActionName
from worldarena.paths import WORLDARENA_ROOT

from .helpers import observation

ROOT = WORLDARENA_ROOT


def test_catalog_emits_strict_function_tools() -> None:
    catalog = ActionCatalog(ROOT / "game" / "actions.json")

    tools = catalog.tools_for(["collect", "rest"])

    assert [tool["name"] for tool in tools] == ["collect", "rest"]
    assert all(tool["strict"] for tool in tools)
    assert all(tool["parameters"]["additionalProperties"] is False for tool in tools)


def test_build_validation_checks_inventory() -> None:
    catalog = ActionCatalog(ROOT / "game" / "actions.json")
    command = ActionCommand(
        turn=1,
        agent_id="sol",
        action=ActionName.BUILD,
        parameters={"structure": "shelter"},
        intent="Build protection before exposure becomes dangerous.",
        source="test",
    )

    with pytest.raises(ActionValidationError, match="needs 12 wood"):
        catalog.validate(command, observation(wood=4, stone=4))

    catalog.validate(command, observation(wood=12, stone=4))


def test_collection_requires_a_visible_source() -> None:
    catalog = ActionCatalog(ROOT / "game" / "actions.json")
    current = observation()
    current.visible_resources = []
    command = ActionCommand(
        turn=1,
        agent_id="sol",
        action=ActionName.COLLECT,
        parameters={"resource": "wood"},
        intent="Gather timber for shelter.",
        source="test",
    )

    with pytest.raises(ActionValidationError, match="no visible wood"):
        catalog.validate(command, current)
