# ruff: noqa: UP045
"""Strict Pydantic wire models for ``worldeval-agent/0.1.0``."""

from __future__ import annotations

from typing import Annotated, Any, Dict, List, Literal, Optional, Union

from pydantic import BaseModel, ConfigDict, Field, TypeAdapter, field_validator, model_validator

PROTOCOL_ID = "worldeval-agent/0.1.0"
Identifier = Annotated[str, Field(pattern=r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$")]
Hash = Annotated[str, Field(pattern=r"^sha256:[0-9a-f]{64}$")]


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, populate_by_name=True)


class Position(StrictModel):
    x: int
    y: int


class CoordinateFrame(StrictModel):
    frame_id: Identifier
    dimensions: Literal[2] = 2
    width: int = Field(ge=1)
    height: int = Field(ge=1)
    origin: Literal["bottom_left", "top_left"]
    x_axis: Literal["east", "right"]
    y_axis: Literal["north", "down"]
    units: Literal["cells"] = "cells"


class Briefing(StrictModel):
    premise: str = Field(min_length=1, max_length=1000)
    agent_role: str = Field(min_length=1, max_length=500)
    success_model: str = Field(min_length=1, max_length=1000)
    rules: List[str] = Field(min_length=1, max_length=64)


class AuthorityDescription(StrictModel):
    engine: Literal["godot"]
    simulation_hz: Literal[10]
    numeric_model: Literal["integer-grid"]


class ProfileSelection(StrictModel):
    action: Identifier
    observation: Identifier
    decision: Identifier


class ContractReferences(StrictModel):
    environment_init: str
    objective: str
    object_catalog: str
    action_catalog: str
    observation: str
    action_plan: str
    decision_response: str
    action_receipt: str
    decision_profile: str
    skill_manifest: str
    replay_bundle: str


class EnvironmentManifest(StrictModel):
    schema_version: Literal["environment-manifest.v1"]
    protocol: Literal[PROTOCOL_ID]
    environment_id: Identifier
    game_id: Identifier
    name: str = Field(min_length=1, max_length=120)
    briefing: Briefing
    authority: AuthorityDescription
    profiles: ProfileSelection
    coordinate_frames: List[CoordinateFrame] = Field(min_length=1, max_length=8)
    controllable_asset_types: List[Identifier] = Field(min_length=1, max_length=32)
    object_catalog: str
    action_catalog: str
    decision_profile: str
    contracts: ContractReferences
    example_traces: List[str] = Field(default_factory=list, max_length=32)
    semantic_world_commands_exposed: Literal[True]
    exact_world_coordinates_exposed: Literal[True]

    @field_validator("coordinate_frames")
    @classmethod
    def unique_frames(cls, value: List[CoordinateFrame]) -> List[CoordinateFrame]:
        ids = [item.frame_id for item in value]
        if len(ids) != len(set(ids)):
            raise ValueError("coordinate frame IDs must be unique")
        return value


class Predicate(StrictModel):
    kind: Identifier
    subject: Optional[Identifier] = None
    parameters: Dict[str, Any] = Field(default_factory=dict)


class ObjectiveTarget(StrictModel):
    role: Identifier
    object_id: Optional[Identifier] = None
    object_type: Optional[Identifier] = None
    position: Optional[Position] = None

    @model_validator(mode="after")
    def has_target(self) -> ObjectiveTarget:
        if self.object_id is None and self.object_type is None and self.position is None:
            raise ValueError("an objective target must identify an object, type, or position")
        return self


class Objective(StrictModel):
    schema_version: Literal["objective.v1"]
    protocol: Literal[PROTOCOL_ID]
    objective_id: Identifier
    instruction: str = Field(min_length=1, max_length=2000)
    coordinate_frame: Identifier
    targets: List[ObjectiveTarget] = Field(min_length=1, max_length=32)
    success_predicates: List[Predicate] = Field(min_length=1, max_length=32)
    failure_predicates: List[Predicate] = Field(default_factory=list, max_length=32)
    safety_constraints: List[Predicate] = Field(default_factory=list, max_length=32)
    priorities: List[str] = Field(min_length=1, max_length=16)
    tick_budget: int = Field(ge=1, le=1_000_000)
    permitted_fallback: Literal["fail", "wait", "return_to_base"]


class ObjectType(StrictModel):
    type_id: Identifier
    traits: List[Identifier] = Field(default_factory=list, max_length=64)
    affordances: List[Identifier] = Field(default_factory=list, max_length=64)
    visible_state_fields: List[Identifier] = Field(default_factory=list, max_length=64)
    lifecycle_events: List[Literal["spawned", "updated", "despawned"]]
    stable_identity: Literal[True]


class ObjectCatalog(StrictModel):
    schema_version: Literal["object-catalog.v1"]
    protocol: Literal[PROTOCOL_ID]
    catalog_id: Identifier
    object_types: List[ObjectType] = Field(min_length=1, max_length=256)

    @field_validator("object_types")
    @classmethod
    def unique_types(cls, value: List[ObjectType]) -> List[ObjectType]:
        ids = [item.type_id for item in value]
        if len(ids) != len(set(ids)):
            raise ValueError("object type IDs must be unique")
        return value


class DurationPolicy(StrictModel):
    kind: Literal["instant", "persistent"]
    maximum_ticks: int = Field(ge=0, le=1_000_000)


class ActionAuthority(StrictModel):
    game_may: List[Identifier] = Field(default_factory=list, max_length=32)
    game_must_not: List[Identifier] = Field(default_factory=list, max_length=32)
    navigation: Literal["none", "direct_only", "pathfinding_allowed"]
    target_selection: Literal["agent_only", "declared_target_only"]


class ActionDefinition(StrictModel):
    action_id: Identifier
    argument_schema: Dict[str, Any]
    preconditions: List[Identifier] = Field(default_factory=list, max_length=32)
    refusal_conditions: List[Identifier] = Field(default_factory=list, max_length=32)
    duration: DurationPolicy
    cancellation_boundary: Literal["immediate", "tick_boundary", "completion"]
    authority: ActionAuthority
    receipt_codes: List[Identifier] = Field(min_length=1, max_length=32)

    @model_validator(mode="after")
    def protect_direct_movement(self) -> ActionDefinition:
        if self.action_id == "move_to":
            if self.authority.navigation != "direct_only":
                raise ValueError("move_to must use direct_only navigation in this profile")
            if "choose_detour" not in self.authority.game_must_not:
                raise ValueError("move_to must explicitly forbid choose_detour")
        return self


class ActionCatalog(StrictModel):
    schema_version: Literal["action-catalog.v1"]
    protocol: Literal[PROTOCOL_ID]
    catalog_id: Identifier
    action_profile: Identifier
    actions: List[ActionDefinition] = Field(min_length=1, max_length=128)

    @field_validator("actions")
    @classmethod
    def unique_actions(cls, value: List[ActionDefinition]) -> List[ActionDefinition]:
        ids = [item.action_id for item in value]
        if len(ids) != len(set(ids)):
            raise ValueError("action IDs must be unique")
        return value


class DynamicDecisionProfile(StrictModel):
    schema_version: Literal["decision-profile.v1"]
    protocol: Literal[PROTOCOL_ID]
    profile_id: Identifier
    kind: Literal["dynamic-step-locked"]
    minimum_ticks: Literal[1]
    maximum_ticks: Literal[5]
    default_ticks: Literal[3]
    simulation_pauses_during_inference: Literal[True]
    observation_policy: Literal["every_boundary"]
    interrupt_events: List[Identifier] = Field(min_length=1, max_length=64)
    explicit_response_required: Literal[True]
    missing_response_behavior: Literal["neutral_noop"]


class StaticDecisionProfile(StrictModel):
    schema_version: Literal["decision-profile.v1"]
    protocol: Literal[PROTOCOL_ID]
    profile_id: Identifier
    kind: Literal["static-event-gated"]
    minimum_ticks: Literal[1]
    maximum_ticks: Literal[50]
    default_ticks: int = Field(ge=1, le=50)
    simulation_pauses_during_inference: Literal[True]
    observation_policy: Literal["event_or_lease_expiry"]
    interrupt_events: List[Identifier] = Field(min_length=1, max_length=64)
    explicit_response_required: Literal[True]
    missing_response_behavior: Literal["neutral_noop"]


DecisionProfile = Annotated[
    Union[DynamicDecisionProfile, StaticDecisionProfile], Field(discriminator="kind")
]


class ObjectInstance(StrictModel):
    object_id: Identifier
    type_id: Identifier
    generation: int = Field(ge=1)
    position: Position
    affordances: List[Identifier] = Field(default_factory=list, max_length=64)
    state: Dict[str, Any] = Field(default_factory=dict)


class ControlledAsset(ObjectInstance):
    capabilities: List[Identifier] = Field(default_factory=list, max_length=64)


class CapabilityStatus(StrictModel):
    capability_id: Identifier
    available: bool
    reason: Optional[str] = None


class EnvironmentInit(StrictModel):
    schema_version: Literal["environment-init.v1"]
    protocol: Literal[PROTOCOL_ID]
    environment_id: Identifier
    game_id: Identifier
    session_id: Identifier
    initialization_hash: Hash
    briefing: Briefing
    authority: AuthorityDescription
    profiles: ProfileSelection
    coordinate_frames: List[CoordinateFrame] = Field(min_length=1, max_length=8)
    controlled_assets: List[ControlledAsset] = Field(min_length=1, max_length=32)
    object_catalog: ObjectCatalog
    action_catalog: ActionCatalog
    decision_profile: DecisionProfile
    active_objective: Objective
    capabilities: List[CapabilityStatus] = Field(default_factory=list, max_length=128)
    contracts: ContractReferences
    example_traces: List[str] = Field(default_factory=list, max_length=32)


class ObservationEvent(StrictModel):
    event_id: Identifier
    kind: Identifier
    object_id: Optional[Identifier] = None
    data: Dict[str, Any] = Field(default_factory=dict)


class ActivePlanSummary(StrictModel):
    plan_id: Identifier
    step_id: Optional[Identifier] = None
    status: Literal["active", "awaiting_confirmation", "suspended", "revoked"]


class DecisionRequired(StrictModel):
    reason: Literal["initial", "lease_expired", "step_boundary", "interrupt", "terminal"]
    allowed_responses: List[Literal["plan.continue", "plan.replace", "plan.abort", "wait"]]
    interrupt_events: List[Identifier] = Field(default_factory=list, max_length=64)


class Observation(StrictModel):
    schema_version: Literal["observation.v1"]
    protocol: Literal[PROTOCOL_ID]
    environment_id: Identifier
    session_id: Identifier
    observation_seq: int = Field(ge=0)
    tick: int = Field(ge=0)
    state_hash: Hash
    coordinate_frame: Identifier
    controlled_assets: List[ControlledAsset] = Field(min_length=1, max_length=32)
    visible_objects: List[ObjectInstance] = Field(default_factory=list, max_length=4096)
    events: List[ObservationEvent] = Field(default_factory=list, max_length=256)
    active_plan: Optional[ActivePlanSummary] = None
    decision_required: DecisionRequired
    terminal: bool = False

    @model_validator(mode="after")
    def unique_object_identities(self) -> Observation:
        ids = [item.object_id for item in self.controlled_assets + self.visible_objects]
        if len(ids) != len(set(ids)):
            raise ValueError("an object ID may appear only once in an observation")
        return self


class SourceObservation(StrictModel):
    observation_seq: int = Field(ge=0)
    tick: int = Field(ge=0)
    state_hash: Hash


class ActionCall(StrictModel):
    action: Identifier
    arguments: Dict[str, Any] = Field(default_factory=dict)


class PlanStep(StrictModel):
    step_id: Identifier
    action: ActionCall
    preconditions: List[Predicate] = Field(default_factory=list, max_length=32)
    expected_completion: Predicate
    interrupt_on: List[Identifier] = Field(default_factory=list, max_length=64)


class ActionPlan(StrictModel):
    schema_version: Literal["action-plan.v1"]
    protocol: Literal[PROTOCOL_ID]
    plan_id: Identifier
    source: SourceObservation
    lease_ticks: int = Field(ge=1, le=50)
    execution_policy: Literal["confirm_each_boundary"]
    steps: List[PlanStep] = Field(min_length=1, max_length=64)
    abort_behavior: Literal["neutral", "cancel_current_action"]

    @field_validator("steps")
    @classmethod
    def unique_steps(cls, value: List[PlanStep]) -> List[PlanStep]:
        ids = [item.step_id for item in value]
        if len(ids) != len(set(ids)):
            raise ValueError("plan step IDs must be unique")
        return value


class ContinueResponse(StrictModel):
    type: Literal["plan.continue"]
    plan_id: Identifier
    source: SourceObservation
    lease_ticks: int = Field(ge=1, le=50)


class ReplaceResponse(StrictModel):
    type: Literal["plan.replace"]
    replaces_plan_id: Optional[Identifier] = None
    plan: ActionPlan


class AbortResponse(StrictModel):
    type: Literal["plan.abort"]
    plan_id: Identifier
    source: SourceObservation
    reason: str = Field(min_length=1, max_length=500)


class WaitResponse(StrictModel):
    type: Literal["wait"]
    source: SourceObservation
    maximum_ticks: int = Field(ge=1, le=50)
    until: List[Identifier] = Field(default_factory=list, max_length=32)


DecisionResponse = Annotated[
    Union[ContinueResponse, ReplaceResponse, AbortResponse, WaitResponse],
    Field(discriminator="type"),
]
_DECISION_RESPONSE_ADAPTER = TypeAdapter(DecisionResponse)


def parse_decision_response(value: Any) -> DecisionResponse:
    return _DECISION_RESPONSE_ADAPTER.validate_python(value)


class ReceiptEffect(StrictModel):
    kind: Identifier
    object_id: Optional[Identifier] = None
    data: Dict[str, Any] = Field(default_factory=dict)


class ActionReceipt(StrictModel):
    schema_version: Literal["action-receipt.v1"]
    protocol: Literal[PROTOCOL_ID]
    receipt_id: Identifier
    observation_seq: int = Field(ge=0)
    response_type: Optional[Literal["plan.continue", "plan.replace", "plan.abort", "wait"]]
    plan_id: Optional[Identifier] = None
    step_id: Optional[Identifier] = None
    accepted: bool
    disposition: Literal["accepted", "no_input", "rejected"]
    fallback: Literal["none", "neutral"]
    no_input_reason: Optional[
        Literal[
            "missing",
            "invalid",
            "timeout",
            "stale_observation",
            "stale_tick",
            "stale_state",
        ]
    ] = None
    start_tick: int = Field(ge=0)
    end_tick: int = Field(ge=0)
    applied_ticks: int = Field(ge=0, le=50)
    codes: List[Identifier] = Field(default_factory=list, max_length=32)
    effects: List[ReceiptEffect] = Field(default_factory=list, max_length=256)

    @model_validator(mode="after")
    def consistent_disposition(self) -> ActionReceipt:
        if self.accepted:
            if self.disposition != "accepted" or self.fallback != "none" or self.no_input_reason:
                raise ValueError("accepted receipts cannot use fallback or a no-input reason")
        elif self.fallback == "neutral":
            if self.disposition != "no_input" or self.no_input_reason is None:
                raise ValueError("neutral fallback receipts require a no-input reason")
        elif self.disposition != "rejected":
            raise ValueError("non-fallback refusal must be rejected")
        if self.end_tick < self.start_tick:
            raise ValueError("receipt end_tick cannot precede start_tick")
        return self


class AuthorityMetrics(StrictModel):
    forbidden_autonomy_count: int = Field(ge=0)
    hostile_attacks: int = Field(ge=0)


class AgentNativeReplay(StrictModel):
    schema_version: Literal["replay-bundle.v1"]
    protocol: Literal[PROTOCOL_ID]
    run_id: Identifier
    environment_id: Identifier
    scenario_id: Identifier
    initialization_hash: Hash
    initial_state_hash: Hash
    terminal_state_hash: Hash
    terminal_outcome: str
    terminal_tick: int = Field(ge=0)
    authority_metrics: AuthorityMetrics
    decisions: List[Optional[DecisionResponse]]
    observations: List[Observation] = Field(min_length=1)
    receipts: List[ActionReceipt]
    provider_calls: Literal[0]
    offline_verified: bool

    @model_validator(mode="after")
    def boundary_arrays_and_hashes_match(self) -> AgentNativeReplay:
        if len(self.decisions) != len(self.receipts):
            raise ValueError("replay decisions and receipts must have equal lengths")
        if len(self.observations) != len(self.decisions) + 1:
            raise ValueError(
                "a replay must contain one observation per boundary plus the initial one"
            )
        if self.initial_state_hash != self.observations[0].state_hash:
            raise ValueError("initial state hash must equal the first observation state hash")
        if self.terminal_state_hash != self.observations[-1].state_hash:
            raise ValueError("terminal state hash must equal the final observation state hash")
        if self.terminal_tick != self.observations[-1].tick:
            raise ValueError("terminal tick must equal the final observation tick")
        return self


class SkillManifest(StrictModel):
    schema_version: Literal["skill-manifest.v1"]
    protocol: Literal[PROTOCOL_ID]
    skill_id: Identifier
    description: str = Field(min_length=1, max_length=1000)
    required_target_affordances: List[Identifier] = Field(default_factory=list, max_length=32)
    required_tool_affordances: List[Identifier] = Field(default_factory=list, max_length=32)
    suggested_actions: List[Identifier] = Field(min_length=1, max_length=32)
    preconditions: List[Predicate] = Field(default_factory=list, max_length=32)
    decision_points: List[Identifier] = Field(default_factory=list, max_length=64)
    success_predicate: Predicate
    compatible_action_profiles: List[Identifier] = Field(min_length=1, max_length=32)
    execution: Literal["agent_expands_to_visible_actions"]
