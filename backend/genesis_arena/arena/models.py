from __future__ import annotations

# ruff: noqa: UP045 -- Pydantic evaluates annotations on the supported Python 3.9 runtime.
import unicodedata
from enum import Enum
from typing import Annotated, Any, Dict, List, Literal, Optional, Union

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

FactionId = Literal["sol", "terra", "luna"]
ProtocolVersion = Literal["world-arena/0.2"]
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
    model_config = ConfigDict(extra="forbid", validate_assignment=True)

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


class ResourceBundle(ArenaModel):
    food: int = Field(default=0, ge=0, le=100_000)
    wood: int = Field(default=0, ge=0, le=100_000)
    stone: int = Field(default=0, ge=0, le=100_000)
    iron: int = Field(default=0, ge=0, le=100_000)
    crystal: int = Field(default=0, ge=0, le=100_000)

    @property
    def total(self) -> int:
        return self.food + self.wood + self.stone + self.iron + self.crystal


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
    resources: Optional[ResourceBundle] = None


class EnemyContact(ArenaModel):
    contact_id: Identifier
    faction_id: FactionId
    unit_kind: str = Field(min_length=1, max_length=32)
    approximate_count: int = Field(ge=1)
    district_id: Identifier
    last_seen_round: int = Field(ge=0)


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


class FactionObservation(ArenaModel):
    match_id: Identifier
    round: int = Field(ge=1, le=48)
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
    available_actions: List[str] = Field(default_factory=list)

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
        return self


class RoundRequest(ArenaModel):
    type: Literal["round_request"] = "round_request"
    protocol: ProtocolVersion = "world-arena/0.2"
    match_id: Identifier
    round: int = Field(ge=1, le=48)
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


class PhysicalAction(str, Enum):
    ASSIGN_WORKERS = "assign_workers"
    HUNT = "hunt"
    SCOUT = "scout"
    REPAIR = "repair"
    BUILD = "build"
    TRAIN = "train"
    RESEARCH = "research"
    MOBILIZE = "mobilize"
    REINFORCE = "reinforce"
    RETREAT = "retreat"


COMMAND_POINT_COST: Dict[PhysicalAction, int] = {
    PhysicalAction.ASSIGN_WORKERS: 1,
    PhysicalAction.HUNT: 1,
    PhysicalAction.SCOUT: 1,
    PhysicalAction.REPAIR: 1,
    PhysicalAction.BUILD: 1,
    PhysicalAction.TRAIN: 1,
    PhysicalAction.RESEARCH: 1,
    PhysicalAction.MOBILIZE: 2,
    PhysicalAction.REINFORCE: 2,
    PhysicalAction.RETREAT: 2,
}


class PhysicalOrder(ArenaModel):
    order_id: Identifier
    action: PhysicalAction
    actor_ids: List[Identifier] = Field(min_length=1, max_length=4)
    target_id: Identifier
    resource: Optional[ResourceKind] = None
    option: Optional[str] = Field(default=None, max_length=64)
    stance: Optional[Literal["raid", "assault", "hold", "avoid"]] = None

    @model_validator(mode="after")
    def validate_action_fields(self) -> PhysicalOrder:
        if len(set(self.actor_ids)) != len(self.actor_ids):
            raise ValueError("order actor IDs must be unique")
        if self.action == PhysicalAction.ASSIGN_WORKERS and self.resource is None:
            raise ValueError("assign_workers requires a resource")
        if self.action in {PhysicalAction.BUILD, PhysicalAction.TRAIN, PhysicalAction.RESEARCH}:
            if not self.option:
                raise ValueError(f"{self.action.value} requires option")
        if self.action in {
            PhysicalAction.MOBILIZE,
            PhysicalAction.REINFORCE,
            PhysicalAction.RETREAT,
        } and self.stance is None:
            raise ValueError(f"{self.action.value} requires stance")
        return self

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
    expires_round: int = Field(ge=1, le=48)

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
    expires_round: int = Field(default=48, ge=1, le=48)

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
    expires_round: int = Field(ge=1, le=48)


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
    schema_version: Literal["arena-v1"] = "arena-v1"
    match_id: Identifier
    round: int = Field(ge=1, le=48)
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
    protocol: ProtocolVersion = "world-arena/0.2"
    match_id: Identifier
    round: int = Field(ge=1, le=48)
    snapshot_hash: HashHex
    commits: List[PlanCommit] = Field(min_length=3, max_length=3)


class RoundCommitsLocked(ArenaModel):
    type: Literal["round_commits_locked"] = "round_commits_locked"
    protocol: ProtocolVersion = "world-arena/0.2"
    match_id: Identifier
    round: int = Field(ge=1, le=48)
    commit_hashes: Dict[FactionId, HashHex]


class RevealedPlan(ArenaModel):
    faction_id: FactionId
    plan: FactionPlan
    salt: Annotated[str, Field(pattern=r"^[0-9a-f]{32}$")]
    commit_hash: HashHex


class RoundPlanReveal(ArenaModel):
    type: Literal["round_plan_reveal"] = "round_plan_reveal"
    protocol: ProtocolVersion = "world-arena/0.2"
    match_id: Identifier
    round: int = Field(ge=1, le=48)
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
    round: int = Field(ge=0, le=48)
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
        "highlight",
        "system",
    ]
    actor_id: Optional[str] = None
    target_ids: List[str] = Field(default_factory=list)
    visibility: Literal["public", "participants", "faction", "spectator"]
    visible_to: List[FactionId] = Field(default_factory=list)
    summary: str = Field(min_length=1, max_length=320)
    payload: Dict[str, object] = Field(default_factory=dict)
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
    supplied_points: int = Field(ge=0, le=13)
    territory_time: int = Field(ge=0)
    crown_hold_rounds: int = Field(default=0, ge=0, le=48)
    completed_structure_value: int = Field(default=0, ge=0)
    completed_structures: int = Field(default=0, ge=0)

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
    completed_rounds: int = Field(ge=1, le=48)
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


class RoundReceipt(ArenaModel):
    type: Literal["round_receipts"] = "round_receipts"
    protocol: ProtocolVersion = "world-arena/0.2"
    match_id: Identifier
    round: int = Field(ge=1, le=48)
    previous_state_hash: HashHex
    state_hash: HashHex
    events: List[ArenaEvent] = Field(default_factory=list)
    validation_receipts: List[Dict[str, object]] = Field(default_factory=list)
    terminal_outcome: Optional[TerminalOutcome] = None

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
        if (
            self.terminal_outcome is not None
            and self.terminal_outcome.completed_rounds != self.round
        ):
            raise ValueError("terminal outcome completed_rounds must equal receipt round")
        return self


def project_events_for_faction(
    events: List[ArenaEvent], faction_id: FactionId
) -> List[ArenaEvent]:
    """Return only events that are legal input to a faction prompt."""

    return [
        event.model_copy(deep=True)
        for event in events
        if event.visibility == "public"
        or (event.visibility in {"participants", "faction"} and faction_id in event.visible_to)
    ]
