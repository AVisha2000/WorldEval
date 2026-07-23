"""Immutable, participant-safe scenario catalog for credential-free solo demos.

A scenario is product metadata around an existing authority task.  Keeping those identities
separate lets a presentation such as ``multi-action-demo-v0`` reuse the frozen
``construction-v0`` authority/replay contract without pretending that it is a new Godot task.

Policy-lock fixture material contains public identifiers and SHA-256 digests of the local policy
implementation.  It deliberately contains neither source paths nor world coordinates; those are
not participant observations and do not belong in browser-safe run metadata.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Mapping

from .protocol import canonical_json_bytes

SCENARIO_FIXTURE_VERSION = "worldarena-demo-scenario/1.0.0"

_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_AUTHORITY_TASKS = frozenset(
    (
        "orientation-v0",
        "interaction-v0",
        "construction-v0",
        "neutral-encounter-v0",
        "movement-maze-v0",
        "operator-action-course-v0",
    )
)
_OUTPUT_CONTRACTS = frozenset(("controller-action", "construction-task-plan"))
_MAX_EPISODE_TICKS = 18_000


@dataclass(frozen=True)
class DemoScenarioDefinition:
    """Strict identity, duration, and fixture inputs for one selectable demo scenario."""

    scenario_id: str
    authority_task_id: str
    policy_id: str
    provider_model: str
    display_label: str
    evaluation_profile_id: str
    output_contract: str
    terminal_tick_minimum: int
    terminal_tick_maximum: int
    episode_tick_budget: int
    total_decision_budget: int
    policy_source_ids: tuple[str, ...]
    replay_label: str

    @property
    def protocol_version(self) -> str:
        """The immutable wire package selected by this authority task.

        This stays derived instead of becoming fixture material so the original Stage A-D
        scenario locks remain byte-for-byte compatible.
        """

        if self.authority_task_id in ("movement-maze-v0", "operator-action-course-v0"):
            return "llm-controller/0.2.0"
        return "llm-controller/0.1.0"

    def __post_init__(self) -> None:
        for field_name in (
            "scenario_id",
            "authority_task_id",
            "policy_id",
            "provider_model",
            "evaluation_profile_id",
        ):
            value = getattr(self, field_name)
            if not isinstance(value, str) or _SAFE_ID.fullmatch(value) is None:
                raise ValueError(f"{field_name} must be a safe identifier")
        if self.authority_task_id not in _AUTHORITY_TASKS:
            raise ValueError("authority_task_id is not a frozen solo authority task")
        if self.output_contract not in _OUTPUT_CONTRACTS:
            raise ValueError("output_contract is unsupported")
        expected_contract = (
            "construction-task-plan"
            if self.authority_task_id == "construction-v0"
            else "controller-action"
        )
        if self.output_contract != expected_contract:
            raise ValueError("output_contract does not match the authority task")
        for field_name in (
            "terminal_tick_minimum",
            "terminal_tick_maximum",
            "episode_tick_budget",
            "total_decision_budget",
        ):
            value = getattr(self, field_name)
            if isinstance(value, bool) or not isinstance(value, int) or value < 1:
                raise ValueError(f"{field_name} must be a positive integer")
        if not (
            self.terminal_tick_minimum
            <= self.terminal_tick_maximum
            <= self.episode_tick_budget
            <= _MAX_EPISODE_TICKS
        ):
            raise ValueError("scenario horizon bounds are invalid")
        if self.total_decision_budget > self.episode_tick_budget:
            raise ValueError("total_decision_budget exceeds the episode horizon")
        if (
            not isinstance(self.policy_source_ids, tuple)
            or not self.policy_source_ids
            or len(set(self.policy_source_ids)) != len(self.policy_source_ids)
        ):
            raise ValueError("policy_source_ids must be a non-empty unique tuple")
        if any(
            not isinstance(source_id, str) or _SAFE_ID.fullmatch(source_id) is None
            for source_id in self.policy_source_ids
        ):
            raise ValueError("policy_source_ids contain an invalid identifier")
        for field_name in ("display_label", "replay_label"):
            value = getattr(self, field_name)
            if (
                not isinstance(value, str)
                or not 1 <= len(value.encode("utf-8")) <= 200
                or value != value.strip()
                or any(ord(character) < 32 for character in value)
            ):
                raise ValueError(f"{field_name} is invalid")

    def fixture_bytes(self, policy_source_sha256: Mapping[str, str]) -> bytes:
        """Return canonical lock material for exact policy-source digests.

        The caller must supply every declared source and no undeclared source.  This makes a
        policy edit change the fixture hash while keeping filesystem paths and source bytes out
        of evidence.
        """

        if not isinstance(policy_source_sha256, Mapping):
            raise TypeError("policy_source_sha256 must be a mapping")
        if set(policy_source_sha256) != set(self.policy_source_ids):
            raise ValueError("policy source identities do not match the scenario")
        sources: list[dict[str, str]] = []
        for source_id in self.policy_source_ids:
            digest = policy_source_sha256[source_id]
            if not isinstance(digest, str) or _SHA256.fullmatch(digest) is None:
                raise ValueError("policy source digest must be lowercase SHA-256")
            sources.append({"source_id": source_id, "sha256": digest})
        return canonical_json_bytes(
            {
                "authority_task_id": self.authority_task_id,
                "display_label": self.display_label,
                "episode_tick_budget": self.episode_tick_budget,
                "evaluation_profile_id": self.evaluation_profile_id,
                "fixture_version": SCENARIO_FIXTURE_VERSION,
                "output_contract": self.output_contract,
                "policy_id": self.policy_id,
                "policy_sources": sources,
                "provider_model": self.provider_model,
                "replay_label": self.replay_label,
                "scenario_id": self.scenario_id,
                "terminal_tick_maximum": self.terminal_tick_maximum,
                "terminal_tick_minimum": self.terminal_tick_minimum,
                "total_decision_budget": self.total_decision_budget,
            }
        )


_DIRECT_SOURCE_ID = "scripted-solo-demo-v1"
_CONSTRUCTION_SOURCE_ID = "scripted-construction-demo-v1"
_MOVEMENT_MAZE_SOURCE_ID = "movement-maze-visible-v1"
_OPERATOR_COURSE_SOURCE_ID = "operator-action-visible-v1"

_SCENARIOS = (
    DemoScenarioDefinition(
        scenario_id="orientation-v0",
        authority_task_id="orientation-v0",
        policy_id="orientation-demo-v1",
        provider_model="orientation-demo-v1",
        display_label="Stage A Orientation",
        evaluation_profile_id="solo-orientation-v1",
        output_contract="controller-action",
        terminal_tick_minimum=1,
        terminal_tick_maximum=600,
        episode_tick_budget=600,
        total_decision_budget=600,
        policy_source_ids=(_DIRECT_SOURCE_ID,),
        replay_label="Orientation v0 scripted demo",
    ),
    DemoScenarioDefinition(
        scenario_id="interaction-v0",
        authority_task_id="interaction-v0",
        policy_id="interaction-demo-v1",
        provider_model="interaction-demo-v1",
        display_label="Stage B Interaction",
        evaluation_profile_id="solo-interaction-v1",
        output_contract="controller-action",
        terminal_tick_minimum=1,
        terminal_tick_maximum=600,
        episode_tick_budget=600,
        total_decision_budget=600,
        policy_source_ids=(_DIRECT_SOURCE_ID,),
        replay_label="Interaction v0 scripted demo",
    ),
    DemoScenarioDefinition(
        scenario_id="construction-v0",
        authority_task_id="construction-v0",
        policy_id="construction-demo-v1",
        provider_model="construction-demo-v1",
        display_label="Stage C Construction",
        evaluation_profile_id="solo-construction-v1",
        output_contract="construction-task-plan",
        terminal_tick_minimum=1,
        terminal_tick_maximum=600,
        episode_tick_budget=600,
        total_decision_budget=600,
        policy_source_ids=(_CONSTRUCTION_SOURCE_ID,),
        replay_label="Construction v0 scripted demo",
    ),
    DemoScenarioDefinition(
        scenario_id="neutral-encounter-v0",
        authority_task_id="neutral-encounter-v0",
        policy_id="neutral-encounter-demo-v1",
        provider_model="neutral-encounter-demo-v1",
        display_label="Stage D Neutral Encounter",
        evaluation_profile_id="solo-neutral-encounter-v1",
        output_contract="controller-action",
        terminal_tick_minimum=1,
        terminal_tick_maximum=600,
        episode_tick_budget=600,
        total_decision_budget=600,
        policy_source_ids=(_DIRECT_SOURCE_ID,),
        replay_label="Neutral Encounter v0 scripted demo",
    ),
    DemoScenarioDefinition(
        scenario_id="multi-action-demo-v0",
        authority_task_id="construction-v0",
        policy_id="multi-action-construction-demo-v1",
        provider_model="construction-demo-v1",
        display_label="Multi-action solo showcase",
        evaluation_profile_id="solo-multi-action-showcase-v1",
        output_contract="construction-task-plan",
        terminal_tick_minimum=900,
        terminal_tick_maximum=1_200,
        # A 100-tick deterministic safety margin permits the terminal event to be sealed even
        # though successful authority duration must remain inside the 900-1,200 tick profile.
        episode_tick_budget=1_300,
        total_decision_budget=1_300,
        policy_source_ids=(_CONSTRUCTION_SOURCE_ID,),
        replay_label="Multi-action solo showcase",
    ),
    DemoScenarioDefinition(
        scenario_id="movement-maze-v0",
        authority_task_id="movement-maze-v0",
        policy_id="movement-maze-visible-v1",
        provider_model="movement-maze-demo-v1",
        display_label="Movement maze",
        evaluation_profile_id="solo-movement-maze-v1",
        output_contract="controller-action",
        terminal_tick_minimum=1,
        terminal_tick_maximum=200,
        episode_tick_budget=200,
        total_decision_budget=200,
        policy_source_ids=(_MOVEMENT_MAZE_SOURCE_ID,),
        replay_label="Movement Maze v0 scripted demo",
    ),
    DemoScenarioDefinition(
        scenario_id="operator-action-course-v0",
        authority_task_id="operator-action-course-v0",
        policy_id="operator-action-visible-v1",
        provider_model="operator-action-course-demo-v1",
        display_label="Operator action course",
        evaluation_profile_id="solo-operator-action-course-v1",
        output_contract="controller-action",
        terminal_tick_minimum=1,
        terminal_tick_maximum=300,
        episode_tick_budget=300,
        total_decision_budget=300,
        policy_source_ids=(_OPERATOR_COURSE_SOURCE_ID,),
        replay_label="Operator Action Course v0 scripted demo",
    ),
)

DEMO_SCENARIOS: Mapping[str, DemoScenarioDefinition] = MappingProxyType(
    {scenario.scenario_id: scenario for scenario in _SCENARIOS}
)

_SOURCE_PATHS: Mapping[str, Path] = MappingProxyType(
    {
        _DIRECT_SOURCE_ID: Path(__file__).with_name("scripted_solo_demo.py"),
        _CONSTRUCTION_SOURCE_ID: Path(__file__).with_name("scripted_construction_demo.py"),
        _MOVEMENT_MAZE_SOURCE_ID: Path(__file__)
        .with_name("control_games")
        .joinpath("movement_maze_demo.py"),
        _OPERATOR_COURSE_SOURCE_ID: Path(__file__)
        .with_name("control_games")
        .joinpath("operator_action_course_demo.py"),
    }
)


def demo_scenario(scenario_id: str) -> DemoScenarioDefinition:
    """Resolve one exact scenario identity, failing closed for aliases and task IDs."""

    if not isinstance(scenario_id, str):
        raise TypeError("scenario_id must be a string")
    try:
        return DEMO_SCENARIOS[scenario_id]
    except KeyError as error:
        raise ValueError("demo scenario is unsupported") from error


def demo_scenario_fixture_bytes(
    scenario_id: str, *, policy_source_sha256: Mapping[str, str] | None = None
) -> bytes:
    """Build stable policy-lock material for a catalog scenario.

    Production callers normally omit ``policy_source_sha256`` so the exact checked-out policy
    files are bound.  Tests and offline verifiers may inject known digests to reproduce a lock
    without depending on a checkout path.
    """

    scenario = demo_scenario(scenario_id)
    if policy_source_sha256 is None:
        policy_source_sha256 = {
            source_id: hashlib.sha256(_SOURCE_PATHS[source_id].read_bytes()).hexdigest()
            for source_id in scenario.policy_source_ids
        }
    return scenario.fixture_bytes(policy_source_sha256)


def demo_scenario_fixture_sha256(
    scenario_id: str, *, policy_source_sha256: Mapping[str, str] | None = None
) -> str:
    """Return the lowercase digest consumed by :class:`DemoPolicyLock`."""

    return hashlib.sha256(
        demo_scenario_fixture_bytes(scenario_id, policy_source_sha256=policy_source_sha256)
    ).hexdigest()


__all__ = [
    "DEMO_SCENARIOS",
    "SCENARIO_FIXTURE_VERSION",
    "DemoScenarioDefinition",
    "demo_scenario",
    "demo_scenario_fixture_bytes",
    "demo_scenario_fixture_sha256",
]
