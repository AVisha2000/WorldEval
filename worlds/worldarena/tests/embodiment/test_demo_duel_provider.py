from __future__ import annotations

from dataclasses import replace

import pytest
from genesis_arena.embodiment.duel import DuelEntrant
from genesis_arena.embodiment.duel.demo_provider import build_demo_duel_provider
from genesis_arena.embodiment.duel.live_runtime import build_paired_duel_plan
from genesis_arena.embodiment.duel.service import DuelSeriesSpec
from genesis_arena.embodiment.protocol import EmbodimentProtocolPackage, strict_json_loads
from genesis_arena.embodiment.providers.contracts import ProviderRequest
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT


def _demo_plan(*, decision_budget: int = 2160):
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    spec = DuelSeriesSpec(
        series_id="series_demo_duel",
        entrants=(
            DuelEntrant("entrant_0", "demo", "duelist-alpha-v1"),
            DuelEntrant("entrant_1", "demo", "duelist-bravo-v1"),
        ),
        seed=37,
        schedule_nonce="demo-duel-0",
        max_live_provider_calls=decision_budget,
    )
    return build_paired_duel_plan(
        spec=spec,
        repository_root=ROOT,
        godot_project_path=ROOT / "godot",
        protocol_package=package,
        provider_timeout_s=1.0,
    )


def _request(participant_id: str, model: str, observation: dict) -> ProviderRequest:
    from genesis_arena.embodiment.protocol import canonical_json_bytes

    package = EmbodimentProtocolPackage.from_repository(ROOT)
    return ProviderRequest(
        episode_id=observation["episode_id"],
        participant_id=participant_id,
        observation_seq=observation["observation_seq"],
        deadline_monotonic_ns=1,
        model=model,
        system_prompt="Return one controller action.",
        observation_json=canonical_json_bytes(observation),
        action_schema_json=canonical_json_bytes(package.schema("controller-action")),
    )


@pytest.mark.asyncio
async def test_demo_duel_entrants_have_independent_locks_and_player_visible_actions() -> None:
    observation = {
        "episode_id": "ep_demo_duel",
        "observation_seq": 0,
        "profile": "text-visible-v1",
        "visible_entities": [
            {
                "affordances": ["interactable"],
                "bearing": "front_right",
                "distance": "medium",
                "id": "v_relay_1",
                "kind": "relay",
                "state": "neutral",
            }
        ],
    }
    alpha = build_demo_duel_provider(
        model="duelist-alpha-v1",
        participant_id="participant_0",
        seed=37,
        decision_budget=2,
    )
    bravo = build_demo_duel_provider(
        model="duelist-bravo-v1",
        participant_id="participant_1",
        seed=37,
        decision_budget=2,
    )

    assert alpha.policy_lock.sha256 != bravo.policy_lock.sha256
    assert alpha.policy_lock.participant_id == "participant_0"
    assert bravo.policy_lock.participant_id == "participant_1"
    result = await alpha.request(_request("participant_0", "duelist-alpha-v1", observation))
    action = strict_json_loads(result.raw_output or b"")
    assert action["control"]["duration_ticks"] == 10
    assert action["control"]["look_x"] == 1000
    assert "v_relay_1" not in repr(action)


def test_demo_plan_locks_both_policies_and_swaps_every_seat_dimension() -> None:
    plan = _demo_plan()
    assert plan.mode == "model-duel-v0"
    assert [lock.provider for lock in plan.fairness_lock.entrants] == ["demo", "demo"]
    assert [lock.reasoning for lock in plan.fairness_lock.entrants] == [
        "deterministic",
        "deterministic",
    ]
    assert (
        plan.fairness_lock.entrants[0].adapter_sha256
        == plan.fairness_lock.entrants[1].adapter_sha256
    )
    first, second = plan.legs
    for entrant in plan.entrants:
        a = next(value for value in first.assignments if value.entrant_id == entrant.entrant_id)
        b = next(value for value in second.assignments if value.entrant_id == entrant.entrant_id)
        assert (a.participant_id, a.spawn_side, a.dispatch_precedence) != (
            b.participant_id,
            b.spawn_side,
            b.dispatch_precedence,
        )


def test_demo_plan_hash_changes_with_each_policy_identity() -> None:
    plan = _demo_plan()
    changed_entrants = (
        replace(plan.entrants[0], model="duelist-bravo-v1"),
        plan.entrants[1],
    )
    changed_locks = (
        replace(plan.fairness_lock.entrants[0], model="duelist-bravo-v1"),
        plan.fairness_lock.entrants[1],
    )
    changed = replace(
        plan,
        entrants=changed_entrants,
        fairness_lock=replace(plan.fairness_lock, entrants=changed_locks),
    )
    assert changed.plan_sha256 != plan.plan_sha256
