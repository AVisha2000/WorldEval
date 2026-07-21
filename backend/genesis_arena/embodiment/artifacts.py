"""Deterministic public/protected evidence bundles for live embodiment episodes."""

from __future__ import annotations

import asyncio
import base64
import hashlib
import re
import tempfile
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Any, Iterable, Mapping

from .demo_scenarios import demo_scenario
from .evaluation import evaluate_solo_replay
from .protocol import (
    EmbodimentProtocolPackage,
    canonical_json_bytes,
    canonical_sha256,
    strict_json_loads,
)
from .protocol_registry import EmbodimentProtocolRegistry
from .replay import verify_replay_bytes

BUNDLE_SCHEMA_VERSION = "llm-controller/episode-artifacts/1.0.0"
PUBLIC_LAYER = "public"
PROTECTED_LAYER = "protected"

_ROLE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
_FORBIDDEN_KEYS = frozenset(
    {
        "apikey",
        "authorization",
        "bearertoken",
        "credential",
        "credentials",
        "headers",
        "password",
        "privatekey",
        "secret",
        "token",
        "xapikey",
        "contenttype",
        "cookie",
        "setcookie",
        "useragent",
    }
)
_SECRET_PATTERNS = (
    re.compile(rb"(?i)bearer\s+[a-z0-9._~+/=-]{8,}"),
    re.compile(rb"\bsk-[A-Za-z0-9_-]{8,}"),
    re.compile(rb"\bAIza[A-Za-z0-9_-]{20,}"),
    re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{8,}"),
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
)
_PUBLIC_ROLES = frozenset(
    {"checkpoints", "evaluation", "public_events", "receipts", "replay_summary"}
)
_PROTECTED_ROLES = frozenset(
    {
        "authority_replay",
        "frames",
        "observations",
        "prompts",
        "provider_outputs",
        "scratchpad",
        "telemetry",
    }
)
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_PARSING_DISPOSITIONS = frozenset({"accepted", "not_attempted", "output_too_large", "rejected"})
_PROVIDER_EVIDENCE_FIELDS = frozenset(
    {
        "adapter_audit",
        "deadline_budget_ms",
        "max_input_bytes",
        "max_output_bytes",
        "model",
        "parsing_disposition",
        "provider",
        "request_material_sha256",
        "schema_sha256",
        "visibility_frame_binding",
    }
)
_ADAPTER_AUDIT_FIELDS = frozenset({"disposition", "duration_ms", "recorded"})
_VISIBILITY_BINDING_FIELDS = frozenset(
    {
        "bound",
        "frame_metadata_sha256",
        "frame_sha256",
        "observation_sha256",
        "participant_id",
        "profile",
        "visible_payload_sha256",
    }
)


class EpisodeArtifactError(ValueError):
    """Artifact content failed structure, integrity, or disclosure policy."""


@dataclass(frozen=True)
class EpisodeArtifact:
    role: str
    media_type: str
    data: bytes

    def __post_init__(self) -> None:
        if _ROLE.fullmatch(self.role) is None:
            raise EpisodeArtifactError("artifact role is invalid")
        if self.media_type not in ("application/json", "application/x-ndjson", "image/png"):
            raise EpisodeArtifactError("artifact media type is invalid")
        if not isinstance(self.data, bytes):
            raise TypeError("artifact data must be immutable bytes")
        _assert_secret_free_bytes(self.data)
        if self.media_type == "application/json":
            try:
                _assert_secret_free_value(strict_json_loads(self.data))
            except EpisodeArtifactError:
                raise
            except Exception as error:
                raise EpisodeArtifactError("JSON artifact data is invalid") from error

    @classmethod
    def json(cls, role: str, value: Any) -> EpisodeArtifact:
        _assert_secret_free_value(value)
        return cls(role, "application/json", canonical_json_bytes(value))


