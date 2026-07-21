"""Canonical public/protected evidence for verified cyclic trio series."""

from __future__ import annotations

import base64
import hashlib
import re
from dataclasses import dataclass
from typing import Any, Mapping

from ..artifacts import (
    PROTECTED_LAYER,
    PUBLIC_LAYER,
    EpisodeArtifact,
    EpisodeArtifactBundle,
    EpisodeArtifactError,
)
from ..protocol import EmbodimentProtocolPackage, canonical_json_bytes, strict_json_loads
from ..providers.contracts import ProviderAuditRecord
from ..replay import verify_replay_bytes
from .evaluation import evaluate_trio_series
from .scheduling import TrioSeriesPlan
from .series import TrioSeriesResult

TRIO_EVIDENCE_SCHEMA_VERSION = "llm-controller/trio-series-evidence/1.0.0"
_SHA256 = re.compile(r"^[0-9a-f]{64}$")


@dataclass(frozen=True)
class TrioVerifiedLegMaterial:
    replay_bytes: bytes
    provider_audits: tuple[ProviderAuditRecord, ...]
    authority_aggregates: Mapping[str, Any]

    def __post_init__(self) -> None:
        if not isinstance(self.replay_bytes, bytes):
            raise TypeError("trio replay evidence must be immutable bytes")
        if not isinstance(self.provider_audits, tuple) or any(
            not isinstance(value, ProviderAuditRecord) for value in self.provider_audits
        ):
            raise TypeError("trio provider audits are invalid")
        if not isinstance(self.authority_aggregates, Mapping):
            raise TypeError("trio authority aggregates are invalid")


@dataclass(frozen=True)
class TrioSeriesEvidenceBundle:
    layer: str
    series_id: str
    plan_sha256: str
    protocol_package_sha256: str
    content_sha256: str
    bundle_bytes: bytes
    legs: tuple[EpisodeArtifactBundle, EpisodeArtifactBundle, EpisodeArtifactBundle]

    @classmethod
    def create(
        cls,
        *,
        layer: str,
        series_id: str,
        plan_sha256: str,
        protocol_package_sha256: str,
        legs: tuple[EpisodeArtifactBundle, EpisodeArtifactBundle, EpisodeArtifactBundle],
    ) -> TrioSeriesEvidenceBundle:
        if layer not in (PUBLIC_LAYER, PROTECTED_LAYER):
            raise EpisodeArtifactError("trio evidence layer is invalid")
        if not isinstance(series_id, str) or not series_id:
            raise EpisodeArtifactError("trio series_id is invalid")
        for name, value in (
            ("plan_sha256", plan_sha256),
            ("protocol_package_sha256", protocol_package_sha256),
        ):
            if not isinstance(value, str) or _SHA256.fullmatch(value) is None:
                raise EpisodeArtifactError(f"trio evidence {name} is invalid")
        if not isinstance(legs, tuple) or len(legs) != 3 or any(
            not isinstance(value, EpisodeArtifactBundle) or value.layer != layer
            for value in legs
        ):
            raise EpisodeArtifactError("trio evidence requires three matching leg bundles")
        body = {
            "layer": layer,
            "legs": [strict_json_loads(value.bundle_bytes) for value in legs],
            "plan_sha256": plan_sha256,
            "protocol_package_sha256": protocol_package_sha256,
            "schema_version": TRIO_EVIDENCE_SCHEMA_VERSION,
            "series_id": series_id,
        }
        digest = hashlib.sha256(canonical_json_bytes(body)).hexdigest()
        payload = canonical_json_bytes({**body, "content_sha256": digest})
        return cls(
            layer,
            series_id,
            plan_sha256,
            protocol_package_sha256,
            digest,
            payload,
            legs,
        )

    @classmethod
    def verify(cls, payload: bytes) -> TrioSeriesEvidenceBundle:
        value = strict_json_loads(payload)
        if not isinstance(value, dict) or canonical_json_bytes(value) != payload:
            raise EpisodeArtifactError("trio evidence is not canonical JSON")
        if set(value) != {
            "content_sha256",
            "layer",
            "legs",
            "plan_sha256",
            "protocol_package_sha256",
            "schema_version",
            "series_id",
        }:
            raise EpisodeArtifactError("trio evidence fields differ")
        body = {key: child for key, child in value.items() if key != "content_sha256"}
        if (
            value["schema_version"] != TRIO_EVIDENCE_SCHEMA_VERSION
            or value["content_sha256"]
            != hashlib.sha256(canonical_json_bytes(body)).hexdigest()
            or not isinstance(value["legs"], list)
            or len(value["legs"]) != 3
        ):
            raise EpisodeArtifactError("trio evidence integrity differs")
        legs = tuple(
            EpisodeArtifactBundle.verify(canonical_json_bytes(child))
            for child in value["legs"]
        )
        return cls.create(
            layer=value["layer"],
            series_id=value["series_id"],
            plan_sha256=value["plan_sha256"],
            protocol_package_sha256=value["protocol_package_sha256"],
            legs=tuple(legs),  # type: ignore[arg-type]
        )


