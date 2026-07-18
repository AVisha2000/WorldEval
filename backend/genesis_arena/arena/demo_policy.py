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
    """Deterministic policy that demonstrates economy, diplomacy, capture, and combat.

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
            if group.unit_kind in {"commander", "militia", "guard", "siege"}
        ]
        orders: List[PhysicalOrder] = []

        if round_number == 1:
            movers = self._ids(fighters[:3] + workers[:1])
            self._move(orders, observation, movers, staging, "assault")
            home_worker = workers[1] if len(workers) > 1 else self._first(workers)
            self._gather(orders, observation, home_worker, "wood")
        elif round_number == 2:
            self._gather(orders, observation, self._worker_at(workers, f"home_{faction}"), "stone")
            self._train(orders, observation, "scout")
        elif round_number == 3:
            builder = self._worker_at(workers, staging) or self._first(workers)
            self._build(orders, observation, builder, staging, "outpost")
            self._gather(orders, observation, self._worker_at(workers, f"home_{faction}"), "wood")
        elif round_number == 4:
            staging_fighters = [group for group in fighters if group.district_id == staging]
            self._move(
                orders,
                observation,
                self._ids(staging_fighters or fighters)[:4],
                "crown",
                "assault",
            )
            self._gather(orders, observation, self._first(workers), "food")
        elif round_number == 8 and faction == "sol":
            # The credential-free showcase includes one intentional pact violation so the
            # observer can see that agreements are recorded but never engine-enforced.
            raiders = fighters or workers
            self._move(
                orders,
                observation,
                self._ids(raiders)[:4],
                "home_terra",
                "raid",
            )
            self._gather(orders, observation, self._first(workers), "food")
        else:
            # Sustain the economy while continually converging military strength on the Crown.
            crown_fighters = [group for group in fighters if group.district_id == "crown"]
            mobile = [group for group in fighters if group.district_id != "crown"]
            if mobile:
                self._move(orders, observation, self._ids(mobile)[:4], "crown", "assault")
            elif crown_fighters and round_number % 5 == 0:
                # Re-issuing a hold target is useful if a renderer/controller dropped a target.
                self._move(
                    orders,
                    observation,
                    self._ids(crown_fighters)[:4],
                    "crown",
                    "hold",
                )
            self._gather(
                orders,
                observation,
                self._first(workers),
                "iron" if round_number % 4 == 0 else "food",
            )
            if self._remaining_command_points(orders) >= 1:
                self._train(
                    orders,
                    observation,
                    "guard" if round_number >= 10 else "militia",
                )

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
            supply_priority=[staging, f"home_{faction}"],
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
                        "Temporary non-aggression? I will avoid your homeland while we "
                        "contest the Crown."
                    ),
                )
            )
            new_offer = NonAggressionOffer(
                recipient=rival,
                duration_rounds=10,
                regions=["*"],
                expires_round=min(48, round_number + 10),
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
                expires_round=min(48, round_number + 2),
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
                            "contest the Crown."
                        ),
                    )
                )
            elif round_number % 4 == 0:
                utterances.append(
                    Utterance(
                        client_ref=f"{faction}-r{round_number}-warning",
                        visibility="public",
                        text=(
                            "The Crown is mine for now. Any coalition against me will pay "
                            "for the opening."
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
            return f"{faction.title()} is establishing a supplied forward mine before committing."
        if round_number <= 7:
            return (
                f"{faction.title()} is converging on the Crown while maintaining food production."
            )
        return f"{faction.title()} is balancing Crown pressure, reinforcement, and coalition risk."

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
        stance: str,
    ) -> None:
        if actor_ids and len(orders) < 3 and self._remaining_command_points(orders) >= 2:
            orders.append(
                PhysicalOrder(
                    order_id=f"{observation.faction_id}-r{observation.round}-move-{target}",
                    action=PhysicalAction.MOBILIZE,
                    actor_ids=actor_ids,
                    target_id=target,
                    stance=stance,
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
                    action=PhysicalAction.ASSIGN_WORKERS,
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
                )
            )

    def _train(
        self, orders: List[PhysicalOrder], observation: FactionObservation, unit: str
    ) -> None:
        actor = self._first(observation.groups)
        if actor is not None and len(orders) < 3 and self._remaining_command_points(orders) >= 1:
            orders.append(
                PhysicalOrder(
                    order_id=f"{observation.faction_id}-r{observation.round}-train-{unit}",
                    action=PhysicalAction.TRAIN,
                    actor_ids=[actor.group_id],
                    target_id=f"core_{observation.faction_id}",
                    option=unit,
                )
            )
