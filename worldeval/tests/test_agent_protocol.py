from __future__ import annotations

import copy
import json
import shutil
from pathlib import Path

import pytest
from pydantic import TypeAdapter, ValidationError
from worldarena.primitive_sandbox import (
    AgentEpisode,
    ReplayVerificationError,
    load_grid_scenario,
    run_primitive_sandbox_demo,
    verify_primitive_sandbox_replay,
)
from worldeval.contracts import (
    ActionCatalog,
    ActionPlan,
    AgentProtocolValidator,
    ProtocolSchemaError,
    generate_game_initiation_markdown,
    materialize_environment_init,
    verify_environment_init_hash,
)
from worldeval.contracts.canonical import CanonicalJSONError, canonical_sha256, strict_json_loads
from worldeval.contracts.models import (
    DecisionProfile,
    EnvironmentManifest,
    ObjectCatalog,
    ObjectInstance,
    Objective,
    Position,
    ReplaceResponse,
    WaitResponse,
    parse_decision_response,
)
from worldeval.runtime import (
    ActionAuthorityError,
    ActionAuthorityGuard,
    ObjectIdentityError,
    ObjectRegistry,
    ObservationSource,
    PlanCoordinator,
)
from worldeval.workspace import find_workspace

REPOSITORY_ROOT = find_workspace(__file__).root
SANDBOX = REPOSITORY_ROOT / "worlds" / "worldarena" / "games" / "primitive-sandbox"


def _json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _profile(name: str = "dynamic-step-locked-v1"):
    return TypeAdapter(DecisionProfile).validate_python(
        _json(SANDBOX / "decision-profiles" / f"{name}.json")
    )


def _catalog() -> ActionCatalog:
    return ActionCatalog.model_validate(_json(SANDBOX / "catalogs" / "action-catalog.json"))


def _plan(source: ObservationSource, *, lease_ticks: int = 3) -> ActionPlan:
    value = _json(SANDBOX / "examples" / "tree-chop-plan.json")
    value["source"] = source.as_model().model_dump(mode="json")
    value["lease_ticks"] = lease_ticks
    return ActionPlan.model_validate(value)


def _apply_fixture_mutation(document: dict, mutation: dict | None) -> dict:
    value = copy.deepcopy(document)
    if mutation is None:
        return value
    path = mutation["path"]
    parent: object = value
    for component in path[:-1]:
        parent = parent[component]  # type: ignore[index]
    last = path[-1]
    if mutation["op"] == "set":
        parent[last] = copy.deepcopy(mutation["value"])  # type: ignore[index]
    elif mutation["op"] == "remove":
        del parent[last]  # type: ignore[index]
    elif mutation["op"] == "duplicate_step":
        steps = parent[last]  # type: ignore[index]
        steps.append(copy.deepcopy(steps[0]))
    else:
        raise AssertionError(f"unknown fixture mutation: {mutation['op']}")
    return value


def _contract_admissible(document: dict, profile_name: str) -> bool:
    profile = _profile(
        "static-event-gated-v1" if profile_name == "static" else "dynamic-step-locked-v1"
    )
    parsed = parse_decision_response(document)
    if isinstance(parsed, ReplaceResponse):
        ticks = parsed.plan.lease_ticks
        calls = [step.action for step in parsed.plan.steps]
    elif isinstance(parsed, WaitResponse):
        ticks = parsed.maximum_ticks
        calls = []
    elif hasattr(parsed, "lease_ticks"):
        ticks = parsed.lease_ticks
        calls = []
    else:
        return True
    if not profile.minimum_ticks <= ticks <= profile.maximum_ticks:
        return False
    guard = ActionAuthorityGuard(_catalog())
    try:
        for call in calls:
            guard.validate(call)
    except ActionAuthorityError:
        return False
    return True


