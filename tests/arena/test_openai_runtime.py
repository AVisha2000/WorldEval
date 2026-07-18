from __future__ import annotations

import json
from types import SimpleNamespace

import pytest
from genesis_arena.arena import (
    ArenaOpenAICommander,
    ArenaOpenAIError,
    ArenaOpenAISpecialist,
    SpecialistRole,
)

from .helpers import observation


class FakeResponses:
    def __init__(self, response=None, error=None):
        self.response = response
        self.error = error
        self.calls = []

    async def create(self, **kwargs):
        self.calls.append(kwargs)
        if self.error is not None:
            raise self.error
        return self.response


class FakeClient:
    def __init__(self, response=None, error=None):
        self.responses = FakeResponses(response=response, error=error)


def response_for(name: str, arguments, *, with_usage: bool = True):
    usage = None
    if with_usage:
        usage = SimpleNamespace(
            input_tokens=100,
            output_tokens=30,
            input_tokens_details=SimpleNamespace(cached_tokens=20),
            output_tokens_details=SimpleNamespace(reasoning_tokens=12),
        )
    return SimpleNamespace(
        output=[
            SimpleNamespace(
                type="function_call",
                name=name,
                arguments=json.dumps(arguments) if not isinstance(arguments, str) else arguments,
            )
        ],
        usage=usage,
        model="model-resolved",
    )


def commander_arguments():
    return {
        "public_intent": "Gather wood while keeping the Homeland supplied.",
        "orders": [
            {
                "order_id": "sol-r1-gather",
                "action": "assign_workers",
                "actor_ids": ["sol-workers"],
                "target_id": "home-sol",
                "resource": "wood",
                "option": None,
                "stance": None,
            }
        ],
        "communication": {"utterances": [], "new_offer": None, "responses": []},
        "specialist_ops": [],
        "supply_priority": [],
    }


@pytest.mark.asyncio
async def test_commander_uses_required_strict_stateless_responses_tool() -> None:
    client = FakeClient(
        response_for(ArenaOpenAICommander.TOOL_NAME, commander_arguments())
    )
    commander = ArenaOpenAICommander(
        model="model-command",
        reasoning_effort="medium",
        client=client,
        prices_per_million={"input": 2.0, "cached_input": 1.0, "output": 8.0},
    )

    output = await commander.plan(observation("sol"), [])
    call = client.responses.calls[0]

    assert output.plan.match_id == "match-test"
    assert output.plan.faction_id == "sol"
    assert output.plan.orders[0].action.value == "assign_workers"
    assert call["model"] == "model-command"
    assert call["reasoning"] == {"effort": "medium"}
    assert call["tool_choice"] == "required"
    assert call["parallel_tool_calls"] is False
    assert call["store"] is False
    assert call["max_output_tokens"] == 1200
    assert "previous_response_id" not in call
    assert call["tools"][0]["strict"] is True
    assert call["tools"][0]["name"] == "submit_faction_plan"
    assert call["tools"][0]["parameters"]["additionalProperties"] is False
    assert output.usage.input_tokens == 100
    assert output.usage.cached_input_tokens == 20
    assert output.usage.output_tokens == 30
    assert output.usage.reasoning_tokens == 12
    assert output.usage.estimated_cost_usd == pytest.approx(0.00042)


@pytest.mark.asyncio
async def test_commander_envelope_is_injected_locally_and_cannot_be_spoofed() -> None:
    arguments = commander_arguments()
    arguments.update({"match_id": "other-match", "round": 40, "faction_id": "terra"})
    client = FakeClient(response_for(ArenaOpenAICommander.TOOL_NAME, arguments))
    commander = ArenaOpenAICommander(model="model-command", client=client)

    output = await commander.plan(observation("sol"), [])

    assert output.plan.match_id == "match-test"
    assert output.plan.round == 1
    assert output.plan.faction_id == "sol"


@pytest.mark.asyncio
async def test_commander_rejects_invalid_plan_after_provider_tool_call() -> None:
    arguments = commander_arguments()
    arguments["orders"][0]["resource"] = None
    client = FakeClient(response_for(ArenaOpenAICommander.TOOL_NAME, arguments))
    commander = ArenaOpenAICommander(model="model-command", client=client)

    with pytest.raises(ArenaOpenAIError, match="invalid Arena faction plan"):
        await commander.plan(observation("sol"), [])