@dataclass(frozen=True)
class EpisodeArtifactBundle:
    """Canonical content-addressed bundle with no filesystem metadata."""

    layer: str
    content_sha256: str
    bundle_bytes: bytes
    artifacts: Mapping[str, EpisodeArtifact]

    @classmethod
    def create(cls, layer: str, artifacts: Iterable[EpisodeArtifact]) -> EpisodeArtifactBundle:
        allowed = _PUBLIC_ROLES if layer == PUBLIC_LAYER else _PROTECTED_ROLES
        if layer not in (PUBLIC_LAYER, PROTECTED_LAYER):
            raise EpisodeArtifactError("artifact layer is invalid")
        selected = tuple(artifacts)
        if not selected:
            raise EpisodeArtifactError("artifact bundle must not be empty")
        by_role = {artifact.role: artifact for artifact in selected}
        if len(by_role) != len(selected) or not set(by_role) <= allowed:
            raise EpisodeArtifactError("artifact roles differ from layer policy")
        entries = []
        for role in sorted(by_role):
            artifact = by_role[role]
            entries.append(
                {
                    "bytes": len(artifact.data),
                    "data_base64": base64.b64encode(artifact.data).decode("ascii"),
                    "media_type": artifact.media_type,
                    "role": role,
                    "sha256": hashlib.sha256(artifact.data).hexdigest(),
                }
            )
        body = {"artifacts": entries, "layer": layer, "schema_version": BUNDLE_SCHEMA_VERSION}
        digest = hashlib.sha256(canonical_json_bytes(body)).hexdigest()
        encoded = canonical_json_bytes({**body, "content_sha256": digest})
        return cls(layer, digest, encoded, MappingProxyType(dict(by_role)))

    @classmethod
    def verify(cls, payload: bytes) -> EpisodeArtifactBundle:
        try:
            value = strict_json_loads(payload)
        except Exception as error:
            raise EpisodeArtifactError("artifact bundle JSON is invalid") from error
        if not isinstance(value, dict) or canonical_json_bytes(value) != payload:
            raise EpisodeArtifactError("artifact bundle is not canonical")
        if set(value) != {"artifacts", "content_sha256", "layer", "schema_version"}:
            raise EpisodeArtifactError("artifact bundle fields differ")
        body = {key: child for key, child in value.items() if key != "content_sha256"}
        digest = hashlib.sha256(canonical_json_bytes(body)).hexdigest()
        if value["schema_version"] != BUNDLE_SCHEMA_VERSION or value["content_sha256"] != digest:
            raise EpisodeArtifactError("artifact bundle digest differs")
        artifacts = []
        entries = value["artifacts"]
        if not isinstance(entries, list):
            raise EpisodeArtifactError("artifact index is invalid")
        roles: list[str] = []
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != {
                "bytes",
                "data_base64",
                "media_type",
                "role",
                "sha256",
            }:
                raise EpisodeArtifactError("artifact descriptor fields differ")
            try:
                data = base64.b64decode(entry["data_base64"], validate=True)
            except Exception as error:
                raise EpisodeArtifactError("artifact base64 is invalid") from error
            if entry["bytes"] != len(data) or entry["sha256"] != hashlib.sha256(data).hexdigest():
                raise EpisodeArtifactError("artifact payload digest differs")
            artifacts.append(EpisodeArtifact(entry["role"], entry["media_type"], data))
            roles.append(entry["role"])
        if roles != sorted(roles) or len(roles) != len(set(roles)):
            raise EpisodeArtifactError("artifact ordering or uniqueness differs")
        return cls.create(value["layer"], artifacts)

    def read(self, role: str) -> bytes:
        try:
            return self.artifacts[role].data
        except KeyError as error:
            raise EpisodeArtifactError("artifact role is unavailable") from error


@dataclass(frozen=True)
class EpisodeBundles:
    public: EpisodeArtifactBundle
    protected: EpisodeArtifactBundle


