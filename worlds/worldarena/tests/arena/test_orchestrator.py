from __future__ import annotations

import asyncio
import time

import pytest
from genesis_arena.arena import (
    ArenaOrchestrator,
    ArenaRuntimeError,
    CognitionBudget,
    DemoSpecialist,
    FactionRuntime,
    RoundCommitsLocked,
    RoundReceipt,
    RoundRequest,
    ScriptedCommander,
    SpecialistOutput,
    SpecialistRecommendation,
    SpecialistRole,
    SpecialistSlot,
    UsageRecord,
    verify_plan_commit,
)
from genesis_arena.arena.models import CreateSpecialist

from .helpers import FACTIONS, STATE_HASH, plan_for, request, runtimes


@pytest.mark.asyncio
async def test_three_commanders_plan_concurrently_and_reveal_only_after_lock() -> None:
    orchestrator = ArenaOrchestrator(
        runtimes(delays={faction: 0.05 for faction in FACTIONS}),
        salt_factory=lambda: "1" * 32,
    )
    started = time.perf_counter()
    commits = await orchestrator.commit_round(request())
    elapsed = time.perf_counter() - started

    assert elapsed < 0.12
    assert [commit.faction_id for commit in commits.commits] == ["luna", "sol", "terra"]
    with pytest.raises(ArenaRuntimeError, match="before Godot locks"):
        await orchestrator.reveal_round("match-test", 1)

    hashes = {commit.faction_id: commit.commit_hash for commit in commits.commits}
    orchestrator.lock_commits(
        RoundCommitsLocked(match_id="match-test", round=1, commit_hashes=hashes)
    )
    reveal = await orchestrator.reveal_round("match-test", 1)
    assert all(
        verify_plan_commit(item.plan, item.salt, item.commit_hash) for item in reveal.plans
    )


@pytest.mark.asyncio
async def test_mismatched_commit_acknowledgement_is_rejected() -> None:
    orchestrator = ArenaOrchestrator(runtimes(), salt_factory=lambda: "2" * 32)
    commits = await orchestrator.commit_round(request())
    hashes = {commit.faction_id: commit.commit_hash for commit in commits.commits}
    hashes["sol"] = "0" * 64
    with pytest.raises(ArenaRuntimeError, match="does not match"):
        orchestrator.lock_commits(
            RoundCommitsLocked(match_id="match-test", round=1, commit_hashes=hashes)
        )


@pytest.mark.asyncio
async def test_timeout_falls_back_without_blocking_other_factions() -> None:
    configured = runtimes()
    configured["sol"] = FactionRuntime(
        faction_id="sol",
        commander=ScriptedCommander(plan_for, delay_seconds=0.05),
        budget=CognitionBudget(),
    )
    orchestrator = ArenaOrchestrator(
        configured,
        decision_timeout_seconds=0.005,
        salt_factory=lambda: "3" * 32,
    )
    commits = await orchestrator.commit_round(request())
    statuses = {commit.faction_id: commit.status for commit in commits.commits}
    assert statuses == {"luna": "planned", "sol": "fallback", "terra": "planned"}
    assert orchestrator.diagnostics("match-test", 1)["sol"].error == "decision_timeout"


@pytest.mark.asyncio
async def test_specialists_share_budget_and_run_before_commander() -> None:
    seen_recommendation_counts = []

    def inspecting_plan(observation_value, recommendations):
        seen_recommendation_counts.append(len(recommendations))
        return plan_for(observation_value, recommendations)

    configured = runtimes()
    configured["sol"] = FactionRuntime(
        faction_id="sol",
        commander=ScriptedCommander(inspecting_plan),
        budget=CognitionBudget(total_units=242),
        specialists={
            f"sol-{role.value}": SpecialistSlot(
                specialist_id=f"sol-{role.value}",
                role=role,
                brief=f"Advise on {role.value} priorities.",
                priority=index,
                advisor=DemoSpecialist(),
            )
            for index, role in enumerate(
                [SpecialistRole.MILITARY, SpecialistRole.ECONOMY, SpecialistRole.SCOUT],
                start=1,
            )
        },
    )
    orchestrator = ArenaOrchestrator(configured, salt_factory=lambda: "4" * 32)
    commits = await orchestrator.commit_round(request())

    assert seen_recommendation_counts == [2]
    sol_commit = next(item for item in commits.commits if item.faction_id == "sol")
    assert sol_commit.specialist_calls == 2
    assert configured["sol"].budget.remaining_units == 238


