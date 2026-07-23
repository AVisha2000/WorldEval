"""Safe, dependency-free feature lifecycle primitives.

The implementation uses only the Python standard library so repository agents
can inspect and repair workflow state before the rest of the project is
installed.  JSON Schema files under ``features/schemas`` are the public
contracts; the checks below are the bootstrap validator for those contracts.
"""

from __future__ import annotations

import fnmatch
import hashlib
import json
import os
import re
import socket
import subprocess
import tempfile
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Iterator, Mapping, Sequence

LIFECYCLE_STATES = ("backlog", "in-progress", "implemented")
FEATURE_ID_PATTERN = re.compile(r"^WEV-[0-9]{4,}$")
SLUG_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
PRIORITIES = {"p0", "p1", "p2", "p3"}
RISKS = {"low", "medium", "high", "critical"}
PROOF_TYPES = {"artifact", "demo", "document", "metric", "replay", "review", "test"}
CHECK_NAMES = ("privacy", "secrets", "migration", "compatibility")
REQUIREMENT_NAMES = ("compatibility", "privacy", "migration", "rollback")
TRANSACTION_FILE = ".lifecycle-transaction.json"
FEATURE_SCHEMA_VERSION = "worldeval/feature/1.0.0"
CLAIM_SCHEMA_VERSION = "worldeval/feature-claim/1.0.0"
EVIDENCE_SCHEMA_VERSION = "worldeval/feature-evidence/1.0.0"
COMPLETION_SCHEMA_VERSION = "worldeval/feature-completion/1.0.0"


class FeatureWorkflowError(RuntimeError):
    """Raised when a lifecycle operation would violate workflow invariants."""


@dataclass(frozen=True)
class ValidationIssue:
    level: str
    code: str
    message: str
    path: str | None = None

    def as_dict(self) -> dict[str, Any]:
        value: dict[str, Any] = {
            "level": self.level,
            "code": self.code,
            "message": self.message,
        }
        if self.path is not None:
            value["path"] = self.path
        return value


@dataclass(frozen=True)
class FeatureRecord:
    feature_id: str
    state: str
    path: Path
    metadata: Mapping[str, Any]
    claim: Mapping[str, Any] | None = None

    def as_dict(self, now: datetime | None = None) -> dict[str, Any]:
        result: dict[str, Any] = {
            "id": self.feature_id,
            "state": self.state,
            "path": self.path.as_posix(),
            "title": self.metadata.get("title", ""),
            "priority": self.metadata.get("priority", ""),
            "risk": self.metadata.get("risk", ""),
            "dependencies": list(self.metadata.get("dependencies", [])),
        }
        if self.claim:
            current = now or datetime.now(timezone.utc)
            expires_at = _parse_datetime(str(self.claim.get("expires_at", "")))
            result["claim"] = {
                "owner": self.claim.get("owner"),
                "branch": self.claim.get("branch"),
                "work_state": self.claim.get("work_state"),
                "expires_at": self.claim.get("expires_at"),
                "expired": bool(expires_at and expires_at <= current),
            }
        return result


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _isoformat(value: datetime) -> str:
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _parse_datetime(value: str) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    if not slug:
        raise FeatureWorkflowError("title must contain at least one letter or number")
    return slug


def _canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n"
    ).encode("utf-8")


