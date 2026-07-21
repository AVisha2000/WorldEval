from __future__ import annotations

# ruff: noqa: UP045 -- Pydantic evaluates annotations on the supported Python 3.9 runtime.
import unicodedata
from enum import Enum
from typing import Annotated, Any, Dict, List, Literal, Optional, Union

from pydantic import BaseModel, ConfigDict, Field, JsonValue, field_validator, model_validator

FactionId = Literal["sol", "terra", "luna"]
# Older envelopes remain readable while conquest clients migrate to v0.4.
ProtocolVersion = Literal["world-arena/0.2", "world-arena/0.3", "world-arena/0.4"]
ObservationMode = Literal["semantic", "vision", "hybrid"]
NarrativePhase = Literal["opening", "fortify", "expand", "war", "endgame"]
MAX_CONQUEST_ROUNDS = 120
HashHex = Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]
Identifier = Annotated[str, Field(min_length=1, max_length=96, pattern=r"^[a-z0-9][a-z0-9_.:-]*$")]
RegionSelector = Annotated[
    str,
    Field(min_length=1, max_length=96, pattern=r"^(?:\*|[a-z0-9][a-z0-9_.:-]*)$"),
]


def _normalize_and_reject_controls(value: Any) -> Any:
    """Normalize all wire text before hashing and reject unsafe invisible controls."""

    if isinstance(value, str):
        normalized = unicodedata.normalize("NFC", value)
        if any(unicodedata.category(character).startswith("C") for character in normalized):
            raise ValueError("control characters are not allowed in Arena text")
        return normalized
    if isinstance(value, dict):
        return {
            _normalize_and_reject_controls(key): _normalize_and_reject_controls(child)
            for key, child in value.items()
        }
    if isinstance(value, list):
        return [_normalize_and_reject_controls(child) for child in value]
    if isinstance(value, tuple):
        return tuple(_normalize_and_reject_controls(child) for child in value)
    return value


class ArenaModel(BaseModel):
    model_config = ConfigDict(extra="forbid", validate_assignment=True, allow_inf_nan=False)

    @model_validator(mode="before")
    @classmethod
    def normalize_text(cls, value: Any) -> Any:
        return _normalize_and_reject_controls(value)


class ResourceKind(str, Enum):
    FOOD = "food"
    WOOD = "wood"
    STONE = "stone"
    IRON = "iron"
    CRYSTAL = "crystal"


class SpecialistRole(str, Enum):
    SCOUT = "scout"
    ECONOMY = "economy"
    MILITARY = "military"
    DIPLOMACY = "diplomacy"


class PhysicalAction(str, Enum):
    """The v0.4 agent SDK vocabulary followed by read-only migration aliases.

    Capitalized values are intentional: they are the public tool/API verbs shown to
    a commander.  Legacy values stay parseable for sealed v0.2/v0.3 replay artifacts
    but are never emitted by a v0.4 action mask or OpenAI tool schema.
    """

    MOVE = "Move"
    GATHER = "Gather"
    BUILD = "Build"
    ATTACK = "Attack"
    RESEARCH = "Research"
    NEGOTIATE = "Negotiate"
    THINK = "Think"

    # v0.2/v0.3 wire aliases.
    ASSIGN_WORKERS = "assign_workers"
    HUNT = "hunt"
    SCOUT = "scout"
    REPAIR = "repair"
    LEGACY_BUILD = "build"
    TRAIN = "train"
    LEGACY_RESEARCH = "research"
    MOBILIZE = "mobilize"
    REINFORCE = "reinforce"
    RETREAT = "retreat"


class ResourceBundle(ArenaModel):
    food: int = Field(default=0, ge=0, le=100_000)
    wood: int = Field(default=0, ge=0, le=100_000)
    stone: int = Field(default=0, ge=0, le=100_000)
    iron: int = Field(default=0, ge=0, le=100_000)
    crystal: int = Field(default=0, ge=0, le=100_000)

    @property
    def total(self) -> int:
        return self.food + self.wood + self.stone + self.iron + self.crystal


class ResourceDelta(ArenaModel):
    food: int = Field(default=0, ge=-100_000, le=100_000)
    wood: int = Field(default=0, ge=-100_000, le=100_000)
    stone: int = Field(default=0, ge=-100_000, le=100_000)
    iron: int = Field(default=0, ge=-100_000, le=100_000)
    crystal: int = Field(default=0, ge=-100_000, le=100_000)


class FriendlyGroup(ArenaModel):
    group_id: Identifier
    unit_kind: str = Field(min_length=1, max_length=32)
    count: int = Field(ge=1, le=4)
    district_id: Identifier
    health: int = Field(ge=0)
    job: Optional[str] = Field(default=None, max_length=64)


class FriendlyStructure(ArenaModel):
    structure_id: Identifier
    structure_kind: str = Field(min_length=1, max_length=32)
    district_id: Identifier
    health: int = Field(ge=0)
    complete: bool = True


class DistrictObservation(ArenaModel):
    district_id: Identifier
    owner_id: Optional[FactionId] = None
    supplied: Optional[bool] = None
    contested: bool = False
    last_seen_round: int = Field(ge=0)
    last_seen_tick: int = Field(default=0, ge=0)
    visibility: Literal["visible", "discovered", "unknown"] = "visible"
    adjacent_ids: List[Identifier] = Field(default_factory=list, max_length=8)
    resources: Optional[ResourceBundle] = None


