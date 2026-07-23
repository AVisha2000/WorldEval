#!/usr/bin/env python3
"""Safely verify, fetch, and import explicitly selected Godot art packs."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import tarfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "godot" / "assets" / "asset_manifest.json"
ASSETS_DIR = ROOT / "godot" / "assets"
CACHE_DIR = ASSETS_DIR / ".intake" / "downloads"
CHUNK_SIZE = 1024 * 1024


def load_manifest() -> dict[str, Any]:
    with MANIFEST_PATH.open(encoding="utf-8") as handle:
        return json.load(handle)


def pack_by_id(pack_id: str) -> dict[str, Any]:
    for pack in load_manifest()["packs"]:
        if pack["id"] == pack_id:
            return pack
    choices = ", ".join(pack["id"] for pack in load_manifest()["packs"])
    raise ValueError(f"Unknown pack '{pack_id}'. Choose one of: {choices}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK_SIZE), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_locked_source(pack: dict[str, Any]) -> tuple[str, str]:
    archive_url = pack.get("archive_url")
    expected = pack.get("sha256", "")
    if not isinstance(archive_url, str) or not archive_url.startswith("https://"):
        raise ValueError(f"{pack['id']} has no reviewed HTTPS archive_url. Download from {pack['source_url']} and record it first.")
    if not isinstance(expected, str) or len(expected) != 64 or any(char not in "0123456789abcdef" for char in expected.lower()):
        raise ValueError(f"{pack['id']} has no valid SHA-256 pin. Run 'sha256' on the reviewed archive and record it first.")
    return archive_url, expected.lower()


def verify(pack: dict[str, Any], archive: Path) -> None:
    _, expected = require_locked_source(pack)
    if not archive.is_file():
        raise ValueError(f"Archive does not exist: {archive}")
    actual = sha256(archive)
    if actual != expected:
        raise ValueError(f"Checksum mismatch for {archive.name}: expected {expected}, got {actual}")
    print(f"Verified {pack['id']}: {actual}")


def safe_members(names: list[str], destination: Path) -> None:
    resolved_destination = destination.resolve()
    for name in names:
        target = (destination / name).resolve()
        if target != resolved_destination and resolved_destination not in target.parents:
            raise ValueError(f"Archive contains an unsafe path: {name}")


def extract(archive: Path, destination: Path) -> None:
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as bundle:
            safe_members(bundle.namelist(), destination)
            bundle.extractall(destination)
        return
    if tarfile.is_tarfile(archive):
        with tarfile.open(archive) as bundle:
            members = bundle.getmembers()
            safe_members([member.name for member in members], destination)
            if any(member.issym() or member.islnk() for member in members):
                raise ValueError("Archive contains links, which are not permitted for intake.")
            bundle.extractall(destination, members=members)
        return
    raise ValueError("Only .zip and tar archives are supported.")


def command_list(_: argparse.Namespace) -> None:
    for pack in load_manifest()["packs"]:
        print(f"{pack['id']}: {pack['family']} | {pack['status']} | {pack['source_url']}")


def command_sha256(args: argparse.Namespace) -> None:
    archive = Path(args.archive).expanduser().resolve()
    if not archive.is_file():
        raise ValueError(f"Archive does not exist: {archive}")
    print(sha256(archive))


def command_verify(args: argparse.Namespace) -> None:
    verify(pack_by_id(args.pack), Path(args.archive).expanduser().resolve())


def command_fetch(args: argparse.Namespace) -> None:
    pack = pack_by_id(args.pack)
    archive_url, _ = require_locked_source(pack)
    suffix = Path(urllib.parse.urlparse(archive_url).path).suffix or ".archive"
    destination = CACHE_DIR / f"{pack['id']}-{pack['version']}{suffix}"
    if destination.exists():
        verify(pack, destination)
        print(f"Using verified cached archive: {destination}")
        return
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".partial")
    try:
        print(f"Fetching {pack['id']} from its recorded archive URL...")
        with urllib.request.urlopen(archive_url, timeout=60) as response, temporary.open("wb") as output:
            shutil.copyfileobj(response, output, length=CHUNK_SIZE)
        verify(pack, temporary)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)
    print(f"Fetched and verified: {destination}")


def command_import(args: argparse.Namespace) -> None:
    pack = pack_by_id(args.pack)
    archive = Path(args.archive).expanduser().resolve()
    verify(pack, archive)
    destination = ASSETS_DIR / "external" / pack["id"]
    if destination.exists():
        raise ValueError(f"Refusing to overwrite existing import: {destination}")
    destination.mkdir(parents=True)
    try:
        extract(archive, destination)
    except Exception:
        shutil.rmtree(destination)
        raise
    print(f"Imported verified {pack['id']} to {destination}")
    print("Open the Godot project to generate local import metadata.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("list", help="List explicit pack choices.").set_defaults(func=command_list)
    hash_parser = subparsers.add_parser("sha256", help="Print a local archive SHA-256.")
    hash_parser.add_argument("archive")
    hash_parser.set_defaults(func=command_sha256)
    for name, handler, help_text in (("verify", command_verify, "Verify a local archive against its manifest pin."), ("fetch", command_fetch, "Fetch the pinned archive for one selected pack."), ("import", command_import, "Extract a verified archive into godot/assets/external/.")):
        command = subparsers.add_parser(name, help=help_text)
        command.add_argument("--pack", required=True, help="Exact pack id from the manifest.")
        if name != "fetch":
            command.add_argument("--archive", required=True, help="Local .zip or tar archive.")
        command.set_defaults(func=handler)
    args = parser.parse_args()
    try:
        args.func(args)
    except (OSError, ValueError, urllib.error.URLError, zipfile.BadZipFile, tarfile.TarError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