def test_protocol_schemas_and_all_checked_in_fixtures_are_strict() -> None:
    validator = AgentProtocolValidator()
    validator.check_schemas()
    expected = {
        "environment-manifest.v1.schema.json",
        "environment-init.v1.schema.json",
        "objective.v1.schema.json",
        "object-catalog.v1.schema.json",
        "action-catalog.v1.schema.json",
        "observation.v1.schema.json",
        "action-plan.v1.schema.json",
        "decision-response.v1.schema.json",
        "action-receipt.v1.schema.json",
        "decision-profile.v1.schema.json",
        "skill-manifest.v1.schema.json",
        "replay-bundle.v1.schema.json",
    }
    assert expected.issubset(set(validator.schema_names))

    fixture_schema = {
        "valid.environment-manifest.v1.json": "environment-manifest.v1.schema.json",
        "valid.environment-init.v1.json": "environment-init.v1.schema.json",
        "valid.objective.v1.json": "objective.v1.schema.json",
        "valid.object-catalog.v1.json": "object-catalog.v1.schema.json",
        "valid.action-catalog.v1.json": "action-catalog.v1.schema.json",
        "valid.observation.v1.json": "observation.v1.schema.json",
        "valid.replay-bundle.v1.json": "replay-bundle.v1.schema.json",
        "valid.action-plan.v1.json": "action-plan.v1.schema.json",
        "valid.action-receipt.v1.json": "action-receipt.v1.schema.json",
        "valid.decision-profile.v1.json": "decision-profile.v1.schema.json",
        "valid.skill-manifest.v1.json": "skill-manifest.v1.schema.json",
    }
    fixtures = validator.root / "fixtures"
    for fixture, schema in fixture_schema.items():
        validator.validate_bytes(schema, (fixtures / fixture).read_bytes())
    for fixture in fixtures.glob("valid.decision-response.*.v1.json"):
        validator.validate_bytes("decision-response.v1.schema.json", fixture.read_bytes())

    invalid = _json(fixtures / "valid.objective.v1.json")
    invalid["hidden_state"] = True
    with pytest.raises(ProtocolSchemaError):
        validator.validate("objective.v1.schema.json", invalid)

    tampered_init = _json(fixtures / "valid.environment-init.v1.json")
    tampered_init["active_objective"]["instruction"] = "Tampered after materialization."
    with pytest.raises(ProtocolSchemaError, match="initialization hash"):
        validator.validate("environment-init.v1.schema.json", tampered_init)


def test_protocol_lock_detects_tampering(tmp_path: Path) -> None:
    source = AgentProtocolValidator().root
    copied = tmp_path / "0.1.0"
    shutil.copytree(source, copied)
    fixture = copied / "fixtures" / "valid.objective.v1.json"
    fixture.write_text(fixture.read_text(encoding="utf-8") + "\n", encoding="utf-8")
    with pytest.raises(ProtocolSchemaError, match="lock mismatch"):
        AgentProtocolValidator(copied)


def test_canonical_hashes_are_order_independent_and_reject_ambiguous_json() -> None:
    assert canonical_sha256({"b": 2, "a": 1}) == canonical_sha256({"a": 1, "b": 2})
    with pytest.raises(CanonicalJSONError, match="duplicate"):
        strict_json_loads('{"x":1,"x":2}')
    with pytest.raises(CanonicalJSONError, match="floating"):
        strict_json_loads('{"x":1.5}')


def test_primitive_sandbox_authored_contracts_and_examples_conform() -> None:
    validator = AgentProtocolValidator()
    validator.validate(
        "environment-manifest.v1.schema.json",
        _json(SANDBOX / "environment-manifest.json"),
    )
    validator.validate(
        "object-catalog.v1.schema.json",
        _json(SANDBOX / "catalogs" / "object-catalog.json"),
    )
    validator.validate(
        "action-catalog.v1.schema.json",
        _json(SANDBOX / "catalogs" / "action-catalog.json"),
    )
    for path in (SANDBOX / "objectives").glob("*.json"):
        validator.validate("objective.v1.schema.json", _json(path))
    for path in (SANDBOX / "decision-profiles").glob("*.json"):
        validator.validate("decision-profile.v1.schema.json", _json(path))
    for path in (SANDBOX / "skills").glob("*.json"):
        validator.validate("skill-manifest.v1.schema.json", _json(path))
    for path in (SANDBOX / "examples").glob("*.json"):
        validator.validate("action-plan.v1.schema.json", _json(path))
    for path in (SANDBOX / "scenarios").glob("*.json"):
        load_grid_scenario(path)


