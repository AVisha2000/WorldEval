from __future__ import annotations

import pytest
from genesis_arena.arena import (
    ArenaEvent,
    CommunicationPlan,
    FactionObservation,
    FactionPlan,
    NonAggressionOffer,
    ObservedMessage,
    OfferResponse,
    PhysicalAction,
    PhysicalOrder,
    ResourceBundle,
    TradeOffer,
    Utterance,
    project_events_for_faction,
)
from pydantic import ValidationError

from .helpers import observation


def test_models_forbid_unknown_fields() -> None:
    payload = observation("sol").model_dump(mode="json")
    payload["api_key"] = "must-not-be-accepted"
    with pytest.raises(ValidationError):
        FactionObservation.model_validate(payload)


def test_private_message_cannot_leak_into_third_party_observation() -> None:
    payload = observation("terra").model_dump(mode="json")
    payload["messages"] = [
        ObservedMessage(
            message_id="private-1",
            sender_id="sol",
            visibility="private",
            recipients=["luna"],
            text="Attack Terra after the trade.",
            sent_round=1,
        ).model_dump(mode="json")
    ]
    with pytest.raises(ValidationError, match="unauthorized private message"):
        FactionObservation.model_validate(payload)


def test_faction_plan_enforces_order_and_communication_limits() -> None:
    expensive_orders = [
        PhysicalOrder(
            order_id=f"order-{index}",
            action=PhysicalAction.MOBILIZE,
            actor_ids=[f"squad-{index}"],
            target_id="crown",
            stance="assault",
        )
        for index in range(3)
    ]
    with pytest.raises(ValidationError, match="four command points"):
        FactionPlan(
            match_id="match-test",
            round=1,
            faction_id="sol",
            public_intent="Commit every squad to the central objective.",
            orders=expensive_orders,
        )

    with pytest.raises(ValidationError, match="cannot message itself"):
        FactionPlan(
            match_id="match-test",
            round=1,
            faction_id="sol",
            public_intent="Attempt an invalid self-directed message.",
            communication=CommunicationPlan(
                utterances=[
                    Utterance(
                        client_ref="self-message",
                        visibility="private",
                        recipients=["sol"],
                        text="This must be rejected.",
                    )
                ]
            ),
        )


def test_trade_requires_value_on_both_sides() -> None:
    with pytest.raises(ValidationError, match="give and receive"):
        TradeOffer(
            recipient="luna",
            give=ResourceBundle(wood=20),
            receive=ResourceBundle(),
            expires_round=4,
        )


def test_event_projection_excludes_spectator_and_unrelated_private_events() -> None:
    public = ArenaEvent(
        event_id="event-public",
        match_id="match-test",
        sequence=1,
        round=1,
        tick=0,
        kind="message",
        visibility="public",
        summary="Public warning",
    )
    private = ArenaEvent(
        event_id="event-private",
        match_id="match-test",
        sequence=2,
        round=1,
        tick=0,
        kind="message",
        visibility="participants",
        visible_to=["sol", "luna"],
        summary="Private coordination",
    )
    spectator = ArenaEvent(
        event_id="event-spectator",
        match_id="match-test",
        sequence=3,
        round=1,
        tick=0,
        kind="advisor",
        visibility="spectator",
        summary="Spectator-only advice trace",
    )

    sol_events = project_events_for_faction([public, private, spectator], "sol")
    assert [event.event_id for event in sol_events] == [
        "event-public",
        "event-private",
    ]
    terra_events = project_events_for_faction([public, private, spectator], "terra")
    assert [event.event_id for event in terra_events] == ["event-public"]


def test_event_visibility_contract_fails_closed() -> None:
    with pytest.raises(ValidationError, match="participant events require"):
        ArenaEvent(
            event_id="private-without-viewers",
            match_id="match-test",
            sequence=1,
            round=1,
            tick=0,
            kind="message",
            visibility="participants",
            summary="This event has no legal audience.",
        )
    with pytest.raises(ValidationError, match="public events cannot"):
        ArenaEvent(
            event_id="contradictory-public",
            match_id="match-test",
            sequence=1,
            round=1,
            tick=0,
            kind="message",
            visibility="public",
            visible_to=["sol"],
            summary="A public event cannot carry a private audience.",
        )


def test_committed_text_is_nfc_normalized_and_controls_are_rejected() -> None:
    utterance = Utterance(
        client_ref="normalized",
        visibility="public",
        text="Cafe\u0301",
    )
    assert utterance.text == "Caf\u00e9"
    with pytest.raises(ValidationError, match="control characters"):
        Utterance(
            client_ref="unsafe",
            visibility="public",
            text="unsafe\nmarkup",
        )


def test_offer_responses_are_unique_and_pact_wildcard_matches_contract() -> None:
    pact = NonAggressionOffer(
        recipient="terra",
        duration_rounds=5,
        regions=["*"],
        expires_round=4,
    )
    assert pact.regions == ["*"]
    with pytest.raises(ValidationError, match="at most one response"):
        CommunicationPlan(
            responses=[
                OfferResponse(offer_id="offer-1", decision="accept"),
                OfferResponse(offer_id="offer-1", decision="reject"),
            ]
        )
    with pytest.raises(ValidationError, match="expire after"):
        FactionPlan(
            match_id="match-test",
            round=4,
            faction_id="sol",
            public_intent="Offer a pact with a valid future expiry.",
            communication=CommunicationPlan(new_offer=pact),
        )