class EpisodeArtifactRecorder:
    """Collect public projections and protected controller evidence without mixing layers."""

    def __init__(
        self,
        episode_id: str,
        *,
        protocol_package: EmbodimentProtocolPackage | None = None,
    ) -> None:
        if not isinstance(episode_id, str) or not episode_id.startswith("ep_"):
            raise EpisodeArtifactError("episode_id is invalid")
        self.episode_id = episode_id
        self.protocol_package = protocol_package
        self.public_events: list[Mapping[str, Any]] = []
        self.receipts: list[Mapping[str, Any]] = []
        self.checkpoints: list[Mapping[str, Any]] = []
        self.observations: list[Mapping[str, Any]] = []
        self.frames: list[Mapping[str, Any]] = []
        self.prompts: list[Mapping[str, Any]] = []
        self.provider_outputs: list[Mapping[str, Any]] = []
        self.scratchpad: list[Mapping[str, Any]] = []
        self.telemetry: list[Mapping[str, Any]] = []
        self._run_configuration_hashes: Mapping[str, str] | None = None
        self._evaluation_identity: tuple[str, str] | None = None

    def freeze_run_configuration(
        self,
        *,
        provider: str,
        model: str,
        settings: Mapping[str, Any],
    ) -> None:
        """Commit public evidence to one provider/model/settings selection."""

        if self._run_configuration_hashes is not None:
            raise EpisodeArtifactError("run configuration is already frozen")
        if not isinstance(provider, str) or not provider:
            raise EpisodeArtifactError("provider is invalid")
        if not isinstance(model, str) or not model:
            raise EpisodeArtifactError("model is invalid")
        if not isinstance(settings, Mapping):
            raise EpisodeArtifactError("settings are invalid")
        selected_settings = dict(settings)
        _assert_secret_free_value(
            {"provider": provider, "model": model, "settings": selected_settings}
        )
        self._run_configuration_hashes = MappingProxyType(
            {
                "provider_sha256": canonical_sha256({"provider": provider}),
                "model_sha256": canonical_sha256({"model": model}),
                "settings_sha256": canonical_sha256(selected_settings),
            }
        )
        policy_lock = selected_settings.get("demo_policy_lock")
        if isinstance(policy_lock, Mapping):
            scenario_id = policy_lock.get("scenario_id")
            if not isinstance(scenario_id, str):
                raise EpisodeArtifactError("demo scenario identity is invalid")
            try:
                scenario = demo_scenario(scenario_id)
            except (TypeError, ValueError) as error:
                raise EpisodeArtifactError("demo scenario identity is invalid") from error
            self._evaluation_identity = (scenario.scenario_id, scenario.evaluation_profile_id)

    def record_boundary(
        self,
        *,
        observation_seq: int,
        state_hash: str,
        observations: Mapping[str, Any],
        receipts: Mapping[str, Any] | None = None,
        public_events: Iterable[Mapping[str, Any]] = (),
        terminal: Mapping[str, Any] | None = None,
    ) -> None:
        self.checkpoints.append(
            {
                "observation_seq": observation_seq,
                "state_hash": state_hash,
                "terminal": terminal,
            }
        )
        self.observations.append(
            {"observation_seq": observation_seq, "participants": dict(observations)}
        )
        if receipts is not None:
            self.receipts.append(
                {"observation_seq": observation_seq - 1, "participants": dict(receipts)}
            )
        self.public_events.extend(dict(event) for event in public_events)

    def record_provider_call(
        self,
        *,
        observation_seq: int,
        prompt: str,
        raw_output: bytes | None,
        scratchpad_utf8: bytes,
        telemetry: Mapping[str, Any],
        frame_png: bytes | None = None,
        frame_metadata: Mapping[str, Any] | None = None,
        participant_id: str | None = None,
        scratchpad_after_utf8: bytes | None = None,
        provider_evidence: Mapping[str, Any] | None = None,
    ) -> None:
        if raw_output is not None:
            _assert_secret_free_bytes(raw_output)
        _assert_secret_free_bytes(scratchpad_utf8)
        if scratchpad_after_utf8 is not None:
            _assert_secret_free_bytes(scratchpad_after_utf8)
        self.prompts.append({"observation_seq": observation_seq, "prompt": prompt})
        self.provider_outputs.append(
            {
                "observation_seq": observation_seq,
                "raw_output_base64": (
                    None if raw_output is None else base64.b64encode(raw_output).decode("ascii")
                ),
            }
        )
        self.scratchpad.append(
            {
                "observation_seq": observation_seq,
                "utf8_base64": base64.b64encode(scratchpad_utf8).decode("ascii"),
                "after_utf8_base64": (
                    None
                    if scratchpad_after_utf8 is None
                    else base64.b64encode(scratchpad_after_utf8).decode("ascii")
                ),
            }
        )
        telemetry_record = {"observation_seq": observation_seq, **dict(telemetry)}
        if provider_evidence is not None:
            telemetry_record["provider_evidence"] = _provider_evidence(provider_evidence)
        self.telemetry.append(telemetry_record)
        if frame_png is not None:
            self.record_frame(
                observation_seq=observation_seq,
                participant_id=participant_id,
                frame_metadata=frame_metadata,
                frame_png=frame_png,
            )

    def record_frame(
        self,
        *,
        observation_seq: int,
        participant_id: str | None,
        frame_metadata: Mapping[str, Any] | None,
        frame_png: bytes,
    ) -> None:
        if not isinstance(participant_id, str) or not participant_id:
            raise EpisodeArtifactError("frame participant is required")
        if not isinstance(frame_metadata, Mapping):
            raise EpisodeArtifactError("frame metadata is required with frame bytes")
        actual_sha256 = hashlib.sha256(frame_png).hexdigest()
        if frame_metadata.get("sha256") != actual_sha256:
            raise EpisodeArtifactError("frame metadata digest differs")
        self.frames.append(
            {
                "observation_seq": observation_seq,
                "participant_id": participant_id,
                "metadata": dict(frame_metadata),
                "png_base64": base64.b64encode(frame_png).decode("ascii"),
                "sha256": actual_sha256,
            }
        )

    def seal(self, *, authority_replay: bytes, evaluation: Mapping[str, Any]) -> EpisodeBundles:
        if self._run_configuration_hashes is None:
            raise EpisodeArtifactError("run configuration was not frozen")
        if not isinstance(evaluation, Mapping):
            raise EpisodeArtifactError("evaluation input is invalid")
        replay = verify_replay_bytes(authority_replay, package=self.protocol_package)
        if replay["config"].get("episode_id") != self.episode_id:
            raise EpisodeArtifactError("authority replay episode differs")
        self._verify_against_replay(replay)
        terminal = replay["final_terminal"]
        evaluation_identity = self._evaluation_identity or (None, None)
        derived_evaluation = evaluate_solo_replay(
            replay,
            self.telemetry,
            replay_verified=True,
            scenario_id=evaluation_identity[0],
            evaluation_profile_id=evaluation_identity[1],
        )
        public = EpisodeArtifactBundle.create(
            PUBLIC_LAYER,
            (
                EpisodeArtifact.json("public_events", self.public_events),
                EpisodeArtifact.json("receipts", self.receipts),
                EpisodeArtifact.json("checkpoints", self.checkpoints),
                EpisodeArtifact.json("evaluation", derived_evaluation),
                EpisodeArtifact.json(
                    "replay_summary",
                    {
                        "episode_id": self.episode_id,
                        "final_state_hash": replay["final_state_hash"],
                        "frozen_configuration": {
                            "config_sha256": replay["config_sha256"],
                            "protocol_package_sha256": replay["protocol_package_sha256"],
                            **dict(self._run_configuration_hashes),
                        },
                        "terminal": terminal,
                    },
                ),
            ),
        )
        protected = EpisodeArtifactBundle.create(
            PROTECTED_LAYER,
            (
                EpisodeArtifact("authority_replay", "application/json", authority_replay),
                EpisodeArtifact.json("observations", self.observations),
                EpisodeArtifact.json("frames", self.frames),
                EpisodeArtifact.json("prompts", self.prompts),
                EpisodeArtifact.json("provider_outputs", self.provider_outputs),
                EpisodeArtifact.json("scratchpad", self.scratchpad),
                EpisodeArtifact.json("telemetry", self.telemetry),
            ),
        )
        return EpisodeBundles(public, protected)

    def _verify_against_replay(self, replay: Mapping[str, Any]) -> None:
        steps = replay["steps"]
        expected_checkpoints = [
            {
                "observation_seq": 0,
                "state_hash": replay["initial_state_hash"],
                "terminal": next(iter(replay["initial_observations"].values()))["terminal"],
            }
        ]
        expected_observations = [
            {
                "observation_seq": 0,
                "participants": replay["initial_observations"],
            }
        ]
        expected_receipts = []
        expected_events = []
        for index, step in enumerate(steps):
            result = step["result"]
            expected_checkpoints.append(
                {
                    "observation_seq": index + 1,
                    "state_hash": result["state_hash"],
                    "terminal": result["terminal"],
                }
            )
            expected_observations.append(
                {"observation_seq": index + 1, "participants": result["observations"]}
            )
            expected_receipts.append({"observation_seq": index, "participants": result["receipts"]})
            expected_events.extend(result["public_events"])
        if self.checkpoints != expected_checkpoints:
            raise EpisodeArtifactError("checkpoint evidence differs from authority replay")
        if self.observations != expected_observations:
            raise EpisodeArtifactError("observation evidence differs from authority replay")
        if self.receipts != expected_receipts:
            raise EpisodeArtifactError("receipt evidence differs from authority replay")
        if self.public_events != expected_events:
            raise EpisodeArtifactError("event evidence differs from authority replay")


