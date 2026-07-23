from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from worldarena.paths import WORLDARENA_ROOT

from .canonical import canonical_json_bytes, canonical_sha256, strict_json_loads

DUEL_PROTOCOL_VERSION = "worldeval-rts/1.0.0"
DEFAULT_PROTOCOL_RELATIVE_PATH = Path("game/duel_protocol")
LOCK_FILENAME = "protocol-lock.json"


class ProtocolPackageError(RuntimeError):
    """The checked-in protocol package is absent, malformed, or incomplete."""


class ProtocolLockMismatch(ProtocolPackageError):
    """The protocol package bytes do not match the frozen lock."""


@dataclass(frozen=True)
class ArtifactDigest:
    path: str
    size_bytes: int
    sha256: str

    def as_dict(self) -> dict[str, Any]:
        return {
            "path": self.path,
            "sha256": self.sha256,
            "size_bytes": self.size_bytes,
        }


def repository_root() -> Path:
    return WORLDARENA_ROOT


class ProtocolPackage:
    """Read and verify the immutable WorldArena Duel public contract package."""

    REQUIRED_PATHS = (
        "VERSION",
        "README.md",
        "schemas/match-config.v1.schema.json",
        "schemas/match-init.v1.schema.json",
        "schemas/observation.v1.schema.json",
        "schemas/action-batch.v1.schema.json",
        "schemas/action-receipt.v1.schema.json",
        "schemas/event.v1.schema.json",
        "schemas/map-manifest.v1.schema.json",
        "schemas/replay-manifest.v1.schema.json",
        "catalogs/actions.hybrid-v1.json",
        "catalogs/rules.duel-v1.json",
        "catalogs/attack-armor.duel-v1.json",
        "catalogs/items.duel-v1.json",
        "catalogs/neutrals.duel-v1.json",
        "catalogs/factions/vanguard-v1.json",
        "catalogs/factions/warhost-v1.json",
        "catalogs/factions/grove-v1.json",
        "catalogs/factions/crypt-v1.json",
        "maps/crossroads-duel-v1.json",
        "prompts/commander-system.v1.txt",
    )

    def __init__(self, root: Path | str | None = None) -> None:
        self.root = (
            Path(root)
            if root is not None
            else repository_root() / DEFAULT_PROTOCOL_RELATIVE_PATH
        )

    def path(self, relative_path: str | Path) -> Path:
        relative = Path(relative_path)
        if relative.is_absolute() or ".." in relative.parts:
            raise ProtocolPackageError(f"protocol path must be package-relative: {relative}")
        resolved = (self.root / relative).resolve()
        try:
            resolved.relative_to(self.root.resolve())
        except ValueError as exc:
            raise ProtocolPackageError(f"protocol path escapes package root: {relative}") from exc
        return resolved

    @property
    def version(self) -> str:
        version_path = self.path("VERSION")
        if not version_path.is_file():
            raise ProtocolPackageError(f"missing protocol VERSION: {version_path}")
        value = version_path.read_text(encoding="utf-8").strip()
        if value != DUEL_PROTOCOL_VERSION:
            raise ProtocolPackageError(
                f"unsupported Duel protocol version {value!r}; expected {DUEL_PROTOCOL_VERSION!r}"
            )
        return value

    def read_json(self, relative_path: str | Path) -> Any:
        artifact_path = self.path(relative_path)
        if not artifact_path.is_file():
            raise ProtocolPackageError(f"missing protocol JSON artifact: {relative_path}")
        try:
            return strict_json_loads(artifact_path.read_bytes())
        except ValueError as exc:
            raise ProtocolPackageError(f"invalid protocol JSON {relative_path}: {exc}") from exc

    def read_schema(self, name: str) -> dict[str, Any]:
        value = self.read_json(Path("schemas") / name)
        if not isinstance(value, dict):
            raise ProtocolPackageError(f"schema root must be an object: {name}")
        return value

    def read_catalog(self, name: str) -> dict[str, Any]:
        value = self.read_json(Path("catalogs") / name)
        if not isinstance(value, dict):
            raise ProtocolPackageError(f"catalog root must be an object: {name}")
        return value

    def assert_required_paths(self, *, require_lock: bool = False) -> None:
        if not self.root.is_dir():
            raise ProtocolPackageError(f"protocol package does not exist: {self.root}")
        missing = [
            relative for relative in self.REQUIRED_PATHS if not self.path(relative).is_file()
        ]
        if require_lock and not self.path(LOCK_FILENAME).is_file():
            missing.append(LOCK_FILENAME)
        if missing:
            formatted = ", ".join(sorted(missing))
            raise ProtocolPackageError(f"protocol package is incomplete; missing: {formatted}")
        _ = self.version

    def artifact_paths(self) -> list[Path]:
        """Return every lockable public artifact except the lock itself."""

        if not self.root.is_dir():
            raise ProtocolPackageError(f"protocol package does not exist: {self.root}")
        paths: list[Path] = []
        for candidate in self.root.rglob("*"):
            if not candidate.is_file() or candidate.name == LOCK_FILENAME:
                continue
            relative = candidate.relative_to(self.root)
            if any(part.startswith(".") or part == "__pycache__" for part in relative.parts):
                continue
            paths.append(candidate)
        return sorted(paths, key=lambda item: item.relative_to(self.root).as_posix())

    def artifact_digests(self) -> list[ArtifactDigest]:
        digests: list[ArtifactDigest] = []
        for artifact_path in self.artifact_paths():
            content = artifact_path.read_bytes()
            digests.append(
                ArtifactDigest(
                    path=artifact_path.relative_to(self.root).as_posix(),
                    size_bytes=len(content),
                    sha256=hashlib.sha256(content).hexdigest(),
                )
            )
        return digests

    def build_lock(self) -> dict[str, Any]:
        self.assert_required_paths(require_lock=False)
        artifact_values = [digest.as_dict() for digest in self.artifact_digests()]
        body: dict[str, Any] = {
            "artifacts": artifact_values,
            "canonicalization": "rfc8785-integer-nfc-subset-v1",
            "hash_algorithm": "sha256",
            "protocol_version": self.version,
        }
        return {**body, "package_sha256": canonical_sha256(body)}

    def lock_bytes(self) -> bytes:
        return canonical_json_bytes(self.build_lock()) + b"\n"

    def verify_lock(self) -> dict[str, Any]:
        self.assert_required_paths(require_lock=True)
        actual = self.build_lock()
        locked = self.read_json(LOCK_FILENAME)
        if not isinstance(locked, dict):
            raise ProtocolLockMismatch("protocol lock root must be an object")
        if locked != actual:
            locked_paths = _digest_map(locked.get("artifacts", []))
            actual_paths = _digest_map(actual.get("artifacts", []))
            details = _describe_digest_difference(locked_paths, actual_paths)
            if locked.get("package_sha256") != actual.get("package_sha256") and not details:
                details.append("package_sha256 differs")
            raise ProtocolLockMismatch("protocol lock mismatch: " + "; ".join(details))
        return actual


def _digest_map(values: Any) -> dict[str, tuple[int, str]]:
    if not isinstance(values, list):
        return {}
    result: dict[str, tuple[int, str]] = {}
    for value in values:
        if not isinstance(value, dict):
            continue
        path = value.get("path")
        size = value.get("size_bytes")
        sha = value.get("sha256")
        if isinstance(path, str) and isinstance(size, int) and isinstance(sha, str):
            result[path] = (size, sha)
    return result


def _describe_digest_difference(
    locked: dict[str, tuple[int, str]], actual: dict[str, tuple[int, str]]
) -> list[str]:
    details: list[str] = []
    for path in sorted(locked.keys() - actual.keys()):
        details.append(f"removed {path}")
    for path in sorted(actual.keys() - locked.keys()):
        details.append(f"unlocked {path}")
    for path in sorted(locked.keys() & actual.keys()):
        if locked[path] != actual[path]:
            details.append(f"changed {path}")
    return details


def iter_json_artifacts(package: ProtocolPackage) -> Iterable[tuple[str, Any]]:
    for artifact_path in package.artifact_paths():
        if artifact_path.suffix != ".json":
            continue
        relative = artifact_path.relative_to(package.root).as_posix()
        yield relative, package.read_json(relative)