class EnemyContact(ArenaModel):
    contact_id: Identifier
    faction_id: FactionId
    unit_kind: str = Field(min_length=1, max_length=32)
    approximate_count: int = Field(ge=1)
    district_id: Identifier
    last_seen_round: int = Field(ge=0)
    last_seen_tick: int = Field(default=0, ge=0)
    confidence: Literal["exact", "high", "medium", "low"] = "high"
    health_band: Optional[Literal["healthy", "damaged", "critical"]] = None
    stale: bool = False


class WildlifeObservation(ArenaModel):
    wildlife_id: Identifier
    species: Literal["deer", "boar", "wolves"]
    approximate_count: int = Field(ge=1)
    district_id: Identifier
    alert: bool = False


class PublicFactionScore(ArenaModel):
    faction_id: FactionId
    core_health: int = Field(ge=0)
    supplied_land: int = Field(ge=0)
    territory_time: int = Field(ge=0)
    eliminated: bool = False
    core_max_health: int = Field(default=1_000, ge=1)
    territory_percent: float = Field(default=0, ge=0, le=100)
    population: int = Field(default=0, ge=0)
    supply_cap: int = Field(default=0, ge=0)
    tech_tier: int = Field(default=0, ge=0, le=3)
    current_intent: str = Field(default="", max_length=240)


class ObservedMessage(ArenaModel):
    message_id: Identifier
    sender_id: FactionId
    visibility: Literal["public", "private"]
    recipients: List[FactionId] = Field(default_factory=list, max_length=2)
    text: str = Field(min_length=1, max_length=320)
    sent_round: int = Field(ge=0)

    @model_validator(mode="after")
    def validate_visibility(self) -> ObservedMessage:
        if self.visibility == "public" and self.recipients:
            raise ValueError("public messages cannot have private recipients")
        if self.visibility == "private" and not self.recipients:
            raise ValueError("private messages require recipients")
        if self.sender_id in self.recipients:
            raise ValueError("a sender cannot be its own recipient")
        if len(set(self.recipients)) != len(self.recipients):
            raise ValueError("message recipients must be unique")
        return self


class PendingOfferView(ArenaModel):
    offer_id: Identifier
    kind: Literal["trade", "non_aggression", "coordinate_attack"]
    sender_id: FactionId
    recipient_id: FactionId
    expires_round: int = Field(ge=1)
    summary: str = Field(min_length=1, max_length=240)


class CognitionView(ArenaModel):
    track: Literal["standard", "agentic", "open"] = "standard"
    remaining_units: int = Field(ge=0)
    commander_cost: int = Field(default=2, ge=0)
    specialist_cost: int = Field(default=1, ge=0)
    active_specialist_ids: List[Identifier] = Field(default_factory=list, max_length=3)

    @model_validator(mode="after")
    def validate_active_specialists(self) -> CognitionView:
        if len(set(self.active_specialist_ids)) != len(self.active_specialist_ids):
            raise ValueError("active specialist IDs must be unique")
        return self


class ActionAvailability(ArenaModel):
    """A serializable action-mask entry for one physical action.

    The v0.2 ``available_actions`` list remains accepted.  v0.3 senders can attach a
    reason and legal target IDs without handing agents opaque engine state.
    """

    action: PhysicalAction
    enabled: bool
    reason: Optional[str] = Field(default=None, min_length=1, max_length=240)
    legal_actor_ids: List[Identifier] = Field(default_factory=list, max_length=64)
    legal_target_ids: List[Identifier] = Field(default_factory=list, max_length=128)

    @model_validator(mode="after")
    def validate_targets(self) -> ActionAvailability:
        if len(set(self.legal_actor_ids)) != len(self.legal_actor_ids):
            raise ValueError("action-mask actor IDs must be unique")
        if len(set(self.legal_target_ids)) != len(self.legal_target_ids):
            raise ValueError("action-mask target IDs must be unique")
        if self.enabled and self.reason is not None:
            raise ValueError("enabled action masks cannot carry a denial reason")
        if not self.enabled and self.reason is None:
            raise ValueError("disabled action masks require a reason")
        return self


class VisionObservation(ArenaModel):
    """Reference-only camera evidence; image bytes never enter semantic prompts."""

    frame_id: Identifier
    content_hash: HashHex
    width: int = Field(ge=1, le=16_384)
    height: int = Field(ge=1, le=16_384)
    mime_type: Literal["image/png", "image/jpeg"] = "image/png"
    frame_uri: str = Field(min_length=1, max_length=2_048)


class StrongholdView(ArenaModel):
    stronghold_id: Identifier
    district_id: Identifier
    health: int = Field(ge=0)
    max_health: int = Field(default=1_000, ge=1)
    under_attack: bool = False


class TechnologyView(ArenaModel):
    tier: int = Field(default=0, ge=0, le=3)
    completed: List[Identifier] = Field(default_factory=list, max_length=32)
    available: List[Identifier] = Field(default_factory=list, max_length=32)
    active_technology_id: Optional[Identifier] = None
    active_progress: int = Field(default=0, ge=0)
    active_required_work: int = Field(default=0, ge=0)

    @model_validator(mode="after")
    def validate_technology(self) -> TechnologyView:
        if len(set(self.completed)) != len(self.completed):
            raise ValueError("completed technologies must be unique")
        if len(set(self.available)) != len(self.available):
            raise ValueError("available technologies must be unique")
        if self.active_progress > self.active_required_work:
            raise ValueError("technology progress cannot exceed required work")
        if self.active_technology_id is None and self.active_progress:
            raise ValueError("technology progress requires an active technology")
        return self


