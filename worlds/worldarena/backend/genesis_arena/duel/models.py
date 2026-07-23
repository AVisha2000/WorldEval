from __future__ import annotations

# ruff: noqa: UP045 -- Keep runtime-compatible Pydantic annotations for Python 3.9.
import unicodedata
from typing import Annotated, Any, Dict, List, Literal, Optional, Tuple, Union

from pydantic import BaseModel, ConfigDict, Field, JsonValue, field_validator, model_validator

ProtocolVersion = Literal["worldeval-rts/1.0.0"]
DecisionMode = Literal["fixed_simultaneous", "continuous_realtime"]
ControlProfile = Literal["hybrid-v1"]
QueuePolicy = Literal["replace", "append", "front"]
HashHex = Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]
Identifier = Annotated[
    str,
    Field(min_length=1, max_length=96, pattern=r"^[a-z0-9][a-z0-9_.:-]*$"),
]
MatchId = Annotated[str, Field(pattern=r"^m_[A-Za-z0-9._-]{1,120}$")]
BatchId = Annotated[str, Field(pattern=r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")]
CommandId = Annotated[str, Field(pattern=r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")]
EntityId = Annotated[str, Field(pattern=r"^e_[A-Za-z0-9._-]{1,80}$")]
PublicId = Annotated[
    str,
    Field(min_length=1, max_length=96, pattern=r"^[a-z0-9][a-z0-9._-]{0,95}$"),
]
Coordinate = Annotated[int, Field(ge=0, le=9_007_199_254_740_991)]
Point = Tuple[Coordinate, Coordinate]


def _normalize_wire_text(value: Any) -> Any:
    if isinstance(value, str):
        normalized = unicodedata.normalize("NFC", value)
        for character in normalized:
            category = unicodedata.category(character)
            if category in {"Cc", "Cf", "Cs"}:
                raise ValueError("control, formatting, and surrogate characters are forbidden")
        return normalized
    if isinstance(value, dict):
        return {
            _normalize_wire_text(key): _normalize_wire_text(child) for key, child in value.items()
        }
    if isinstance(value, list):
        return [_normalize_wire_text(child) for child in value]
    if isinstance(value, tuple):
        return tuple(_normalize_wire_text(child) for child in value)
    return value


class DuelModel(BaseModel):
    model_config = ConfigDict(
        extra="forbid",
        validate_assignment=True,
        allow_inf_nan=False,
    )

    @model_validator(mode="before")
    @classmethod
    def normalize_text(cls, value: Any) -> Any:
        return _normalize_wire_text(value)


class PlayerConfig(DuelModel):
    slot: int = Field(ge=0, le=1)
    model: str = Field(min_length=1, max_length=200)
    reasoning: str = Field(min_length=1, max_length=80)
    provider_adapter: Optional[Identifier] = None


class SpectatorConfig(DuelModel):
    enabled: bool
    initial_perspective: Literal["omniscient", "slot_0", "slot_1"]
    record_replay: bool


class MatchConfig(DuelModel):
    protocol_version: ProtocolVersion = "worldeval-rts/1.0.0"
    ruleset_id: Literal["duel-rules-v1"] = "duel-rules-v1"
    decision_mode: DecisionMode
    control_profile: ControlProfile = "hybrid-v1"
    observation_profile: Literal["full-belief-v1"] = "full-belief-v1"
    faction_preset_id: Literal[
        "vanguard-v1", "warhost-v1", "grove-v1", "crypt-v1"
    ]
    mirror_faction: Literal[True] = True
    map_id: Literal["crossroads-duel-v1"] = "crossroads-duel-v1"
    seed: int = Field(ge=0, le=9_007_199_254_740_991)
    simulation_hz: Literal[10] = 10
    decision_period_ticks: int = Field(ge=1, le=10_000)
    response_deadline_ms: int = Field(ge=1, le=45_000)
    maximum_match_ticks: int = Field(default=18_000, ge=1, le=18_000)
    memory_policy: Literal[
        "fresh-match-with-bounded-scratchpad", "adaptive-series"
    ] = "fresh-match-with-bounded-scratchpad"
    cadence_profile_id: Optional[Identifier] = None
    spectator: Optional[SpectatorConfig] = None
    players: List[PlayerConfig] = Field(min_length=2, max_length=2)

    @model_validator(mode="after")
    def validate_players_and_mode(self) -> MatchConfig:
        if [player.slot for player in self.players] != [0, 1]:
            raise ValueError("match requires player slots in canonical order [0, 1]")
        if self.decision_mode == "fixed_simultaneous":
            if self.decision_period_ticks not in {50, 100, 150}:
                raise ValueError("fixed_simultaneous cadence must be 50, 100, or 150 ticks")
        else:
            if self.decision_period_ticks != 50:
                raise ValueError("continuous_realtime cadence is 50 ticks")
            if self.response_deadline_ms > 8_000:
                raise ValueError("continuous_realtime deadline cannot exceed 8000 ms")
        return self


class EntityTarget(DuelModel):
    kind: Literal["entity"]
    entity_id: EntityId


class PointTarget(DuelModel):
    kind: Literal["point"]
    xy_mt: Point


class RegionSlotTarget(DuelModel):
    kind: Literal["region_slot"]
    region_id: Identifier
    slot_id: Identifier


class SiteTarget(DuelModel):
    kind: Literal["site"]
    site_id: Identifier


Target = Annotated[
    Union[EntityTarget, PointTarget, RegionSlotTarget, SiteTarget],
    Field(discriminator="kind"),
]


class CommandBase(DuelModel):
    command_id: CommandId


class ActorGroupCommand(CommandBase):
    actor_ids: List[EntityId] = Field(min_length=1, max_length=24)

    @field_validator("actor_ids")
    @classmethod
    def unique_actors(cls, value: List[str]) -> List[str]:
        if len(value) != len(set(value)):
            raise ValueError("actor_ids must be unique")
        return value


class MoveCommand(ActorGroupCommand):
    op: Literal["move"]
    target: Union[PointTarget, RegionSlotTarget]
    queue: QueuePolicy


class AttackMoveCommand(ActorGroupCommand):
    op: Literal["attack_move"]
    target: Union[PointTarget, RegionSlotTarget]
    queue: QueuePolicy


class AttackEntityCommand(ActorGroupCommand):
    op: Literal["attack_entity"]
    target: EntityTarget
    queue: QueuePolicy


class AttackGroundCommand(ActorGroupCommand):
    op: Literal["attack_ground"]
    target: PointTarget
    queue: QueuePolicy


class StopCommand(ActorGroupCommand):
    op: Literal["stop"]


class HoldPositionCommand(ActorGroupCommand):
    op: Literal["hold_position"]


class PatrolCommand(ActorGroupCommand):
    op: Literal["patrol"]
    targets: List[Union[PointTarget, RegionSlotTarget]] = Field(min_length=2, max_length=8)
    queue: QueuePolicy


class FollowCommand(ActorGroupCommand):
    op: Literal["follow"]
    target: EntityTarget
    distance_mt: int = Field(ge=0, le=50_000)
    queue: QueuePolicy


class RetreatCommand(ActorGroupCommand):
    op: Literal["retreat"]
    target: Union[EntityTarget, SiteTarget]
    queue: QueuePolicy


class SetStanceCommand(ActorGroupCommand):
    op: Literal["set_stance"]
    stance: Literal["aggressive", "defensive", "hold_position", "hold_fire"]


class WorkerGroupCommand(CommandBase):
    worker_ids: List[EntityId] = Field(min_length=1, max_length=24)

    @field_validator("worker_ids")
    @classmethod
    def unique_workers(cls, value: List[str]) -> List[str]:
        if len(value) != len(set(value)):
            raise ValueError("worker_ids must be unique")
        return value


class GatherCommand(WorkerGroupCommand):
    op: Literal["gather"]
    resource_target: Union[EntityTarget, SiteTarget]
    queue: QueuePolicy


class ReturnCargoCommand(WorkerGroupCommand):
    op: Literal["return_cargo"]
    deposit_target: Optional[EntityTarget] = None
    queue: QueuePolicy


class RepairCommand(WorkerGroupCommand):
    op: Literal["repair"]
    target: EntityTarget
    queue: QueuePolicy


class BuildCommand(CommandBase):
    op: Literal["build"]
    builder_ids: List[EntityId] = Field(min_length=1, max_length=24)
    building_type_id: Identifier
    build_site_id: Identifier

    @field_validator("builder_ids")
    @classmethod
    def unique_builders(cls, value: List[str]) -> List[str]:
        if len(value) != len(set(value)):
            raise ValueError("builder_ids must be unique")
        return value


class CancelConstructionCommand(CommandBase):
    op: Literal["cancel_construction"]
    building_id: EntityId


class ProduceCommand(CommandBase):
    op: Literal["produce"]
    producer_id: EntityId
    unit_type_id: Identifier
    quantity: int = Field(ge=1, le=5)


class ResearchCommand(CommandBase):
    op: Literal["research"]
    producer_id: EntityId
    upgrade_id: Identifier


class UpgradeTierCommand(CommandBase):
    op: Literal["upgrade_tier"]
    stronghold_id: EntityId
    target_tier: int = Field(ge=2, le=3)


class CancelQueueCommand(CommandBase):
    op: Literal["cancel_queue"]
    producer_id: EntityId
    queue_entry_id: Identifier


class SetRallyCommand(CommandBase):
    op: Literal["set_rally"]
    producer_id: EntityId
    target: Target


class ReviveHeroCommand(CommandBase):
    op: Literal["revive_hero"]
    reviver_id: EntityId
    hero_id: EntityId
    revival_method: Literal["altar", "tavern"]


class CastCommand(CommandBase):
    op: Literal["cast"]
    actor_id: EntityId
    ability_id: Identifier
    target: Optional[Target] = None
    queue: QueuePolicy


class SetAutocastCommand(ActorGroupCommand):
    op: Literal["set_autocast"]
    ability_id: Identifier
    enabled: bool


class LearnAbilityCommand(CommandBase):
    op: Literal["learn_ability"]
    hero_id: EntityId
    ability_id: Identifier


class UseItemCommand(CommandBase):
    op: Literal["use_item"]
    hero_id: EntityId
    item_instance_id: Identifier
    target: Optional[Target] = None
    queue: QueuePolicy


class PickUpItemCommand(CommandBase):
    op: Literal["pick_up_item"]
    hero_id: EntityId
    item_entity_id: EntityId
    queue: QueuePolicy


class DropItemCommand(CommandBase):
    op: Literal["drop_item"]
    hero_id: EntityId
    item_instance_id: Identifier
    target: PointTarget


class TransferItemCommand(CommandBase):
    op: Literal["transfer_item"]
    from_hero_id: EntityId
    to_hero_id: EntityId
    item_instance_id: Identifier


class SellItemCommand(CommandBase):
    op: Literal["sell_item"]
    hero_id: EntityId
    shop_id: EntityId
    item_instance_id: Identifier


class PurchaseOfferCommand(CommandBase):
    op: Literal["purchase_offer"]
    buyer_id: EntityId
    shop_id: EntityId
    offer_id: Identifier
    quantity: int = Field(default=1, ge=1, le=5)
    service_target: Optional[Union[PointTarget, RegionSlotTarget]] = None


class LoadTransportCommand(CommandBase):
    op: Literal["load_transport"]
    transport_id: EntityId
    passenger_ids: List[EntityId] = Field(min_length=1, max_length=24)
    queue: QueuePolicy


class UnloadTransportCommand(CommandBase):
    op: Literal["unload_transport"]
    transport_id: EntityId
    passengers: Union[Literal["all"], List[EntityId]]
    target: PointTarget

    @field_validator("passengers")
    @classmethod
    def validate_passengers(cls, value: Union[str, List[str]]) -> Union[str, List[str]]:
        if isinstance(value, list):
            if not 1 <= len(value) <= 24:
                raise ValueError("passengers list must contain 1 through 24 IDs")
            if len(value) != len(set(value)):
                raise ValueError("passengers must be unique")
        return value


class DefineSquadCommand(CommandBase):
    op: Literal["define_squad"]
    squad_id: Identifier
    member_ids: List[EntityId] = Field(min_length=1, max_length=24)


class UpdateSquadCommand(CommandBase):
    op: Literal["update_squad"]
    squad_id: Identifier
    member_ids: List[EntityId] = Field(min_length=1, max_length=24)


class DisbandSquadCommand(CommandBase):
    op: Literal["disband_squad"]
    squad_id: Identifier


class OrderSquadCommand(CommandBase):
    op: Literal["order_squad"]
    squad_id: Identifier
    objective: Literal[
        "move_to",
        "attack_move_to",
        "focus_visible_entity",
        "retreat_to",
        "hold_area",
        "patrol_points",
    ]
    target: Target
    formation: Literal["none", "line", "compact", "spread", "wedge"]
    engagement: Literal["avoid", "defend_if_attacked", "engage_visible", "focus_target"]
    queue: QueuePolicy


class ActorTacticsSubject(DuelModel):
    kind: Literal["actors"]
    actor_ids: List[EntityId] = Field(min_length=1, max_length=24)


class SquadTacticsSubject(DuelModel):
    kind: Literal["squad"]
    squad_id: Annotated[str, Field(pattern=r"^squad\.[a-z0-9][a-z0-9._-]{0,47}$")]


TacticsSubject = Annotated[
    Union[ActorTacticsSubject, SquadTacticsSubject],
    Field(discriminator="kind"),
]


class SetTacticsCommand(CommandBase):
    op: Literal["set_tactics"]
    subject: TacticsSubject
    formation: Literal["none", "line", "compact", "spread", "wedge"]
    stance: Literal["aggressive", "defensive", "hold_position", "hold_fire"]
    focus_tag: Literal[
        "none",
        "hero",
        "healer",
        "caster",
        "siege",
        "anti_air",
        "air",
        "ground",
        "structure",
        "worker",
    ]
    retreat_hp_threshold_bp: int = Field(ge=0, le=10_000)
    retreat_target: Optional[Union[EntityTarget, SiteTarget]] = None

    @model_validator(mode="after")
    def validate_subject_and_retreat(self) -> SetTacticsCommand:
        if isinstance(self.subject, ActorTacticsSubject) and len(
            self.subject.actor_ids
        ) != len(set(self.subject.actor_ids)):
            raise ValueError("actor_ids must be unique")
        if self.retreat_hp_threshold_bp > 0 and self.retreat_target is None:
            raise ValueError("non-zero retreat threshold requires retreat_target")
        return self


Command = Annotated[
    Union[
        MoveCommand,
        AttackMoveCommand,
        AttackEntityCommand,
        AttackGroundCommand,
        StopCommand,
        HoldPositionCommand,
        PatrolCommand,
        FollowCommand,
        RetreatCommand,
        SetStanceCommand,
        GatherCommand,
        ReturnCargoCommand,
        RepairCommand,
        BuildCommand,
        CancelConstructionCommand,
        ProduceCommand,
        ResearchCommand,
        UpgradeTierCommand,
        CancelQueueCommand,
        SetRallyCommand,
        ReviveHeroCommand,
        CastCommand,
        SetAutocastCommand,
        LearnAbilityCommand,
        UseItemCommand,
        PickUpItemCommand,
        DropItemCommand,
        TransferItemCommand,
        SellItemCommand,
        PurchaseOfferCommand,
        LoadTransportCommand,
        UnloadTransportCommand,
        DefineSquadCommand,
        UpdateSquadCommand,
        DisbandSquadCommand,
        OrderSquadCommand,
        SetTacticsCommand,
    ],
    Field(discriminator="op"),
]


class ActionBatch(DuelModel):
    message_type: Literal["action_batch"] = "action_batch"
    protocol_version: ProtocolVersion = "worldeval-rts/1.0.0"
    match_id: MatchId
    observation_seq: int = Field(ge=0)
    based_on_observation_hash: HashHex
    client_batch_id: BatchId
    valid_until_tick: int = Field(ge=1)
    intent_summary: Optional[str] = Field(default=None, max_length=240)
    working_memory: Optional[str] = None
    commands: List[Command] = Field(default_factory=list, max_length=16)

    @field_validator("working_memory")
    @classmethod
    def bound_working_memory_bytes(cls, value: Optional[str]) -> Optional[str]:
        if value is not None and len(value.encode("utf-8")) > 4_096:
            raise ValueError("working_memory exceeds 4096 UTF-8 bytes")
        return value

    @model_validator(mode="after")
    def unique_command_ids(self) -> ActionBatch:
        command_ids = [command.command_id for command in self.commands]
        if len(command_ids) != len(set(command_ids)):
            raise ValueError("command_id values must be unique within a batch")
        return self


class MatchInit(DuelModel):
    message_type: Literal["match_init"] = "match_init"
    protocol_version: ProtocolVersion = "worldeval-rts/1.0.0"
    match_id: MatchId
    perspective: Literal["self"] = "self"
    artifacts: Dict[str, JsonValue]
    ruleset: Dict[str, JsonValue]
    faction: Dict[str, JsonValue]
    map: Dict[str, JsonValue]
    decision: Dict[str, JsonValue]
    limits: Dict[str, JsonValue]
    coordinate_frame: Dict[str, JsonValue]
    victory_rules: Dict[str, JsonValue]
    draw_rules: Dict[str, JsonValue]
    failure_rules: Dict[str, JsonValue]
    observation_rules: Dict[str, JsonValue]
    memory_rules: Dict[str, JsonValue]
    scoring_rules: Dict[str, JsonValue]
    action_schema: Dict[str, JsonValue]
    public_catalogs: Dict[str, JsonValue]
    map_manifest: Dict[str, JsonValue]
    starting_state: Dict[str, JsonValue]


class VisibleShopOffer(DuelModel):
    offer_id: PublicId
    kind: Literal["item", "unit", "service", "revival"]
    cost_gold: int = Field(ge=0)
    cost_lumber: int = Field(ge=0)
    stock: Optional[int] = Field(ge=0)
    next_restock_tick: Optional[int] = Field(ge=0)
    available: bool
    requires_service_target: bool = False


class VisibleShop(DuelModel):
    shop_id: EntityId
    site_id: PublicId
    shop_type: Literal["merchant", "laboratory", "tavern", "faction_shop"]
    position_mt: Point
    region_id: PublicId
    offers: List[VisibleShopOffer]


class Observation(DuelModel):
    message_type: Literal["observation"] = "observation"
    protocol_version: ProtocolVersion = "worldeval-rts/1.0.0"
    match_id: MatchId
    observation_seq: int = Field(ge=0)
    observation_hash: HashHex
    tick: int = Field(ge=0)
    game_time: Dict[str, JsonValue]
    decision: Dict[str, JsonValue]
    working_memory: Optional[str]
    objective: Optional[Dict[str, JsonValue]]
    match_state: Optional[Dict[str, JsonValue]]
    day_phase: Literal["day", "night", "forced_night"]
    remaining_match_ticks: int = Field(ge=0, le=18_000)
    economy: Dict[str, JsonValue]
    food: Dict[str, JsonValue]
    upkeep: Dict[str, JsonValue]
    technology: Dict[str, JsonValue]
    heroes: List[Dict[str, JsonValue]]
    owned_entities: List[Dict[str, JsonValue]]
    owned_structures: List[Dict[str, JsonValue]]
    squads: List[Dict[str, JsonValue]]
    visible_contacts: List[Dict[str, JsonValue]]
    remembered_contacts: List[Dict[str, JsonValue]]
    visible_neutrals: List[Dict[str, JsonValue]]
    visible_items: List[Dict[str, JsonValue]]
    visible_shops: List[VisibleShop] = Field(max_length=16)
    map_state: Dict[str, JsonValue]
    events_since_previous: List[Dict[str, JsonValue]]
    last_action_receipt: Optional[Dict[str, JsonValue]]
    limits_remaining: Dict[str, JsonValue]
    observation_truncated: bool = False
    omitted_counts: Dict[str, int] = Field(default_factory=dict)
    brief: List[str] = Field(default_factory=list)

    @field_validator("working_memory")
    @classmethod
    def bound_observation_memory_bytes(cls, value: Optional[str]) -> Optional[str]:
        if value is not None and len(value.encode("utf-8")) > 4_096:
            raise ValueError("working_memory exceeds 4096 UTF-8 bytes")
        return value


RejectionCode = Literal[
    "invalid_json",
    "schema_mismatch",
    "unsupported_version",
    "wrong_match",
    "wrong_observation",
    "observation_hash_mismatch",
    "expired_batch",
    "duplicate_batch",
    "duplicate_command_id",
    "too_many_commands",
    "atomic_budget_exceeded",
    "too_many_actors",
    "unknown_entity",
    "actor_unavailable",
    "not_owner",
    "target_unavailable",
    "invalid_target_type",
    "out_of_bounds",
    "unexplored_location",
    "requirement_not_met",
    "insufficient_resources",
    "food_cap_blocked",
    "queue_full",
    "ability_unavailable",
    "cooldown_active",
    "invalid_placement",
    "conflicting_order",
    "unsupported_operation",
    "execution_failed",
    "provider_timeout",
]


class CommandReceipt(DuelModel):
    command_id: CommandId
    status: Literal["applied", "partially_applied", "rejected"]
    code: Optional[RejectionCode]
    requested_quantity: Optional[int] = Field(default=None, ge=1, le=24)
    accepted_quantity: Optional[int] = Field(default=None, ge=0, le=24)
    atomic_cost: Optional[int] = Field(default=None, ge=0, le=64)
    compiled_order_ids: Optional[List[BatchId]] = Field(default=None, max_length=24)

    @model_validator(mode="after")
    def validate_quantities_and_ids(self) -> CommandReceipt:
        if (
            self.requested_quantity is not None
            and self.accepted_quantity is not None
            and self.accepted_quantity > self.requested_quantity
        ):
            raise ValueError("accepted_quantity cannot exceed requested_quantity")
        if self.compiled_order_ids is not None:
            if len(self.compiled_order_ids) != len(set(self.compiled_order_ids)):
                raise ValueError("compiled_order_ids must be unique")
            if self.compiled_order_ids != sorted(self.compiled_order_ids):
                raise ValueError("compiled_order_ids must use ascending canonical order")
        if self.status == "rejected" and self.code is None:
            raise ValueError("a rejected command requires a stable rejection code")
        return self


class ActionReceipt(DuelModel):
    batch_id: BatchId
    observation_seq: int = Field(ge=0)
    received_tick: int = Field(ge=0)
    apply_tick: Optional[int] = Field(ge=1)
    batch_status: Literal[
        "applied",
        "partially_applied",
        "rejected",
        "expired",
        "timed_out",
        "no_op",
    ]
    code: Optional[RejectionCode] = None
    commands: List[CommandReceipt] = Field(default_factory=list, max_length=16)

    @model_validator(mode="after")
    def validate_status(self) -> ActionReceipt:
        if self.batch_status in {"applied", "partially_applied"} and self.apply_tick is None:
            raise ValueError("an applied batch requires apply_tick")
        if self.batch_status in {"rejected", "expired", "timed_out"} and self.code is None:
            raise ValueError("a failed batch requires a stable rejection code")
        return self

    def to_wire_dict(self) -> Dict[str, Any]:
        """Emit schema bytes while retaining each command's required nullable code."""

        value = self.model_dump(mode="json", exclude_none=True)
        for command_index, command in enumerate(self.commands):
            value["commands"][command_index]["code"] = command.code
        return value


EventKind = Literal[
    "entity_created",
    "entity_entered_vision",
    "entity_left_vision",
    "entity_reacquired",
    "entity_transformed",
    "entity_destroyed",
    "attack_observed",
    "damage_observed",
    "healing_observed",
    "cast_observed",
    "status_started",
    "status_ended",
    "item_picked_up",
    "item_dropped",
    "resource_deposited",
    "resource_spent",
    "resource_refunded",
    "upkeep_changed",
    "order_started",
    "order_completed",
    "order_cancelled",
    "order_paused",
    "order_failed",
    "construction_progress",
    "construction_completed",
    "repair_progress",
    "production_progress",
    "production_completed",
    "research_progress",
    "research_completed",
    "tier_completed",
    "revival_progress",
    "revival_completed",
    "hero_xp_gained",
    "hero_level_gained",
    "hero_skill_learned",
    "creep_camp_cleared",
    "camp_item_revealed",
    "shop_restocked",
    "shop_purchase",
    "day_phase_changed",
    "resource_depleted",
    "terrain_changed",
    "pathing_changed",
    "batch_timeout",
    "batch_schema_failed",
    "command_applied",
    "command_rejected",
    "terminal_win",
    "terminal_loss",
    "terminal_draw",
    "terminal_forfeit",
    "terminal_infrastructure_void",
]


class EventPayload(DuelModel):
    entity_id: Optional[BatchId] = None
    source_entity_id: Optional[BatchId] = None
    target_entity_id: Optional[BatchId] = None
    type_id: Optional[BatchId] = None
    previous_type_id: Optional[BatchId] = None
    site_id: Optional[BatchId] = None
    region_id: Optional[BatchId] = None
    position_mt: Optional[Tuple[int, int]] = None
    resource: Optional[Literal["gold", "lumber", "food", "mana", "hp"]] = None
    amount: Optional[int] = None
    damage: Optional[int] = Field(default=None, ge=0)
    healing: Optional[int] = Field(default=None, ge=0)
    progress_bp: Optional[int] = Field(default=None, ge=0, le=10_000)
    status_id: Optional[BatchId] = None
    ability_id: Optional[BatchId] = None
    item_id: Optional[BatchId] = None
    upgrade_id: Optional[BatchId] = None
    offer_id: Optional[BatchId] = None
    queue_entry_id: Optional[BatchId] = None
    batch_id: Optional[BatchId] = None
    command_id: Optional[BatchId] = None
    compiled_order_id: Optional[BatchId] = None
    code: Optional[str] = Field(default=None, max_length=64)
    day_phase: Optional[Literal["day", "night", "forced_night"]] = None
    terminal_reason: Optional[str] = Field(default=None, max_length=80)
    winner: Optional[Literal["self", "opponent", "none"]] = None
    tier: Optional[int] = Field(default=None, ge=1, le=3)
    level: Optional[int] = Field(default=None, ge=1, le=10)
    xp: Optional[int] = Field(default=None, ge=0)
    details: Optional[List[BatchId]] = Field(default=None, max_length=24)

    @field_validator("details")
    @classmethod
    def canonical_details(cls, value: Optional[List[str]]) -> Optional[List[str]]:
        if value is not None and (len(value) != len(set(value)) or value != sorted(value)):
            raise ValueError("event details must be unique and in ascending canonical order")
        return value


class ObservableEvent(DuelModel):
    event_seq: int = Field(ge=1)
    tick: int = Field(ge=0)
    kind: EventKind
    audience: Literal["self", "opponent", "omniscient"]
    payload: EventPayload

    def to_wire_dict(self) -> Dict[str, Any]:
        return self.model_dump(mode="json", exclude_none=True)