def _pretty_json_bytes(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _safe_relative_path(value: str) -> bool:
    if not value or "\\" in value:
        return False
    path = PurePosixPath(value)
    return not path.is_absolute() and all(part not in {"", ".", ".."} for part in path.parts)


def _paths_overlap(left: str, right: str) -> bool:
    """Conservatively determine whether two repository path scopes overlap."""

    def base(value: str) -> str:
        normalized = value.strip("/")
        wildcard = min(
            (normalized.find(token) for token in ("*", "?", "[") if token in normalized),
            default=len(normalized),
        )
        normalized = normalized[:wildcard].rstrip("/")
        return normalized

    left_base = base(left)
    right_base = base(right)
    if not left_base or not right_base:
        return True
    if left_base == right_base:
        return True
    if left_base.startswith(right_base + "/") or right_base.startswith(left_base + "/"):
        return True
    return fnmatch.fnmatch(left, right) or fnmatch.fnmatch(right, left)


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise FeatureWorkflowError(f"missing required file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise FeatureWorkflowError(f"invalid JSON in {path}: {exc}") from exc


def _atomic_write(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        if temporary.exists():
            temporary.unlink()


def _write_json(path: Path, value: Any) -> None:
    _atomic_write(path, _pretty_json_bytes(value))


def _fsync_directory(path: Path) -> None:
    try:
        descriptor = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(descriptor)
    except OSError:
        pass
    finally:
        os.close(descriptor)


class FeatureWorkspace:
    """Manage feature records rooted at a WorldEval checkout."""

    def __init__(
        self,
        root: str | os.PathLike[str] | None = None,
        *,
        now: Callable[[], datetime] | None = None,
        lease_hours: int = 24,
        native_replay_verifiers: Any = None,
    ) -> None:
        self.root = self._find_root(Path(root) if root is not None else Path.cwd())
        self.features_root = self.root / "features"
        self._now = now or _utc_now
        self.lease_hours = lease_hours
        self.native_replay_verifiers = native_replay_verifiers

    @staticmethod
    def _find_root(start: Path) -> Path:
        resolved = start.resolve()
        candidates = (resolved, *resolved.parents)
        for candidate in candidates:
            if (candidate / "worldeval.workspace.json").is_file():
                return candidate
        for candidate in candidates:
            if (candidate / ".git").exists() and (candidate / "features").exists():
                return candidate
        if (resolved / ".git").exists():
            return resolved
        raise FeatureWorkflowError(
            f"could not find repository root from {start}; "
            "expected worldeval.workspace.json or .git"
        )

    def ensure_layout(self) -> None:
        for name in (*LIFECYCLE_STATES, "schemas", "templates"):
            (self.features_root / name).mkdir(parents=True, exist_ok=True)

    def _git_dir(self) -> Path:
        marker = self.root / ".git"
        if marker.is_dir():
            return marker
        if marker.is_file():
            text = marker.read_text(encoding="utf-8").strip()
            if not text.startswith("gitdir:"):
                raise FeatureWorkflowError(f"unsupported git marker: {marker}")
            raw = text.split(":", 1)[1].strip()
            candidate = Path(raw)
            return (
                candidate.resolve()
                if candidate.is_absolute()
                else (self.root / candidate).resolve()
            )
        raise FeatureWorkflowError(
            f"feature operations require a git checkout: {marker} is missing"
        )

    @property
    def lock_directory(self) -> Path:
        return self._git_dir() / "worldeval-feature-locks"

    @contextmanager
    def _lock(self) -> Iterator[None]:
        self.lock_directory.mkdir(parents=True, exist_ok=True)
        lock_path = self.lock_directory / "workspace.lock"
        token = uuid.uuid4().hex
        payload = {
            "schema_version": "worldeval/feature-lock/1.0.0",
            "token": token,
            "pid": os.getpid(),
            "host": socket.gethostname(),
            "acquired_at": _isoformat(self._now()),
        }
        try:
            descriptor = os.open(lock_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError as exc:
            raise FeatureWorkflowError(
                f"feature workspace is locked at {lock_path}; run `worldeval feature doctor`"
            ) from exc
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(_canonical_json_bytes(payload))
                handle.flush()
                os.fsync(handle.fileno())
            yield
        finally:
            try:
                existing = _read_json(lock_path)
            except FeatureWorkflowError:
                existing = None
            if isinstance(existing, dict) and existing.get("token") == token:
                lock_path.unlink(missing_ok=True)
                _fsync_directory(lock_path.parent)

    def _git_output(self, *arguments: str) -> str | None:
        try:
            result = subprocess.run(
                ["git", *arguments],
                cwd=self.root,
                check=True,
                capture_output=True,
                text=True,
            )
        except (OSError, subprocess.CalledProcessError):
            return None
        return result.stdout.strip()

    def _head_revision(self) -> str | None:
        return self._git_output("rev-parse", "HEAD")

    def _current_branch(self) -> str | None:
        return self._git_output("branch", "--show-current")

    def _dirty_paths(self, paths: Sequence[str]) -> set[str]:
        if not paths:
            return set()
        changed = self._git_output("diff", "--name-only", "HEAD", "--", *paths)
        untracked = self._git_output("ls-files", "--others", "--exclude-standard", "--", *paths)
        values: set[str] = set()
        for output in (changed, untracked):
            if output:
                values.update(line for line in output.splitlines() if line)
        return values

    def _iter_feature_paths(self) -> Iterator[tuple[str, Path]]:
        for state in LIFECYCLE_STATES:
            state_root = self.features_root / state
            if not state_root.exists():
                continue
            for child in sorted(state_root.iterdir()):
                if child.is_dir() and not child.name.startswith("."):
                    yield state, child

    def _scan_features(self) -> tuple[list[FeatureRecord], list[ValidationIssue]]:
        records: list[FeatureRecord] = []
        issues: list[ValidationIssue] = []
        for state, path in self._iter_feature_paths():
            relative = path.relative_to(self.root).as_posix()
            metadata_path = path / "feature.json"
            if not metadata_path.is_file():
                issues.append(
                    ValidationIssue(
                        "error",
                        "missing-feature-json",
                        "lifecycle directory does not contain feature.json",
                        relative,
                    )
                )
                continue
            try:
                metadata = _read_json(metadata_path)
            except FeatureWorkflowError as exc:
                issues.append(ValidationIssue("error", "invalid-json", str(exc), relative))
                continue
            if not isinstance(metadata, dict):
                issues.append(
                    ValidationIssue(
                        "error",
                        "invalid-feature-json",
                        "feature.json must contain an object",
                        relative,
                    )
                )
                continue
            claim_path = path / "claim.json"
            claim = None
            if claim_path.is_file():
                try:
                    claim = _read_json(claim_path)
                except FeatureWorkflowError as exc:
                    issues.append(ValidationIssue("error", "invalid-json", str(exc), relative))
            records.append(
                FeatureRecord(
                    feature_id=str(metadata.get("id", path.name)),
                    state=state,
                    path=path,
                    metadata=metadata,
                    claim=claim if isinstance(claim, dict) else None,
                )
            )
        return sorted(records, key=lambda record: record.feature_id), issues

    def list_features(self) -> list[FeatureRecord]:
        records, issues = self._scan_features()
        if issues:
            raise FeatureWorkflowError("; ".join(issue.message for issue in issues))
        return records

    def _records_for(self, feature_id: str) -> list[FeatureRecord]:
        return [record for record in self.list_features() if record.feature_id == feature_id]

    def get(self, feature_id: str, *, state: str | None = None) -> FeatureRecord:
        records = self._records_for(feature_id)
        if state is not None:
            records = [record for record in records if record.state == state]
        if not records:
            qualifier = f" in {state}" if state else ""
            raise FeatureWorkflowError(f"feature {feature_id} was not found{qualifier}")
        if len(records) > 1:
            locations = ", ".join(str(record.path) for record in records)
            raise FeatureWorkflowError(f"feature {feature_id} is duplicated: {locations}")
        return records[0]

    def create(
        self,
        feature_id: str,
        *,
        title: str,
        summary: str,
        product: str = "worldeval",
        kind: str = "capability",
        priority: str = "p2",
        risk: str = "medium",
        dependencies: Sequence[str] = (),
        related_features: Sequence[str] = (),
        supersedes: Sequence[str] = (),
        in_scope: Sequence[str] = (),
        out_of_scope: Sequence[str] = (),
        affected_paths: Sequence[str] = (),
        shared_surfaces: Sequence[str] = (),
        acceptance_criteria: Sequence[Mapping[str, Any]] | None = None,
        required_approvals: Sequence[str] = (),
        compatibility: Sequence[str] = (),
        privacy: Sequence[str] = (),
        migration: Sequence[str] = (),
        rollback: Sequence[str] = (),
        slug: str | None = None,
    ) -> FeatureRecord:
        self.ensure_layout()
        normalized_slug = slug or _slugify(title)
        criteria = list(acceptance_criteria or ())
        if not criteria:
            criteria = [
                {
                    "id": f"{feature_id}-AC-01",
                    "description": "The implementation satisfies the documented feature plan.",
                    "proof_types": ["test"],
                    "demo_required": False,
                    "replay_required": False,
                }
            ]
        metadata = {
            "schema_version": FEATURE_SCHEMA_VERSION,
            "id": feature_id,
            "slug": normalized_slug,
            "title": title,
            "summary": summary,
            "product": product,
            "kind": kind,
            "priority": priority,
            "risk": risk,
            "dependencies": list(dependencies),
            "related_features": list(related_features),
            "supersedes": list(supersedes),
            "scope": {"in": list(in_scope), "out": list(out_of_scope)},
            "affected_paths": list(affected_paths),
            "exclusive_shared_surfaces": list(shared_surfaces),
            "acceptance_criteria": criteria,
            "required_approvals": list(required_approvals),
            "requirements": {
                "compatibility": list(compatibility),
                "privacy": list(privacy),
                "migration": list(migration),
                "rollback": list(rollback),
            },
        }
        issues = self._validate_metadata(metadata, Path("feature.json"))
        if issues:
            raise FeatureWorkflowError("; ".join(issue.message for issue in issues))

        with self._lock():
            if self._records_for(feature_id):
                raise FeatureWorkflowError(f"feature {feature_id} already exists")
            destination = self.features_root / "backlog" / f"{feature_id.lower()}-{normalized_slug}"
            if destination.exists():
                raise FeatureWorkflowError(f"feature destination already exists: {destination}")
            temporary = Path(
                tempfile.mkdtemp(prefix=f".{feature_id.lower()}-creating-", dir=destination.parent)
            )
            try:
                self._populate_new_feature(temporary, metadata)
                os.rename(temporary, destination)
                _fsync_directory(destination.parent)
            except Exception:
                # A populated staging directory is deliberately preserved for doctor/recovery.
                raise
        return self.get(feature_id, state="backlog")

    def _populate_new_feature(self, path: Path, metadata: Mapping[str, Any]) -> None:
        (path / "decisions").mkdir(parents=True, exist_ok=True)
        (path / "evidence").mkdir(parents=True, exist_ok=True)
        _write_json(path / "feature.json", metadata)
        title = str(metadata["title"])
        _atomic_write(
            path / "README.md",
            f"# {metadata['id']}: {title}\n\n{metadata['summary']}\n".encode(),
        )
        _atomic_write(
            path / "plan.md",
            (
                f"# Implementation plan: {title}\n\n"
                "## Intent\n\nDescribe the implementation boundary and decisions here.\n\n"
                "## Verification\n\nMap each acceptance criterion to reproducible evidence.\n"
            ).encode(),
        )
        _atomic_write(
            path / "progress.md",
            f"# Progress: {title}\n\n- Created: {_isoformat(self._now())}\n".encode(),
        )
        evidence = {
            "schema_version": EVIDENCE_SCHEMA_VERSION,
            "feature_id": metadata["id"],
            "criteria": {},
            "tests": [],
            "replays": [],
            "checks": {
                name: {"passed": False, "checked_at": None, "evidence": "not yet checked"}
                for name in CHECK_NAMES
            },
            "human_approvals": [],
        }
        _write_json(path / "evidence" / "manifest.json", evidence)

    def validate(self, feature_id: str | None = None) -> list[ValidationIssue]:
        all_records, issues = self._scan_features()
        records = all_records
        if feature_id is not None:
            records = [record for record in records if record.feature_id == feature_id]
            if not records:
                issues.append(
                    ValidationIssue("error", "not-found", f"feature {feature_id} was not found")
                )
                return issues

        by_id: dict[str, list[FeatureRecord]] = {}
        for record in all_records:
            by_id.setdefault(record.feature_id, []).append(record)
        for duplicated_id, duplicate_records in by_id.items():
            if len(duplicate_records) > 1 and (feature_id is None or feature_id == duplicated_id):
                issues.append(
                    ValidationIssue(
                        "error",
                        "duplicate-id",
                        f"{duplicated_id} exists in multiple lifecycle directories",
                    )
                )

        all_ids = set(by_id)
        for record in records:
            relative = record.path.relative_to(self.root)
            issues.extend(self._validate_record(record))
            for dependency in record.metadata.get("dependencies", []):
                if dependency not in all_ids:
                    issues.append(
                        ValidationIssue(
                            "error",
                            "missing-dependency",
                            f"dependency {dependency} does not exist",
                            str(relative / "feature.json"),
                        )
                    )
        if feature_id is None:
            issues.extend(self._validate_dependency_graph(by_id))
        return issues

    def _validate_metadata(self, value: Any, path: Path) -> list[ValidationIssue]:
        issues: list[ValidationIssue] = []

        def error(code: str, message: str) -> None:
            issues.append(ValidationIssue("error", code, message, path.as_posix()))

        if not isinstance(value, dict):
            error("schema", "feature.json must contain an object")
            return issues
        required = {
            "schema_version",
            "id",
            "slug",
            "title",
            "summary",
            "product",
            "kind",
            "priority",
            "risk",
            "dependencies",
            "related_features",
            "supersedes",
            "scope",
            "affected_paths",
            "exclusive_shared_surfaces",
            "acceptance_criteria",
            "required_approvals",
            "requirements",
        }
        for name in sorted(required - set(value)):
            error("schema", f"feature.json is missing {name}")
        for name in sorted(set(value) - required):
            error("schema", f"feature.json contains unsupported property {name}")
        if "status" in value:
            error(
                "duplicated-status",
                "feature.json must not contain status; directory placement is authoritative",
            )
        if value.get("schema_version") != FEATURE_SCHEMA_VERSION:
            error("schema-version", f"schema_version must be {FEATURE_SCHEMA_VERSION}")
        feature_id = value.get("id")
        if not isinstance(feature_id, str) or not FEATURE_ID_PATTERN.fullmatch(feature_id):
            error("feature-id", "id must match WEV-NNNN")
        slug = value.get("slug")
        if not isinstance(slug, str) or not SLUG_PATTERN.fullmatch(slug):
            error("slug", "slug must contain lowercase words separated by hyphens")
        for name in ("title", "summary", "product", "kind"):
            if not isinstance(value.get(name), str) or not str(value.get(name)).strip():
                error("schema", f"{name} must be a non-empty string")
        if value.get("priority") not in PRIORITIES:
            error("schema", f"priority must be one of {sorted(PRIORITIES)}")
        if value.get("risk") not in RISKS:
            error("schema", f"risk must be one of {sorted(RISKS)}")
        for name in (
            "dependencies",
            "related_features",
            "supersedes",
            "affected_paths",
            "exclusive_shared_surfaces",
            "required_approvals",
        ):
            item = value.get(name)
            if not isinstance(item, list) or any(not isinstance(entry, str) for entry in item):
                error("schema", f"{name} must be an array of strings")
            elif len(set(item)) != len(item):
                error("schema", f"{name} must not contain duplicates")
        approvals = value.get("required_approvals", [])
        if isinstance(approvals, list):
            for approval in approvals:
                if approval not in {"behavioral", "visual"}:
                    error("schema", f"unsupported human approval type: {approval}")
        for dependency_field in ("dependencies", "related_features", "supersedes"):
            entries = value.get(dependency_field, [])
            if isinstance(entries, list):
                for entry in entries:
                    if not isinstance(entry, str) or not FEATURE_ID_PATTERN.fullmatch(entry):
                        error("schema", f"{dependency_field} entries must match WEV-NNNN")
                    if entry == feature_id:
                        error(
                            "self-reference", f"{dependency_field} must not reference {feature_id}"
                        )
        for path_value in (
            value.get("affected_paths", []) if isinstance(value.get("affected_paths"), list) else []
        ):
            if isinstance(path_value, str) and not _safe_relative_path(path_value):
                error("unsafe-path", f"affected path is not repository-relative: {path_value}")
        scope = value.get("scope")
        if not isinstance(scope, dict) or any(
            not isinstance(scope.get(name), list)
            or any(not isinstance(entry, str) for entry in scope.get(name, []))
            for name in ("in", "out")
        ):
            error("schema", "scope must contain string arrays named in and out")
        requirements = value.get("requirements")
        if not isinstance(requirements, dict) or any(
            not isinstance(requirements.get(name), list)
            or any(not isinstance(entry, str) for entry in requirements.get(name, []))
            for name in REQUIREMENT_NAMES
        ):
            error(
                "schema", f"requirements must contain string arrays: {', '.join(REQUIREMENT_NAMES)}"
            )
        criteria = value.get("acceptance_criteria")
        if not isinstance(criteria, list) or not criteria:
            error("schema", "acceptance_criteria must contain at least one criterion")
        else:
            seen: set[str] = set()
            for index, criterion in enumerate(criteria):
                if not isinstance(criterion, dict):
                    error("schema", f"acceptance_criteria[{index}] must be an object")
                    continue
                criterion_id = criterion.get("id")
                if not isinstance(criterion_id, str) or not criterion_id.startswith(
                    f"{feature_id}-AC-"
                ):
                    error(
                        "criterion-id", f"acceptance criterion {index} must use {feature_id}-AC-NN"
                    )
                elif criterion_id in seen:
                    error("criterion-id", f"acceptance criterion {criterion_id} is duplicated")
                else:
                    seen.add(criterion_id)
                if (
                    not isinstance(criterion.get("description"), str)
                    or not criterion["description"].strip()
                ):
                    error("schema", f"acceptance criterion {index} needs a description")
                proof_types = criterion.get("proof_types")
                if (
                    not isinstance(proof_types, list)
                    or not proof_types
                    or any(proof not in PROOF_TYPES for proof in proof_types)
                ):
                    error(
                        "schema",
                        f"acceptance criterion {index} needs proof_types "
                        f"from {sorted(PROOF_TYPES)}",
                    )
                for flag in ("demo_required", "replay_required"):
                    if not isinstance(criterion.get(flag), bool):
                        error("schema", f"acceptance criterion {index} must define boolean {flag}")
        return issues

    def _validate_record(self, record: FeatureRecord) -> list[ValidationIssue]:
        relative = record.path.relative_to(self.root)
        issues = self._validate_metadata(record.metadata, relative / "feature.json")
        expected_directory = f"{record.feature_id.lower()}-{record.metadata.get('slug', '')}"
        if record.path.name != expected_directory:
            issues.append(
                ValidationIssue(
                    "error",
                    "directory-name",
                    f"directory must be named {expected_directory}",
                    relative.as_posix(),
                )
            )
        for required_path in (
            "README.md",
            "plan.md",
            "progress.md",
            "decisions",
            "evidence/manifest.json",
        ):
            if not (record.path / required_path).exists():
                issues.append(
                    ValidationIssue(
                        "error",
                        "missing-file",
                        f"missing required feature path {required_path}",
                        relative.as_posix(),
                    )
                )
        claim_exists = (record.path / "claim.json").is_file()
        completion_exists = (record.path / "completion.json").is_file()
        transaction_exists = (record.path / TRANSACTION_FILE).is_file()
        if record.state == "backlog" and claim_exists and not transaction_exists:
            issues.append(
                ValidationIssue(
                    "error",
                    "stray-claim",
                    "backlog feature must not contain claim.json",
                    relative.as_posix(),
                )
            )
        if record.state == "backlog" and completion_exists:
            issues.append(
                ValidationIssue(
                    "error",
                    "stray-completion",
                    "backlog feature must not contain completion.json",
                    relative.as_posix(),
                )
            )
        if record.state == "in-progress" and not claim_exists:
            issues.append(
                ValidationIssue(
                    "error",
                    "missing-claim",
                    "in-progress feature requires claim.json",
                    relative.as_posix(),
                )
            )
        if record.state == "in-progress" and completion_exists and not transaction_exists:
            issues.append(
                ValidationIssue(
                    "error",
                    "early-completion",
                    "in-progress feature must not contain completion.json",
                    relative.as_posix(),
                )
            )
        if record.state == "implemented" and not completion_exists:
            issues.append(
                ValidationIssue(
                    "error",
                    "missing-completion",
                    "implemented feature requires completion.json",
                    relative.as_posix(),
                )
            )
        if record.state == "implemented" and claim_exists and not transaction_exists:
            issues.append(
                ValidationIssue(
                    "error",
                    "stray-claim",
                    "implemented feature must not contain claim.json",
                    relative.as_posix(),
                )
            )
        evidence_path = record.path / "evidence" / "manifest.json"
        if evidence_path.is_file():
            try:
                evidence = _read_json(evidence_path)
            except FeatureWorkflowError as exc:
                issues.append(
                    ValidationIssue("error", "invalid-evidence", str(exc), relative.as_posix())
                )
            else:
                if (
                    not isinstance(evidence, dict)
                    or evidence.get("feature_id") != record.feature_id
                ):
                    issues.append(
                        ValidationIssue(
                            "error",
                            "invalid-evidence",
                            "evidence manifest feature_id must match feature.json",
                            (relative / "evidence/manifest.json").as_posix(),
                        )
                    )
                elif evidence.get("schema_version") != EVIDENCE_SCHEMA_VERSION:
                    issues.append(
                        ValidationIssue(
                            "error",
                            "schema-version",
                            f"evidence schema_version must be {EVIDENCE_SCHEMA_VERSION}",
                            (relative / "evidence/manifest.json").as_posix(),
                        )
                    )
                else:
                    issues.extend(self._validate_evidence_manifest(evidence, record))
        if claim_exists:
            try:
                claim = _read_json(record.path / "claim.json")
            except FeatureWorkflowError as exc:
                issues.append(
                    ValidationIssue("error", "invalid-claim", str(exc), relative.as_posix())
                )
            else:
                issues.extend(self._validate_claim(claim, record))
                expires_at = _parse_datetime(str(claim.get("expires_at", "")))
                if expires_at is not None and expires_at <= self._now():
                    issues.append(
                        ValidationIssue(
                            "warning",
                            "expired-claim",
                            (
                                "claim lease has expired; inspect the preserved revision "
                                "before reclaiming"
                            ),
                            (relative / "claim.json").as_posix(),
                        )
                    )
        if completion_exists:
            try:
                completion = _read_json(record.path / "completion.json")
            except FeatureWorkflowError as exc:
                issues.append(
                    ValidationIssue("error", "invalid-completion", str(exc), relative.as_posix())
                )
            else:
                issues.extend(self._validate_completion(completion, record))
        return issues

    def _validate_evidence_manifest(
        self, evidence: Mapping[str, Any], record: FeatureRecord
    ) -> list[ValidationIssue]:
        path = (record.path.relative_to(self.root) / "evidence/manifest.json").as_posix()
        issues: list[ValidationIssue] = []
        required = {
            "schema_version",
            "feature_id",
            "criteria",
            "tests",
            "replays",
            "checks",
            "human_approvals",
        }
        for name in sorted(required - set(evidence)):
            issues.append(
                ValidationIssue("error", "invalid-evidence", f"evidence is missing {name}", path)
            )
        for name in sorted(set(evidence) - required):
            issues.append(
                ValidationIssue(
                    "error",
                    "invalid-evidence",
                    f"evidence contains unsupported property {name}",
                    path,
                )
            )
        for name in ("tests", "replays", "human_approvals"):
            if not isinstance(evidence.get(name), list):
                issues.append(
                    ValidationIssue(
                        "error", "invalid-evidence", f"evidence {name} must be an array", path
                    )
                )
        if not isinstance(evidence.get("criteria"), dict):
            issues.append(
                ValidationIssue(
                    "error", "invalid-evidence", "evidence criteria must be an object", path
                )
            )
        checks = evidence.get("checks")
        if not isinstance(checks, dict) or set(checks) != set(CHECK_NAMES):
            issues.append(
                ValidationIssue(
                    "error",
                    "invalid-evidence",
                    f"evidence checks must be exactly {', '.join(CHECK_NAMES)}",
                    path,
                )
            )
        return issues

    def _validate_claim(self, claim: Any, record: FeatureRecord) -> list[ValidationIssue]:
        path = (record.path.relative_to(self.root) / "claim.json").as_posix()
        issues: list[ValidationIssue] = []
        if not isinstance(claim, dict):
            return [
                ValidationIssue("error", "invalid-claim", "claim.json must contain an object", path)
            ]
        required = {
            "schema_version",
            "feature_id",
            "owner",
            "collaborators",
            "branch",
            "base_revision",
            "task_id",
            "affected_paths",
            "exclusive_shared_surfaces",
            "claimed_at",
            "renewed_at",
            "expires_at",
            "work_state",
            "blockers",
            "reclaim_history",
        }
        for name in sorted(required - set(claim)):
            issues.append(
                ValidationIssue("error", "invalid-claim", f"claim is missing {name}", path)
            )
        allowed = {*required, "ready_at"}
        for name in sorted(set(claim) - allowed):
            issues.append(
                ValidationIssue(
                    "error", "invalid-claim", f"claim contains unsupported property {name}", path
                )
            )
        if claim.get("schema_version") != CLAIM_SCHEMA_VERSION:
            issues.append(
                ValidationIssue("error", "schema-version", "unsupported claim schema_version", path)
            )
        if claim.get("feature_id") != record.feature_id:
            issues.append(
                ValidationIssue("error", "invalid-claim", "claim feature_id does not match", path)
            )
        if claim.get("affected_paths") != record.metadata.get("affected_paths"):
            issues.append(
                ValidationIssue(
                    "error",
                    "invalid-claim",
                    "claim affected_paths do not match feature scope",
                    path,
                )
            )
        if claim.get("exclusive_shared_surfaces") != record.metadata.get(
            "exclusive_shared_surfaces"
        ):
            issues.append(
                ValidationIssue(
                    "error",
                    "invalid-claim",
                    "claim shared surfaces do not match feature scope",
                    path,
                )
            )
        for field in ("owner", "branch", "base_revision", "claimed_at", "renewed_at", "expires_at"):
            if not isinstance(claim.get(field), str) or not claim[field]:
                issues.append(
                    ValidationIssue(
                        "error", "invalid-claim", f"claim {field} must be a string", path
                    )
                )
        if isinstance(claim.get("branch"), str) and not claim["branch"].startswith("codex/"):
            issues.append(
                ValidationIssue(
                    "error", "invalid-claim", "claim branch must use the codex/ prefix", path
                )
            )
        for field in ("claimed_at", "renewed_at", "expires_at"):
            if isinstance(claim.get(field), str) and _parse_datetime(claim[field]) is None:
                issues.append(
                    ValidationIssue(
                        "error", "invalid-claim", f"claim {field} is not ISO-8601", path
                    )
                )
        if "ready_at" in claim and _parse_datetime(str(claim.get("ready_at", ""))) is None:
            issues.append(
                ValidationIssue("error", "invalid-claim", "claim ready_at is not ISO-8601", path)
            )
        renewed_at = _parse_datetime(str(claim.get("renewed_at", "")))
        expires_at = _parse_datetime(str(claim.get("expires_at", "")))
        if renewed_at and expires_at and expires_at <= renewed_at:
            issues.append(
                ValidationIssue(
                    "error", "invalid-claim", "claim expires_at must follow renewed_at", path
                )
            )
        if claim.get("work_state") not in {"active", "blocked", "ready"}:
            issues.append(
                ValidationIssue("error", "invalid-claim", "invalid claim work_state", path)
            )
        for field in (
            "collaborators",
            "affected_paths",
            "exclusive_shared_surfaces",
            "blockers",
            "reclaim_history",
        ):
            if not isinstance(claim.get(field), list):
                issues.append(
                    ValidationIssue(
                        "error", "invalid-claim", f"claim {field} must be an array", path
                    )
                )
        return issues

    def _validate_completion(self, completion: Any, record: FeatureRecord) -> list[ValidationIssue]:
        path = (record.path.relative_to(self.root) / "completion.json").as_posix()
        issues: list[ValidationIssue] = []
        if not isinstance(completion, dict):
            return [
                ValidationIssue(
                    "error", "invalid-completion", "completion.json must contain an object", path
                )
            ]
        required = {
            "schema_version",
            "feature_id",
            "completed_at",
            "completed_by",
            "implementation_revision",
            "base_revision",
            "evidence_manifest_sha256",
            "acceptance_criteria",
            "verified_replay_count",
            "checks",
        }
        for name in sorted(required - set(completion)):
            issues.append(
                ValidationIssue(
                    "error", "invalid-completion", f"completion is missing {name}", path
                )
            )
        for name in sorted(set(completion) - required):
            issues.append(
                ValidationIssue(
                    "error",
                    "invalid-completion",
                    f"completion contains unsupported property {name}",
                    path,
                )
            )
        if completion.get("schema_version") != COMPLETION_SCHEMA_VERSION:
            issues.append(
                ValidationIssue(
                    "error", "schema-version", "unsupported completion schema_version", path
                )
            )
        if completion.get("feature_id") != record.feature_id:
            issues.append(
                ValidationIssue(
                    "error", "invalid-completion", "completion feature_id does not match", path
                )
            )
        if not _parse_datetime(str(completion.get("completed_at", ""))):
            issues.append(
                ValidationIssue(
                    "error", "invalid-completion", "completed_at must be ISO-8601", path
                )
            )
        expected_criteria = [
            criterion["id"] for criterion in record.metadata.get("acceptance_criteria", [])
        ]
        if completion.get("acceptance_criteria") != expected_criteria:
            issues.append(
                ValidationIssue(
                    "error",
                    "invalid-completion",
                    "completion acceptance criteria do not match feature.json",
                    path,
                )
            )
        evidence_path = record.path / "evidence" / "manifest.json"
        if evidence_path.is_file() and completion.get("evidence_manifest_sha256") != _sha256(
            evidence_path
        ):
            issues.append(
                ValidationIssue(
                    "error",
                    "invalid-completion",
                    "completion evidence manifest hash does not match",
                    path,
                )
            )
        checks = completion.get("checks")
        if not isinstance(checks, dict) or checks != {name: True for name in CHECK_NAMES}:
            issues.append(
                ValidationIssue(
                    "error", "invalid-completion", "completion checks must all be true", path
                )
            )
        return issues

    def _validate_dependency_graph(
        self, by_id: Mapping[str, list[FeatureRecord]]
    ) -> list[ValidationIssue]:
        issues: list[ValidationIssue] = []
        visiting: set[str] = set()
        visited: set[str] = set()

        def visit(feature_id: str, stack: list[str]) -> None:
            if feature_id in visiting:
                cycle_start = stack.index(feature_id) if feature_id in stack else 0
                cycle = " -> ".join([*stack[cycle_start:], feature_id])
                issues.append(
                    ValidationIssue("error", "dependency-cycle", f"dependency cycle: {cycle}")
                )
                return
            if feature_id in visited or feature_id not in by_id or len(by_id[feature_id]) != 1:
                return
            visiting.add(feature_id)
            stack.append(feature_id)
            for dependency in by_id[feature_id][0].metadata.get("dependencies", []):
                visit(dependency, stack)
            stack.pop()
            visiting.remove(feature_id)
            visited.add(feature_id)

        for feature_id in sorted(by_id):
            visit(feature_id, [])
        return issues

    def _assert_valid_feature(self, feature_id: str) -> FeatureRecord:
        record = self.get(feature_id)
        errors = [issue for issue in self._validate_record(record) if issue.level == "error"]
        if errors:
            raise FeatureWorkflowError("; ".join(issue.message for issue in errors))
        return record

    def _assert_dependencies_implemented(self, record: FeatureRecord) -> None:
        for dependency in record.metadata.get("dependencies", []):
            dependency_records = self._records_for(dependency)
            if len(dependency_records) != 1 or dependency_records[0].state != "implemented":
                raise FeatureWorkflowError(
                    f"feature {record.feature_id} requires implemented dependency {dependency}"
                )

    def _assert_no_claim_collision(self, record: FeatureRecord) -> None:
        requested_paths = list(record.metadata.get("affected_paths", []))
        requested_surfaces = set(record.metadata.get("exclusive_shared_surfaces", []))
        for other in self.list_features():
            if other.state != "in-progress" or other.feature_id == record.feature_id:
                continue
            other_paths = list(
                (other.claim or {}).get("affected_paths", other.metadata.get("affected_paths", []))
            )
            for left in requested_paths:
                for right in other_paths:
                    if _paths_overlap(left, right):
                        raise FeatureWorkflowError(
                            f"affected path {left!r} overlaps active "
                            f"{other.feature_id} scope {right!r}"
                        )
            other_surfaces = set(
                (other.claim or {}).get(
                    "exclusive_shared_surfaces", other.metadata.get("exclusive_shared_surfaces", [])
                )
            )
            collision = sorted(requested_surfaces & other_surfaces)
            if collision:
                raise FeatureWorkflowError(
                    f"shared surface collision with {other.feature_id}: {', '.join(collision)}"
                )

    def claim(
        self,
        feature_id: str,
        *,
        owner: str,
        collaborators: Sequence[str] = (),
        branch: str | None = None,
        task_id: str | None = None,
        lease_hours: int | None = None,
    ) -> FeatureRecord:
        self.ensure_layout()
        if not owner.strip():
            raise FeatureWorkflowError("claim owner must be non-empty")
        with self._lock():
            record = self._assert_valid_feature(feature_id)
            if record.state != "backlog":
                raise FeatureWorkflowError(f"feature {feature_id} is {record.state}, not backlog")
            self._assert_dependencies_implemented(record)
            self._assert_no_claim_collision(record)
            now = self._now()
            duration = lease_hours if lease_hours is not None else self.lease_hours
            if duration <= 0:
                raise FeatureWorkflowError("lease hours must be positive")
            claim = {
                "schema_version": CLAIM_SCHEMA_VERSION,
                "feature_id": feature_id,
                "owner": owner,
                "collaborators": sorted(set(collaborators)),
                "branch": branch or f"codex/{feature_id.lower()}-{record.metadata['slug']}",
                "base_revision": self._head_revision() or "unavailable",
                "task_id": task_id,
                "affected_paths": list(record.metadata.get("affected_paths", [])),
                "exclusive_shared_surfaces": list(
                    record.metadata.get("exclusive_shared_surfaces", [])
                ),
                "claimed_at": _isoformat(now),
                "renewed_at": _isoformat(now),
                "expires_at": _isoformat(now + timedelta(hours=duration)),
                "work_state": "active",
                "blockers": [],
                "reclaim_history": [],
            }
            claim_issues = self._validate_claim(claim, record)
            if claim_issues:
                raise FeatureWorkflowError("; ".join(issue.message for issue in claim_issues))
            self._transition(record, "in-progress", "claim", {"claim": claim})
        return self.get(feature_id, state="in-progress")

    def _require_actor(self, claim: Mapping[str, Any], actor: str) -> None:
        allowed = {claim.get("owner"), *claim.get("collaborators", [])}
        if actor not in allowed:
            raise FeatureWorkflowError(f"{actor!r} is not the claim owner or a collaborator")

    def renew(
        self, feature_id: str, *, actor: str, lease_hours: int | None = None
    ) -> FeatureRecord:
        with self._lock():
            record = self.get(feature_id, state="in-progress")
            claim = dict(_read_json(record.path / "claim.json"))
            self._require_actor(claim, actor)
            duration = lease_hours if lease_hours is not None else self.lease_hours
            if duration <= 0:
                raise FeatureWorkflowError("lease hours must be positive")
            now = self._now()
            claim["renewed_at"] = _isoformat(now)
            claim["expires_at"] = _isoformat(now + timedelta(hours=duration))
            _write_json(record.path / "claim.json", claim)
        return self.get(feature_id, state="in-progress")

    def block(
        self,
        feature_id: str,
        *,
        actor: str,
        reason: str,
        next_action: str,
        lease_hours: int | None = None,
    ) -> FeatureRecord:
        if not reason.strip() or not next_action.strip():
            raise FeatureWorkflowError("block reason and next action must be non-empty")
        with self._lock():
            record = self.get(feature_id, state="in-progress")
            claim = dict(_read_json(record.path / "claim.json"))
            self._require_actor(claim, actor)
            blockers = list(claim.get("blockers", []))
            blocker_id = f"BLOCK-{len(blockers) + 1:03d}"
            now = self._now()
            blockers.append(
                {
                    "id": blocker_id,
                    "reason": reason,
                    "next_action": next_action,
                    "created_at": _isoformat(now),
                    "resolved_at": None,
                }
            )
            duration = lease_hours if lease_hours is not None else self.lease_hours
            if duration <= 0:
                raise FeatureWorkflowError("lease hours must be positive")
            claim.update(
                {
                    "work_state": "blocked",
                    "blockers": blockers,
                    "renewed_at": _isoformat(now),
                    "expires_at": _isoformat(now + timedelta(hours=duration)),
                }
            )
            claim.pop("ready_at", None)
            _write_json(record.path / "claim.json", claim)
            self._append_progress(
                record.path,
                f"Blocked by {actor}: {reason}. Next action: {next_action}.",
            )
        return self.get(feature_id, state="in-progress")

    def ready(
        self,
        feature_id: str,
        *,
        actor: str,
        resolve_blockers: bool = False,
    ) -> FeatureRecord:
        with self._lock():
            record = self.get(feature_id, state="in-progress")
            claim = dict(_read_json(record.path / "claim.json"))
            self._require_actor(claim, actor)
            if resolve_blockers:
                resolved_at = _isoformat(self._now())
                claim["blockers"] = [
                    {**blocker, "resolved_at": blocker.get("resolved_at") or resolved_at}
                    for blocker in claim.get("blockers", [])
                ]
                claim["work_state"] = "active"
            issues = self._completion_issues(record, claim, check_git=True)
            if issues:
                raise FeatureWorkflowError("feature is not ready: " + "; ".join(issues))
            claim["work_state"] = "ready"
            claim["ready_at"] = _isoformat(self._now())
            _write_json(record.path / "claim.json", claim)
            self._append_progress(record.path, f"Completion evidence marked ready by {actor}.")
        return self.get(feature_id, state="in-progress")

    def release(self, feature_id: str, *, actor: str, reason: str) -> FeatureRecord:
        if not reason.strip():
            raise FeatureWorkflowError("release reason must be non-empty")
        with self._lock():
            record = self.get(feature_id, state="in-progress")
            claim = dict(_read_json(record.path / "claim.json"))
            self._require_actor(claim, actor)
            self._append_progress(record.path, f"Claim released by {actor}: {reason}")
            self._transition(record, "backlog", "release", {"reason": reason, "actor": actor})
        return self.get(feature_id, state="backlog")

    def reclaim(
        self,
        feature_id: str,
        *,
        owner: str,
        inspected_revision: str,
        collaborators: Sequence[str] = (),
        branch: str | None = None,
        task_id: str | None = None,
        lease_hours: int | None = None,
    ) -> FeatureRecord:
        if not owner.strip():
            raise FeatureWorkflowError("reclaim owner must be non-empty")
        with self._lock():
            record = self.get(feature_id, state="in-progress")
            claim = dict(_read_json(record.path / "claim.json"))
            expires_at = _parse_datetime(str(claim.get("expires_at", "")))
            if expires_at is None or expires_at > self._now():
                raise FeatureWorkflowError("claim has not expired and cannot be reclaimed")
            if not inspected_revision.strip():
                raise FeatureWorkflowError(
                    "reclaim requires the preserved revision that was inspected"
                )
            self._assert_no_claim_collision(record)
            now = self._now()
            duration = lease_hours if lease_hours is not None else self.lease_hours
            if duration <= 0:
                raise FeatureWorkflowError("lease hours must be positive")
            history = list(claim.get("reclaim_history", []))
            history.append(
                {
                    "previous_owner": claim.get("owner"),
                    "previous_branch": claim.get("branch"),
                    "previous_expires_at": claim.get("expires_at"),
                    "inspected_revision": inspected_revision,
                    "reclaimed_at": _isoformat(now),
                    "reclaimed_by": owner,
                }
            )
            claim.update(
                {
                    "owner": owner,
                    "collaborators": sorted(set(collaborators)),
                    "branch": branch or f"codex/{feature_id.lower()}-{record.metadata['slug']}",
                    "base_revision": inspected_revision,
                    "task_id": task_id,
                    "claimed_at": _isoformat(now),
                    "renewed_at": _isoformat(now),
                    "expires_at": _isoformat(now + timedelta(hours=duration)),
                    "work_state": "blocked"
                    if any(not blocker.get("resolved_at") for blocker in claim.get("blockers", []))
                    else "active",
                    "reclaim_history": history,
                }
            )
            claim.pop("ready_at", None)
            claim_issues = self._validate_claim(claim, record)
            if claim_issues:
                raise FeatureWorkflowError("; ".join(issue.message for issue in claim_issues))
            _write_json(record.path / "claim.json", claim)
            self._append_progress(
                record.path,
                f"Expired claim reclaimed by {owner} after inspecting {inspected_revision}.",
            )
        return self.get(feature_id, state="in-progress")

    def complete(self, feature_id: str, *, actor: str) -> FeatureRecord:
        with self._lock():
            record = self.get(feature_id, state="in-progress")
            claim = dict(_read_json(record.path / "claim.json"))
            self._require_actor(claim, actor)
            issues = self._completion_issues(record, claim, check_git=True)
            if issues:
                raise FeatureWorkflowError("feature cannot be completed: " + "; ".join(issues))
            evidence_path = record.path / "evidence" / "manifest.json"
            head = self._head_revision()
            evidence = _read_json(evidence_path)
            completion = {
                "schema_version": COMPLETION_SCHEMA_VERSION,
                "feature_id": feature_id,
                "completed_at": _isoformat(self._now()),
                "completed_by": actor,
                "implementation_revision": head,
                "base_revision": claim.get("base_revision"),
                "evidence_manifest_sha256": _sha256(evidence_path),
                "acceptance_criteria": [
                    criterion["id"] for criterion in record.metadata.get("acceptance_criteria", [])
                ],
                "verified_replay_count": sum(
                    1 for replay in evidence.get("replays", []) if replay.get("verified") is True
                ),
                "checks": {name: True for name in CHECK_NAMES},
            }
            self._append_progress(record.path, f"Feature completed by {actor} at revision {head}.")
            self._transition(record, "implemented", "complete", {"completion": completion})
        return self.get(feature_id, state="implemented")

    def _completion_issues(
        self,
        record: FeatureRecord,
        claim: Mapping[str, Any],
        *,
        check_git: bool,
    ) -> list[str]:
        issues: list[str] = []
        structural = [
            issue.message for issue in self._validate_record(record) if issue.level == "error"
        ]
        issues.extend(structural)
        expires_at = _parse_datetime(str(claim.get("expires_at", "")))
        if expires_at is None or expires_at <= self._now():
            issues.append("claim is expired")
        unresolved = [
            blocker for blocker in claim.get("blockers", []) if not blocker.get("resolved_at")
        ]
        if unresolved:
            issues.append("claim has unresolved blockers")
        if claim.get("work_state") == "blocked":
            issues.append("claim is blocked")

        evidence_path = record.path / "evidence" / "manifest.json"
        try:
            evidence = _read_json(evidence_path)
        except FeatureWorkflowError as exc:
            issues.append(str(exc))
            return issues
        if (
            not isinstance(evidence, dict)
            or evidence.get("schema_version") != EVIDENCE_SCHEMA_VERSION
        ):
            issues.append("evidence manifest has an unsupported schema_version")
            return issues
        if evidence.get("feature_id") != record.feature_id:
            issues.append("evidence manifest feature_id does not match")

        criteria_evidence = evidence.get("criteria")
        if not isinstance(criteria_evidence, dict):
            issues.append("evidence criteria must be an object")
            criteria_evidence = {}
        for criterion in record.metadata.get("acceptance_criteria", []):
            criterion_id = criterion["id"]
            entries = criteria_evidence.get(criterion_id, [])
            if not isinstance(entries, list) or not entries:
                issues.append(f"{criterion_id} has no evidence")
                continue
            verified_types = {
                entry.get("type")
                for entry in entries
                if isinstance(entry, dict) and entry.get("verified") is True
            }
            for proof_type in criterion.get("proof_types", []):
                if proof_type not in verified_types:
                    issues.append(f"{criterion_id} lacks verified {proof_type} evidence")
            if criterion.get("demo_required") and "demo" not in verified_types:
                issues.append(f"{criterion_id} requires a verified demo")
            if criterion.get("replay_required") and "replay" not in verified_types:
                issues.append(f"{criterion_id} requires verified replay evidence")
            for entry in entries if isinstance(entries, list) else []:
                if not isinstance(entry, dict) or entry.get("verified") is not True:
                    continue
                artifact_path = entry.get("path")
                if entry.get("type") == "replay":
                    issues.extend(
                        self._verify_replay_evidence(artifact_path, entry.get("sha256"))
                    )
                else:
                    issues.extend(self._verify_evidence_file(artifact_path, entry.get("sha256")))

        tests = evidence.get("tests")
        if not isinstance(tests, list) or not tests:
            issues.append("at least one recorded test is required")
        else:
            for index, test in enumerate(tests):
                if not isinstance(test, dict):
                    issues.append(f"test record {index} must be an object")
                    continue
                if (
                    not test.get("command")
                    or test.get("exit_code") != 0
                    or not _parse_datetime(str(test.get("timestamp", "")))
                ):
                    issues.append(
                        f"test record {index} needs command, zero exit_code, and timestamp"
                    )
                if not test.get("report_path") or not test.get("report_sha256"):
                    issues.append(
                        f"test record {index} needs a hashed, persisted report_path"
                    )
                else:
                    issues.extend(
                        self._verify_evidence_file(
                            test.get("report_path"),
                            test.get("report_sha256"),
                        )
                    )

        replay_required = any(
            criterion.get("replay_required")
            for criterion in record.metadata.get("acceptance_criteria", [])
        )
        replays = evidence.get("replays")
        if replay_required and (
            not isinstance(replays, list)
            or not any(replay.get("verified") is True for replay in replays)
        ):
            issues.append("a verified replay bundle is required")
        if isinstance(replays, list):
            for replay in replays:
                if isinstance(replay, dict) and replay.get("verified") is True:
                    issues.extend(
                        self._verify_replay_evidence(
                            replay.get("path"), replay.get("sha256")
                        )
                    )

        checks = evidence.get("checks")
        for check_name in CHECK_NAMES:
            check = checks.get(check_name) if isinstance(checks, dict) else None
            if not isinstance(check, dict) or check.get("passed") is not True:
                issues.append(f"{check_name} check has not passed")
            elif not _parse_datetime(str(check.get("checked_at", ""))) or not check.get("evidence"):
                issues.append(f"{check_name} check needs a timestamp and evidence")

        required_approvals = set(record.metadata.get("required_approvals", []))
        if any(
            criterion.get("demo_required")
            for criterion in record.metadata.get("acceptance_criteria", [])
        ):
            required_approvals.add("behavioral")
        if record.metadata.get("kind") in {"behavioral", "visual"}:
            required_approvals.add(str(record.metadata["kind"]))
        approvals = evidence.get("human_approvals", [])
        approved_types = {
            approval.get("type")
            for approval in approvals
            if isinstance(approval, dict)
            and approval.get("approved") is True
            and approval.get("by")
            and _parse_datetime(str(approval.get("at", "")))
        }
        for approval_type in sorted(required_approvals - approved_types):
            issues.append(f"missing recorded {approval_type} human approval")

        if check_git:
            head = self._head_revision()
            current_branch = self._current_branch()
            if not head:
                issues.append("git HEAD is unavailable")
            elif head == claim.get("base_revision"):
                issues.append("implementation must be committed after the claim base revision")
            if current_branch != claim.get("branch"):
                issues.append(
                    f"checkout branch {current_branch!r} does not match claim branch "
                    f"{claim.get('branch')!r}"
                )
            affected_paths = list(record.metadata.get("affected_paths", []))
            literal_paths = [
                path for path in affected_paths if not any(char in path for char in "*?[")
            ]
            feature_path = record.path.relative_to(self.root).as_posix()
            committed_paths = [*literal_paths, feature_path]
            if committed_paths:
                dirty = self._dirty_paths(committed_paths)
                allowed_ready_changes: set[str] = set()
                if claim.get("work_state") == "ready":
                    allowed_ready_changes = {
                        f"{feature_path}/claim.json",
                        f"{feature_path}/progress.md",
                    }
                if dirty - allowed_ready_changes:
                    issues.append(
                        "feature evidence or affected implementation paths contain "
                        "uncommitted changes"
                    )
        return issues

    def _verify_evidence_file(self, value: Any, expected_sha256: Any) -> list[str]:
        if not isinstance(value, str) or not _safe_relative_path(value):
            return [f"evidence path is unsafe: {value!r}"]
        if (
            not isinstance(expected_sha256, str)
            or re.fullmatch(r"[a-f0-9]{64}", expected_sha256) is None
        ):
            return [f"evidence needs an exact SHA-256: {value}"]
        path = self.root / value
        try:
            resolved = path.resolve(strict=True)
        except FileNotFoundError:
            return [f"evidence file does not exist: {value}"]
        if self.root.resolve() not in resolved.parents and resolved != self.root.resolve():
            return [f"evidence path escapes the repository: {value}"]
        if path.is_symlink() or not path.is_file():
            return [f"evidence must be a regular non-symlink file: {value}"]
        if _sha256(path) != expected_sha256:
            return [f"evidence hash mismatch: {value}"]
        return []

    def _verify_replay_evidence(self, value: Any, expected_sha256: Any) -> list[str]:
        if not isinstance(value, str) or not _safe_relative_path(value):
            return [f"replay evidence path is unsafe: {value!r}"]
        if (
            not isinstance(expected_sha256, str)
            or re.fullmatch(r"[a-f0-9]{64}", expected_sha256) is None
        ):
            return [f"replay evidence needs an exact manifest SHA-256: {value}"]
        selected = self.root / value
        bundle = selected.parent if selected.name == "manifest.json" else selected
        try:
            resolved = bundle.resolve(strict=True)
        except FileNotFoundError:
            return [f"replay bundle does not exist: {value}"]
        root = self.root.resolve()
        if root not in resolved.parents and resolved != root:
            return [f"replay bundle escapes the repository: {value}"]
        manifest = bundle / "manifest.json"
        if (
            bundle.is_symlink()
            or not bundle.is_dir()
            or manifest.is_symlink()
            or not manifest.is_file()
        ):
            return [f"replay evidence must name an immutable bundle directory: {value}"]
        if _sha256(manifest) != expected_sha256:
            return [f"replay manifest hash mismatch: {value}"]
        if self.native_replay_verifiers is None:
            return ["native replay verifier registry is unavailable"]
        try:
            from worldeval.replay import verify_replay_bundle

            report = verify_replay_bundle(
                bundle,
                native_verifiers=self.native_replay_verifiers,
                require_native_verification=True,
                require_provider_calls_zero=True,
                require_claim_binding=True,
            )
        except Exception as exc:
            return [f"replay bundle failed independent verification: {value}: {exc}"]
        for descriptor in report.manifest.get("artifacts", []):
            if descriptor.get("kind") != "replay":
                continue
            identity = f"{descriptor.get('role', '')} {descriptor.get('native_schema', '')}"
            if "presentation_script" in identity:
                return [f"presentation script cannot satisfy replay evidence: {value}"]
        return []

    def _append_progress(self, feature_path: Path, message: str) -> None:
        progress_path = feature_path / "progress.md"
        existing = (
            progress_path.read_text(encoding="utf-8") if progress_path.exists() else "# Progress\n"
        )
        line = f"\n- {_isoformat(self._now())}: {message}\n"
        _atomic_write(progress_path, (existing.rstrip() + line).encode("utf-8"))

    def _transition(
        self,
        record: FeatureRecord,
        destination_state: str,
        operation: str,
        payload: Mapping[str, Any],
    ) -> None:
        source = record.path
        destination = self.features_root / destination_state / source.name
        if destination.exists():
            raise FeatureWorkflowError(f"transition destination already exists: {destination}")
        if source.parent.stat().st_dev != destination.parent.stat().st_dev:
            raise FeatureWorkflowError("feature lifecycle transitions must stay on one filesystem")
        transaction = {
            "schema_version": "worldeval/feature-transition/1.0.0",
            "feature_id": record.feature_id,
            "operation": operation,
            "from": record.state,
            "to": destination_state,
            "started_at": _isoformat(self._now()),
            "payload": payload,
        }
        _write_json(source / TRANSACTION_FILE, transaction)
        self._prepare_transition(source, transaction)
        os.rename(source, destination)
        _fsync_directory(source.parent)
        _fsync_directory(destination.parent)
        self._finalize_transition(destination, transaction)

    def _prepare_transition(self, path: Path, transaction: Mapping[str, Any]) -> None:
        operation = transaction.get("operation")
        payload = transaction.get("payload", {})
        if operation == "claim":
            _write_json(path / "claim.json", payload["claim"])
        elif operation == "complete":
            _write_json(path / "completion.json", payload["completion"])

    def _archive_claim(self, path: Path, operation: str) -> None:
        claim_path = path / "claim.json"
        if not claim_path.is_file():
            return
        claim = _read_json(claim_path)
        timestamp = re.sub(r"[^0-9]", "", str(claim.get("renewed_at", "unknown")))[:14] or "unknown"
        claim_hash = hashlib.sha256(_canonical_json_bytes(claim)).hexdigest()[:12]
        archive_path = (
            path / "decisions" / f"lifecycle-{operation}-{timestamp}-{claim_hash}.claim.json"
        )
        if not archive_path.exists():
            _write_json(archive_path, claim)
        claim_path.unlink()
        _fsync_directory(path)

    def _finalize_transition(self, path: Path, transaction: Mapping[str, Any]) -> None:
        operation = str(transaction.get("operation"))
        if operation in {"release", "complete"}:
            self._archive_claim(path, operation)
        transaction_path = path / TRANSACTION_FILE
        transaction_path.unlink(missing_ok=True)
        _fsync_directory(path)

    def doctor(self, *, repair: bool = False) -> dict[str, Any]:
        report: dict[str, Any] = {"issues": [], "repaired": []}
        lock_path = self.lock_directory / "workspace.lock"
        if lock_path.exists():
            stale = self._lock_is_stale(lock_path)
            report["issues"].append(
                {
                    "code": "stale-lock" if stale else "active-lock",
                    "path": str(lock_path),
                    "message": "feature workspace lock is stale"
                    if stale
                    else "feature workspace is actively locked",
                }
            )
            if repair and stale:
                self.lock_directory.mkdir(parents=True, exist_ok=True)
                archive = self.lock_directory / f"recovered-lock-{uuid.uuid4().hex}.json"
                os.rename(lock_path, archive)
                report["repaired"].append({"code": "archived-stale-lock", "path": str(archive)})
            elif repair:
                return report

        if repair:
            with self._lock():
                self._repair_staging_directories(report)
                self._repair_transactions(report)
        else:
            self._report_staging_directories(report)
            self._report_transactions(report)

        for issue in self.validate():
            report["issues"].append(issue.as_dict())
        return report

    def _lock_is_stale(self, lock_path: Path) -> bool:
        try:
            payload = _read_json(lock_path)
        except FeatureWorkflowError:
            return True
        if not isinstance(payload, dict) or payload.get("host") != socket.gethostname():
            return False
        pid = payload.get("pid")
        if not isinstance(pid, int) or pid <= 0:
            return True
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            return False
        return False

    def _staging_paths(self) -> list[Path]:
        backlog = self.features_root / "backlog"
        return sorted(path for path in backlog.glob(".*-creating-*") if path.is_dir())

    def _report_staging_directories(self, report: dict[str, Any]) -> None:
        for path in self._staging_paths():
            report["issues"].append(
                {
                    "code": "interrupted-create",
                    "path": str(path),
                    "message": "feature creation was interrupted",
                }
            )

    def _repair_staging_directories(self, report: dict[str, Any]) -> None:
        for path in self._staging_paths():
            metadata_path = path / "feature.json"
            if not metadata_path.is_file():
                report["issues"].append(
                    {
                        "code": "unrecoverable-create",
                        "path": str(path),
                        "message": "staging work preserved because feature.json is missing",
                    }
                )
                continue
            try:
                metadata = _read_json(metadata_path)
            except FeatureWorkflowError as exc:
                report["issues"].append(
                    {"code": "unrecoverable-create", "path": str(path), "message": str(exc)}
                )
                continue
            expected = path.parent / f"{metadata.get('id', '').lower()}-{metadata.get('slug', '')}"
            issues = self._validate_metadata(metadata, metadata_path)
            required_paths = (
                "README.md",
                "plan.md",
                "progress.md",
                "decisions",
                "evidence/manifest.json",
            )
            incomplete = any(
                not (path / required_path).exists() for required_path in required_paths
            )
            if issues or incomplete or expected.exists():
                report["issues"].append(
                    {
                        "code": "unrecoverable-create",
                        "path": str(path),
                        "message": (
                            "staging work preserved because it is invalid or conflicts "
                            "with a destination"
                        ),
                    }
                )
                continue
            os.rename(path, expected)
            report["repaired"].append({"code": "completed-create", "path": str(expected)})

    def _transaction_records(self) -> list[tuple[FeatureRecord, Mapping[str, Any]]]:
        values: list[tuple[FeatureRecord, Mapping[str, Any]]] = []
        for record in self._scan_features()[0]:
            path = record.path / TRANSACTION_FILE
            if path.is_file():
                try:
                    transaction = _read_json(path)
                except FeatureWorkflowError:
                    continue
                if isinstance(transaction, dict):
                    values.append((record, transaction))
        return values

    def _report_transactions(self, report: dict[str, Any]) -> None:
        for record, transaction in self._transaction_records():
            report["issues"].append(
                {
                    "code": "interrupted-transition",
                    "path": str(record.path),
                    "message": f"interrupted {transaction.get('operation')} transition",
                }
            )

    def _repair_transactions(self, report: dict[str, Any]) -> None:
        for record, transaction in list(self._transaction_records()):
            source_state = transaction.get("from")
            destination_state = transaction.get("to")
            if source_state not in LIFECYCLE_STATES or destination_state not in LIFECYCLE_STATES:
                report["issues"].append(
                    {
                        "code": "invalid-transition",
                        "path": str(record.path),
                        "message": "transaction states are invalid; work was preserved",
                    }
                )
                continue
            destination = self.features_root / str(destination_state) / record.path.name
            if record.state == source_state:
                if destination.exists():
                    report["issues"].append(
                        {
                            "code": "transition-conflict",
                            "path": str(record.path),
                            "message": "destination exists; both copies were preserved",
                        }
                    )
                    continue
                self._prepare_transition(record.path, transaction)
                os.rename(record.path, destination)
                self._finalize_transition(destination, transaction)
                report["repaired"].append(
                    {"code": "completed-transition", "path": str(destination)}
                )
            elif record.state == destination_state:
                self._prepare_transition(record.path, transaction)
                self._finalize_transition(record.path, transaction)
                report["repaired"].append(
                    {"code": "finalized-transition", "path": str(record.path)}
                )
            else:
                report["issues"].append(
                    {
                        "code": "misplaced-transition",
                        "path": str(record.path),
                        "message": "transaction is in neither declared state; work was preserved",
                    }
                )


# A descriptive alias for callers that prefer manager terminology.
FeatureManager = FeatureWorkspace