class ActiveTaskView(ArenaModel):
    task_id: Identifier
    task_kind: Literal[
        "move",
        "gather",
        "build",
        "train",
        "attack",
        "research",
        "repair",
        "scout",
        "negotiate",
        "think",
    ]
    state: Literal["active", "paused", "complete", "cancelled"]
    district_id: Optional[Identifier] = None
    actor_ids: List[Identifier] = Field(default_factory=list, max_length=16)
    target_id: Optional[Identifier] = None
    required_work: int = Field(ge=0)
    completed_work: int = Field(ge=0)
    work_rate: int = Field(default=0, ge=0)
    eta_ticks: Optional[int] = Field(default=None, ge=0)
    pause_reason: Optional[str] = Field(default=None, min_length=1, max_length=160)

    @model_validator(mode="after")
    def validate_progress(self) -> ActiveTaskView:
        if len(set(self.actor_ids)) != len(self.actor_ids):
            raise ValueError("task actor IDs must be unique")
        if self.completed_work > self.required_work:
            raise ValueError("task completed_work cannot exceed required_work")
        if self.state == "paused" and self.pause_reason is None:
            raise ValueError("paused tasks require a pause_reason")
        return self


class FactionObservation(ArenaModel):
    match_id: Identifier
    round: int = Field(ge=1, le=MAX_CONQUEST_ROUNDS)
    faction_id: FactionId
    snapshot_hash: HashHex
    inventory: ResourceBundle
    groups: List[FriendlyGroup] = Field(default_factory=list)
    structures: List[FriendlyStructure] = Field(default_factory=list)
    districts: List[DistrictObservation] = Field(default_factory=list)
    enemy_contacts: List[EnemyContact] = Field(default_factory=list)
    wildlife: List[WildlifeObservation] = Field(default_factory=list)
    public_scores: List[PublicFactionScore] = Field(min_length=3, max_length=3)
    messages: List[ObservedMessage] = Field(default_factory=list, max_length=24)
    pending_offers: List[PendingOfferView] = Field(default_factory=list, max_length=12)
    recent_events: List[str] = Field(default_factory=list, max_length=24)
    cognition: CognitionView
    # Legacy v0.2 list.  Its values are constrained to the same action vocabulary as
    # the richer v0.3 mask, so it remains safe to pass to older commanders.
    available_actions: List[PhysicalAction] = Field(default_factory=list)
    observation_mode: ObservationMode = "semantic"
    action_mask: List[ActionAvailability] = Field(default_factory=list)
    active_tasks: List[ActiveTaskView] = Field(default_factory=list, max_length=24)
    projected_at_tick: int = Field(default=0, ge=0)
    narrative_phase: NarrativePhase = "opening"
    stronghold: Optional[StrongholdView] = None
    technology: TechnologyView = Field(default_factory=TechnologyView)
    population: int = Field(default=0, ge=0)
    supply_cap: int = Field(default=0, ge=0)
    explored_district_ids: List[Identifier] = Field(default_factory=list, max_length=128)
    vision: Optional[VisionObservation] = None

    @model_validator(mode="after")
    def reject_private_information_leaks(self) -> FactionObservation:
        score_ids = [score.faction_id for score in self.public_scores]
        if set(score_ids) != {"sol", "terra", "luna"}:
            raise ValueError("public_scores must contain each faction exactly once")
        for message in self.messages:
            if (
                message.visibility == "private"
                and self.faction_id != message.sender_id
                and self.faction_id not in message.recipients
            ):
                raise ValueError("observation contains an unauthorized private message")
        for offer in self.pending_offers:
            if self.faction_id not in {offer.sender_id, offer.recipient_id}:
                raise ValueError("observation contains an unauthorized private offer")
        if len(set(self.available_actions)) != len(self.available_actions):
            raise ValueError("available actions must be unique")
        masks = [item.action for item in self.action_mask]
        if len(set(masks)) != len(masks):
            raise ValueError("action mask entries must be unique per action")
        if self.action_mask:
            enabled = {item.action for item in self.action_mask if item.enabled}
            if set(self.available_actions) != enabled:
                raise ValueError("available_actions must exactly match enabled action-mask entries")
        if self.observation_mode == "vision" and self.vision is None:
            raise ValueError("vision observations require a vision frame")
        if self.observation_mode == "hybrid" and self.vision is None:
            raise ValueError("hybrid observations require a vision frame")
        if self.population > self.supply_cap and self.supply_cap > 0:
            raise ValueError("population cannot exceed supply cap")
        if len(set(self.explored_district_ids)) != len(self.explored_district_ids):
            raise ValueError("explored district IDs must be unique")
        return self


class RoundRequest(ArenaModel):
    type: Literal["round_request"] = "round_request"
    protocol: ProtocolVersion = "world-arena/0.4"
    match_id: Identifier
    round: int = Field(ge=1, le=MAX_CONQUEST_ROUNDS)
    snapshot_hash: HashHex
    observations: List[FactionObservation] = Field(min_length=3, max_length=3)

    @model_validator(mode="after")
    def validate_batch(self) -> RoundRequest:
        if {item.faction_id for item in self.observations} != {"sol", "terra", "luna"}:
            raise ValueError("round request requires exactly one observation per faction")
        for item in self.observations:
            if (
                item.match_id != self.match_id
                or item.round != self.round
                or item.snapshot_hash != self.snapshot_hash
            ):
                raise ValueError("observation does not match its round envelope")
        return self


