"""Product catalog for the credential-free two-participant game ladder.

The catalog is deliberately small and immutable.  It binds each selectable authority task to
exactly two independent participant-visible Demo policies and to the safe authority evaluator
used after a leg seals.  Central Relay remains on the frozen v1 duel path; the additive games use
the versioned v2 managed path.
"""

from __future__ import annotations

from dataclasses import dataclass
from types import MappingProxyType
from typing import Callable, Mapping

from ..demo_provider import DemoProvider
from .checkpoint_race import (
    CHECKPOINT_RACE_MODELS,
    CHECKPOINT_RACE_SCENARIO_ID,
    build_checkpoint_race_demo_provider,
    evaluate_checkpoint_race,
)
from .relay_control import (
    RELAY_CONTROL_MODELS,
    RELAY_CONTROL_SCENARIO_ID,
    build_relay_control_demo_provider,
    evaluate_relay_control,
)
from .resource_relay import (
    RESOURCE_RELAY_MODELS,
    RESOURCE_RELAY_SCENARIO_ID,
    build_resource_relay_demo_provider,
    evaluate_resource_relay,
)
from .rts_skirmish import (
    RTS_SKIRMISH_MODELS,
    RTS_SKIRMISH_SCENARIO_ID,
    build_rts_skirmish_demo_provider,
    evaluate_rts_skirmish,
)
from .spar import SPAR_MODELS, SPAR_SCENARIO_ID, build_spar_demo_provider, evaluate_spar

CENTRAL_RELAY_TASK_ID = "central-relay-v0"
DUO_PROTOCOL_VERSION = "llm-controller/0.2.0"
CENTRAL_RELAY_PROTOCOL_VERSION = "llm-controller/0.1.0"

ProviderBuilder = Callable[..., DemoProvider]
Evaluator = Callable[[Mapping[str, object]], dict[str, object]]


@dataclass(frozen=True)
class DuoGameDefinition:
    task_id: str
    display_label: str
    protocol_version: str
    models: tuple[str, str]
    provider_builder: ProviderBuilder | None
    evaluator: Evaluator | None
    maximum_episode_ticks: int

    @property
    def is_additive_game(self) -> bool:
        return self.protocol_version == DUO_PROTOCOL_VERSION


def _model_pair(models: Mapping[str, object]) -> tuple[str, str]:
    values = tuple(models)
    if len(values) != 2:
        raise RuntimeError("a duo game must bind exactly two Demo policies")
    return values[0], values[1]


DUO_GAME_CATALOG: Mapping[str, DuoGameDefinition] = MappingProxyType(
    {
        CENTRAL_RELAY_TASK_ID: DuoGameDefinition(
            CENTRAL_RELAY_TASK_ID,
            "Central Relay",
            CENTRAL_RELAY_PROTOCOL_VERSION,
            ("duelist-alpha-v1", "duelist-bravo-v1"),
            None,
            None,
            1800,
        ),
        CHECKPOINT_RACE_SCENARIO_ID: DuoGameDefinition(
            CHECKPOINT_RACE_SCENARIO_ID,
            "Checkpoint Race",
            DUO_PROTOCOL_VERSION,
            _model_pair(CHECKPOINT_RACE_MODELS),
            build_checkpoint_race_demo_provider,
            evaluate_checkpoint_race,
            1200,
        ),
        RELAY_CONTROL_SCENARIO_ID: DuoGameDefinition(
            RELAY_CONTROL_SCENARIO_ID,
            "Relay Control",
            DUO_PROTOCOL_VERSION,
            _model_pair(RELAY_CONTROL_MODELS),
            build_relay_control_demo_provider,
            evaluate_relay_control,
            1200,
        ),
        SPAR_SCENARIO_ID: DuoGameDefinition(
            SPAR_SCENARIO_ID,
            "Sparring",
            DUO_PROTOCOL_VERSION,
            _model_pair(SPAR_MODELS),
            build_spar_demo_provider,
            evaluate_spar,
            1200,
        ),
        RESOURCE_RELAY_SCENARIO_ID: DuoGameDefinition(
            RESOURCE_RELAY_SCENARIO_ID,
            "Resource Relay",
            DUO_PROTOCOL_VERSION,
            _model_pair(RESOURCE_RELAY_MODELS),
            build_resource_relay_demo_provider,
            evaluate_resource_relay,
            1200,
        ),
        RTS_SKIRMISH_SCENARIO_ID: DuoGameDefinition(
            RTS_SKIRMISH_SCENARIO_ID,
            "RTS Skirmish",
            DUO_PROTOCOL_VERSION,
            _model_pair(RTS_SKIRMISH_MODELS),
            build_rts_skirmish_demo_provider,
            evaluate_rts_skirmish,
            1200,
        ),
    }
)


def duo_game(task_id: str) -> DuoGameDefinition:
    try:
        return DUO_GAME_CATALOG[task_id]
    except KeyError as error:
        raise ValueError("unsupported duo task") from error


def build_duo_game_demo_provider(
    *, task_id: str, model: str, participant_id: str, seed: int, decision_budget: int
) -> DemoProvider:
    game = duo_game(task_id)
    if not game.is_additive_game or game.provider_builder is None or model not in game.models:
        raise ValueError("Demo policy is not valid for the selected duo task")
    return game.provider_builder(
        model=model,
        participant_id=participant_id,
        seed=seed,
        decision_budget=decision_budget,
    )


__all__ = [
    "CENTRAL_RELAY_PROTOCOL_VERSION",
    "CENTRAL_RELAY_TASK_ID",
    "DUO_GAME_CATALOG",
    "DUO_PROTOCOL_VERSION",
    "DuoGameDefinition",
    "build_duo_game_demo_provider",
    "duo_game",
]