@pytest.mark.asyncio
async def test_duplicate_round_commit_is_rejected() -> None:
    orchestrator = ArenaOrchestrator(runtimes(), salt_factory=lambda: "5" * 32)
    await orchestrator.commit_round(request())
    with pytest.raises(ArenaRuntimeError, match="already been committed"):
        await orchestrator.commit_round(request())


def test_budget_never_spends_reserved_commander_units() -> None:
    budget = CognitionBudget(total_units=241)
    assert budget.can_call_specialist()
    budget.spend_specialist()
    assert not budget.can_call_specialist()
    for _ in range(120):
        budget.spend_commander()
    assert budget.remaining_units == 0


@pytest.mark.asyncio
async def test_cancelling_parent_task_does_not_create_a_reveal() -> None:
    configured = runtimes(delays={faction: 0.2 for faction in FACTIONS})
    orchestrator = ArenaOrchestrator(configured)
    task = asyncio.create_task(orchestrator.commit_round(request()))
    await asyncio.sleep(0)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task

    with pytest.raises(ArenaRuntimeError, match="no pending commits"):
        await orchestrator.reveal_round("match-test", 1)
    for runtime in configured.values():
        runtime.commander.delay_seconds = 0
    retry = await orchestrator.commit_round(request())
    assert len(retry.commits) == 3


@pytest.mark.asyncio
async def test_concurrent_duplicate_commit_is_reserved_before_model_calls() -> None:
    configured = runtimes(delays={faction: 0.03 for faction in FACTIONS})
    orchestrator = ArenaOrchestrator(configured)

    results = await asyncio.gather(
        orchestrator.commit_round(request()),
        orchestrator.commit_round(request()),
        return_exceptions=True,
    )

    assert sum(not isinstance(result, Exception) for result in results) == 1
    duplicate = next(result for result in results if isinstance(result, Exception))
    assert isinstance(duplicate, ArenaRuntimeError)
    assert {faction: runtime.budget.commander_calls for faction, runtime in configured.items()} == {
        "sol": 1,
        "terra": 1,
        "luna": 1,
    }


async def _lock_and_reveal(orchestrator: ArenaOrchestrator) -> None:
    commits = await orchestrator.commit_round(request())
    orchestrator.lock_commits(
        RoundCommitsLocked(
            match_id="match-test",
            round=1,
            commit_hashes={item.faction_id: item.commit_hash for item in commits.commits},
        )
    )
    await orchestrator.reveal_round("match-test", 1)


@pytest.mark.asyncio
async def test_round_order_advances_only_after_authoritative_receipt() -> None:
    orchestrator = ArenaOrchestrator(runtimes())
    with pytest.raises(ArenaRuntimeError, match="out of order"):
        await orchestrator.commit_round(request(round_number=2))

    await _lock_and_reveal(orchestrator)
    with pytest.raises(ArenaRuntimeError, match="out of order"):
        await orchestrator.commit_round(request(round_number=2))

    await orchestrator.finalize_round(
        RoundReceipt(
            match_id="match-test",
            round=1,
            previous_state_hash=STATE_HASH,
            state_hash="b" * 64,
        )
    )
    with pytest.raises(ArenaRuntimeError, match="state hash"):
        await orchestrator.commit_round(request(round_number=2))
    next_payload = request(round_number=2).model_dump(mode="json")
    next_payload["snapshot_hash"] = "b" * 64
    for observation_payload in next_payload["observations"]:
        observation_payload["snapshot_hash"] = "b" * 64
    commits = await orchestrator.commit_round(RoundRequest.model_validate(next_payload))
    assert commits.round == 2


@pytest.mark.asyncio
async def test_concurrent_duplicate_reveal_returns_exactly_one_batch() -> None:
    orchestrator = ArenaOrchestrator(runtimes())
    commits = await orchestrator.commit_round(request())
    orchestrator.lock_commits(
        RoundCommitsLocked(
            match_id="match-test",
            round=1,
            commit_hashes={item.faction_id: item.commit_hash for item in commits.commits},
        )
    )
    results = await asyncio.gather(
        orchestrator.reveal_round("match-test", 1),
        orchestrator.reveal_round("match-test", 1),
        return_exceptions=True,
    )
    assert sum(not isinstance(result, Exception) for result in results) == 1
    assert sum(isinstance(result, ArenaRuntimeError) for result in results) == 1