COMMAND_POINT_COST: Dict[PhysicalAction, int] = {
    PhysicalAction.MOVE: 2,
    PhysicalAction.GATHER: 1,
    PhysicalAction.BUILD: 1,
    PhysicalAction.ATTACK: 2,
    PhysicalAction.RESEARCH: 1,
    PhysicalAction.NEGOTIATE: 0,
    PhysicalAction.THINK: 0,
    PhysicalAction.ASSIGN_WORKERS: 1,
    PhysicalAction.HUNT: 1,
    PhysicalAction.SCOUT: 1,
    PhysicalAction.REPAIR: 1,
    PhysicalAction.LEGACY_BUILD: 1,
    PhysicalAction.TRAIN: 1,
    PhysicalAction.LEGACY_RESEARCH: 1,
    PhysicalAction.MOBILIZE: 2,
    PhysicalAction.REINFORCE: 2,
    PhysicalAction.RETREAT: 2,
}


class PhysicalOrder(ArenaModel):
    order_id: Identifier
    action: PhysicalAction
    actor_ids: List[Identifier] = Field(default_factory=list, max_length=16)
    target_id: Optional[Identifier] = None
    resource: Optional[ResourceKind] = None
    option: Optional[str] = Field(default=None, max_length=64)
    stance: Optional[Literal["raid", "assault", "hold", "avoid"]] = None
    mode: Optional[
        Literal[
            "advance",
            "scout",
            "retreat",
            "hold",
            "raid",
            "assault",
            "construct",
            "repair",
            "train",
            "offer",
            "respond",
            "deliberate",
        ]
    ] = None
    attributes: Dict[str, JsonValue] = Field(default_factory=dict, max_length=16)

    @model_validator(mode="after")
    def validate_action_fields(self) -> PhysicalOrder:
        if len(set(self.actor_ids)) != len(self.actor_ids):
            raise ValueError("order actor IDs must be unique")
        if self.action in {
            PhysicalAction.MOVE,
            PhysicalAction.GATHER,
            PhysicalAction.BUILD,
            PhysicalAction.ATTACK,
            PhysicalAction.RESEARCH,
            PhysicalAction.ASSIGN_WORKERS,
            PhysicalAction.HUNT,
            PhysicalAction.SCOUT,
            PhysicalAction.REPAIR,
            PhysicalAction.TRAIN,
            PhysicalAction.LEGACY_BUILD,
            PhysicalAction.LEGACY_RESEARCH,
            PhysicalAction.MOBILIZE,
            PhysicalAction.REINFORCE,
            PhysicalAction.RETREAT,
        } and not self.actor_ids:
            raise ValueError(f"{self.action.value} requires at least one actor")
        if self.action in {
            PhysicalAction.MOVE,
            PhysicalAction.GATHER,
            PhysicalAction.BUILD,
            PhysicalAction.ATTACK,
            PhysicalAction.ASSIGN_WORKERS,
            PhysicalAction.HUNT,
            PhysicalAction.SCOUT,
            PhysicalAction.REPAIR,
            PhysicalAction.TRAIN,
            PhysicalAction.LEGACY_BUILD,
            PhysicalAction.MOBILIZE,
            PhysicalAction.REINFORCE,
            PhysicalAction.RETREAT,
        } and self.target_id is None:
            raise ValueError(f"{self.action.value} requires a target")
        if self.action == PhysicalAction.GATHER and self.resource is None:
            raise ValueError("Gather requires a resource")
        if self.action == PhysicalAction.ASSIGN_WORKERS and self.resource is None:
            raise ValueError("assign_workers requires a resource")
        if self.action in {
            PhysicalAction.BUILD,
            PhysicalAction.RESEARCH,
            PhysicalAction.TRAIN,
            PhysicalAction.LEGACY_BUILD,
            PhysicalAction.LEGACY_RESEARCH,
        }:
            if not self.option:
                raise ValueError(f"{self.action.value} requires option")
        if (
            self.action
            in {
                PhysicalAction.MOBILIZE,
                PhysicalAction.REINFORCE,
                PhysicalAction.RETREAT,
            }
            and self.stance is None
        ):
            raise ValueError(f"{self.action.value} requires stance")
        return self

    @property
    def canonical_action(self) -> PhysicalAction:
        aliases = {
            PhysicalAction.ASSIGN_WORKERS: PhysicalAction.GATHER,
            PhysicalAction.HUNT: PhysicalAction.GATHER,
            PhysicalAction.SCOUT: PhysicalAction.MOVE,
            PhysicalAction.REPAIR: PhysicalAction.BUILD,
            PhysicalAction.TRAIN: PhysicalAction.BUILD,
            PhysicalAction.LEGACY_BUILD: PhysicalAction.BUILD,
            PhysicalAction.LEGACY_RESEARCH: PhysicalAction.RESEARCH,
            PhysicalAction.MOBILIZE: PhysicalAction.MOVE,
            PhysicalAction.REINFORCE: PhysicalAction.MOVE,
            PhysicalAction.RETREAT: PhysicalAction.MOVE,
        }
        return aliases.get(self.action, self.action)

    @property
    def command_points(self) -> int:
        return COMMAND_POINT_COST[self.action]


class Utterance(ArenaModel):
    client_ref: Identifier
    visibility: Literal["public", "private"]
    recipients: List[FactionId] = Field(default_factory=list, max_length=2)
    text: str = Field(min_length=1, max_length=320)

    @model_validator(mode="after")
    def validate_visibility(self) -> Utterance:
        if self.visibility == "public" and self.recipients:
            raise ValueError("public utterances cannot name private recipients")
        if self.visibility == "private" and not self.recipients:
            raise ValueError("private utterances require recipients")
        if len(set(self.recipients)) != len(self.recipients):
            raise ValueError("utterance recipients must be unique")
        return self


