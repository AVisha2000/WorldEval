#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path


def _repository_root() -> Path:
    return Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate or verify the immutable WorldArena Duel protocol lock."
    )
    parser.add_argument("--check", action="store_true", help="verify without writing")
    parser.add_argument(
        "--package",
        type=Path,
        default=_repository_root() / "game" / "duel_protocol",
        help="protocol package root",
    )
    args = parser.parse_args()

    sys.path.insert(0, str(_repository_root() / "backend"))
    from genesis_arena.duel import ProtocolPackage, ProtocolPackageError

    package = ProtocolPackage(args.package)
    try:
        if args.check:
            lock = package.verify_lock()
            print(f"verified {len(lock['artifacts'])} artifacts: {lock['package_sha256']}")
            return 0
        destination = package.path("protocol-lock.json")
        destination.write_bytes(package.lock_bytes())
        print(f"wrote {destination} ({len(package.artifact_paths())} artifacts)")
        return 0
    except ProtocolPackageError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
