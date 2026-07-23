from __future__ import annotations

import json

import pytest
from genesis_arena.arena import (
    ModelSnapshot,
    RunArtifactStore,
    RunManifest,
)
from pydantic import ValidationError


def manifest() -> RunManifest:
    return RunManifest(
        match_id="match-artifact",
        map_id="tri-13-v1",
        map_hash="a" * 64,
        rules_id="arena-v1",
        rules_hash="b" * 64,
        tool_hash="c" * 64,
        seed=42,
        cognition_track="agentic",
        models=[
            ModelSnapshot(
                faction_id=faction,
                model="model-test",
                reasoning_effort="low",
                prompt_hash="d" * 64,
            )
            for faction in ("sol", "terra", "luna")
        ],
    )


def test_store_creates_secret_free_manifest_and_replay_index(tmp_path) -> None:
    store = RunArtifactStore(tmp_path)
    directory = store.create(manifest())

    persisted = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    assert persisted["match_id"] == "match-artifact"
    assert "api_key" not in persisted
    replay = json.loads((directory / "replay.json").read_text(encoding="utf-8"))
    assert replay["rounds_file"] == "rounds.jsonl"


def test_store_allocates_a_new_immutable_directory_for_reused_protocol_match_id(tmp_path) -> None:
    first = RunArtifactStore(tmp_path)
    second = RunArtifactStore(tmp_path)

    first_directory = first.create(manifest())
    second_directory = second.create(manifest())

    assert first_directory.name == "match-artifact"
    assert second_directory.name == "match-artifact-001"
    assert json.loads((first_directory / "manifest.json").read_text()) == json.loads(
        (second_directory / "manifest.json").read_text()
    )


def test_store_rejects_secret_bearing_checkpoint_fields(tmp_path) -> None:
    store = RunArtifactStore(tmp_path)
    store.create(manifest())
    with pytest.raises(ValueError, match="cannot be persisted"):
        store.write_checkpoint(
            "match-artifact",
            0,
            {"state_hash": "e" * 64, "nested": {"api_key": "sk-do-not-write"}},
        )


@pytest.mark.parametrize(
    "secret_value",
    [
        "Bearer abcdefghijklmnopqrstuvwxyz",
        "sk-" + "proj-" + "abcdefghijklmnop",
        "ghp" + "_abcdefghijklmnopqrstuvwxyz",
        "-----BEGIN PRIVATE KEY-----",
    ],
)
def test_store_rejects_secret_like_values(tmp_path, secret_value: str) -> None:
    store = RunArtifactStore(tmp_path)
    store.create(manifest())
    with pytest.raises(ValueError, match="secret-like value"):
        store.write_checkpoint("match-artifact", 0, {"diagnostic": secret_value})


def test_manifest_metadata_is_typed_and_allowlisted() -> None:
    payload = manifest().model_dump(mode="json")
    payload["metadata"] = {"connection": "not-a-supported-manifest-field"}
    with pytest.raises(ValidationError):
        RunManifest.model_validate(payload)


def test_manifest_requires_one_model_per_faction() -> None:
    payload = manifest().model_dump(mode="json")
    payload["models"] = [payload["models"][0]] * 3
    with pytest.raises(ValidationError, match="one model per faction"):
        RunManifest.model_validate(payload)