class TradeOffer(ArenaModel):
    kind: Literal["trade"] = "trade"
    recipient: FactionId
    visibility: Literal["private"] = "private"
    give: ResourceBundle
    receive: ResourceBundle
    expires_round: int = Field(ge=1, le=MAX_CONQUEST_ROUNDS)

    @model_validator(mode="after")
    def validate_exchange(self) -> TradeOffer:
        if self.give.total == 0 or self.receive.total == 0:
            raise ValueError("trade must give and receive at least one resource")
        return self


class NonAggressionOffer(ArenaModel):
    kind: Literal["non_aggression"] = "non_aggression"
    recipient: FactionId
    visibility: Literal["public_on_accept", "private"] = "public_on_accept"
    duration_rounds: int = Field(ge=1, le=20)
    regions: List[RegionSelector] = Field(
        default_factory=lambda: ["*"], min_length=1, max_length=13
    )
    expires_round: int = Field(default=MAX_CONQUEST_ROUNDS, ge=1, le=MAX_CONQUEST_ROUNDS)

    @field_validator("regions", mode="before")
    @classmethod
    def normalize_wildcard(cls, value: Any) -> Any:
        if isinstance(value, list):
            return ["*" if region == "all" else region for region in value]
        return value

    @model_validator(mode="after")
    def validate_regions(self) -> NonAggressionOffer:
        if len(set(self.regions)) != len(self.regions):
            raise ValueError("pact regions must be unique")
        if "*" in self.regions and len(self.regions) != 1:
            raise ValueError("the pact wildcard cannot be combined with named regions")
        return self


class CoordinateAttackOffer(ArenaModel):
    kind: Literal["coordinate_attack"] = "coordinate_attack"
    recipient: FactionId
    visibility: Literal["private"] = "private"
    target_faction: FactionId
    target_district: Identifier
    expires_round: int = Field(ge=1, le=MAX_CONQUEST_ROUNDS)


FormalOffer = Annotated[
    Union[TradeOffer, NonAggressionOffer, CoordinateAttackOffer],
    Field(discriminator="kind"),
]


class OfferResponse(ArenaModel):
    offer_id: Identifier
    decision: Literal["accept", "reject", "withdraw"]


class CommunicationPlan(ArenaModel):
    utterances: List[Utterance] = Field(default_factory=list, max_length=2)
    new_offer: Optional[FormalOffer] = None
    responses: List[OfferResponse] = Field(default_factory=list, max_length=3)

    @model_validator(mode="after")
    def validate_responses(self) -> CommunicationPlan:
        offer_ids = [response.offer_id for response in self.responses]
        if len(set(offer_ids)) != len(offer_ids):
            raise ValueError("an offer may receive at most one response per round")
        return self


class CreateSpecialist(ArenaModel):
    operation: Literal["create"] = "create"
    specialist_id: Identifier
    role: SpecialistRole
    brief: str = Field(min_length=3, max_length=320)
    priority: int = Field(default=1, ge=1, le=3)


class UpdateSpecialist(ArenaModel):
    operation: Literal["update"] = "update"
    specialist_id: Identifier
    brief: str = Field(min_length=3, max_length=320)
    priority: int = Field(default=1, ge=1, le=3)


class SpecialistStateChange(ArenaModel):
    operation: Literal["pause", "resume", "dismiss"]
    specialist_id: Identifier


SpecialistOperation = Annotated[
    Union[CreateSpecialist, UpdateSpecialist, SpecialistStateChange],
    Field(discriminator="operation"),
]


class FactionPlan(ArenaModel):
    schema_version: Literal["arena-v1", "arena-v2"] = "arena-v2"
    match_id: Identifier
    round: int = Field(ge=1, le=MAX_CONQUEST_ROUNDS)
    faction_id: FactionId
    public_intent: str = Field(min_length=3, max_length=240)
    orders: List[PhysicalOrder] = Field(default_factory=list, max_length=3)
    communication: CommunicationPlan = Field(default_factory=CommunicationPlan)
    specialist_ops: List[SpecialistOperation] = Field(default_factory=list, max_length=3)
    supply_priority: List[Identifier] = Field(default_factory=list, max_length=6)

    @model_validator(mode="after")
    def validate_plan(self) -> FactionPlan:
        order_ids = [order.order_id for order in self.orders]
        if len(set(order_ids)) != len(order_ids):
            raise ValueError("order IDs must be unique")
        command_points = sum(order.command_points for order in self.orders)
        if self.supply_priority:
            command_points += 1
        if command_points > 4:
            raise ValueError("plan exceeds four command points")
        if len(set(self.supply_priority)) != len(self.supply_priority):
            raise ValueError("supply priority IDs must be unique")
        for utterance in self.communication.utterances:
            if self.faction_id in utterance.recipients:
                raise ValueError("a faction cannot message itself")
        offer = self.communication.new_offer
        if offer is not None and offer.recipient == self.faction_id:
            raise ValueError("a faction cannot make itself an offer")
        if offer is not None:
            expires_round = getattr(offer, "expires_round", None)
            if expires_round is not None and expires_round <= self.round:
                raise ValueError("a new offer must expire after the current round")
        negotiation_orders = [
            order for order in self.orders if order.action == PhysicalAction.NEGOTIATE
        ]
        if negotiation_orders and not (
            self.communication.utterances
            or self.communication.new_offer is not None
            or self.communication.responses
        ):
            raise ValueError("Negotiate requires a communication message, offer, or response")
        return self


