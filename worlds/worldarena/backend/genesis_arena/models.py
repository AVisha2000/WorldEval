from __future__ import annotations

from enum import Enum
from typing import Any, Dict, List, Literal
from uuid import uuid4

from pydantic import BaseModel, ConfigDict, Field


class ResourceKind(str, Enum):
    WOOD = "wood"
    STONE = "stone"
    FOOD = "food"
    IRON = "iron"
    CRYSTAL = "crystal"
    WATER = "water"


class StructureKind(str, Enum):
    SHELTER = "shelter"
    FARM = "farm"
    STORAGE = "storage"
    WALL = "wall"
    WORKSHOP = "workshop"


class ActionName(str, Enum):
    COLLECT = "collect"
    BUILD = "build"
    INSPECT = "inspect"
    REST = "rest"
    CRAFT = "craft"
    SEND_MESSAGE = "send_message"
    ATTACK = "attack"
    DEFEND = "defend"


class AgentState(BaseModel):
    model_config = ConfigDict(extra="forbid")

    health: float = Field(default=100, ge=0, le=100)
    food: float = Field(default=50, ge=0, le=100)
    inventory: Dict[str, int] = Field(default_factory=dict)
    structures: Dict[str, int] = Field(default_factory=dict)
    technology: float = Field(default=0, ge=0)
    population: int = Field(default=1, ge=0)


class VisibleResource(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    kind: ResourceKind
    distance: float = Field(ge=0)
    direction: str
    quantity: int = Field(ge=0)


class Observation(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["observation"] = "observation"
    turn: int = Field(ge=0)
    day: int = Field(ge=0)
    max_days: int = Field(default=20, ge=1)
    agent_id: str = "sol"
    agent: AgentState
    visible_resources: List[VisibleResource] = Field(default_factory=list)
    visible_world: List[Dict[str, Any]] = Field(default_factory=list)
    events: List[str] = Field(default_factory=list)
    available_actions: List[str] = Field(
        default_factory=lambda: ["collect", "build", "inspect", "rest"]
    )


class ActionCommand(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["action_command"] = "action_command"
    command_id: str = Field(default_factory=lambda: str(uuid4()))
    turn: int
    agent_id: str
    action: ActionName
    parameters: Dict[str, Any] = Field(default_factory=dict)
    intent: str = Field(min_length=3, max_length=120)
    source: str


class DecisionTrace(BaseModel):
    turn: int
    agent_id: str
    action: str
    valid: bool
    source: str
    latency_ms: float
    error: str = ""


class AgentBrainConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agent_id: str = Field(min_length=1, max_length=32, pattern=r"^[a-z][a-z0-9_]*$")
    model: str = Field(min_length=1, max_length=120)
    reasoning_effort: Literal["none", "low", "medium", "high", "xhigh", "max"] = "low"


class SimulationConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["configure"] = "configure"
    api_key: str = Field(min_length=8, max_length=512)
    agents: List[AgentBrainConfig] = Field(min_length=3, max_length=3)


class RunMetrics(BaseModel):
    agent_id: str = "sol"
    survived: bool = False
    days_survived: int = 0
    health: float = 0
    resources_collected: int = 0
    resources_spent: int = 0
    resources_wasted: int = 0
    shelter_built_day: int = 0
    invalid_actions: int = 0
    disaster_responses: int = 0
    disasters_survived: int = 0
    successful_negotiations: int = 0
    attempted_negotiations: int = 0