@pytest.mark.asyncio
async def test_specialist_is_recommendation_only_and_tracks_usage() -> None:
    arguments = {
        "assessment": "The eastern supply route has only one visible militia squad.",
        "risks": ["Moving both militia groups would expose the Homeland."],
        "recommended_orders": ["Scout mine-st before committing the reserve."],
        "recommendation_summary": "Scout first, then raid only if the route remains weak.",
    }
    client = FakeClient(response_for(ArenaOpenAISpecialist.TOOL_NAME, arguments))
    specialist = ArenaOpenAISpecialist(
        model="model-specialist",
        reasoning_effort="low",
        client=client,
    )

    output = await specialist.advise(
        observation("sol"),
        "sol-military",
        SpecialistRole.MILITARY,
        "Find a low-risk way to cut enemy supply.",
    )
    call = client.responses.calls[0]

    assert output.recommendation.specialist_id == "sol-military"
    assert output.recommendation.role == SpecialistRole.MILITARY
    assert call["tools"][0]["name"] == "submit_specialist_recommendation"
    assert call["tools"][0]["strict"] is True
    assert call["tool_choice"] == "required"
    assert call["parallel_tool_calls"] is False
    assert call["store"] is False
    assert call["max_output_tokens"] == 400
    assert output.usage.reasoning_tokens == 12


@pytest.mark.asyncio
async def test_provider_failures_are_sanitized_and_do_not_echo_secrets() -> None:
    secret = "sk-proj-never-log-this"
    client = FakeClient(error=RuntimeError(f"Authorization failed for {secret}"))
    commander = ArenaOpenAICommander(model="model-command", client=client)

    with pytest.raises(ArenaOpenAIError) as error:
        await commander.plan(observation("sol"), [])

    assert str(error.value) == "OpenAI Arena request failed"
    assert secret not in str(error.value)
    assert error.value.__cause__ is None
    assert error.value.__suppress_context__ is True


@pytest.mark.asyncio
async def test_missing_or_malformed_submit_call_is_rejected_locally() -> None:
    malformed = FakeClient(
        response_for(ArenaOpenAICommander.TOOL_NAME, "{not valid json")
    )
    commander = ArenaOpenAICommander(model="model-command", client=malformed)
    with pytest.raises(ArenaOpenAIError, match="malformed Arena tool arguments"):
        await commander.plan(observation("sol"), [])

    missing = FakeClient(response=SimpleNamespace(output=[], usage=None))
    commander = ArenaOpenAICommander(model="model-command", client=missing)
    with pytest.raises(ArenaOpenAIError, match="required Arena tool"):
        await commander.plan(observation("sol"), [])


@pytest.mark.asyncio
async def test_multiple_tool_calls_are_rejected_and_usage_is_preserved() -> None:
    response = response_for(ArenaOpenAICommander.TOOL_NAME, commander_arguments())
    response.output.append(response.output[0])
    commander = ArenaOpenAICommander(model="model-command", client=FakeClient(response))

    with pytest.raises(ArenaOpenAIError, match="required Arena tool") as error:
        await commander.plan(observation("sol"), [])

    assert error.value.usage.input_tokens == 100


@pytest.mark.asyncio
async def test_reported_input_token_cap_is_enforced_and_charged() -> None:
    commander = ArenaOpenAICommander(
        model="model-command",
        client=FakeClient(
            response_for(ArenaOpenAICommander.TOOL_NAME, commander_arguments())
        ),
        max_input_tokens=99,
    )

    with pytest.raises(ArenaOpenAIError, match="input token limit") as error:
        await commander.plan(observation("sol"), [])

    assert error.value.usage.input_tokens == 100


def test_pact_tool_schema_requires_offer_expiry() -> None:
    commander = ArenaOpenAICommander(
        model="model-command",
        client=FakeClient(
            response_for(ArenaOpenAICommander.TOOL_NAME, commander_arguments())
        ),
    )
    offers = commander.submit_tool["parameters"]["properties"]["communication"][
        "properties"
    ]["new_offer"]["anyOf"]
    pact = next(
        item
        for item in offers
        if item.get("properties", {}).get("kind", {}).get("enum") == ["non_aggression"]
    )
    assert "expires_round" in pact["required"]