def test_python_and_godot_share_strict_decision_conformance_documents() -> None:
    fixture = _json(SANDBOX / "fixtures" / "decision-conformance.v1.json")
    assert fixture["format"] == "worldeval-agent/decision-conformance/1.0.0"
    validator = AgentProtocolValidator()
    seen: set[str] = set()
    for case in fixture["cases"]:
        assert case["id"] not in seen
        seen.add(case["id"])
        document = _apply_fixture_mutation(
            fixture["bases"][case["base"]],
            case.get("mutation"),
        )
        try:
            validator.validate("decision-response.v1.schema.json", document)
        except ProtocolSchemaError:
            schema_valid = False
        else:
            schema_valid = True
        assert schema_valid is case["schema_valid"], case["id"]
        admissible = schema_valid and _contract_admissible(document, case["profile"])
        assert admissible is case["contract_admissible"], case["id"]


def test_environment_init_is_materialized_hashed_and_has_generated_companion() -> None:
    result = run_primitive_sandbox_demo("nominal", sandbox_root=SANDBOX)
    assert verify_environment_init_hash(result.initialization)
    markdown = generate_game_initiation_markdown(result.initialization)
    assert markdown == (SANDBOX / "game_initiation.md").read_text(encoding="utf-8")
    assert "generated, non-authoritative" in markdown
    assert result.initialization.protocol == "worldeval-agent/0.1.0"
    assert result.initialization.active_objective.objective_id == "tree-chop-nominal-v0"


def test_materialization_rejects_mismatched_profiles_and_coordinate_frames() -> None:
    manifest = EnvironmentManifest.model_validate(_json(SANDBOX / "environment-manifest.json"))
    objects = ObjectCatalog.model_validate(_json(SANDBOX / "catalogs" / "object-catalog.json"))
    actions = _catalog()
    objective_data = _json(SANDBOX / "objectives" / "tree-chop-nominal-v0.json")
    objective_data["coordinate_frame"] = "hidden_frame"
    objective = Objective.model_validate(objective_data)
    scenario = load_grid_scenario(SANDBOX / "scenarios" / "tree-chop-nominal-v0.json")
    with pytest.raises(ValueError, match="coordinate frame"):
        materialize_environment_init(
            manifest,
            session_id="bad-session",
            objective=objective,
            object_catalog=objects,
            action_catalog=actions,
            decision_profile=_profile(),
            controlled_assets=[scenario.agent.model_dump(mode="json", exclude={"inventory"})],
        )


def test_episode_requires_initialization_ack_and_silence_is_neutral() -> None:
    scenario = load_grid_scenario(SANDBOX / "scenarios" / "tree-chop-nominal-v0.json")
    episode = AgentEpisode(
        scenario,
        _profile(),
        _catalog(),
        initialization_hash="sha256:" + "a" * 64,
    )
    with pytest.raises(RuntimeError, match="acknowledged"):
        episode.respond(None)
    with pytest.raises(ValueError, match="does not match"):
        episode.acknowledge_initialization("sha256:" + "b" * 64)
    episode.acknowledge_initialization("sha256:" + "a" * 64)

    receipt, observation = episode.respond(None)
    assert receipt.disposition == "no_input"
    assert receipt.fallback == "neutral"
    assert receipt.no_input_reason == "missing"
    assert receipt.applied_ticks == 0
    assert observation.tick == 0

    invalid, observation = episode.respond({"type": "plan.continue"})
    assert invalid.no_input_reason == "invalid"
    assert invalid.fallback == "neutral"
    assert observation.tick == 0

    timeout, observation = episode.respond(None, missing_reason="timeout")
    assert timeout.no_input_reason == "timeout"
    assert timeout.fallback == "neutral"
    assert observation.tick == 0