class SpecialistRecommendation(ArenaModel):
    specialist_id: Identifier
    role: SpecialistRole
    assessment: str = Field(min_length=1, max_length=500)
    risks: List[str] = Field(default_factory=list, max_length=4)
    recommended_orders: List[str] = Field(default_factory=list, max_length=3)
    recommendation_summary: str = Field(min_length=1, max_length=320)


class UsageRecord(ArenaModel):
    input_tokens: int = Field(default=0, ge=0)
    cached_input_tokens: int = Field(default=0, ge=0)
    output_tokens: int = Field(default=0, ge=0)
    reasoning_tokens: int = Field(default=0, ge=0)
    latency_ms: float = Field(default=0, ge=0)
    estimated_cost_usd: float = Field(default=0, ge=0)


class PlanCommit(ArenaModel):
    faction_id: FactionId
    commit_hash: HashHex
    status: Literal["planned", "fallback"]
    specialist_calls: int = Field(default=0, ge=0, le=2)


class RoundCommitHashes(ArenaModel):
    type: Literal["round_commit_hashes"] = "round_commit_hashes"
    protocol: ProtocolVersion = "world-arena/0.4"
    match_id: Identifier
    round: int = Field(ge=1, le=MAX_CONQUEST_ROUNDS)
    snapshot_hash: HashHex
    commits: List[PlanCommit] = Field(min_length=3, max_length=3)


class RoundCommitsLocked(ArenaModel):
    type: Literal["round_commits_locked"] = "round_commits_locked"
    protocol: ProtocolVersion = "world-arena/0.4"
    match_id: Identifier
    round: int = Field(ge=1, le=MAX_CONQUEST_ROUNDS)
    commit_hashes: Dict[FactionId, HashHex]


class RevealedPlan(ArenaModel):
    faction_id: FactionId
    plan: FactionPlan
    salt: Annotated[str, Field(pattern=r"^[0-9a-f]{32}$")]
    commit_hash: HashHex


class RoundPlanReveal(ArenaModel):
    type: Literal["round_plan_reveal"] = "round_plan_reveal"
    protocol: ProtocolVersion = "world-arena/0.4"
    match_id: Identifier
    round: int = Field(ge=1, le=MAX_CONQUEST_ROUNDS)
    plans: List[RevealedPlan] = Field(min_length=3, max_length=3)


DecisionErrorCode = Literal[
    "",
    "decision_timeout",
    "decision_failed",
    "cognition_exhausted",
]


class DecisionDiagnostic(ArenaModel):
    faction_id: FactionId
    status: Literal["planned", "fallback"]
    error: DecisionErrorCode = ""
    specialist_calls: int = Field(default=0, ge=0, le=2)
    cognition_remaining: int = Field(ge=0)
    usage: UsageRecord = Field(default_factory=UsageRecord)


class ArenaEvent(ArenaModel):
    schema_version: Literal[1] = 1
    event_id: Identifier
    match_id: Identifier
    sequence: int = Field(ge=0)
    round: int = Field(ge=0, le=MAX_CONQUEST_ROUNDS)
    tick: int = Field(ge=0, le=150)
    kind: Literal[
        "message",
        "offer",
        "pact",
        "betrayal",
        "advisor",
        "order",
        "territory",
        "supply",
        "combat",
        "resource",
        "core",
        "movement",
        "visibility",
        "research",
        "structure",
        "attack",
        "elimination",
        "phase",
        "technology",
        "truncation",
        "task_started",
        "task_progress",
        "task_paused",
        "task_resumed",
        "task_impact",
        "task_completed",
        "highlight",
        "system",
    ]
    actor_id: Optional[str] = None
    target_ids: List[str] = Field(default_factory=list)
    visibility: Literal["public", "participants", "faction", "spectator"]
    visible_to: List[FactionId] = Field(default_factory=list)
    summary: str = Field(min_length=1, max_length=320)
    # JsonValue rejects arbitrary Python objects, making an event safe to serialize,
    # hash, and replay without a custom encoder.
    payload: Dict[str, JsonValue] = Field(default_factory=dict)
    related_event_ids: List[Identifier] = Field(default_factory=list)

    @model_validator(mode="after")
    def validate_visibility(self) -> ArenaEvent:
        if len(set(self.visible_to)) != len(self.visible_to):
            raise ValueError("event visible_to factions must be unique")
        if self.visibility in {"public", "spectator"} and self.visible_to:
            raise ValueError(f"{self.visibility} events cannot carry visible_to factions")
        if self.visibility == "faction" and len(self.visible_to) != 1:
            raise ValueError("faction events require exactly one visible_to faction")
        if self.visibility == "participants" and not self.visible_to:
            raise ValueError("participant events require at least one visible_to faction")
        return self


class RoundDelta(ArenaModel):
    """Canonical, replayable state changes visible after a simultaneous round."""

    base_state_hash: HashHex
    canonical_events: List[ArenaEvent] = Field(default_factory=list, max_length=2_048)
    resource_deltas: Dict[FactionId, ResourceDelta] = Field(default_factory=dict)
    metadata: Dict[str, JsonValue] = Field(default_factory=dict)

    @model_validator(mode="after")
    def validate_canonical_events(self) -> RoundDelta:
        event_ids = [event.event_id for event in self.canonical_events]
        sequences = [event.sequence for event in self.canonical_events]
        if len(set(event_ids)) != len(event_ids):
            raise ValueError("delta canonical event IDs must be unique")
        if sequences != sorted(sequences) or len(set(sequences)) != len(sequences):
            raise ValueError("delta canonical events must have unique ordered sequences")
        return self