@pytest.mark.asyncio
async def test_specialist_operations_apply_only_after_receipt_and_respect_disabled_limit() -> None:
    def creating_plan(observation_value, recommendations):
        plan = plan_for(observation_value, recommendations)
        plan.specialist_ops = [
            CreateSpecialist(
                specialist_id=f"{observation_value.faction_id}-economy",
                role=SpecialistRole.ECONOMY,
                brief="Track production and recommend efficient worker jobs.",
            )
        ]
        return plan

    configured = {
        faction: FactionRuntime(
            faction_id=faction,
            commander=ScriptedCommander(creating_plan),
            budget=CognitionBudget(),
            max_specialists=0 if faction == "luna" else 3,
        )
        for faction in FACTIONS
    }
    orchestrator = ArenaOrchestrator(configured)
    await _lock_and_reveal(orchestrator)
    assert all(not runtime.specialists for runtime in configured.values())

    await orchestrator.finalize_round(
        RoundReceipt(
            match_id="match-test",
            round=1,
            previous_state_hash=STATE_HASH,
            state_hash="b" * 64,
        )
    )
    assert set(configured["sol"].specialists) == {"sol-economy"}
    assert set(configured["terra"].specialists) == {"terra-economy"}
    assert configured["luna"].specialists == {}


@pytest.mark.asyncio
async def test_failed_specialist_attempt_is_counted_and_available_usage_is_aggregated() -> None:
    class FailingAdvisor:
        async def advise(self, observation_value, specialist_id, role, brief):
            error = RuntimeError("provider failed")
            error.usage = UsageRecord(input_tokens=17, output_tokens=3)
            raise error

    configured = runtimes()
    configured["sol"] = FactionRuntime(
        faction_id="sol",
        commander=ScriptedCommander(plan_for),
        budget=CognitionBudget(),
        specialists={
            "sol-scout": SpecialistSlot(
                specialist_id="sol-scout",
                role=SpecialistRole.SCOUT,
                brief="Find safe expansion routes.",
                priority=1,
                advisor=FailingAdvisor(),
            )
        },
    )
    orchestrator = ArenaOrchestrator(configured)
    commits = await orchestrator.commit_round(request())
    sol = next(commit for commit in commits.commits if commit.faction_id == "sol")
    diagnostic = orchestrator.diagnostics("match-test", 1)["sol"]

    assert sol.specialist_calls == 1
    assert diagnostic.usage.input_tokens == 17
    assert diagnostic.usage.output_tokens == 3


@pytest.mark.asyncio
async def test_calls_receive_authoritative_post_spend_cognition_view() -> None:
    observed = {}

    class InspectingAdvisor:
        async def advise(self, observation_value, specialist_id, role, brief):
            observed["specialist"] = observation_value.cognition.remaining_units
            return SpecialistOutput(
                recommendation=SpecialistRecommendation(
                    specialist_id=specialist_id,
                    role=role,
                    assessment="The legal observation contains one supplied Homeland.",
                    recommendation_summary="Keep the Homeland supplied.",
                )
            )

    def inspecting_plan(observation_value, recommendations):
        observed["commander"] = observation_value.cognition.remaining_units
        return plan_for(observation_value, recommendations)

    configured = runtimes()
    configured["sol"] = FactionRuntime(
        faction_id="sol",
        commander=ScriptedCommander(inspecting_plan),
        budget=CognitionBudget(),
        specialists={
            "sol-economy": SpecialistSlot(
                specialist_id="sol-economy",
                role=SpecialistRole.ECONOMY,
                brief="Track the legal economy state.",
                priority=1,
                advisor=InspectingAdvisor(),
            )
        },
    )
    await ArenaOrchestrator(configured).commit_round(request())

    assert observed == {"specialist": 359, "commander": 357}


def test_120_round_cap_has_no_sudden_death_exception() -> None:
    budget = CognitionBudget()
    assert budget.total_rounds == 120
    assert budget.total_units == 360
    for _ in range(120):
        budget.spend_commander()
    assert budget.commander_calls == 120
    assert budget.remaining_units == 120
    with pytest.raises(ArenaRuntimeError, match="round limit exhausted"):
        budget.spend_commander()
