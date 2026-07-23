from __future__ import annotations

from pathlib import Path

from tools.check_document_links import check_document


def test_document_link_checker_accepts_local_anchor_and_external_links(
    tmp_path: Path,
) -> None:
    target = tmp_path / "guide.md"
    target.write_text("# Guide\n", encoding="utf-8")
    document = tmp_path / "README.md"
    document.write_text(
        "[guide](guide.md#start) [anchor](#local) [site](https://example.com)\n",
        encoding="utf-8",
    )
    assert check_document(document, tmp_path) == []


def test_document_link_checker_rejects_missing_and_escaping_targets(
    tmp_path: Path,
) -> None:
    root = tmp_path / "workspace"
    root.mkdir()
    document = root / "README.md"
    document.write_text("[missing](nope.md) [escape](../private.md)\n", encoding="utf-8")
    findings = check_document(document, root)
    assert [(finding.target, finding.reason) for finding in findings] == [
        ("nope.md", "target does not exist"),
        ("../private.md", "link escapes workspace"),
    ]
