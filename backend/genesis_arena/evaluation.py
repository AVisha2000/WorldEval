from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Dict

from .models import RunMetrics

WEIGHTS: Dict[str, float] = {
    "survival": 0.30,
    "resource_efficiency": 0.20,
    "strategic_planning": 0.20,
    "adaptation": 0.15,
    "social_intelligence": 0.15,
}


def _ratio(numerator: float, denominator: float, neutral: float = 0.5) -> float:
    if denominator <= 0:
        return neutral
    return max(0.0, min(1.0, numerator / denominator))


def evaluate(metrics: RunMetrics) -> Dict[str, object]:
    day_ratio = _ratio(metrics.days_survived, 20, neutral=0)
    survival = (0.7 if metrics.survived else 0.0) + (0.3 * day_ratio)

    handled = metrics.resources_spent + metrics.resources_wasted
    efficiency = _ratio(metrics.resources_spent, handled)
    if metrics.resources_collected > 0:
        efficiency = 0.7 * efficiency + 0.3 * _ratio(
            metrics.resources_spent, metrics.resources_collected
        )

    shelter_timing = 0.0
    if metrics.shelter_built_day > 0:
        shelter_timing = max(0.0, 1.0 - ((metrics.shelter_built_day - 1) / 20))
    planning = max(0.0, shelter_timing - min(0.5, metrics.invalid_actions * 0.1))

    adaptation = _ratio(metrics.disasters_survived, metrics.disaster_responses)
    social = _ratio(metrics.successful_negotiations, metrics.attempted_negotiations)

    dimensions = {
        "survival": round(survival * 100, 2),
        "resource_efficiency": round(efficiency * 100, 2),
        "strategic_planning": round(planning * 100, 2),
        "adaptation": round(adaptation * 100, 2),
        "social_intelligence": round(social * 100, 2),
    }
    weighted = sum(dimensions[name] * weight for name, weight in WEIGHTS.items())
    return {
        "agent_id": metrics.agent_id,
        "score": round(weighted, 2),
        "dimensions": dimensions,
        "weights": WEIGHTS,
        "raw_metrics": metrics.model_dump(),
    }


def _load(path: Path) -> RunMetrics:
    with path.open("r", encoding="utf-8") as handle:
        return RunMetrics.model_validate(json.load(handle))


def main() -> None:
    parser = argparse.ArgumentParser(description="Score a Genesis Arena run metrics file.")
    parser.add_argument("metrics", type=Path)
    args = parser.parse_args()
    print(json.dumps(evaluate(_load(args.metrics)), indent=2))


if __name__ == "__main__":
    main()
