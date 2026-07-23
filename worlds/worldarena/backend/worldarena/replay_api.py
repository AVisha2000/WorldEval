"""Safe public projection of sealed WorldEval replay bundles."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated, Any, Iterable, Mapping, Optional

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import FileResponse
from worldeval.replay import (
    BundleVerificationError,
    NativeVerifierRegistry,
    ProtectedArtifactError,
    ReplayBundleError,
    VerificationReport,
    resolve_artifact,
    verify_replay_bundle,
)

from .replay_verifiers import default_native_verifiers

MaybeInt = Optional[int]


class ReplayCatalogError(RuntimeError):
    """The archive has an ambiguous public identity."""


@dataclass(frozen=True)
class CatalogEntry:
    run_id: str
    bundle_path: Path
    projection: Mapping[str, Any]


class ReplayCatalog:
    """Discover verified local and promoted bundles without exposing private files."""

    def __init__(
        self,
        roots: Iterable[Path],
        *,
        native_verifiers: NativeVerifierRegistry | None = None,
    ) -> None:
        self.roots = tuple(Path(root).resolve() for root in roots)
        self.native_verifiers = (
            default_native_verifiers()
            if native_verifiers is None
            else native_verifiers
        )

    def verify(self, bundle: Path) -> VerificationReport:
        """Re-run outer and native offline verification for one public read."""

        return verify_replay_bundle(
            bundle,
            native_verifiers=self.native_verifiers,
            require_native_verification=True,
            require_provider_calls_zero=True,
            require_claim_binding=True,
        )

    def entries(self) -> tuple[CatalogEntry, ...]:
        indexed: dict[str, CatalogEntry] = {}
        for bundle in self._bundle_paths():
            try:
                report = self.verify(bundle)
                projection = _public_projection(report)
            except (OSError, ReplayBundleError):
                continue
            run_id = str(report.manifest["run_id"])
            if run_id in indexed:
                raise ReplayCatalogError(f"duplicate replay run_id: {run_id}")
            indexed[run_id] = CatalogEntry(run_id, bundle, projection)
        return tuple(sorted(indexed.values(), key=lambda item: item.run_id, reverse=True))

    def get(self, run_id: str) -> CatalogEntry | None:
        return next((entry for entry in self.entries() if entry.run_id == run_id), None)

    def _bundle_paths(self) -> tuple[Path, ...]:
        discovered: set[Path] = set()
        for root in self.roots:
            if root.is_symlink() or not root.is_dir():
                continue
            for directory, names, files in os.walk(root, followlinks=False):
                names[:] = [
                    name for name in names if not (Path(directory) / name).is_symlink()
                ]
                if "manifest.json" in files:
                    discovered.add(Path(directory).resolve())
                    names[:] = []
        return tuple(sorted(discovered))


router = APIRouter(prefix="/api/worldeval/replays", tags=["worldeval-replays"])


def _catalog(request: Request) -> ReplayCatalog:
    value = getattr(request.app.state, "worldeval_replays", None)
    if not isinstance(value, ReplayCatalog):
        raise HTTPException(status_code=503, detail="replay catalog is unavailable")
    return value


@router.get("")
async def list_worldeval_replays(
    request: Request,
    limit: int = Query(default=50, ge=1, le=100),
) -> list[Mapping[str, Any]]:
    try:
        entries = _catalog(request).entries()
    except ReplayCatalogError as error:
        raise HTTPException(status_code=503, detail="replay catalog is ambiguous") from error
    return [entry.projection for entry in entries[:limit]]


@router.get("/{run_id}")
async def get_worldeval_replay(request: Request, run_id: str) -> Mapping[str, Any]:
    entry = _entry_or_404(request, run_id)
    return entry.projection


@router.get("/{run_id}/files/{role}")
async def get_worldeval_replay_file(
    request: Request,
    run_id: str,
    role: str,
    leg: Annotated[MaybeInt, Query(ge=0)] = None,
) -> FileResponse:
    catalog = _catalog(request)
    entry = _entry_or_404(request, run_id)
    try:
        # Verify again immediately before resolving the download.  A prior list
        # or detail response is never treated as an authorization cache.
        report = catalog.verify(entry.bundle_path)
        descriptors = tuple(
            value
            for value in report.manifest["artifacts"]
            if value["visibility"] == "public"
        )
        descriptor = next(
            (
                value
                for value in descriptors
                if value["role"] == role and (leg is None or value.get("leg") == leg)
            ),
            None,
        )
        if descriptor is None:
            raise ReplayBundleError("public artifact is unavailable")
        target = resolve_artifact(
            entry.bundle_path,
            role,
            leg=leg,
            allow_protected=False,
            native_verifiers=catalog.native_verifiers,
            require_native_verification=True,
            require_provider_calls_zero=True,
            require_claim_binding=True,
        )
    except (ProtectedArtifactError, ReplayBundleError, BundleVerificationError) as error:
        raise HTTPException(status_code=404, detail="public replay file not found") from error
    response = FileResponse(
        target,
        media_type=str(descriptor["media_type"]),
        filename=target.name,
    )
    response.headers["ETag"] = f'"sha256:{descriptor["sha256"]}"'
    response.headers["Cache-Control"] = "private, max-age=0, must-revalidate"
    response.headers["X-Content-Type-Options"] = "nosniff"
    return response


def _entry_or_404(request: Request, run_id: str) -> CatalogEntry:
    try:
        entry = _catalog(request).get(run_id)
    except ReplayCatalogError as error:
        raise HTTPException(status_code=503, detail="replay catalog is ambiguous") from error
    if entry is None:
        raise HTTPException(status_code=404, detail="replay not found")
    return entry


def _public_projection(report: VerificationReport) -> Mapping[str, Any]:
    manifest = report.manifest
    public = [
        dict(value)
        for value in manifest["artifacts"]
        if value["visibility"] == "public"
    ]
    offline = report.independent_offline_verification
    if offline is None or offline["provider_calls"] != 0:
        raise BundleVerificationError(
            "public replay lacks independent provider-free verification"
        )
    return {
        "schema": manifest["schema"],
        "run_id": manifest["run_id"],
        "game": manifest["game"],
        "scenario": manifest["scenario"],
        "task": manifest["task"],
        "subject": manifest["subject"],
        "protocol": manifest["protocol"],
        "engine": manifest["engine"],
        "seed": manifest["seed"],
        "profiles": manifest["profiles"],
        "terminal": manifest["terminal"],
        "offline_verification": dict(offline),
        "artifacts": public,
    }

__all__ = ["CatalogEntry", "ReplayCatalog", "ReplayCatalogError", "router"]