def test_stale_source_is_neutral_and_never_continues_a_plan() -> None:
    profile = _profile()
    coordinator = PlanCoordinator(profile, _catalog())
    source = ObservationSource(0, 0, "sha256:" + "0" * 64)
    plan = _plan(source)
    accepted = coordinator.handle(
        {"type": "plan.replace", "replaces_plan_id": None, "plan": plan.model_dump(mode="json")},
        source,
    )
    assert accepted.receipt.accepted
    current = ObservationSource(1, 3, "sha256:" + "1" * 64)
    stale = coordinator.handle(
        {
            "type": "plan.continue",
            "plan_id": plan.plan_id,
            "source": source.as_model().model_dump(mode="json"),
            "lease_ticks": 3,
        },
        current,
    )
    assert stale.receipt.no_input_reason == "stale_observation"
    assert stale.authorization is None
    assert stale.receipt.applied_ticks == 0


def test_dynamic_lease_is_capped_at_five_and_static_profile_can_batch_corridor() -> None:
    source = ObservationSource(0, 0, "sha256:" + "0" * 64)
    too_long = _plan(source, lease_ticks=6)
    dynamic = PlanCoordinator(_profile(), _catalog()).handle(
        {
            "type": "plan.replace",
            "replaces_plan_id": None,
            "plan": too_long.model_dump(mode="json"),
        },
        source,
    )
    assert not dynamic.receipt.accepted
    assert "invalid_plan" in dynamic.receipt.codes

    scenario = load_grid_scenario(SANDBOX / "scenarios" / "tree-chop-nominal-v0.json")
    episode = AgentEpisode(
        scenario,
        _profile("static-event-gated-v1"),
        _catalog(),
        initialization_hash="sha256:" + "c" * 64,
    )
    episode.acknowledge_initialization("sha256:" + "c" * 64)
    observation = episode.observation
    plan_data = _plan(
        ObservationSource(observation.observation_seq, observation.tick, observation.state_hash),
        lease_ticks=21,
    ).model_dump(mode="json")
    plan_data["steps"] = plan_data["steps"][:1]
    receipt, after = episode.respond(
        {"type": "plan.replace", "replaces_plan_id": None, "plan": plan_data}
    )
    assert receipt.accepted
    assert receipt.applied_ticks == 21
    assert after.controlled_assets[0].position == Position(x=23, y=12)


def test_revoked_plan_cannot_be_continued() -> None:
    coordinator = PlanCoordinator(_profile(), _catalog())
    source = ObservationSource(0, 0, "sha256:" + "0" * 64)
    plan = _plan(source)
    coordinator.handle(
        {"type": "plan.replace", "replaces_plan_id": None, "plan": plan.model_dump(mode="json")},
        source,
    )
    coordinator.interrupt("hostile_near_target", revoke=True)
    rejected = coordinator.handle(
        {
            "type": "plan.continue",
            "plan_id": plan.plan_id,
            "source": source.as_model().model_dump(mode="json"),
            "lease_ticks": 3,
        },
        source,
    )
    assert not rejected.receipt.accepted
    assert "plan_revoked" in rejected.receipt.codes


def test_object_ids_are_never_rebound_after_despawn() -> None:
    tree = ObjectInstance(
        object_id="tree-7",
        type_id="tree",
        generation=1,
        position=Position(x=23, y=12),
        affordances=["choppable"],
        state={},
    )
    registry = ObjectRegistry([tree])
    registry.despawn("tree-7", generation=1)
    with pytest.raises(ObjectIdentityError, match="cannot be reused"):
        registry.spawn(tree.model_copy(update={"generation": 2}))
    with pytest.raises(ObjectIdentityError, match="not active"):
        registry.resolve("tree-7")


def test_move_to_catalog_cannot_delegate_detours() -> None:
    invalid = _json(SANDBOX / "catalogs" / "action-catalog.json")
    move = next(item for item in invalid["actions"] if item["action_id"] == "move_to")
    move["authority"]["navigation"] = "pathfinding_allowed"
    with pytest.raises(ValidationError, match="direct_only"):
        ActionCatalog.model_validate(invalid)


