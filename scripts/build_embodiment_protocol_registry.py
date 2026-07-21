#!/usr/bin/env python3
"""Build or verify the additive embodiment protocol registry and immutable locks."""

from __future__ import annotations

import argparse
from pathlib import Path

from genesis_arena.embodiment.protocol import EmbodimentProtocolPackage, canonical_json_bytes
from genesis_arena.embodiment.protocol_registry import (
    REGISTRY_VERSION,
    SUPPORTED_PROTOCOL_PATHS,
    VersionedEmbodimentProtocolPackage,
)


def expected_artifacts(repository_root: Path) -> tuple[tuple[Path, bytes], ...]:
    repository_root = repository_root.resolve()
    v1 = EmbodimentProtocolPackage.from_repository(repository_root)
    package_root = (
        repository_root / "game" / "embodiment_protocol_packages" / "llm-controller-0.2.0"
    )
    v2 = VersionedEmbodimentProtocolPackage(
        package_root,
        protocol_version="llm-controller/0.2.0",
        verify_lock=False,
    )
    v2_lock = canonical_json_bytes(v2.build_lock()) + b"\n"
    v3_root = (
        repository_root / "game" / "embodiment_protocol_packages" / "llm-controller-0.3.0"
    )
    v3 = VersionedEmbodimentProtocolPackage(
        v3_root,
        protocol_version="llm-controller/0.3.0",
        verify_lock=False,
    )
    v3_lock = canonical_json_bytes(v3.build_lock()) + b"\n"
    registry = {
        "packages": [
            {
                "package_sha256": v1.package_sha256,
                "path": SUPPORTED_PROTOCOL_PATHS["llm-controller/0.1.0"],
                "protocol_version": "llm-controller/0.1.0",
            },
            {
                "package_sha256": v2.build_lock()["package_sha256"],
                "path": SUPPORTED_PROTOCOL_PATHS["llm-controller/0.2.0"],
                "protocol_version": "llm-controller/0.2.0",
            },
            {
                "package_sha256": v3.build_lock()["package_sha256"],
                "path": SUPPORTED_PROTOCOL_PATHS["llm-controller/0.3.0"],
                "protocol_version": "llm-controller/0.3.0",
            },
        ],
        "registry_version": REGISTRY_VERSION,
    }
    registry_path = repository_root / "game" / "embodiment_protocol_packages" / "registry.v1.json"
    return (
        (package_root / "protocol-lock.json", v2_lock),
        (v3_root / "protocol-lock.json", v3_lock),
        (registry_path, canonical_json_bytes(registry) + b"\n"),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repository-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    artifacts = expected_artifacts(args.repository_root)
    if args.check:
        for path, expected_bytes in artifacts:
            if not path.is_file() or path.read_bytes() != expected_bytes:
                raise SystemExit(f"{path.name} is stale or non-canonical: {path}")
        return 0
    for path, expected_bytes in artifacts:
        path.write_bytes(expected_bytes)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
