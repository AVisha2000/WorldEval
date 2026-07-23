"""Strict browser-safe projections of sealed authority-derived evaluation evidence."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Mapping, Sequence

from .evaluation import EVALUATION_SCHEMA_VERSION
from .protocol import canonical_json_bytes, canonical_sha256, strict_json_loads

EVALUATION_PROJECTION_VERSION = "llm-controller/evaluation-projection/1.0.0"

_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_SOLO_METRICS = frozenset(
    {
        "completion_tick",
        "controller_changes",
        "damage_taken",
        "deterministic_replay_verification",
        "interaction_alignment_failures",
        "memory_consistency",
        "path_efficiency",
        "progress_checkpoints_reached",
        "provider_latency_efficiency",
        "provider_token_efficiency",
        "recovery_quality",
        "repeated_ineffective_windows",
        "task_success",
        "total_held_ticks",
        "unnecessary_collisions",
        "valid_action_rate",
    }
)
_PAIRED_METRICS = frozenset(
    {
        "adaptation_after_losing_exchange",
        "deterministic_replay_verification",
        "disengagement_success",
        "positional_advantage",
    }
)
_UNAVAILABLE_REASONS = frozenset(
    {
        "evidence_not_ready",
        "evaluation_unavailable",
        "replay_summary_unavailable",
    }
)
_METRIC_UNAVAILABLE_REASONS = frozenset(
    {
        "disengagement_outcome_not_typed",
        "exchange_loss_boundary_not_typed",
        "memory_not_in_authority_replay",
        "normative_recovery_baseline_not_recorded",
        "normative_route_baseline_not_recorded",
        "provider_latency_not_recorded",
        "provider_telemetry_not_recorded",
        "provider_token_usage_not_recorded",
        "runner_memory_not_in_authority_replay",
        "shortest_legal_route_not_recorded",
        "exact_positions_not_in_public_replay",
    }
)
_EVENT_KINDS = frozenset(
    {
        "barricade_completed",
        "beacon_entered",
        "episode_succeeded",
        "material_deposited",
        "neutral_damaged",
        "relay_activated",
        "resource_gathered",
    }
)
_RUN_FIELDS = frozenset(
    {
        "certification_eligible",
        "episode_id",
        "evaluation_profile_id",
        "run_class",
        "scenario_id",
        "task_id",
    }
)
_REPLAY_SUMMARY_FIELDS = frozenset(
    {"episode_id", "final_state_hash", "frozen_configuration", "terminal"}
)
_FROZEN_CONFIGURATION_FIELDS = frozenset(
    {
        "config_sha256",
        "model_sha256",
        "protocol_package_sha256",
        "provider_sha256",
        "settings_sha256",
    }
)
_RESULT_FIELDS = frozenset(
    {"episode_id", "final_state_hash", "provider_failures", "terminal", "windows"}
)
_TERMINAL_FIELDS = frozenset({"ended", "outcome", "reason"})


class EvaluationProjectionError(ValueError):
    """Sealed inputs cannot be represented by the browser-safe projection contract."""


@dataclass(frozen=True, init=False)
class EvaluationProjection:
    """Immutable canonical projection; callers receive copies, never mutable internals."""

    _canonical_body: bytes
    projection_sha256: str

    @classmethod
    def _create(cls, body: Mapping[str, Any]) -> EvaluationProjection:
        canonical = canonical_json_bytes(body)
        instance = object.__new__(cls)
        object.__setattr__(instance, "_canonical_body", canonical)
        object.__setattr__(instance, "projection_sha256", canonical_sha256(body))
        return instance

    @property
    def state(self) -> str:
        return str(strict_json_loads(self._canonical_body)["state"])

    @property
    def scope(self) -> str:
        return str(strict_json_loads(self._canonical_body)["scope"])

    def as_dict(self) -> Mapping[str, Any]:
        body = strict_json_loads(self._canonical_body)
        return {**body, "projection_sha256": self.projection_sha256}

    @property
    def canonical_bytes(self) -> bytes:
        return canonical_json_bytes(self.as_dict())


def build_solo_evaluation_projection(
    *,
    evaluation: Mapping[str, Any],
    replay_summary: Mapping[str, Any],
    run_spec: Mapping[str, Any],
    result: Mapping[str, Any],
    receipts: Sequence[Mapping[str, Any]] = (),
    public_events: Sequence[Mapping[str, Any]] = (),
) -> EvaluationProjection:
    """Project a completed solo run using sealed public artifacts only."""

    run = _run(run_spec)
    summary = _replay_summary(replay_summary, run["episode_id"])
    safe_result = _result(result, run["episode_id"], summary)
    safe_evaluation = _solo_evaluation(evaluation, run)
    body = {
        "evaluation": safe_evaluation,
        "references": _references(receipts, public_events),
        "result": safe_result,
        "run": run,
        "schema_version": EVALUATION_PROJECTION_VERSION,
        "scope": "solo",
        "state": "supported",
    }
    return EvaluationProjection._create(body)


def build_paired_duel_leg_evaluation_projection(
    *,
    evaluation: Mapping[str, Any],
    replay_summary: Mapping[str, Any],
    run_spec: Mapping[str, Any],
    result: Mapping[str, Any],
    receipts: Sequence[Mapping[str, Any]] = (),
    public_events: Sequence[Mapping[str, Any]] = (),
) -> EvaluationProjection:
    """Project one paired-duel leg while retaining side-normalized safe evaluation."""

    run = _run(run_spec)
    summary = _replay_summary(replay_summary, run["episode_id"])
    safe_result = _result(result, run["episode_id"], summary)
    body = {
        "evaluation": _paired_evaluation(evaluation),
        "references": _references(receipts, public_events),
        "result": safe_result,
        "run": run,
        "schema_version": EVALUATION_PROJECTION_VERSION,
        "scope": "paired_duel_leg",
        "state": "supported",
    }
    return EvaluationProjection._create(body)


def build_unavailable_evaluation_projection(
    *, run_spec: Mapping[str, Any], scope: str, reason: str
) -> EvaluationProjection:
    """Return a deterministic safe state without fabricating evaluation values."""

    if scope not in ("solo", "paired_duel") or reason not in _UNAVAILABLE_REASONS:
        raise EvaluationProjectionError("evaluation availability identity is invalid")
    return EvaluationProjection._create(
        {
            "reason": reason,
            "run": _run(run_spec),
            "schema_version": EVALUATION_PROJECTION_VERSION,
            "scope": scope,
            "state": "unavailable",
        }
    )


def _run(value: Mapping[str, Any]) -> dict[str, Any]:
    _mapping(value, "run spec")
    if not set(value) <= _RUN_FIELDS or not {
        "certification_eligible",
        "episode_id",
        "run_class",
        "task_id",
    } <= set(value):
        raise EvaluationProjectionError("run spec fields differ")
    result: dict[str, Any] = {
        "certification_eligible": _boolean(value["certification_eligible"], "certification"),
        "episode_id": _identifier(value["episode_id"], "episode_id", prefix="ep_"),
        "run_class": _identifier(value["run_class"], "run_class"),
        "task_id": _identifier(value["task_id"], "task_id"),
    }
    for name in ("scenario_id", "evaluation_profile_id"):
        if name in value:
            result[name] = _identifier(value[name], name)
    if ("scenario_id" in result) != ("evaluation_profile_id" in result):
        raise EvaluationProjectionError("run evaluation identity is incomplete")
    return result


def _replay_summary(value: Mapping[str, Any], episode_id: str) -> dict[str, Any]:
    _exact(value, _REPLAY_SUMMARY_FIELDS, "replay summary")
    if value["episode_id"] != episode_id:
        raise EvaluationProjectionError("replay summary episode differs")
    frozen = value["frozen_configuration"]
    _exact(frozen, _FROZEN_CONFIGURATION_FIELDS, "frozen configuration")
    hashes = {name: _sha256(child, name) for name, child in frozen.items()}
    return {
        "final_state_hash": _sha256(value["final_state_hash"], "final_state_hash"),
        "frozen_configuration": hashes,
        "terminal": _terminal(value["terminal"]),
    }


def _result(
    value: Mapping[str, Any], episode_id: str, replay_summary: Mapping[str, Any]
) -> dict[str, Any]:
    _exact(value, _RESULT_FIELDS, "result")
    if value["episode_id"] != episode_id:
        raise EvaluationProjectionError("result episode differs")
    result = {
        "final_state_hash": _sha256(value["final_state_hash"], "final_state_hash"),
        "provider_failures": _nonnegative(value["provider_failures"], "provider_failures"),
        "terminal": _terminal(value["terminal"]),
        "windows": _nonnegative(value["windows"], "windows"),
    }
    if (
        result["final_state_hash"] != replay_summary["final_state_hash"]
        or result["terminal"] != replay_summary["terminal"]
    ):
        raise EvaluationProjectionError("result differs from replay summary")
    return result


def _solo_evaluation(value: Mapping[str, Any], run: Mapping[str, Any]) -> dict[str, Any]:
    fields = {"metrics", "schema_version", "scope"}
    if "scenario_id" in run:
        fields.update(("scenario_id", "evaluation_profile_id"))
    _exact(value, frozenset(fields), "solo evaluation")
    if value["schema_version"] != EVALUATION_SCHEMA_VERSION or value["scope"] != "solo":
        raise EvaluationProjectionError("solo evaluation identity differs")
    for name in ("scenario_id", "evaluation_profile_id"):
        if name in run and value[name] != run[name]:
            raise EvaluationProjectionError("solo evaluation run identity differs")
    metrics = value["metrics"]
    _exact(metrics, _SOLO_METRICS, "solo metrics")
    return {
        "metrics": {name: _solo_metric(name, metrics[name]) for name in sorted(metrics)},
        **(
            {
                "evaluation_profile_id": run["evaluation_profile_id"],
                "scenario_id": run["scenario_id"],
            }
            if "scenario_id" in run
            else {}
        ),
    }


def _solo_metric(name: str, value: Any) -> Mapping[str, Any]:
    status, child = _metric_envelope(value)
    if status == "unavailable":
        return child
    raw = child["value"]
    if name in ("task_success", "deterministic_replay_verification"):
        safe: Any = _boolean(raw, name)
    elif name in {
        "completion_tick",
        "controller_changes",
        "damage_taken",
        "interaction_alignment_failures",
        "total_held_ticks",
        "unnecessary_collisions",
    }:
        safe = _nonnegative(raw, name)
    elif name == "valid_action_rate":
        safe = _ratio(raw)
    elif name == "progress_checkpoints_reached":
        _exact(raw, frozenset({"count", "event_kinds"}), name)
        kinds = raw["event_kinds"]
        if not isinstance(kinds, list) or any(kind not in _EVENT_KINDS for kind in kinds):
            raise EvaluationProjectionError("progress event kinds differ")
        safe = {"count": _nonnegative(raw["count"], "count"), "event_kinds": list(kinds)}
    elif name == "repeated_ineffective_windows":
        _exact(raw, frozenset({"longest_run", "windows_in_repeated_runs"}), name)
        safe = {key: _nonnegative(raw[key], key) for key in sorted(raw)}
    elif name == "provider_token_efficiency":
        safe = _integer_record(
            raw, ("cached_input_tokens", "calls", "input_tokens", "output_tokens"), name
        )
    elif name == "provider_latency_efficiency":
        safe = _integer_record(raw, ("calls", "maximum_ms", "mean_ms", "total_ms"), name)
    else:
        raise EvaluationProjectionError(f"{name} cannot be marked supported")
    return {"state": "supported", "value": safe}


def _paired_evaluation(value: Mapping[str, Any]) -> dict[str, Any]:
    _exact(
        value,
        frozenset(
            {"entrants", "leg_index", "metrics", "pair_metrics", "schema_version", "scope"}
        ),
        "paired evaluation",
    )
    if (
        value["schema_version"] != EVALUATION_SCHEMA_VERSION
        or value["scope"] != "paired_duel_leg"
    ):
        raise EvaluationProjectionError("paired evaluation identity differs")
    metrics = value["metrics"]
    _exact(metrics, _PAIRED_METRICS, "paired metrics")
    entrants = _paired_entrants(value["entrants"])
    return {
        "entrants": entrants,
        "leg_index": _nonnegative(value["leg_index"], "leg_index"),
        "metrics": {name: _paired_metric(name, metrics[name]) for name in sorted(metrics)},
        "pair_metrics": _pair_metrics(value["pair_metrics"], frozenset(entrants)),
    }


def _paired_metric(name: str, value: Any) -> Mapping[str, Any]:
    status, child = _metric_envelope(value)
    if status == "unavailable":
        return child
    if name != "deterministic_replay_verification":
        raise EvaluationProjectionError(f"{name} cannot be marked supported")
    return {"state": "supported", "value": _boolean(child["value"], name)}


def _paired_entrants(value: Any) -> dict[str, Any]:
    _mapping(value, "paired entrants")
    if len(value) != 2:
        raise EvaluationProjectionError("paired entrants must contain exactly two entrants")
    result: dict[str, Any] = {}
    fields = frozenset(
        {
            "action_validity",
            "damage_dealt",
            "damage_taken",
            "guard_efficiency",
            "idle_ticks",
            "objective_control_ticks",
            "oscillation",
            "participant_id",
            "provider_latency_efficiency",
            "provider_token_efficiency",
            "total_actions",
            "valid_actions",
        }
    )
    for entrant_id, entrant in sorted(value.items()):
        safe_id = _identifier(entrant_id, "entrant_id")
        _exact(entrant, fields, "paired entrant")
        result[safe_id] = {
            "action_validity": _ratio(entrant["action_validity"]),
            "damage_dealt": _nonnegative(entrant["damage_dealt"], "damage_dealt"),
            "damage_taken": _nonnegative(entrant["damage_taken"], "damage_taken"),
            "guard_efficiency": _ratio(entrant["guard_efficiency"]),
            "idle_ticks": _nonnegative(entrant["idle_ticks"], "idle_ticks"),
            "objective_control_ticks": _nonnegative(
                entrant["objective_control_ticks"], "objective_control_ticks"
            ),
            "oscillation": _nonnegative(entrant["oscillation"], "oscillation"),
            "participant_id": _identifier(
                entrant["participant_id"], "participant_id", prefix="participant_"
            ),
            "provider_latency_efficiency": _efficiency_metric(
                entrant["provider_latency_efficiency"], latency=True
            ),
            "provider_token_efficiency": _efficiency_metric(
                entrant["provider_token_efficiency"], latency=False
            ),
            "total_actions": _nonnegative(entrant["total_actions"], "total_actions"),
            "valid_actions": _nonnegative(entrant["valid_actions"], "valid_actions"),
        }
    return result


def _efficiency_metric(value: Any, *, latency: bool) -> Mapping[str, Any]:
    status, child = _metric_envelope(value)
    if status == "unavailable":
        return child
    safe = (
        _integer_record(child["value"], ("calls", "maximum_ms", "mean_ms", "total_ms"), "latency")
        if latency
        else _integer_record(
            child["value"],
            ("cached_input_tokens", "calls", "input_tokens", "output_tokens"),
            "tokens",
        )
    )
    return {"state": "supported", "value": safe}


def _pair_metrics(value: Any, entrant_ids: frozenset[str]) -> dict[str, Any]:
    _exact(
        value,
        frozenset(
            {
                "deterministic_replay_verification",
                "series_result",
                "side_normalized_performance",
            }
        ),
        "pair metrics",
    )
    deterministic = _required_supported(value["deterministic_replay_verification"])
    series = _required_supported(value["series_result"])
    _exact(series, frozenset({"draws", "entrant_wins", "winner_entrant_id"}), "series result")
    wins = series["entrant_wins"]
    _mapping(wins, "entrant wins")
    if set(wins) != entrant_ids:
        raise EvaluationProjectionError("series entrant identities differ")
    winner = series["winner_entrant_id"]
    if winner is not None and winner not in entrant_ids:
        raise EvaluationProjectionError("series winner differs")
    performance = _required_supported(value["side_normalized_performance"])
    _mapping(performance, "side normalized performance")
    if set(performance) != entrant_ids:
        raise EvaluationProjectionError("performance entrant identities differ")
    aggregates: dict[str, Any] = {}
    aggregate_fields = frozenset(
        {
            "damage_dealt",
            "damage_taken",
            "draws",
            "idle_ticks",
            "losses",
            "objective_control_ticks",
            "valid_action_rate",
            "wins",
        }
    )
    for entrant_id, aggregate in sorted(performance.items()):
        _exact(aggregate, aggregate_fields, "side normalized entrant")
        aggregates[entrant_id] = {
            key: (
                _ratio(aggregate[key])
                if key == "valid_action_rate"
                else _nonnegative(aggregate[key], key)
            )
            for key in sorted(aggregate)
        }
    return {
        "deterministic_replay_verification": {
            "state": "supported",
            "value": _boolean(deterministic, "deterministic_replay_verification"),
        },
        "series_result": {
            "state": "supported",
            "value": {
                "draws": _nonnegative(series["draws"], "draws"),
                "entrant_wins": {
                    entrant_id: _nonnegative(wins[entrant_id], "wins")
                    for entrant_id in sorted(entrant_ids)
                },
                "winner_entrant_id": winner,
            },
        },
        "side_normalized_performance": {"state": "supported", "value": aggregates},
    }


def _required_supported(value: Any) -> Any:
    status, child = _metric_envelope(value)
    if status != "supported":
        raise EvaluationProjectionError("required paired metric is unavailable")
    return child["value"]


def _metric_envelope(value: Any) -> tuple[str, Mapping[str, Any]]:
    _mapping(value, "metric")
    status = value.get("status")
    if status == "supported" and set(value) == {"status", "value"}:
        return "supported", {"value": value["value"]}
    if status == "unsupported" and set(value) == {"reason", "status"}:
        reason = value["reason"]
        if reason not in _METRIC_UNAVAILABLE_REASONS:
            raise EvaluationProjectionError("metric unavailable reason differs")
        return "unavailable", {"reason": reason, "state": "unavailable"}
    raise EvaluationProjectionError("metric envelope differs")


def _references(
    receipts: Sequence[Mapping[str, Any]], public_events: Sequence[Mapping[str, Any]]
) -> Mapping[str, Any]:
    receipt_refs: list[dict[str, Any]] = []
    for item in receipts:
        _exact(item, frozenset({"observation_seq", "participants"}), "receipt record")
        sequence = _nonnegative(item["observation_seq"], "observation_seq")
        participants = item["participants"]
        _mapping(participants, "receipt participants")
        for participant_id, receipt in sorted(participants.items()):
            _mapping(receipt, "receipt")
            receipt_refs.append(
                {
                    "action_id": _identifier(receipt.get("action_id"), "action_id"),
                    "observation_seq": sequence,
                    "participant_id": _identifier(
                        participant_id, "participant_id", prefix="participant_"
                    ),
                }
            )
    event_refs: list[dict[str, Any]] = []
    for event in public_events:
        _mapping(event, "public event")
        kind = event.get("kind")
        if kind not in _EVENT_KINDS:
            continue
        event_refs.append({"kind": kind, "tick": _nonnegative(event.get("tick"), "tick")})
    return {"events": event_refs, "receipts": receipt_refs}


def _terminal(value: Any) -> dict[str, Any]:
    _exact(value, _TERMINAL_FIELDS, "terminal")
    return {
        "ended": _boolean(value["ended"], "ended"),
        "outcome": _identifier(value["outcome"], "outcome"),
        "reason": _identifier(value["reason"], "reason"),
    }


def _ratio(value: Any) -> dict[str, int]:
    keys = ("basis_points", "denominator", "numerator")
    result = _integer_record(value, keys, "ratio")
    if result["basis_points"] > 10_000 or result["numerator"] > result["denominator"]:
        raise EvaluationProjectionError("ratio is invalid")
    return result


def _integer_record(value: Any, keys: Sequence[str], label: str) -> dict[str, int]:
    _exact(value, frozenset(keys), label)
    return {key: _nonnegative(value[key], key) for key in keys}


def _mapping(value: Any, label: str) -> None:
    if not isinstance(value, Mapping):
        raise EvaluationProjectionError(f"{label} must be an object")


def _exact(value: Any, fields: frozenset[str], label: str) -> None:
    _mapping(value, label)
    if set(value) != fields:
        raise EvaluationProjectionError(f"{label} fields differ")


def _identifier(value: Any, label: str, *, prefix: str | None = None) -> str:
    if not isinstance(value, str) or _ID.fullmatch(value) is None:
        raise EvaluationProjectionError(f"{label} is invalid")
    if prefix is not None and not value.startswith(prefix):
        raise EvaluationProjectionError(f"{label} is invalid")
    return value


def _sha256(value: Any, label: str) -> str:
    if not isinstance(value, str) or _SHA256.fullmatch(value) is None:
        raise EvaluationProjectionError(f"{label} is invalid")
    return value


def _nonnegative(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise EvaluationProjectionError(f"{label} is invalid")
    return value


def _boolean(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise EvaluationProjectionError(f"{label} is invalid")
    return value


__all__ = [
    "EVALUATION_PROJECTION_VERSION",
    "EvaluationProjection",
    "EvaluationProjectionError",
    "build_paired_duel_leg_evaluation_projection",
    "build_solo_evaluation_projection",
    "build_unavailable_evaluation_projection",
]
