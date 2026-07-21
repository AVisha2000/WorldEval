from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest
from genesis_arena.embodiment.protocol import ProtocolValidationError
from genesis_arena.embodiment.protocol_registry import EmbodimentProtocolRegistry

ROOT = Path(__file__).resolve().parents[2]
V1_SHA256 = "ddfc8998dfe33c0bb68aff31f78118a227792f4d568bd438d732c3d3abe0c34d"
V2_SHA256 = "edbd41865f3ed7186b02f6d370dd6e655910bcfebe66c330bafa42d5e533fff5"
V3_SHA256 = "4b39a9fb9c7dd056092131dfa18c93e1174ef16bc6ec45f443917de731387f08"


@pytest.fixture(scope="module")
def registry() -> EmbodimentProtocolRegistry:
    return EmbodimentProtocolRegistry.from_repository(ROOT)


def episode_config(protocol_version: str, task_id: str) -> dict[str, object]:
    return {
        "protocol_version": protocol_version,
        "episode_id": "ep_registry_contract",
        "mode": "solo-curriculum-v0",
        "task_id": task_id,
        "seed": 19,
        "observation_profile": "hybrid-visible-v1",
        "timing_track": "step-locked-v1",
        "maximum_episode_ticks": 1200,
        "participant_ids": ["participant_0"],
    }


def test_registry_loads_exact_hash_bound_packages(
    registry: EmbodimentProtocolRegistry,
) -> None:
    assert registry.available_versions == (
        "llm-controller/0.1.0",
        "llm-controller/0.2.0",
        "llm-controller/0.3.0",
    )
    v1 = registry.package("llm-controller/0.1.0")
    v2 = registry.package("llm-controller/0.2.0")
    v3 = registry.package("llm-controller/0.3.0")
    assert v1.package_sha256 == V1_SHA256
    assert v2.package_sha256 == V2_SHA256
    assert v3.package_sha256 == V3_SHA256
    assert registry.package("llm-controller/0.1.0") is v1
    assert registry.package("llm-controller/0.2.0") is v2


@pytest.mark.parametrize("task_id", ["movement-maze-v0", "operator-action-course-v0"])
def test_v2_adds_solo_control_game_ids_without_changing_v1(
    registry: EmbodimentProtocolRegistry, task_id: str
) -> None:
    v2_config = episode_config("llm-controller/0.2.0", task_id)
    registry.validate("llm-controller/0.2.0", "episode-config", v2_config)
    with pytest.raises(ProtocolValidationError):
        registry.validate(
            "llm-controller/0.1.0",
            "episode-config",
            {**v2_config, "protocol_version": "llm-controller/0.1.0"},
        )
    with pytest.raises(ProtocolValidationError):
        registry.validate(
            "llm-controller/0.2.0",
            "episode-config",
            {
                **v2_config,
                "mode": "model-duel-v0",
                "participant_ids": ["participant_0", "participant_1"],
            },
        )


def test_packages_reject_cross_version_payloads_and_unknown_tasks(
    registry: EmbodimentProtocolRegistry,
) -> None:
    v1_config = episode_config("llm-controller/0.1.0", "orientation-v0")
    registry.validate("llm-controller/0.1.0", "episode-config", v1_config)
    with pytest.raises(ProtocolValidationError):
        registry.validate("llm-controller/0.2.0", "episode-config", v1_config)
    with pytest.raises(ProtocolValidationError):
        registry.validate(
            "llm-controller/0.2.0",
            "episode-config",
            episode_config("llm-controller/0.2.0", "hidden-route-v0"),
        )


def test_v2_retains_contract_surface_and_claims_only_integrated_control_games(
    registry: EmbodimentProtocolRegistry,
) -> None:
    v1 = registry.package("llm-controller/0.1.0")
    v2 = registry.package("llm-controller/0.2.0")
    assert tuple(v1.SCHEMA_FILES) == tuple(v2.SCHEMA_FILES)
    assert not any(path.is_symlink() for path in v2.artifact_paths())
    manifest = v2.manifest
    assert manifest["observations"]["default_profile"] == "text-visible-v1"
    assert manifest["capabilities"]["implemented_observation_profiles"] == [
        "text-visible-v1",
        "hybrid-visible-v1",
    ]
    assert "managed_solo_task_plans" not in manifest
    assert [item["id"] for item in manifest["curriculum"]][4:6] == [
        "movement-maze-v0",
        "operator-action-course-v0",
    ]
    assert manifest["capabilities"]["implemented_tasks"] == [
        "movement-maze-v0",
        "operator-action-course-v0",
        "duo-checkpoint-race-v0",
        "duo-relay-control-v0",
        "duo-spar-v0",
        "duo-resource-relay-v0",
        "rts-skirmish-v0",
    ]


def test_v2_schema_ids_and_refs_are_version_qualified_and_do_not_collide(
    registry: EmbodimentProtocolRegistry,
) -> None:
    v1 = registry.package("llm-controller/0.1.0")
    v2 = registry.package("llm-controller/0.2.0")
    v1_ids = {str(v1.schema(name)["$id"]) for name in v1.SCHEMA_FILES}
    v2_ids = {str(v2.schema(name)["$id"]) for name in v2.SCHEMA_FILES}

    assert v1_ids.isdisjoint(v2_ids)
    assert all(
        value.startswith("https://worldeval.local/llm-controller/0.2.0/")
        for value in v2_ids
    )

    refs: list[str] = []

    def collect_refs(value: object) -> None:
        if isinstance(value, dict):
            reference = value.get("$ref")
            if isinstance(reference, str):
                refs.append(reference)
            for child in value.values():
                collect_refs(child)
        elif isinstance(value, list):
            for child in value:
                collect_refs(child)

    for name in v2.SCHEMA_FILES:
        collect_refs(v2.schema(name))
    assert refs
    assert all(
        reference.startswith("https://worldeval.local/llm-controller/0.2.0/")
        for reference in refs
    )


def test_replay_selection_requires_matching_version_and_package_hash(
    registry: EmbodimentProtocolRegistry,
) -> None:
    selected = registry.package_for_replay(
        {
            "protocol_version": "llm-controller/0.2.0",
            "protocol_package_sha256": V2_SHA256,
        }
    )
    assert selected.PROTOCOL_VERSION == "llm-controller/0.2.0"
    with pytest.raises(ProtocolValidationError, match="does not match registry"):
        registry.package_for_replay(
            {
                "protocol_version": "llm-controller/0.2.0",
                "protocol_package_sha256": V1_SHA256,
            }
        )
    with pytest.raises(ProtocolValidationError, match="unsupported"):
        registry.package_for_replay(
            {
                "protocol_version": "llm-controller/9.9.9",
                "protocol_package_sha256": V2_SHA256,
            }
        )


def test_registry_parser_rejects_unknown_fields(tmp_path: Path) -> None:
    source = json.loads(
        (ROOT / "game" / "embodiment_protocol_packages" / "registry.v1.json").read_text()
    )
    source["private_route"] = "forbidden"
    path = tmp_path / "registry.v1.json"
    path.write_text(json.dumps(source), encoding="utf-8")
    with pytest.raises(ProtocolValidationError, match="unknown fields"):
        EmbodimentProtocolRegistry(path)


def test_v2_lock_and_registry_are_reproducible() -> None:
    completed = subprocess.run(
        [
            str(ROOT / ".venv" / "bin" / "python"),
            str(ROOT / "scripts" / "build_embodiment_protocol_registry.py"),
            "--repository-root",
            str(ROOT),
            "--check",
        ],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    assert completed.returncode == 0, completed.stderr or completed.stdout
