from __future__ import annotations

# ruff: noqa: UP045 -- Python 3.9-compatible annotations are intentional.
from typing import Dict, List, Optional

from .models import (
    CommunicationPlan,
    CreateSpecialist,
    FactionObservation,
    FactionPlan,
    FriendlyGroup,
    NonAggressionOffer,
    OfferResponse,
    PhysicalAction,
    PhysicalOrder,
    ResourceBundle,
    SpecialistRole,
    TradeOffer,
    Utterance,
)


class ArenaDemoCommander:
    """Deterministic policy that demonstrates the complete conquest story.

    It is deliberately a visible fallback/demo opponent rather than a benchmark model. Its
    plans use the same strict contract and simultaneous commit/reveal path as live models.
    """

    STAGING: Dict[str, str] = {
        "sol": "mine_st",
        "terra": "mine_tl",
        "luna": "mine_ls",
    }
    RIVAL: Dict[str, str] = {"sol": "terra", "terra": "luna", "luna": "sol"}
    THIRD: Dict[str, str] = {"sol": "luna", "terra": "sol", "luna": "terra"}

    async def plan(self, observation: FactionObservation, recommendations: list) -> FactionPlan:
        faction = observation.faction_id
        round_number = observation.round
        staging = self.STAGING[faction]
        groups = observation.groups
        workers = [group for group in groups if group.unit_kind == "worker"]
        fighters = [
            group
            for group in groups
            if group.unit_kind in {"commander", "scout", "militia", "guard", "siege"}
        ]
        orders: List[PhysicalOrder] = []
        home = f"home_{faction}"
        rival_core = f"core_{self.RIVAL[faction]}"
        home_worker = self._worker_at(workers, home) or self._first(workers)
        staging_worker = self._worker_at(workers, staging)
        commander = next(
            (group for group in groups if group.unit_kind == "commander"),
            self._first(groups),
        )

        if round_number == 1:
            # One worker is intentionally scarce; produce a second before splitting jobs.
            self._train(orders, observation, commander, "worker")
        elif round_number == 2:
            self._gather(orders, observation, home_worker, "wood")
            other = next((worker for worker in workers if worker != home_worker), None)
            self._gather(orders, observation, other, "stone")
        elif round_number == 3:
            movers = self._ids(([commander] if commander else []) + workers[:1])
            self._move(orders, observation, movers, staging, "advance")
            self._gather(orders, observation, workers[1] if len(workers) > 1 else None, "food")
        elif round_number == 4:
            self._build(orders, observation, staging_worker or self._first(workers), staging, "outpost")
            self._gather(orders, observation, home_worker, "food")
        elif round_number == 5:
            self._gather(orders, observation, staging_worker, "iron")
            self._train(orders, observation, commander, "scout")
        elif round_number == 6:
            self._build(orders, observation, home_worker, home, "wall")
            scouts = [group for group in groups if group.unit_kind == "scout"]
            self._move(orders, observation, self._ids(scouts), staging, "scout")
        elif round_number == 7:
            self._research(orders, observation, home_worker, home, "fieldcraft")
            self._gather(orders, observation, staging_worker, "iron")
        elif round_number == 8:
            self._build(orders, observation, staging_worker, staging, "workshop")
            self._gather(orders, observation, home_worker, "food")
        elif round_number == 9:
            self._research(orders, observation, staging_worker or home_worker, staging, "ironworking")
            self._train(orders, observation, commander, "militia")
        elif round_number in {10, 11}:
            self._train(
                orders,
                observation,
                commander,
                "guard" if round_number == 10 else "siege",
            )
            self._gather(orders, observation, home_worker, "food")
        else:
            # Endgame orders are explicit attacks on a rival keep, never a center rush.
            attack_force = [
                group for group in fighters if group.unit_kind in {"militia", "guard", "siege"}
            ]
            if attack_force:
                self._attack(orders, observation, self._ids(attack_force), rival_core)
            else:
                self._train(orders, observation, commander, "militia")
            self._gather(orders, observation, home_worker, "food")

        communication = self._communication(observation)
        specialist_ops = []
        if round_number == 1 and observation.cognition.track == "agentic":
            specialist_ops = [
                CreateSpecialist(
                    specialist_id=f"{faction}_economy",
                    role=SpecialistRole.ECONOMY,
                    brief="Track bottlenecks, supply, and the best legal economic order.",
                    priority=1,
                ),
                CreateSpecialist(
                    specialist_id=f"{faction}_military",
                    role=SpecialistRole.MILITARY,
                    brief="Track hostile concentrations and recommend one supplied objective.",
                    priority=2,
                ),
            ]

        if specialist_ops and len(orders) < 3:
            orders.append(
                PhysicalOrder(
                    order_id=f"{faction}-r{round_number}-think",
                    action=PhysicalAction.THINK,
                    mode="deliberate",
                    option="coordinate_specialists",
                )
            )
        if (
            len(orders) < 3
            and (
                communication.utterances
                or communication.new_offer is not None
                or communication.responses
            )
        ):
            orders.append(
                PhysicalOrder(
                    order_id=f"{faction}-r{round_number}-negotiate",
                    action=PhysicalAction.NEGOTIATE,
                    mode="offer" if communication.new_offer is not None else "respond",
                    option="communication_plan",
                )
            )

        recommendation_note = (
            f" Advisor input received from {len(recommendations)} specialist(s)."
            if recommendations
            else ""
        )
        intent = self._intent(round_number, faction) + recommendation_note
        return FactionPlan(
            match_id=observation.match_id,
            round=round_number,
            faction_id=faction,
            public_intent=intent[:240],
            orders=orders,
            communication=communication,
            specialist_ops=specialist_ops,
            supply_priority=[staging, home],
        )

    def _communication(self, observation: FactionObservation) -> CommunicationPlan:
        faction = observation.faction_id
        round_number = observation.round
        utterances: List[Utterance] = []
        new_offer = None
        responses: List[OfferResponse] = []
        incoming = [
            offer
            for offer in observation.pending_offers
            if offer.recipient_id == faction and offer.expires_round >= round_number
        ]
        if incoming:
            responses.append(OfferResponse(offer_id=incoming[0].offer_id, decision="accept"))

        if round_number == 1:
            utterances.append(
                Utterance(
                    client_ref=f"{faction}-r1-public",
                    visibility="public",
                    text="I am securing a supply route. Respect my border and we can trade.",
                )
            )
        elif round_number == 2:
            rival = self.RIVAL[faction]
            utterances.append(
                Utterance(
                    client_ref=f"{faction}-r2-private",
                    visibility="private",
                    recipients=[rival],
                    text=(
                        "Temporary non-aggression? I will avoid your homeland while both "
                        "of us establish defenses."
                    ),
                )
            )
            new_offer = NonAggressionOffer(
                recipient=rival,
                duration_rounds=10,
                regions=["*"],
                expires_round=min(120, round_number + 10),
            )
        elif round_number == 6:
            rival = self.RIVAL[faction]
            utterances.append(
                Utterance(
                    client_ref=f"{faction}-r6-trade",
                    visibility="private",
                    recipients=[rival],
                    text="I can trade food for stone now. A deal keeps both of us competitive.",
                )
            )
            new_offer = TradeOffer(
                recipient=rival,
                give=ResourceBundle(food=10),
                receive=ResourceBundle(stone=5),
                expires_round=min(120, round_number + 2),
            )
        elif round_number >= 8:
            leader = max(
                observation.public_scores,
                key=lambda score: (score.territory_time, score.supplied_land, score.faction_id),
            ).faction_id
            if leader != faction:
                partner = next(
                    candidate
                    for candidate in (self.RIVAL[faction], self.THIRD[faction])
                    if candidate != leader
                )
                utterances.append(
                    Utterance(
                        client_ref=f"{faction}-r{round_number}-coalition",
                        visibility="private",
                        recipients=[partner],
                        text=(
                            f"{leader.title()} is leading. Pressure their supply while I "
                            "threaten their outer stronghold."
                        ),
                    )
                )
            elif round_number % 4 == 0:
                utterances.append(
                    Utterance(
                        client_ref=f"{faction}-r{round_number}-warning",
                        visibility="public",
                        text=(
                            "My stronghold is fortified. Any siege against it will pay "
                            "for every wall breached."
                        ),
                    )
                )

        return CommunicationPlan(
            utterances=utterances,
            new_offer=new_offer,
            responses=responses,
        )

    @staticmethod
    def _intent(round_number: int, faction: str) -> str:
        if round_number <= 3:
            return f"{faction.title()} is splitting labor between food, timber, and expansion."
        if round_number <= 7:
            return (
                f"{faction.title()} is fortifying home and scouting a supplied frontier."
            )
        if round_number <= 11:
            return f"{faction.title()} is researching iron weapons and assembling a siege force."
        return f"{faction.title()} is attacking a rival stronghold while sustaining reinforcements."

    @staticmethod
    def _ids(groups: List[FriendlyGroup]) -> List[str]:
        return [group.group_id for group in groups]

    @staticmethod
    def _first(groups: List[FriendlyGroup]) -> Optional[FriendlyGroup]:
        return groups[0] if groups else None

    @staticmethod
    def _worker_at(
        workers: List[FriendlyGroup], district_id: str
    ) -> Optional[FriendlyGroup]:
        return next((worker for worker in workers if worker.district_id == district_id), None)

    @staticmethod
    def _remaining_command_points(orders: List[PhysicalOrder]) -> int:
        # One point remains reserved for the supply-priority update on every demo plan.
        return 3 - sum(order.command_points for order in orders)

    def _move(
        self,
        orders: List[PhysicalOrder],
        observation: FactionObservation,
        actor_ids: List[str],
        target: str,
        mode: str,
    ) -> None:
        if actor_ids and len(orders) < 3 and self._remaining_command_points(orders) >= 2:
            orders.append(
                PhysicalOrder(
                    order_id=f"{observation.faction_id}-r{observation.round}-move-{target}",
                    action=PhysicalAction.MOVE,
                    actor_ids=actor_ids,
                    target_id=target,
                    mode=mode,
                )
            )

    def _gather(
        self,
        orders: List[PhysicalOrder],
        observation: FactionObservation,
        worker: Optional[FriendlyGroup],
        resource: str,
    ) -> None:
        if worker is not None and len(orders) < 3 and self._remaining_command_points(orders) >= 1:
            orders.append(
                PhysicalOrder(
                    order_id=f"{observation.faction_id}-r{observation.round}-gather-{resource}",
                    action=PhysicalAction.GATHER,
                    actor_ids=[worker.group_id],
                    target_id=worker.district_id,
                    resource=resource,
                )
            )

    def _build(
        self,
        orders: List[PhysicalOrder],
        observation: FactionObservation,
        worker: Optional[FriendlyGroup],
        district: str,
        structure: str,
    ) -> None:
        if worker is not None and len(orders) < 3 and self._remaining_command_points(orders) >= 1:
            orders.append(
                PhysicalOrder(
                    order_id=f"{observation.faction_id}-r{observation.round}-build-{structure}",
                    action=PhysicalAction.BUILD,
                    actor_ids=[worker.group_id],
                    target_id=district,
                    option=structure,
                    mode="construct",
                )
            )

    def _train(
        self,
        orders: List[PhysicalOrder],
        observation: FactionObservation,
        producer: Optional[FriendlyGroup],
        unit: str,
    ) -> None:
        if producer is not None and len(orders) < 3 and self._remaining_command_points(orders) >= 1:
            orders.append(
                PhysicalOrder(
                    order_id=f"{observation.faction_id}-r{observation.round}-train-{unit}",
                    action=PhysicalAction.BUILD,
                    actor_ids=[producer.group_id],
                    target_id=f"core_{observation.faction_id}",
                    option=unit,
                    mode="train",
                )
            )

    def _research(
        self,
        orders: List[PhysicalOrder],
        observation: FactionObservation,
        worker: Optional[FriendlyGroup],
        district: str,
        technology: str,
    ) -> None:
        if worker is not None and len(orders) < 3 and self._remaining_command_points(orders) >= 1:
            orders.append(
                PhysicalOrder(
                    order_id=(
                        f"{observation.faction_id}-r{observation.round}-research-{technology}"
                    ),
                    action=PhysicalAction.RESEARCH,
                    actor_ids=[worker.group_id],
                    target_id=district,
                    option=technology,
                )
            )

    def _attack(
        self,
        orders: List[PhysicalOrder],
        observation: FactionObservation,
        actor_ids: List[str],
        target_id: str,
    ) -> None:
        if actor_ids and len(orders) < 3 and self._remaining_command_points(orders) >= 2:
            orders.append(
                PhysicalOrder(
                    order_id=f"{observation.faction_id}-r{observation.round}-attack-{target_id}",
                    action=PhysicalAction.ATTACK,
                    actor_ids=actor_ids[:16],
                    target_id=target_id,
                    stance="assault",
                    mode="assault",
                )
            )