def verify_offline_replay(
    protected_bundle: bytes,
    *,
    package: EmbodimentProtocolPackage | None = None,
    registry: EmbodimentProtocolRegistry | None = None,
) -> Mapping[str, Any]:
    """Verify a protected bundle and replay its authority ledger from its genesis boundary."""

    bundle = EpisodeArtifactBundle.verify(protected_bundle)
    if bundle.layer != PROTECTED_LAYER:
        raise EpisodeArtifactError("offline replay requires a protected bundle")
    return verify_replay_bytes(
        bundle.read("authority_replay"), package=package, registry=registry
    )


async def verify_offline_replay_with_godot(
    protected_bundle: bytes,
    *,
    package: EmbodimentProtocolPackage,
    godot_executable: Path,
    project_path: Path,
    timeout_s: float = 20.0,
) -> Mapping[str, Any]:
    """Re-execute a sealed authority ledger from genesis in the pinned Godot verifier."""

    verified = verify_offline_replay(protected_bundle, package=package)
    bundle = EpisodeArtifactBundle.verify(protected_bundle)
    replay = bundle.read("authority_replay")
    replay_path: Path | None = None
    command = [
        str(godot_executable),
        "--no-header",
        "--headless",
        "--audio-driver",
        "Dummy",
        "--path",
        str(project_path),
        "--script",
    ]
    if package.PROTOCOL_VERSION == EmbodimentProtocolPackage.PROTOCOL_VERSION:
        command.append("res://scripts/embodiment/replay/embodiment_replay_cli.gd")
        stdin = asyncio.subprocess.PIPE
    elif package.PROTOCOL_VERSION in ("llm-controller/0.2.0", "llm-controller/0.3.0"):
        temporary = tempfile.NamedTemporaryFile(
            mode="wb", prefix="worldarena-versioned-replay-", suffix=".json", delete=False
        )
        try:
            temporary.write(replay)
            temporary.flush()
        finally:
            temporary.close()
        replay_path = Path(temporary.name)
        command.extend(
            (
                "res://scripts/embodiment/v2/replay/embodiment_versioned_replay_cli.gd",
                "--",
                str(replay_path),
            )
        )
        stdin = None
    else:
        raise EpisodeArtifactError("Godot replay verifier does not support this protocol version")
    try:
        process = await asyncio.create_subprocess_exec(
            *command,
            stdin=stdin,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        try:
            output, _ = await asyncio.wait_for(
                process.communicate(replay if stdin is not None else None), timeout_s
            )
        except asyncio.TimeoutError:
            process.kill()
            await process.wait()
            raise EpisodeArtifactError("Godot genesis replay timed out") from None
    finally:
        if replay_path is not None:
            replay_path.unlink(missing_ok=True)
    if process.returncode != 0:
        raise EpisodeArtifactError("Godot genesis replay rejected the bundle")
    lines = output.decode("utf-8", errors="strict").strip().splitlines()
    if not lines:
        raise EpisodeArtifactError("Godot genesis replay emitted no seal")
    if package.PROTOCOL_VERSION in ("llm-controller/0.2.0", "llm-controller/0.3.0"):
        expected = (
            "EMBODIMENT_REPLAY_VERIFIED "
            f"{package.PROTOCOL_VERSION} {verified['final_state_hash']}"
        )
        if lines[-1] != expected:
            raise EpisodeArtifactError("Godot genesis replay seal differs")
        return verified
    seal = strict_json_loads(lines[-1].encode("utf-8"))
    if (
        not isinstance(seal, dict)
        or seal.get("kind") != "embodiment_replay_verified"
        or seal.get("episode_id") != verified["config"]["episode_id"]
        or seal.get("final_state_hash") != verified["final_state_hash"]
    ):
        raise EpisodeArtifactError("Godot genesis replay seal differs")
    return seal


def _normalized_key(value: str) -> str:
    return "".join(character.lower() for character in value if character.isalnum())


def _provider_evidence(value: Mapping[str, Any]) -> Mapping[str, Any]:
    """Copy only the bounded request/audit fields admitted to protected evidence."""

    selected = dict(value)
    if set(selected) != _PROVIDER_EVIDENCE_FIELDS:
        raise EpisodeArtifactError("provider evidence fields differ from the allow-list")
    for name in ("provider", "model"):
        if not isinstance(selected[name], str) or not selected[name]:
            raise EpisodeArtifactError(f"provider evidence {name} is invalid")
    for name in ("deadline_budget_ms", "max_input_bytes", "max_output_bytes"):
        child = selected[name]
        if isinstance(child, bool) or not isinstance(child, int) or child < 1:
            raise EpisodeArtifactError(f"provider evidence {name} is invalid")
    for name in ("request_material_sha256", "schema_sha256"):
        if not isinstance(selected[name], str) or _SHA256.fullmatch(selected[name]) is None:
            raise EpisodeArtifactError(f"provider evidence {name} is invalid")
    if selected["parsing_disposition"] not in _PARSING_DISPOSITIONS:
        raise EpisodeArtifactError("provider evidence parsing disposition is invalid")

    adapter = selected["adapter_audit"]
    if not isinstance(adapter, Mapping) or set(adapter) != _ADAPTER_AUDIT_FIELDS:
        raise EpisodeArtifactError("adapter audit fields differ from the allow-list")
    recorded = adapter["recorded"]
    duration_ms = adapter["duration_ms"]
    disposition = adapter["disposition"]
    if not isinstance(recorded, bool):
        raise EpisodeArtifactError("adapter audit recorded flag is invalid")
    if recorded:
        if (
            isinstance(duration_ms, bool)
            or not isinstance(duration_ms, int)
            or duration_ms < 0
            or not isinstance(disposition, str)
            or not disposition
        ):
            raise EpisodeArtifactError("recorded adapter audit is invalid")
    elif duration_ms is not None or disposition is not None:
        raise EpisodeArtifactError("missing adapter audit must not contain values")

    binding = selected["visibility_frame_binding"]
    if not isinstance(binding, Mapping) or set(binding) != _VISIBILITY_BINDING_FIELDS:
        raise EpisodeArtifactError("visibility/frame binding fields differ from the allow-list")
    if not isinstance(binding["bound"], bool):
        raise EpisodeArtifactError("visibility/frame binding flag is invalid")
    for name in ("participant_id", "profile"):
        if not isinstance(binding[name], str) or not binding[name]:
            raise EpisodeArtifactError(f"visibility/frame binding {name} is invalid")
    for name in ("observation_sha256", "visible_payload_sha256"):
        if not isinstance(binding[name], str) or _SHA256.fullmatch(binding[name]) is None:
            raise EpisodeArtifactError(f"visibility/frame binding {name} is invalid")
    for name in ("frame_metadata_sha256", "frame_sha256"):
        child = binding[name]
        if child is not None and (not isinstance(child, str) or _SHA256.fullmatch(child) is None):
            raise EpisodeArtifactError(f"visibility/frame binding {name} is invalid")
    if (binding["frame_metadata_sha256"] is None) != (binding["frame_sha256"] is None):
        raise EpisodeArtifactError("visibility/frame binding frame hashes differ")

    copied = {
        **selected,
        "adapter_audit": dict(adapter),
        "visibility_frame_binding": dict(binding),
    }
    _assert_secret_free_value(copied)
    canonical_json_bytes(copied)
    return copied


def _assert_secret_free_value(value: Any) -> None:
    if isinstance(value, Mapping):
        for key, child in value.items():
            normalized = _normalized_key(key) if isinstance(key, str) else ""
            if (
                not isinstance(key, str)
                or normalized in _FORBIDDEN_KEYS
                or normalized.endswith("apikey")
                or normalized.endswith("credential")
                or normalized.endswith("credentials")
                or normalized.endswith("header")
                or normalized.endswith("headers")
                or normalized.endswith("privatekey")
                or (normalized.endswith("key") and normalized.startswith("provider"))
            ):
                raise EpisodeArtifactError("artifact contains a forbidden credential/header key")
            _assert_secret_free_value(child)
    elif isinstance(value, (list, tuple)):
        for child in value:
            _assert_secret_free_value(child)
    elif isinstance(value, str):
        _assert_secret_free_bytes(value.encode("utf-8"))


def _assert_secret_free_bytes(value: bytes) -> None:
    if any(pattern.search(value) is not None for pattern in _SECRET_PATTERNS):
        raise EpisodeArtifactError("artifact contains credential-like material")


__all__ = [
    "BUNDLE_SCHEMA_VERSION",
    "EpisodeArtifact",
    "EpisodeArtifactBundle",
    "EpisodeArtifactError",
    "EpisodeArtifactRecorder",
    "EpisodeBundles",
    "PROTECTED_LAYER",
    "PUBLIC_LAYER",
    "verify_offline_replay",
    "verify_offline_replay_with_godot",
]