class TaskReceipt(ArenaModel):
    """Authoritative outcome of a persistent v0.3 work task."""

    task_id: Identifier
    faction_id: FactionId
    task_kind: Literal[
        "move",
        "gather",
        "build",
        "train",
        "attack",
        "research",
        "repair",
        "scout",
        "negotiate",
        "think",
    ]
    status: Literal["started", "progress", "paused", "impact", "completed", "cancelled"]
    required_work: int = Field(ge=0)
    completed_work: int = Field(ge=0)
    work_delta: int = Field(default=0, ge=0)
    resource_delta: ResourceDelta = Field(default_factory=ResourceDelta)
    event_id: Optional[Identifier] = None
    detail: Dict[str, JsonValue] = Field(default_factory=dict)

    @model_validator(mode="after")
    def validate_task_receipt(self) -> TaskReceipt:
        if self.completed_work > self.required_work:
            raise ValueError("task receipt completed_work cannot exceed required_work")
        if self.status == "completed" and self.completed_work != self.required_work:
            raise ValueError("completed task receipts require all work to be completed")
        return self


class ValidationReceipt(ArenaModel):
    receipt_id: Identifier
    subject_id: Identifier
    accepted: bool
    code: str = Field(min_length=1, max_length=96, pattern=r"^[a-z0-9][a-z0-9_.:-]*$")
    detail: Optional[str] = Field(default=None, min_length=1, max_length=320)
    metadata: Dict[str, JsonValue] = Field(default_factory=dict)


class RewardVector(ArenaModel):
    """Unweighted training/evaluation components, deliberately separate from placement."""

    faction_id: FactionId
    components: Dict[str, float] = Field(default_factory=dict, max_length=16)

    @field_validator("components")
    @classmethod
    def validate_component_names(cls, value: Dict[str, float]) -> Dict[str, float]:
        for name in value:
            if (
                not name
                or len(name) > 64
                or not all(
                    character.islower() or character.isdigit() or character == "_"
                    for character in name
                )
            ):
                raise ValueError("reward component names must be lowercase snake_case")
        return value


class RewardVectorMetadata(ArenaModel):
    schema_version: Literal[1] = 1
    exposed_to_agent: bool = False
    vectors: List[RewardVector] = Field(min_length=3, max_length=3)
    scenario_id: Optional[Identifier] = None

    @model_validator(mode="after")
    def validate_vectors(self) -> RewardVectorMetadata:
        if {item.faction_id for item in self.vectors} != {"sol", "terra", "luna"}:
            raise ValueError("reward vectors require sol, terra, and luna exactly once")
        return self


class TerminationMetadata(ArenaModel):
    terminated: bool
    reason: Optional[
        Literal[
            "last_faction_surviving",
            "verified_draw",
            "scenario_complete",
            # Legacy receipt reasons remain parseable.
            "winner",
            "draw",
            "elimination",
        ]
    ] = None

    @model_validator(mode="after")
    def validate_reason(self) -> TerminationMetadata:
        if self.terminated != (self.reason is not None):
            raise ValueError("termination reason must be present exactly when terminated")
        return self


class TruncationMetadata(ArenaModel):
    truncated: bool
    reason: Optional[Literal["time_limit", "round_limit", "external_stop"]] = None

    @model_validator(mode="after")
    def validate_reason(self) -> TruncationMetadata:
        if self.truncated != (self.reason is not None):
            raise ValueError("truncation reason must be present exactly when truncated")
        return self


class TerminalFactionOutcome(ArenaModel):
    """Minimal final-world facts exported by the authoritative Godot simulation.

    This deliberately contains outcomes and physical-state measurements only.  Model
    usage, plan diagnostics, and score derivation remain in the backend, so a client
    cannot submit a ready-made or mock scorecard as verified evidence.
    """

    faction_id: FactionId
    placement: int = Field(ge=1, le=3)
    won: bool = False
    draw: bool = False
    core_health: int = Field(ge=0, le=1_000)
    supplied_points: int = Field(ge=0, le=128)
    territory_time: int = Field(ge=0)
    enemy_strongholds_destroyed: int = Field(default=0, ge=0, le=2)
    districts_discovered: int = Field(default=0, ge=0, le=128)
    tech_tier: int = Field(default=0, ge=0, le=3)
    completed_structure_value: int = Field(default=0, ge=0)
    completed_structures: int = Field(default=0, ge=0)

    @model_validator(mode="before")
    @classmethod
    def discard_legacy_center_score(cls, value: Any) -> Any:
        # Read old sealed artifacts without carrying the removed king-of-the-hill
        # metric into v0.4 output, evaluation, or agent prompts.
        if isinstance(value, dict) and "crown_hold_rounds" in value:
            value = dict(value)
            value.pop("crown_hold_rounds", None)
        return value

    @model_validator(mode="after")
    def validate_outcome(self) -> TerminalFactionOutcome:
        if self.won and (self.placement != 1 or self.draw):
            raise ValueError("a terminal winner must be a sole first-place faction")
        if self.draw and self.won:
            raise ValueError("a terminal faction cannot both win and draw")
        return self


