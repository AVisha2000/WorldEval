"""Strict multi-version registry for immutable embodiment protocol packages."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Any, Mapping

from .protocol import (
    EmbodimentProtocolPackage,
    ProtocolValidationError,
    canonical_sha256,
    strict_json_loads,
)

REGISTRY_VERSION = "embodiment-protocol-registry/1"
SUPPORTED_PROTOCOL_PATHS = MappingProxyType(
    {
        "llm-controller/0.1.0": "../embodiment_protocol",
        "llm-controller/0.2.0": "llm-controller-0.2.0",
        "llm-controller/0.3.0": "llm-controller-0.3.0",
    }
)
_SHA256 = re.compile(r"^[0-9a-f]{64}$")


class VersionedEmbodimentProtocolPackage(EmbodimentProtocolPackage):
    """The existing strict package loader with an entry-bound protocol version."""

    def __init__(
        self,
        root: Path,
        *,
        protocol_version: str,
        expected_package_sha256: str | None = None,
        verify_lock: bool = True,
    ) -> None:
        self.PROTOCOL_VERSION = protocol_version
        if protocol_version == "llm-controller/0.3.0":
            self.SCHEMA_FILES = {
                **EmbodimentProtocolPackage.SCHEMA_FILES,
                "trio-result": "trio-result.v1.schema.json",
            }
        super().__init__(root, verify_lock=verify_lock)
        if expected_package_sha256 is not None and self.package_sha256 != expected_package_sha256:
            raise ProtocolValidationError(
                f"{protocol_version} package hash does not match registry"
            )


@dataclass(frozen=True)
class ProtocolRegistryEntry:
    protocol_version: str
    path: str
    package_sha256: str

    def as_dict(self) -> dict[str, str]:
        return {
            "path": self.path,
            "protocol_version": self.protocol_version,
            "package_sha256": self.package_sha256,
        }


class EmbodimentProtocolRegistry:
    """Resolve a replay protocol version to exactly one hash-bound package."""

    REGISTRY_NAME = "registry.v1.json"

    def __init__(self, registry_path: Path) -> None:
        self.registry_path = registry_path.resolve()
        self.package_root = self.registry_path.parent
        self.game_root = self.package_root.parent.resolve()
        raw = self._load_registry(self.registry_path)
        self._entries = self._parse_entries(raw)
        self._packages: dict[str, VersionedEmbodimentProtocolPackage] = {}

    @classmethod
    def from_repository(cls, repository_root: Path) -> EmbodimentProtocolRegistry:
        return cls(
            repository_root
            / "game"
            / "embodiment_protocol_packages"
            / cls.REGISTRY_NAME
        )

    @property
    def available_versions(self) -> tuple[str, ...]:
        return tuple(self._entries)

    @property
    def registry_sha256(self) -> str:
        return canonical_sha256(
            {
                "packages": [entry.as_dict() for entry in self._entries.values()],
                "registry_version": REGISTRY_VERSION,
            }
        )

    def entry(self, protocol_version: str) -> ProtocolRegistryEntry:
        try:
            return self._entries[protocol_version]
        except KeyError as error:
            raise ProtocolValidationError(
                f"unsupported embodiment protocol version: {protocol_version}"
            ) from error

    def package(self, protocol_version: str) -> VersionedEmbodimentProtocolPackage:
        entry = self.entry(protocol_version)
        cached = self._packages.get(protocol_version)
        if cached is not None:
            return cached
        root = (self.package_root / entry.path).resolve()
        if not root.is_relative_to(self.game_root):
            raise ProtocolValidationError("protocol package path escapes game root")
        package = VersionedEmbodimentProtocolPackage(
            root,
            protocol_version=entry.protocol_version,
            expected_package_sha256=entry.package_sha256,
        )
        self._packages[protocol_version] = package
        return package

    def validate(self, protocol_version: str, schema_name: str, instance: Any) -> None:
        self.package(protocol_version).validate(schema_name, instance)

    def package_for_replay(
        self, replay: Mapping[str, Any]
    ) -> VersionedEmbodimentProtocolPackage:
        """Select a verifier only when both replay version and package hash are bound."""

        protocol_version = replay.get("protocol_version")
        package_sha256 = replay.get("protocol_package_sha256")
        if not isinstance(protocol_version, str) or not isinstance(package_sha256, str):
            raise ProtocolValidationError("replay has no protocol package identity")
        entry = self.entry(protocol_version)
        if package_sha256 != entry.package_sha256:
            raise ProtocolValidationError("replay protocol package hash does not match registry")
        return self.package(protocol_version)

    def package_for_launch(
        self,
        config: Mapping[str, Any],
        protocol_package_sha256: str,
    ) -> VersionedEmbodimentProtocolPackage:
        """Select and schema-check a managed launch before authority reset."""

        protocol_version = config.get("protocol_version")
        if not isinstance(protocol_version, str):
            raise ProtocolValidationError("launch config has no protocol version")
        entry = self.entry(protocol_version)
        if protocol_package_sha256 != entry.package_sha256:
            raise ProtocolValidationError("launch protocol package hash does not match registry")
        package = self.package(protocol_version)
        package.validate("episode-config", config)
        return package

    def validate_replay(self, replay: Mapping[str, Any]) -> None:
        self.package_for_replay(replay).validate("episode-replay", replay)

    @staticmethod
    def _load_registry(path: Path) -> Mapping[str, Any]:
        try:
            raw = strict_json_loads(path.read_bytes())
        except (OSError, ProtocolValidationError) as error:
            raise ProtocolValidationError("cannot load embodiment protocol registry") from error
        if not isinstance(raw, dict):
            raise ProtocolValidationError("embodiment protocol registry is not an object")
        return raw

    @staticmethod
    def _parse_entries(raw: Mapping[str, Any]) -> dict[str, ProtocolRegistryEntry]:
        if set(raw) != {"packages", "registry_version"}:
            raise ProtocolValidationError("embodiment protocol registry has unknown fields")
        if raw["registry_version"] != REGISTRY_VERSION:
            raise ProtocolValidationError("embodiment protocol registry version is unsupported")
        packages = raw["packages"]
        if not isinstance(packages, list):
            raise ProtocolValidationError("embodiment protocol registry packages must be an array")
        entries: dict[str, ProtocolRegistryEntry] = {}
        for value in packages:
            if not isinstance(value, dict) or set(value) != {
                "package_sha256",
                "path",
                "protocol_version",
            }:
                raise ProtocolValidationError("invalid embodiment protocol registry entry")
            protocol_version = value["protocol_version"]
            path = value["path"]
            package_sha256 = value["package_sha256"]
            if not isinstance(protocol_version, str) or protocol_version in entries:
                raise ProtocolValidationError("duplicate or invalid protocol version")
            if not isinstance(path, str) or path != SUPPORTED_PROTOCOL_PATHS.get(protocol_version):
                raise ProtocolValidationError("protocol package path is not the frozen path")
            if not isinstance(package_sha256, str) or _SHA256.fullmatch(package_sha256) is None:
                raise ProtocolValidationError("protocol package hash must be lowercase sha256")
            entries[protocol_version] = ProtocolRegistryEntry(
                protocol_version=protocol_version,
                path=path,
                package_sha256=package_sha256,
            )
        expected_versions = tuple(SUPPORTED_PROTOCOL_PATHS)
        if tuple(entries) != expected_versions:
            raise ProtocolValidationError(
                "embodiment protocol registry packages are missing or out of order"
            )
        return entries