@pytest.mark.parametrize(
    ("name", "expected"), [("nominal", "tree_destroyed"), ("interrupted", "safe_return")]
)
def test_reference_demos_are_deterministic_schema_valid_and_authority_evaluated(
    name: str, expected: str
) -> None:
    result = run_primitive_sandbox_demo(name, sandbox_root=SANDBOX)
    validator = AgentProtocolValidator()
    validator.validate(
        "environment-init.v1.schema.json", result.initialization.model_dump(mode="json")
    )
    validator.validate("replay-bundle.v1.schema.json", result.replay)
    assert result.replay["terminal_outcome"] == expected
    assert result.replay["provider_calls"] == 0
    assert result.replay["authority_metrics"] == {
        "forbidden_autonomy_count": 0,
        "hostile_attacks": 0,
    }
    assert len(result.replay["decisions"]) == len(result.replay["receipts"])
    assert result.replay["offline_verified"] is True
    assert verify_primitive_sandbox_replay(result.replay, sandbox_root=SANDBOX)
    assert result.evaluation.passed is True
    assert result.evaluation.forbidden_autonomy_count == 0
    assert result.evaluation.replay_offline_verified is True


def test_interrupted_demo_observes_barrier_then_hostile_and_routes_explicitly() -> None:
    result = run_primitive_sandbox_demo("interrupted", sandbox_root=SANDBOX)
    observations = result.replay["observations"]
    events = [
        (observation["tick"], event["kind"])
        for observation in observations
        for event in observation["events"]
    ]
    blocked_tick = next(tick for tick, kind in events if kind == "movement_blocked")
    hostile_tick = next(tick for tick, kind in events if kind == "hostile_near_target")
    assert blocked_tick < hostile_tick
    blocked_observation = next(
        item
        for item in observations
        if any(event["kind"] == "movement_blocked" for event in item["events"])
    )
    assert blocked_observation["controlled_assets"][0]["position"] == {"x": 11, "y": 12}
    hostile_observation = next(
        item
        for item in observations
        if any(event["kind"] == "hostile_near_target" for event in item["events"])
    )
    assert hostile_observation["controlled_assets"][0]["position"] == {"x": 14, "y": 11}
    hostile_receipt = next(
        item
        for item in result.replay["receipts"]
        if "material_interrupt" in item["codes"]
    )
    assert hostile_receipt["end_tick"] == hostile_observation["tick"]
    assert result.evaluation.suspension_reasons == {
        "hostile_near_target": 1,
        "movement_blocked": 1,
    }
    assert result.evaluation.correct_retreat is True
    assert result.evaluation.correct_tool_selected is False
    assert result.evaluation.path_distance > result.evaluation.direct_distance
    abort_receipts = [
        item
        for item in result.replay["receipts"]
        if item["accepted"] and item["response_type"] == "plan.abort"
    ]
    assert len(abort_receipts) == 1
    abort_index = result.replay["receipts"].index(abort_receipts[0])
    assert result.replay["decisions"][abort_index]["type"] == "plan.abort"
    assert result.replay["decisions"][abort_index + 1]["type"] == "plan.replace"


def test_offline_replay_verifier_rejects_tampered_decision() -> None:
    result = run_primitive_sandbox_demo("nominal", sandbox_root=SANDBOX)
    tampered = copy.deepcopy(result.replay)
    tampered["decisions"][0]["plan"]["steps"][0]["action"]["arguments"]["target"][
        "object_id"
    ] = "tree-999"
    with pytest.raises(ReplayVerificationError, match="could not be executed"):
        verify_primitive_sandbox_replay(tampered, sandbox_root=SANDBOX)


def test_replay_metrics_are_required_and_independently_reexecuted() -> None:
    result = run_primitive_sandbox_demo("interrupted", sandbox_root=SANDBOX)
    validator = AgentProtocolValidator()
    missing = copy.deepcopy(result.replay)
    del missing["authority_metrics"]
    with pytest.raises(ProtocolSchemaError):
        validator.validate("replay-bundle.v1.schema.json", missing)

    tampered = copy.deepcopy(result.replay)
    tampered["authority_metrics"]["forbidden_autonomy_count"] = 1
    with pytest.raises(ReplayVerificationError, match="authority_metrics"):
        verify_primitive_sandbox_replay(tampered, sandbox_root=SANDBOX)
