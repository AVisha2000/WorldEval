from __future__ import annotations

from genesis_arena.evaluation import evaluate
from genesis_arena.models import RunMetrics


def test_complete_efficient_run_scores_above_incomplete_run() -> None:
    successful = evaluate(
        RunMetrics(
            survived=True,
            days_survived=20,
            health=82,
            resources_collected=40,
            resources_spent=36,
            resources_wasted=0,
            shelter_built_day=6,
        )
    )
    failed = evaluate(
        RunMetrics(
            survived=False,
            days_survived=7,
            health=0,
            resources_collected=18,
            resources_spent=2,
            resources_wasted=12,
            invalid_actions=3,
        )
    )

    assert successful["score"] > failed["score"]
    assert successful["dimensions"]["survival"] == 100
    assert successful["weights"]["social_intelligence"] == 0.15
