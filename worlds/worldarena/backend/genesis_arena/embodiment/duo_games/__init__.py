"""Isolated deterministic policy and evaluation cores for simple two-player games.

The package deliberately has no service, API, protocol-registry, or dashboard imports.  Product
integration can therefore compose these policies without giving them an authority backdoor.
"""

from .catalog import (
    CENTRAL_RELAY_TASK_ID,
    DUO_GAME_CATALOG,
    DUO_PROTOCOL_VERSION,
    DuoGameDefinition,
    build_duo_game_demo_provider,
    duo_game,
)
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
    RESOURCE_RELAY_OBJECTIVE_TARGET,
    RESOURCE_RELAY_SCENARIO_ID,
    build_resource_relay_demo_provider,
    evaluate_resource_relay,
)
from .spar import (
    SPAR_MODELS,
    SPAR_SCENARIO_ID,
    build_spar_demo_provider,
    evaluate_spar,
)

__all__ = [
    "CHECKPOINT_RACE_MODELS",
    "CHECKPOINT_RACE_SCENARIO_ID",
    "RELAY_CONTROL_MODELS",
    "RELAY_CONTROL_SCENARIO_ID",
    "SPAR_MODELS",
    "SPAR_SCENARIO_ID",
    "RESOURCE_RELAY_MODELS",
    "RESOURCE_RELAY_OBJECTIVE_TARGET",
    "RESOURCE_RELAY_SCENARIO_ID",
    "CENTRAL_RELAY_TASK_ID",
    "DUO_GAME_CATALOG",
    "DUO_PROTOCOL_VERSION",
    "DuoGameDefinition",
    "build_duo_game_demo_provider",
    "build_checkpoint_race_demo_provider",
    "build_relay_control_demo_provider",
    "build_spar_demo_provider",
    "build_resource_relay_demo_provider",
    "evaluate_checkpoint_race",
    "evaluate_relay_control",
    "evaluate_spar",
    "evaluate_resource_relay",
    "duo_game",
]
