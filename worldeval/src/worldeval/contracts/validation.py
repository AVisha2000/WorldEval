"""Checked-in Draft 2020-12 schema and wire-model validation."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from importlib import resources
from pathlib import Path
from typing import Any, Dict, Iterable, Mapping

from jsonschema import Draft202012Validator, FormatChecker
from jsonschema.exceptions import SchemaError, ValidationError
from pydantic import BaseModel, TypeAdapter
from pydantic import ValidationError as PydanticValidationError
from referencing import Registry, Resource

from worldeval.workspace import WorkspaceError, find_workspace

from .canonical import canonical_sha256, strict_json_loads
from .materialization import verify_environment_init_hash
from .models import (
    ActionCatalog,
    ActionPlan,
    ActionReceipt,
    AgentNativeReplay,
    DecisionProfile,
    DecisionResponse,
    EnvironmentInit,
    EnvironmentManifest,
    ObjectCatalog,
    Objective,
    Observation,
    SkillManifest,
)


class ProtocolSchemaError(ValueError):
    """A schema is invalid or an instance fails protocol validation."""


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


MODEL_BY_SCHEMA: Dict[str, Any] = {
    "environment-manifest.v1.schema.json": EnvironmentManifest,
    "environment-init.v1.schema.json": EnvironmentInit,
    "objective.v1.schema.json": Objective,
    "object-catalog.v1.schema.json": ObjectCatalog,
    "action-catalog.v1.schema.json": ActionCatalog,
    "observation.v1.schema.json": Observation,
    "action-plan.v1.schema.json": ActionPlan,
    "decision-response.v1.schema.json": DecisionResponse,
    "action-receipt.v1.schema.json": ActionReceipt,
    "decision-profile.v1.schema.json": DecisionProfile,
    "skill-manifest.v1.schema.json": SkillManifest,
    "replay-bundle.v1.schema.json": AgentNativeReplay,
}


def default_protocol_root() -> Any:
    try:
        source_root = find_workspace(__file__).path("worldeval") / "protocols" / "agent" / "0.1.0"
    except WorkspaceError:
        source_root = None
    if source_root is not None and source_root.is_dir():
        return source_root
    packaged = resources.files("worldeval").joinpath("protocols", "agent", "0.1.0")
    if packaged.is_dir():
        return packaged
    raise ProtocolSchemaError(
        "worldeval-agent/0.1.0 is absent from both the source workspace and installed package"
    )


class AgentProtocolValidator:
    def __init__(self, root: Path | None = None, *, verify_lock: bool = True) -> None:
        selected = root or default_protocol_root()
        self.root = selected.resolve() if isinstance(selected, Path) else selected
        schema_dir = self.root / "schemas"
        if not schema_dir.is_dir():
            raise ProtocolSchemaError(f"missing agent protocol schema directory: {schema_dir}")
        self._schemas: Dict[str, Mapping[str, Any]] = {}
        paths = sorted(
            (path for path in schema_dir.iterdir() if path.name.endswith(".schema.json")),
            key=lambda path: path.name,
        )
        for path in paths:
            value = strict_json_loads(path.read_bytes())
            if not isinstance(value, dict):
                raise ProtocolSchemaError(f"schema root must be an object: {path.name}")
            self._schemas[path.name] = value
        resources = []
        for name, schema in self._schemas.items():
            resource = Resource.from_contents(schema)
            resources.extend([(name, resource), (f"schema://worldeval-agent/{name}", resource)])
            if isinstance(schema.get("$id"), str):
                resources.append((schema["$id"], resource))
        self._registry = Registry().with_resources(resources)
        self._validators: Dict[str, Draft202012Validator] = {}
        if verify_lock:
            self.verify_lock()

    @property
    def schema_names(self) -> list[str]:
        return sorted(self._schemas)

    def check_schemas(self) -> None:
        for name, schema in self._schemas.items():
            try:
                Draft202012Validator.check_schema(schema)
            except SchemaError as exc:
                raise ProtocolSchemaError(f"invalid schema {name}: {exc}") from exc

    def validator(self, schema_name: str) -> Draft202012Validator:
        if schema_name not in self._schemas:
            raise ProtocolSchemaError(f"unknown agent protocol schema: {schema_name}")
        if schema_name not in self._validators:
            self._validators[schema_name] = Draft202012Validator(
                self._schemas[schema_name],
                registry=self._registry,
                format_checker=FormatChecker(),
            )
        return self._validators[schema_name]

    def violations(self, schema_name: str, instance: Any) -> list[SchemaViolation]:
        errors = sorted(
            self.validator(schema_name).iter_errors(instance),
            key=lambda error: (list(error.absolute_path), error.message),
        )
        return [SchemaViolation.from_error(error) for error in errors]

    def validate(self, schema_name: str, instance: Any, *, model: bool = True) -> Any:
        violations = self.violations(schema_name, instance)
        if violations:
            first = violations[0]
            raise ProtocolSchemaError(
                f"{schema_name} rejected {first.instance_path}: {first.message} "
                f"({len(violations)} violation(s))"
            )
        model_type = MODEL_BY_SCHEMA.get(schema_name) if model else None
        if model_type is None:
            return instance
        try:
            if isinstance(model_type, type) and issubclass(model_type, BaseModel):
                result = model_type.model_validate(instance)
            else:
                result = TypeAdapter(model_type).validate_python(instance)
        except PydanticValidationError as exc:
            raise ProtocolSchemaError(f"{schema_name} failed semantic validation: {exc}") from exc
        if schema_name == "environment-init.v1.schema.json" and not verify_environment_init_hash(
            result
        ):
            raise ProtocolSchemaError("environment initialization hash does not match its body")
        return result

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
            "protocol_version": "worldeval-agent/0.1.0",
        }
        return {
            **body,
            "package_sha256": canonical_sha256(body).removeprefix("sha256:"),
        }

    def verify_lock(self) -> Mapping[str, Any]:
        path = self.root / "protocol-lock.json"
        if not path.is_file():
            raise ProtocolSchemaError(f"missing agent protocol lock: {path}")
        locked = strict_json_loads(path.read_bytes())
        actual = self.build_lock()
        if locked != actual:
            raise ProtocolSchemaError("worldeval-agent/0.1.0 protocol lock mismatch")
        return actual

    @property
    def package_sha256(self) -> str:
        return str(self.verify_lock()["package_sha256"])


def _path_components(path: Iterable[Any]) -> Iterable[str]:
    for component in path:
        if isinstance(component, int):
            yield f"[{component}]"
        else:
            escaped = str(component).replace("~", "~0").replace("/", "~1")
            yield f"/{escaped}"


def _walk_files(root: Any, prefix: str = "") -> list[tuple[str, Any]]:
    files = []
    for child in sorted(root.iterdir(), key=lambda item: item.name):
        relative = f"{prefix}/{child.name}" if prefix else child.name
        if child.is_dir():
            files.extend(_walk_files(child, relative))
        elif child.is_file():
            files.append((relative, child))
    return files