@dataclass(frozen=True)
class TrioSeriesEvidence:
    public: TrioSeriesEvidenceBundle
    protected: TrioSeriesEvidenceBundle

    def __post_init__(self) -> None:
        if self.public.layer != PUBLIC_LAYER or self.protected.layer != PROTECTED_LAYER:
            raise EpisodeArtifactError("trio evidence layers are invalid")
        if (
            self.public.series_id,
            self.public.plan_sha256,
            self.public.protocol_package_sha256,
        ) != (
            self.protected.series_id,
            self.protected.plan_sha256,
            self.protected.protocol_package_sha256,
        ):
            raise EpisodeArtifactError("trio public/protected identities differ")


@dataclass(frozen=True)
class TrioSeriesExecution:
    result: TrioSeriesResult
    evidence: TrioSeriesEvidence
    evaluation: Mapping[str, Any]

    def __post_init__(self) -> None:
        if (
            not isinstance(self.result, TrioSeriesResult)
            or not isinstance(self.evidence, TrioSeriesEvidence)
            or not isinstance(self.evaluation, Mapping)
        ):
            raise TypeError("trio series execution is invalid")
        if self.result.plan.plan_sha256 != self.evidence.public.plan_sha256:
            raise ValueError("trio evidence belongs to another plan")


def build_trio_series_evidence(
    *,
    plan: TrioSeriesPlan,
    result: TrioSeriesResult,
    materials: tuple[
        TrioVerifiedLegMaterial, TrioVerifiedLegMaterial, TrioVerifiedLegMaterial
    ],
    protocol_package: EmbodimentProtocolPackage,
) -> TrioSeriesEvidence:
    if result.plan != plan or len(materials) != 3:
        raise EpisodeArtifactError("trio evidence inputs differ")
    replays = tuple(
        verify_replay_bytes(value.replay_bytes, package=protocol_package)
        for value in materials
    )
    evaluation = evaluate_trio_series(
        plan, [value.authority_aggregates for value in materials]
    )
    public_legs = []
    protected_legs = []
    for leg_index, (leg_result, material, replay) in enumerate(
        zip(result.legs, materials, replays)
    ):
        if (
            replay["config"]["episode_id"] != leg_result.plan.episode_id
            or hashlib.sha256(material.replay_bytes).hexdigest()
            != leg_result.replay_sha256
        ):
            raise EpisodeArtifactError("trio verified replay identity differs")
        events = [
            event
            for step in replay["steps"]
            for event in step["result"]["public_events"]
        ]
        receipts = [
            {
                "observation_seq": index,
                "participants": step["result"]["receipts"],
            }
            for index, step in enumerate(replay["steps"])
        ]
        public_legs.append(
            EpisodeArtifactBundle.create(
                PUBLIC_LAYER,
                (
                    EpisodeArtifact.json("evaluation", evaluation["legs"][leg_index]),
                    EpisodeArtifact.json("public_events", events),
                    EpisodeArtifact.json("receipts", receipts),
                    EpisodeArtifact.json("replay_summary", leg_result.public_dict()),
                ),
            )
        )
        protected_legs.append(
            EpisodeArtifactBundle.create(
                PROTECTED_LAYER,
                (
                    EpisodeArtifact(
                        "authority_replay", "application/json", material.replay_bytes
                    ),
                    EpisodeArtifact.json(
                        "provider_outputs",
                        [_protected_audit(value) for value in material.provider_audits],
                    ),
                ),
            )
        )
    public = TrioSeriesEvidenceBundle.create(
        layer=PUBLIC_LAYER,
        series_id=plan.series_id,
        plan_sha256=plan.plan_sha256,
        protocol_package_sha256=protocol_package.package_sha256,
        legs=tuple(public_legs),  # type: ignore[arg-type]
    )
    protected = TrioSeriesEvidenceBundle.create(
        layer=PROTECTED_LAYER,
        series_id=plan.series_id,
        plan_sha256=plan.plan_sha256,
        protocol_package_sha256=protocol_package.package_sha256,
        legs=tuple(protected_legs),  # type: ignore[arg-type]
    )
    return TrioSeriesEvidence(public, protected)


def _protected_audit(record: ProviderAuditRecord) -> Mapping[str, Any]:
    request = record.request
    result = record.result
    return {
        "failure": None if result.failure is None else result.failure.value,
        "model": request.model,
        "observation_seq": request.observation_seq,
        "participant_id": request.participant_id,
        "provider": record.provider,
        "raw_output_base64": (
            None
            if result.raw_output is None
            else base64.b64encode(result.raw_output).decode("ascii")
        ),
        "request_sha256": hashlib.sha256(
            canonical_json_bytes(
                {
                    "action_schema_sha256": hashlib.sha256(
                        request.action_schema_json
                    ).hexdigest(),
                    "observation_sha256": hashlib.sha256(
                        request.observation_json
                    ).hexdigest(),
                    "participant_id": request.participant_id,
                    "scratchpad_sha256": hashlib.sha256(
                        request.scratchpad_utf8
                    ).hexdigest(),
                }
            )
        ).hexdigest(),
    }


__all__ = [
    "TRIO_EVIDENCE_SCHEMA_VERSION",
    "TrioSeriesEvidence",
    "TrioSeriesEvidenceBundle",
    "TrioSeriesExecution",
    "TrioVerifiedLegMaterial",
    "build_trio_series_evidence",
]
