#!/usr/bin/env python3
"""Validate repository-local Markdown links outside the historical archive."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence
from urllib.parse import unquote, urlsplit

from worldeval.workspace import find_workspace

_LINK = re.compile(r"!?\[[^\]]*\]\((?P<target><[^>]+>|[^)\s]+)(?:\s+[^)]*)?\)")
_SKIP_PARTS = frozenset({".git", ".venv", "node_modules", "dist", "archive"})
_EXTERNAL_SCHEMES = frozenset({"app", "data", "file", "http", "https", "mailto", "tel"})


@dataclass(frozen=True)
class BrokenLink:
    document: Path
    target: str
    reason: str


def markdown_files(roots: Iterable[Path]) -> list[Path]:
    files: list[Path] = []
    for root in roots:
        selected = Path(root)
        candidates = (selected,) if selected.is_file() else selected.rglob("*.md")
        for path in candidates:
            if path.is_file() and not _SKIP_PARTS.intersection(path.parts):
                files.append(path)
    return sorted(set(files))


def check_document(path: Path, workspace_root: Path) -> list[BrokenLink]:
    try:
        text = Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return [BrokenLink(Path(path), "", "document is not readable UTF-8")]
    findings: list[BrokenLink] = []
    for match in _LINK.finditer(text):
        raw = match.group("target").strip("<>")
        if not raw or raw.startswith("#"):
            continue
        parsed = urlsplit(raw)
        if parsed.scheme.lower() in _EXTERNAL_SCHEMES or parsed.netloc:
            continue
        if parsed.path.startswith("/"):
            # Root-relative web application routes are not filesystem links.
            continue
        target = unquote(parsed.path)
        if not target:
            continue
        resolved = (Path(path).parent / target).resolve()
        try:
            resolved.relative_to(workspace_root.resolve())
        except ValueError:
            findings.append(BrokenLink(Path(path), raw, "link escapes workspace"))
            continue
        if not resolved.exists():
            findings.append(BrokenLink(Path(path), raw, "target does not exist"))
    return findings


def main(argv: Sequence[str] | None = None) -> int:
    workspace = find_workspace(Path.cwd())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", type=Path)
    arguments = parser.parse_args(argv)
    roots = arguments.paths or [
        workspace.root / "README.md",
        workspace.root / "AGENTS.md",
        workspace.root / "docs",
        workspace.root / "features",
        workspace.path("worldeval"),
        workspace.path("worldarena") / "AGENTS.md",
        workspace.path("worldarena") / "demos",
        workspace.path("worldarena") / "games",
        workspace.path("worldeval_web") / "README.md",
        workspace.path("worldeval_web") / "AGENTS.md",
        workspace.path("operations"),
        workspace.path("media"),
    ]
    documents = markdown_files(roots)
    findings = [
        finding
        for document in documents
        for finding in check_document(document, workspace.root)
    ]
    if findings:
        for finding in findings:
            display = finding.document.resolve().relative_to(workspace.root)
            print(f"DOCUMENT_LINK_ERROR {display}: {finding.target} ({finding.reason})")
        return 1
    print(f"DOCUMENT_LINKS_OK files={len(documents)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