class TerminalOutcome(ArenaModel):
    """Terminal receipt proof needed before the backend emits an official result."""

    ended: Literal[True] = True
    winner: Literal["sol", "terra", "luna", "draw"]
    completed_rounds: int = Field(ge=1, le=MAX_CONQUEST_ROUNDS)
    termination_reason: Literal["last_faction_surviving", "verified_draw"] = (
        "last_faction_surviving"
    )
    rules_hash: HashHex
    map_hash: HashHex
    tool_hash: HashHex
    factions: List[TerminalFactionOutcome] = Field(min_length=3, max_length=3)

    @model_validator(mode="after")
    def validate_terminal_outcome(self) -> TerminalOutcome:
        if {item.faction_id for item in self.factions} != {"sol", "terra", "luna"}:
            raise ValueError("terminal outcome requires sol, terra, and luna exactly once")
        winners = [item for item in self.factions if item.won]
        draws = [item for item in self.factions if item.draw]
        placements = sorted(item.placement for item in self.factions)
        if self.winner == "draw":
            if winners or len(draws) < 2 or sum(item.placement == 1 for item in draws) < 2:
                raise ValueError("terminal draw requires at least two tied first-place factions")
        else:
            if placements != [1, 2, 3] or len(winners) != 1 or winners[0].faction_id != self.winner:
                raise ValueError("terminal winner conflicts with placements")
        return self


class TruncationStandings(ArenaModel):
    """Non-victory ordering emitted when the benchmark time budget expires."""

    round: int = Field(ge=1, le=MAX_CONQUEST_ROUNDS)
    reason: Literal["time_limit", "round_limit", "external_stop"]
    factions: List[TerminalFactionOutcome] = Field(min_length=3, max_length=3)

    @model_validator(mode="after")
    def validate_standings(self) -> TruncationStandings:
        if {item.faction_id for item in self.factions} != {"sol", "terra", "luna"}:
            raise ValueError("truncation standings require every faction exactly once")
        if any(item.won or item.draw for item in self.factions):
            raise ValueError("truncation standings cannot declare a winner or draw")
        if sorted(item.placement for item in self.factions) != [1, 2, 3]:
            raise ValueError("truncation standings require deterministic ranks 1, 2, and 3")
        return self


class RoundReceipt(ArenaModel):
    type: Literal["round_receipts"] = "round_receipts"
    protocol: ProtocolVersion = "world-arena/0.4"
    match_id: Identifier
    round: int = Field(ge=1, le=MAX_CONQUEST_ROUNDS)
    previous_state_hash: HashHex
    state_hash: HashHex
    events: List[ArenaEvent] = Field(default_factory=list)
    # Raw v0.2 receipts remain accepted, but are constrained to JSON values instead
    # of arbitrary Python objects.  v0.3 producers should use typed_validation_receipts.
    validation_receipts: List[Union[ValidationReceipt, Dict[str, JsonValue]]] = Field(
        default_factory=list
    )
    # v0.3 fields are optional so a frozen v0.2 Godot sender remains valid.
    delta: Optional[RoundDelta] = None
    task_receipts: List[TaskReceipt] = Field(default_factory=list, max_length=256)
    typed_validation_receipts: List[ValidationReceipt] = Field(default_factory=list, max_length=256)
    reward_vector: Optional[RewardVectorMetadata] = None
    termination: Optional[TerminationMetadata] = None
    truncation: Optional[TruncationMetadata] = None
    terminal_outcome: Optional[TerminalOutcome] = None
    standings: Optional[TruncationStandings] = None

    @model_validator(mode="after")
    def validate_events(self) -> RoundReceipt:
        event_ids = [event.event_id for event in self.events]
        sequences = [event.sequence for event in self.events]
        if len(set(event_ids)) != len(event_ids):
            raise ValueError("round receipt event IDs must be unique")
        if len(set(sequences)) != len(sequences):
            raise ValueError("round receipt event sequences must be unique")
        if sequences != sorted(sequences):
            raise ValueError("round receipt events must be in sequence order")
        for event in self.events:
            if event.match_id != self.match_id or event.round != self.round:
                raise ValueError("round receipt event does not match its envelope")
        if self.delta is not None:
            if self.delta.base_state_hash != self.previous_state_hash:
                raise ValueError("delta base_state_hash must equal receipt previous_state_hash")
            for event in self.delta.canonical_events:
                if event.match_id != self.match_id or event.round != self.round:
                    raise ValueError("delta event does not match its receipt envelope")
        # A task may legitimately emit progress and impact receipts in one round; the
        # pair is made unambiguous by their status rather than silently deduplicated.
        if len(set((item.task_id, item.status) for item in self.task_receipts)) != len(
            self.task_receipts
        ):
            raise ValueError("task receipt task_id/status pairs must be unique per round")
        if self.termination is not None and self.termination.terminated != (
            self.terminal_outcome is not None
        ):
            raise ValueError("termination metadata must agree with terminal_outcome")
        if self.truncation is not None and self.truncation.truncated and self.terminal_outcome:
            raise ValueError("a receipt cannot be both truncated and terminal")
        if self.standings is not None:
            if self.truncation is None or not self.truncation.truncated:
                raise ValueError("standings are only legal on a truncated receipt")
            if self.standings.round != self.round:
                raise ValueError("truncation standings must match the receipt round")
            if self.standings.reason != self.truncation.reason:
                raise ValueError("standings and truncation reasons must agree")
        if (
            self.terminal_outcome is not None
            and self.terminal_outcome.completed_rounds != self.round
        ):
            raise ValueError("terminal outcome completed_rounds must equal receipt round")
        return self


def project_events_for_faction(events: List[ArenaEvent], faction_id: FactionId) -> List[ArenaEvent]:
    """Return only events that are legal input to a faction prompt."""

    return [
        event.model_copy(deep=True)
        for event in events
        if event.visibility == "public"
        or (event.visibility in {"participants", "faction"} and faction_id in event.visible_to)
    ]
