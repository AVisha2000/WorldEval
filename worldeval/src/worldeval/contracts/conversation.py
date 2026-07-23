# ruff: noqa: UP045
"""Strict, public-safe contracts for ``worldeval-conversation/0.1.0``.

The conversation package records intent and grounding; it never authorizes a
world mutation. Execution must still go through the environment's visible
action-plan contract and its authoritative simulator.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from importlib import resources
from pathlib import Path
from typing import Any, Dict, Iterable, List, Literal, Mapping, Optional, Union

from jsonschema import Draft202012Validator, FormatChecker
from jsonschema.exceptions import SchemaError, ValidationError
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
from referencing import Registry, Resource

from worldeval.workspace import WorkspaceError, find_workspace

from .canonical import canonical_sha256, strict_json_loads
from .models import Hash, Identifier, SourceObservation

CONVERSATION_PROTOCOL_ID = "worldeval-conversation/0.1.0"


class ConversationProtocolError(ValueError):
    """The immutable conversation package or a wire document is invalid."""


class ConversationStrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class VisibleEvidence(ConversationStrictModel):
    observation_seq: int = Field(ge=0)
    tick: int = Field(ge=0)
    state_hash: Hash
    visible_entity_id: Identifier
    generation: int = Field(ge=1)


class EntityReference(ConversationStrictModel):
    entity_id: Identifier
    generation: int = Field(ge=1)
    type_id: Identifier


class ChatCommand(ConversationStrictModel):
    schema_version: Literal["chat-command.v1"]
    protocol: Literal[CONVERSATION_PROTOCOL_ID]
    conversation_id: Identifier
    message_id: Identifier
    sequence: int = Field(ge=0)
    sender: Literal["human"]
    text: str = Field(min_length=1, max_length=2000)
    source: SourceObservation
    visibility: Literal["public"]


class GroundingCandidate(ConversationStrictModel):
    candidate_id: Identifier
    entity: EntityReference
    visible_evidence: VisibleEvidence

    @model_validator(mode="after")
    def evidence_matches_entity(self) -> GroundingCandidate:
        if self.visible_evidence.visible_entity_id != self.entity.entity_id:
            raise ValueError("visible evidence must name the candidate entity")
        if self.visible_evidence.generation != self.entity.generation:
            raise ValueError("visible evidence generation must match the candidate entity")
        return self


class GroundingHypotheses(ConversationStrictModel):
    schema_version: Literal["grounding-hypotheses.v1"]
    protocol: Literal[CONVERSATION_PROTOCOL_ID]
    hypothesis_set_id: Identifier
    task_id: Identifier
    conversation_id: Identifier
    command_message_id: Identifier
    source: SourceObservation
    status: Literal["resolved", "ambiguous", "unresolved"]
    selected_candidate_id: Optional[Identifier] = None
    candidates: List[GroundingCandidate] = Field(min_length=1, max_length=16)

    @model_validator(mode="after")
    def selection_is_explicit_and_current(self) -> GroundingHypotheses:
        candidate_ids = [item.candidate_id for item in self.candidates]
        if len(candidate_ids) != len(set(candidate_ids)):
            raise ValueError("grounding candidate IDs must be unique")
        if self.status == "resolved":
            if self.selected_candidate_id not in candidate_ids:
                raise ValueError("resolved grounding must select a candidate")
        elif self.selected_candidate_id is not None:
            raise ValueError("only resolved grounding may select a candidate")
        for candidate in self.candidates:
            if candidate.visible_evidence.observation_seq != self.source.observation_seq:
                raise ValueError("grounding evidence must use the source observation")
            if candidate.visible_evidence.tick != self.source.tick:
                raise ValueError("grounding evidence must use the source tick")
            if candidate.visible_evidence.state_hash != self.source.state_hash:
                raise ValueError("grounding evidence must use the source state hash")
        return self


class ReferentBinding(ConversationStrictModel):
    schema_version: Literal["referent-binding.v1"]
    protocol: Literal[CONVERSATION_PROTOCOL_ID]
    binding_id: Identifier
    task_id: Identifier
    conversation_id: Identifier
    command_message_id: Identifier
    hypothesis_set_id: Identifier
    candidate_id: Identifier
    entity: EntityReference
    visible_evidence: VisibleEvidence
    bound_by: Literal["unique_visible_candidate", "human_confirmation"]
    expires_at_observation_seq: int = Field(ge=0)
    status: Literal["active", "revoked", "expired"]

    @model_validator(mode="after")
    def valid_binding_window(self) -> ReferentBinding:
        if self.visible_evidence.visible_entity_id != self.entity.entity_id:
            raise ValueError("binding evidence must name the bound entity")
        if self.visible_evidence.generation != self.entity.generation:
            raise ValueError("binding evidence generation must match the bound entity")
        if self.expires_at_observation_seq < self.visible_evidence.observation_seq:
            raise ValueError("binding expiry cannot precede its visible evidence")
        return self


class TaskConstraint(ConversationStrictModel):
    constraint_id: Identifier
    level: Literal["hard", "soft"]
    kind: Identifier
    binding_ids: List[Identifier] = Field(default_factory=list, max_length=16)
    parameters: Dict[str, Optional[Union[str, int, bool]]] = Field(
        default_factory=dict, max_length=16
    )

    @field_validator("binding_ids")
    @classmethod
    def unique_binding_ids(cls, value: List[str]) -> List[str]:
        if len(value) != len(set(value)):
            raise ValueError("constraint binding IDs must be unique")
        return value


class TaskExecution(ConversationStrictModel):
    action_profile: Identifier
    observation_profile: Identifier
    decision_profile: Identifier
    permitted_action_ids: List[Identifier] = Field(min_length=1, max_length=64)
    mode: Literal["agent_visible_action_plan_only"]
    gameplay_authority: Literal["environment_authority"]

    @field_validator("permitted_action_ids")
    @classmethod
    def unique_actions(cls, value: List[str]) -> List[str]:
        if len(value) != len(set(value)):
            raise ValueError("permitted action IDs must be unique")
        return value


class GroundedTask(ConversationStrictModel):
    schema_version: Literal["grounded-task.v1"]
    protocol: Literal[CONVERSATION_PROTOCOL_ID]
    task_id: Identifier
    revision: int = Field(ge=0)
    conversation_id: Identifier
    command_message_id: Identifier
    source: SourceObservation
    intent_id: Identifier
    bindings: List[Identifier] = Field(default_factory=list, max_length=16)
    constraints: List[TaskConstraint] = Field(default_factory=list, max_length=32)
    execution: TaskExecution
    state: Literal["clarification_required", "ready"]
    task_hash: Hash

    @model_validator(mode="after")
    def valid_contract(self) -> GroundedTask:
        if len(self.bindings) != len(set(self.bindings)):
            raise ValueError("task binding IDs must be unique")
        if len({item.constraint_id for item in self.constraints}) != len(self.constraints):
            raise ValueError("task constraint IDs must be unique")
        bound = set(self.bindings)
        for constraint in self.constraints:
            if not set(constraint.binding_ids).issubset(bound):
                raise ValueError("constraint references a binding absent from the task")
        if self.state == "ready" and not self.bindings:
            raise ValueError("ready tasks require an explicit referent binding")
        if self.state == "clarification_required" and self.bindings:
            raise ValueError("clarification-required tasks cannot authorize bindings")
        if self.task_hash != grounded_task_hash(self):
            raise ValueError("task hash does not match the task body")
        return self


class TaskRevision(ConversationStrictModel):
    schema_version: Literal["task-revision.v1"]
    protocol: Literal[CONVERSATION_PROTOCOL_ID]
    revision_id: Identifier
    task_id: Identifier
    from_revision: int = Field(ge=0)
    to_revision: int = Field(ge=1)
    cause: Literal["human_correction", "grounding_update", "world_interrupt"]
    source: SourceObservation
    supersedes_task_hash: Hash
    new_task_hash: Hash

    @model_validator(mode="after")
    def advances_once(self) -> TaskRevision:
        if self.to_revision != self.from_revision + 1:
            raise ValueError("task revisions must advance exactly one revision")
        if self.new_task_hash == self.supersedes_task_hash:
            raise ValueError("a task revision must change the task contract")
        return self


class TaskRevocation(ConversationStrictModel):
    schema_version: Literal["task-revocation.v1"]
    protocol: Literal[CONVERSATION_PROTOCOL_ID]
    revocation_id: Identifier
    task_id: Identifier
    revision: int = Field(ge=0)
    source: SourceObservation
    reason: Literal["human_correction", "binding_stale", "world_interrupt", "task_cancelled"]
    revoked_plan_ids: List[Identifier] = Field(default_factory=list, max_length=64)
    disposition: Literal["neutral_noop"]

    @field_validator("revoked_plan_ids")
    @classmethod
    def unique_plan_ids(cls, value: List[str]) -> List[str]:
        if len(value) != len(set(value)):
            raise ValueError("revoked plan IDs must be unique")
        return value


class TaskStatus(ConversationStrictModel):
    schema_version: Literal["task-status.v1"]
    protocol: Literal[CONVERSATION_PROTOCOL_ID]
    status_id: Identifier
    task_id: Identifier
    revision: int = Field(ge=0)
    source: SourceObservation
    state: Literal[
        "clarification_required",
        "ready",
        "planning",
        "executing",
        "interrupted",
        "completed",
        "failed",
        "cancelled",
    ]
    active_plan_id: Optional[Identifier] = None
    summary: str = Field(min_length=1, max_length=1000)
    visibility: Literal["public"]

    @model_validator(mode="after")
    def active_plan_is_only_for_live_execution(self) -> TaskStatus:
        live = {"planning", "executing", "interrupted"}
        if self.active_plan_id is not None and self.state not in live:
            raise ValueError("only a live task status may expose an active plan")
        return self


MODEL_BY_SCHEMA: Dict[str, Any] = {
    "chat-command.v1.schema.json": ChatCommand,
    "grounding-hypotheses.v1.schema.json": GroundingHypotheses,
    "referent-binding.v1.schema.json": ReferentBinding,
    "grounded-task.v1.schema.json": GroundedTask,
    "task-revision.v1.schema.json": TaskRevision,
    "task-revocation.v1.schema.json": TaskRevocation,
    "task-status.v1.schema.json": TaskStatus,
}


def grounded_task_hash(value: GroundedTask | Mapping[str, Any]) -> str:
    data = value.model_dump(mode="json") if isinstance(value, GroundedTask) else dict(value)
    data.pop("task_hash", None)
    return canonical_sha256(data)


def materialize_grounded_task(
    *,
    task_id: str,
    conversation_id: str,
    command_message_id: str,
    source: SourceObservation | Mapping[str, Any],
    intent_id: str,
    bindings: Iterable[ReferentBinding | Mapping[str, Any]],
    constraints: Iterable[TaskConstraint | Mapping[str, Any]],
    execution: TaskExecution | Mapping[str, Any],
    state: Literal["clarification_required", "ready"],
    revision: int = 0,
) -> GroundedTask:
    source_model = (
        source
        if isinstance(source, SourceObservation)
        else SourceObservation.model_validate(source)
    )
    binding_models = [
        item if isinstance(item, ReferentBinding) else ReferentBinding.model_validate(item)
        for item in bindings
    ]
    constraint_models = [
        item if isinstance(item, TaskConstraint) else TaskConstraint.model_validate(item)
        for item in constraints
    ]
    execution_model = (
        execution
        if isinstance(execution, TaskExecution)
        else TaskExecution.model_validate(execution)
    )
    if any(item.task_id != task_id for item in binding_models):
        raise ConversationProtocolError("all bindings must belong to the materialized task")
    if any(item.status != "active" for item in binding_models):
        raise ConversationProtocolError("only active bindings may authorize a task")
    body: Dict[str, Any] = {
        "schema_version": "grounded-task.v1",
        "protocol": CONVERSATION_PROTOCOL_ID,
        "task_id": task_id,
        "revision": revision,
        "conversation_id": conversation_id,
        "command_message_id": command_message_id,
        "source": source_model.model_dump(mode="json"),
        "intent_id": intent_id,
        "bindings": [item.binding_id for item in binding_models],
        "constraints": [item.model_dump(mode="json") for item in constraint_models],
        "execution": execution_model.model_dump(mode="json"),
        "state": state,
    }
    body["task_hash"] = canonical_sha256(body)
    try:
        return GroundedTask.model_validate(body)
    except Exception as exc:
        raise ConversationProtocolError(f"grounded task materialization failed: {exc}") from exc


def validate_referent_binding(
    hypotheses: GroundingHypotheses | Mapping[str, Any],
    binding: ReferentBinding | Mapping[str, Any],
) -> ReferentBinding:
    hypotheses_model = (
        hypotheses
        if isinstance(hypotheses, GroundingHypotheses)
        else GroundingHypotheses.model_validate(hypotheses)
    )
    binding_model = (
        binding if isinstance(binding, ReferentBinding) else ReferentBinding.model_validate(binding)
    )
    if (
        hypotheses_model.task_id,
        hypotheses_model.conversation_id,
        hypotheses_model.command_message_id,
    ) != (
        binding_model.task_id,
        binding_model.conversation_id,
        binding_model.command_message_id,
    ):
        raise ConversationProtocolError("binding and hypothesis ownership must match")
    if binding_model.hypothesis_set_id != hypotheses_model.hypothesis_set_id:
        raise ConversationProtocolError("binding must cite its grounding hypothesis set")
    candidate = next(
        (
            item
            for item in hypotheses_model.candidates
            if item.candidate_id == binding_model.candidate_id
        ),
        None,
    )
    if candidate is None or candidate.entity != binding_model.entity:
        raise ConversationProtocolError("binding must name a visible grounding candidate")
    if candidate.visible_evidence != binding_model.visible_evidence:
        raise ConversationProtocolError("binding must preserve the candidate's visible evidence")
    if (
        binding_model.bound_by == "unique_visible_candidate"
        and hypotheses_model.status != "resolved"
    ):
        raise ConversationProtocolError("unique-visible binding requires resolved grounding")
    if (
        hypotheses_model.status == "resolved"
        and hypotheses_model.selected_candidate_id != binding_model.candidate_id
    ):
        raise ConversationProtocolError("resolved grounding may only bind its selected candidate")
    return binding_model


@dataclass(frozen=True)
class SchemaViolation:
    instance_path: str
    schema_path: str
    validator: str
    message: str

    @classmethod
    def from_error(cls, error: ValidationError) -> SchemaViolation:
        return cls(
            instance_path="$" + "".join(_path_components(error.absolute_path)),
            schema_path="$" + "".join(_path_components(error.absolute_schema_path)),
            validator=str(error.validator),
            message=error.message,
        )


def default_conversation_protocol_root() -> Any:
    try:
        source_root = (
            find_workspace(__file__).path("worldeval") / "protocols" / "conversation" / "0.1.0"
        )
    except WorkspaceError:
        source_root = None
    if source_root is not None and source_root.is_dir():
        return source_root
    packaged = resources.files("worldeval").joinpath("protocols", "conversation", "0.1.0")
    if packaged.is_dir():
        return packaged
    raise ConversationProtocolError(
        "worldeval-conversation/0.1.0 is absent from source and package"
    )


class ConversationProtocolValidator:
    def __init__(self, root: Path | None = None, *, verify_lock: bool = True) -> None:
        selected = root or default_conversation_protocol_root()
        self.root = selected.resolve() if isinstance(selected, Path) else selected
        schema_dir = self.root / "schemas"
        if not schema_dir.is_dir():
            raise ConversationProtocolError(f"missing conversation schema directory: {schema_dir}")
        self._schemas: Dict[str, Mapping[str, Any]] = {}
        for path in sorted(schema_dir.glob("*.schema.json")):
            value = strict_json_loads(path.read_bytes())
            if not isinstance(value, dict):
                raise ConversationProtocolError(f"schema root must be an object: {path.name}")
            self._schemas[path.name] = value
        resources_by_uri = []
        for name, schema in self._schemas.items():
            resource = Resource.from_contents(schema)
            resources_by_uri.extend(
                [(name, resource), (f"schema://worldeval-conversation/{name}", resource)]
            )
            if isinstance(schema.get("$id"), str):
                resources_by_uri.append((schema["$id"], resource))
        self._registry = Registry().with_resources(resources_by_uri)
        self._validators: Dict[str, Draft202012Validator] = {}
        if verify_lock:
            self.verify_lock()

    @property
    def schema_names(self) -> List[str]:
        return sorted(self._schemas)

    def check_schemas(self) -> None:
        for name, schema in self._schemas.items():
            try:
                Draft202012Validator.check_schema(schema)
            except SchemaError as exc:
                raise ConversationProtocolError(f"invalid schema {name}: {exc}") from exc

    def validator(self, schema_name: str) -> Draft202012Validator:
        if schema_name not in self._schemas:
            raise ConversationProtocolError(f"unknown conversation schema: {schema_name}")
        if schema_name not in self._validators:
            self._validators[schema_name] = Draft202012Validator(
                self._schemas[schema_name], registry=self._registry, format_checker=FormatChecker()
            )
        return self._validators[schema_name]

    def violations(self, schema_name: str, instance: Any) -> List[SchemaViolation]:
        errors = sorted(
            self.validator(schema_name).iter_errors(instance),
            key=lambda error: (list(error.absolute_path), error.message),
        )
        return [SchemaViolation.from_error(error) for error in errors]

    def validate(self, schema_name: str, instance: Any, *, model: bool = True) -> Any:
        violations = self.violations(schema_name, instance)
        if violations:
            first = violations[0]
            raise ConversationProtocolError(
                f"{schema_name} rejected {first.instance_path}: {first.message} "
                f"({len(violations)} violation(s))"
            )
        model_type = MODEL_BY_SCHEMA.get(schema_name) if model else None
        if model_type is None:
            return instance
        try:
            return model_type.model_validate(instance)
        except Exception as exc:
            raise ConversationProtocolError(
                f"{schema_name} failed semantic validation: {exc}"
            ) from exc

    def validate_bytes(self, schema_name: str, payload: str | bytes | bytearray) -> Any:
        return self.validate(schema_name, strict_json_loads(payload))

    def build_lock(self) -> Mapping[str, Any]:
        artifacts = []
        for relative_path, path in _walk_files(self.root):
            if relative_path == "protocol-lock.json" or any(
                part.startswith(".") for part in relative_path.split("/")
            ):
                continue
            payload = path.read_bytes()
            artifacts.append(
                {
                    "path": relative_path,
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "size_bytes": len(payload),
                }
            )
        body = {
            "artifacts": artifacts,
            "canonical_json": "rfc8785-integer-nfc-subset-v1",
            "hash_algorithm": "sha256",
            "protocol_version": CONVERSATION_PROTOCOL_ID,
        }
        return {**body, "package_sha256": canonical_sha256(body).removeprefix("sha256:")}

    def verify_lock(self) -> Mapping[str, Any]:
        path = self.root / "protocol-lock.json"
        if not path.is_file():
            raise ConversationProtocolError(f"missing conversation protocol lock: {path}")
        locked = strict_json_loads(path.read_bytes())
        actual = self.build_lock()
        if locked != actual:
            raise ConversationProtocolError("worldeval-conversation/0.1.0 protocol lock mismatch")
        return actual

    @property
    def package_sha256(self) -> str:
        return str(self.verify_lock()["package_sha256"])


def _path_components(path: Iterable[Any]) -> Iterable[str]:
    for component in path:
        if isinstance(component, int):
            yield f"[{component}]"
        else:
            yield "/" + str(component).replace("~", "~0").replace("/", "~1")


def _walk_files(root: Any, prefix: str = "") -> List[tuple[str, Any]]:
    files = []
    for child in sorted(root.iterdir(), key=lambda item: item.name):
        relative = f"{prefix}/{child.name}" if prefix else child.name
        if child.is_dir():
            files.extend(_walk_files(child, relative))
        elif child.is_file():
            files.append((relative, child))
    return files
