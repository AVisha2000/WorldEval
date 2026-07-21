from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, Iterable, List, Mapping

from jsonschema import Draft202012Validator, FormatChecker
from jsonschema.exceptions import SchemaError, ValidationError
from referencing import Registry, Resource

from .canonical import strict_json_loads
from .protocol import ProtocolPackage, ProtocolPackageError


class ProtocolSchemaError(ProtocolPackageError):
    """A schema is invalid or an instance does not conform to its frozen schema."""


@dataclass(frozen=True)
class SchemaViolation:
    instance_path: str
    schema_path: str
    validator: str
    message: str

    @classmethod
    def from_error(cls, error: ValidationError) -> SchemaViolation:
        instance_path = "$" + "".join(_path_components(error.absolute_path))
        schema_path = "$" + "".join(_path_components(error.absolute_schema_path))
        return cls(
            instance_path=instance_path,
            schema_path=schema_path,
            validator=str(error.validator),
            message=error.message,
        )


class DuelSchemaValidator:
    """Draft 2020-12 validation backed only by checked-in Duel schema resources."""

    def __init__(self, package: ProtocolPackage | None = None) -> None:
        self.package = package or ProtocolPackage()
        self._schemas = self._load_schemas()
        self._registry = self._build_registry(self._schemas)
        self._validators: Dict[str, Draft202012Validator] = {}

    @property
    def schema_names(self) -> List[str]:
        return sorted(self._schemas)

    def check_schemas(self) -> None:
        for name, schema in self._schemas.items():
            try:
                Draft202012Validator.check_schema(schema)
            except SchemaError as exc:
                raise ProtocolSchemaError(f"invalid Draft 2020-12 schema {name}: {exc}") from exc

    def validator(self, schema_name: str) -> Draft202012Validator:
        if schema_name not in self._schemas:
            raise ProtocolSchemaError(f"unknown Duel schema: {schema_name}")
        if schema_name not in self._validators:
            self._validators[schema_name] = Draft202012Validator(
                self._schemas[schema_name],
                registry=self._registry,
                format_checker=FormatChecker(),
            )
        return self._validators[schema_name]

    def violations(self, schema_name: str, instance: Any) -> List[SchemaViolation]:
        errors = sorted(
            self.validator(schema_name).iter_errors(instance),
            key=lambda error: (
                list(error.absolute_path),
                list(error.absolute_schema_path),
                error.message,
            ),
        )
        return [SchemaViolation.from_error(error) for error in errors]

    def validate(self, schema_name: str, instance: Any) -> Any:
        violations = self.violations(schema_name, instance)
        if violations:
            first = violations[0]
            raise ProtocolSchemaError(
                f"{schema_name} rejected {first.instance_path}: {first.message} "
                f"({len(violations)} violation(s))"
            )
        return instance

    def validate_bytes(self, schema_name: str, payload: str | bytes | bytearray) -> Any:
        return self.validate(schema_name, strict_json_loads(payload))

    def _load_schemas(self) -> Dict[str, Mapping[str, Any]]:
        schema_dir = self.package.path("schemas")
        if not schema_dir.is_dir():
            raise ProtocolSchemaError(f"missing schema directory: {schema_dir}")
        schemas: Dict[str, Mapping[str, Any]] = {}
        for path in sorted(schema_dir.glob("*.schema.json")):
            value = self.package.read_json(path.relative_to(self.package.root))
            if not isinstance(value, dict):
                raise ProtocolSchemaError(f"schema root must be an object: {path.name}")
            schemas[path.name] = value
        if not schemas:
            raise ProtocolSchemaError("protocol package contains no schemas")
        return schemas

    @staticmethod
    def _build_registry(schemas: Mapping[str, Mapping[str, Any]]) -> Registry:
        resources = []
        for name, schema in schemas.items():
            resource = Resource.from_contents(schema)
            schema_id = schema.get("$id")
            if isinstance(schema_id, str) and schema_id:
                resources.append((schema_id, resource))
            resources.append((name, resource))
            resources.append((f"schema://worldeval/{name}", resource))
        return Registry().with_resources(resources)


def _path_components(path: Iterable[Any]) -> Iterable[str]:
    for component in path:
        if isinstance(component, int):
            yield f"[{component}]"
        else:
            escaped = str(component).replace("~", "~0").replace("/", "~1")
            yield f"/{escaped}"
