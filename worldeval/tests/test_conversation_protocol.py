from __future__ import annotations

import copy
import json
import shutil
from pathlib import Path

import pytest
from worldeval.contracts import (
    ConversationProtocolError,
    ConversationProtocolValidator,
    GroundingHypotheses,
    ReferentBinding,
    TaskConstraint,
    TaskExecution,
    grounded_task_hash,
    materialize_grounded_task,
    validate_referent_binding,
)


def _json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def test_conversation_protocol_schemas_lock_and_fixtures_are_strict() -> None:
    validator = ConversationProtocolValidator()
    validator.check_schemas()
    expected = {
        "chat-command.v1.schema.json",
        "grounding-hypotheses.v1.schema.json",
        "referent-binding.v1.schema.json",
        "grounded-task.v1.schema.json",
        "task-revision.v1.schema.json",
        "task-revocation.v1.schema.json",
        "task-status.v1.schema.json",
    }
    assert expected.issubset(validator.schema_names)
    fixtures = validator.root / "fixtures"
    for schema_name in expected:
        fixture = fixtures / f"valid.{schema_name.removesuffix('.schema.json')}.json"
        assert fixture.is_file()
        validator.validate_bytes(schema_name, fixture.read_bytes())
    assert len(validator.package_sha256) == 64


def test_conversation_protocol_lock_rejects_tampering(tmp_path: Path) -> None:
    source = ConversationProtocolValidator().root
    copied = tmp_path / "0.1.0"
    shutil.copytree(source, copied)
    (copied / "README.md").write_text("tampered\n", encoding="utf-8")
    with pytest.raises(ConversationProtocolError, match="lock mismatch"):
        ConversationProtocolValidator(copied)


def test_grounding_binding_requires_visible_current_candidate() -> None:
    validator = ConversationProtocolValidator()
    fixtures = validator.root / "fixtures"
    hypotheses = GroundingHypotheses.model_validate(
        _json(fixtures / "valid.grounding-hypotheses.v1.json")
    )
    binding = ReferentBinding.model_validate(_json(fixtures / "valid.referent-binding.v1.json"))
    assert validate_referent_binding(hypotheses, binding) == binding

    stale = binding.model_copy(
        update={"visible_evidence": binding.visible_evidence.model_copy(update={"generation": 2})}
    )
    with pytest.raises(ConversationProtocolError, match="candidate's visible evidence"):
        validate_referent_binding(hypotheses, stale)

    ambiguous_data = hypotheses.model_dump(mode="json")
    ambiguous_data["status"] = "ambiguous"
    ambiguous_data["selected_candidate_id"] = None
    ambiguous = GroundingHypotheses.model_validate(ambiguous_data)
    with pytest.raises(ConversationProtocolError, match="requires resolved grounding"):
        validate_referent_binding(ambiguous, binding)


def test_materialized_task_is_hashed_bounded_and_cannot_embed_code() -> None:
    validator = ConversationProtocolValidator()
    fixtures = validator.root / "fixtures"
    binding = ReferentBinding.model_validate(_json(fixtures / "valid.referent-binding.v1.json"))
    task = materialize_grounded_task(
        task_id="task-1",
        conversation_id="warehouse-chat-1",
        command_message_id="message-1",
        source={
            "observation_seq": 4,
            "tick": 12,
            "state_hash": "sha256:" + "1" * 64,
        },
        intent_id="pick_up",
        bindings=[binding],
        constraints=[
            TaskConstraint(
                constraint_id="constraint-visible",
                level="hard",
                kind="target_must_remain_visible",
                binding_ids=[binding.binding_id],
                parameters={},
            )
        ],
        execution=TaskExecution(
            action_profile="semantic-grid-actions-v1",
            observation_profile="semantic-grid-visible-v1",
            decision_profile="dynamic-step-locked-v1",
            permitted_action_ids=["move_to", "pick_up"],
            mode="agent_visible_action_plan_only",
            gameplay_authority="environment_authority",
        ),
        state="ready",
    )
    assert task.task_hash == grounded_task_hash(task)
    validator.validate("grounded-task.v1.schema.json", task.model_dump(mode="json"))

    tampered = task.model_dump(mode="json")
    tampered["intent_id"] = "drop"
    with pytest.raises(ConversationProtocolError, match="task hash"):
        validator.validate("grounded-task.v1.schema.json", tampered)

    code = copy.deepcopy(task.model_dump(mode="json"))
    code["execution"]["controller_code"] = "walk_to(box)"
    with pytest.raises(ConversationProtocolError, match="Additional properties"):
        validator.validate("grounded-task.v1.schema.json", code)


def test_ambiguous_commands_cannot_be_materialized_ready_and_statuses_do_not_leak_plans() -> None:
    validator = ConversationProtocolValidator()
    fixtures = validator.root / "fixtures"
    binding = ReferentBinding.model_validate(_json(fixtures / "valid.referent-binding.v1.json"))
    with pytest.raises(ConversationProtocolError, match="ready tasks require"):
        materialize_grounded_task(
            task_id="task-ambiguous",
            conversation_id="warehouse-chat-1",
            command_message_id="message-1",
            source={"observation_seq": 4, "tick": 12, "state_hash": "sha256:" + "1" * 64},
            intent_id="pick_up",
            bindings=[],
            constraints=[],
            execution=TaskExecution(
                action_profile="semantic-grid-actions-v1",
                observation_profile="semantic-grid-visible-v1",
                decision_profile="dynamic-step-locked-v1",
                permitted_action_ids=["move_to"],
                mode="agent_visible_action_plan_only",
                gameplay_authority="environment_authority",
            ),
            state="ready",
        )
    assert binding.status == "active"

    completed = _json(fixtures / "valid.task-status.v1.json")
    completed["state"] = "completed"
    completed["active_plan_id"] = "plan-should-not-leak"
    with pytest.raises(ConversationProtocolError, match="live task status"):
        validator.validate("task-status.v1.schema.json", completed)
