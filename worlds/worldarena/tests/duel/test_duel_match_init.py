from __future__ import annotations

import hashlib
import shutil
from pathlib import Path
from typing import Any, Dict, Tuple

import pytest
from genesis_arena.duel.canonical import (
    canonical_json_bytes,
    canonical_sha256,
    strict_json_loads,
)
from genesis_arena.duel.match_init import (
    MatchInitAssembler,
    MatchInitAssembly,
    MatchInitAssemblyError,
    assemble_match_init,
)
from genesis_arena.duel.models import MatchConfig, MatchInit
from genesis_arena.duel.protocol import ProtocolPackage
from genesis_arena.duel.runtime import (
    MAX_CANONICAL_INPUT_BYTES,
    FixedPlayerInput,
    canonical_provider_input_envelope_bytes,
)
from genesis_arena.duel.schema_validation import DuelSchemaValidator

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ProtocolPackage(REPOSITORY_ROOT / "game" / "duel_protocol")
FACTIONS = ("vanguard-v1", "warhost-v1", "grove-v1", "crypt-v1")
MODES = ("fixed_simultaneous", "continuous_realtime")
ENGINE_BUILD_ID = "godot-4.5.stable.official.876b29033"
ENGINE_BUILD_SHA256 = "39b904eb0014941330f6435796ae0a041979802047495eb6fb87d59f327de719"


def match_config(
    faction_id: str,
    mode: str,
    *,
    maximum_match_ticks: int = 18_000,
) -> MatchConfig:
    return MatchConfig(
        decision_mode=mode,
        faction_preset_id=faction_id,
        seed=8_675_309,
        decision_period_ticks=100 if mode == "fixed_simultaneous" else 50,
        response_deadline_ms=45_000 if mode == "fixed_simultaneous" else 8_000,
        maximum_match_ticks=maximum_match_ticks,
        players=[
            {
                "slot": 0,
                "model": "private-slot-zero-model-name",
                "reasoning": "slot-zero-reasoning",
                "provider_adapter": "provider-zero",
            },
            {
                "slot": 1,
                "model": "private-slot-one-model-name",
                "reasoning": "slot-one-reasoning",
                "provider_adapter": "provider-one",
            },
        ],
    )


@pytest.fixture(scope="module")
def assemblies() -> Dict[Tuple[str, str], MatchInitAssembly]:
    assembler = MatchInitAssembler(PACKAGE)
    return {
        (mode, faction_id): assembler.assemble(
            match_config(faction_id, mode),
            match_id="m_assembly_matrix",
            engine_build_id=ENGINE_BUILD_ID,
            engine_build_sha256=ENGINE_BUILD_SHA256,
        )
        for mode in MODES
        for faction_id in FACTIONS
    }


@pytest.mark.parametrize("mode", MODES)
@pytest.mark.parametrize("faction_id", FACTIONS)
def test_all_factions_and_modes_are_pydantic_schema_and_canonical_valid(
    assemblies: Dict[Tuple[str, str], MatchInitAssembly],
    mode: str,
    faction_id: str,
) -> None:
    assembly = assemblies[(mode, faction_id)]
    decoded = strict_json_loads(assembly.canonical_bytes)

    assert MatchInit.model_validate(decoded) == assembly.message
    assert DuelSchemaValidator(PACKAGE).validate("match-init.v1.schema.json", decoded) == decoded
    assert canonical_json_bytes(decoded) == assembly.canonical_bytes
    assert assembly.player_payloads == (assembly.canonical_bytes, assembly.canonical_bytes)
    assert assembly.player_payloads[0] is assembly.player_payloads[1]

    assert decoded["faction"]["id"] == faction_id
    assert decoded["faction"]["mirror_faction"] is True
    assert decoded["decision"]["mode"] == mode
    assert decoded["decision"]["decision_period_ticks"] == (
        100 if mode == "fixed_simultaneous" else 50
    )
    assert decoded["decision"]["response_deadline_ms"] == (
        45_000 if mode == "fixed_simultaneous" else 8_000
    )
    assert decoded["decision"]["validity_window_ticks"] == (
        1 if mode == "fixed_simultaneous" else 100
    )
    assert decoded["decision"]["max_in_flight_calls_per_player"] == 1

    for private_value in (
        b"private-slot-zero-model-name",
        b"private-slot-one-model-name",
        b"slot-zero-reasoning",
        b"slot-one-reasoning",
        b"provider-zero",
        b"provider-one",
    ):
        assert private_value not in assembly.canonical_bytes


@pytest.mark.parametrize("faction_id", FACTIONS)
def test_selected_faction_catalogs_and_starting_slots_are_complete(
    assemblies: Dict[Tuple[str, str], MatchInitAssembly], faction_id: str
) -> None:
    decoded = strict_json_loads(
        assemblies[("fixed_simultaneous", faction_id)].canonical_bytes
    )
    faction = PACKAGE.read_json(f"catalogs/factions/{faction_id}.json")
    public = decoded["public_catalogs"]
    assert public["units"] == faction["units"]
    assert public["buildings"] == faction["structures"]
    assert public["heroes"] == faction["heroes"]
    assert public["abilities"] == faction["abilities"]
    assert public["upgrades"] == faction["upgrades"]

    map_manifest = PACKAGE.read_json("maps/crossroads-duel-v1.json")
    expected_spawns = sorted(
        (
            spawn
            for spawn in map_manifest["spawns"]
            if spawn["seat"] == 0 and spawn["kind"] == "unit"
        ),
        key=lambda spawn: spawn["id"],
    )
    entities = decoded["starting_state"]["entities"]
    assert [entity["position_mt"] for entity in entities] == [
        spawn["position_mt"] for spawn in expected_spawns
    ]
    assert [entity["entity_id"] for entity in entities] == sorted(
        entity["entity_id"] for entity in entities
    )
    assert sum(entity["food"] for entity in entities) == 5

    starting = faction["starting_state"]
    expected_types = [starting["worker_type_id"]] * starting["worker_count"]
    for special in starting["special_units"]:
        expected_types.extend([special["type_id"]] * special["count"])
    assert [entity["type_id"] for entity in entities] == expected_types

    role_to_type = {
        structure["shared_role"]: structure["type_id"]
        for structure in faction["structures"].values()
    }
    assert [structure["type_id"] for structure in decoded["starting_state"]["structures"]] == [
        role_to_type["food"],
        role_to_type["stronghold"],
    ]


def test_crypt_expands_to_three_acolytes_and_two_ghasts(
    assemblies: Dict[Tuple[str, str], MatchInitAssembly],
) -> None:
    starting_state = assemblies[("fixed_simultaneous", "crypt-v1")].message.starting_state
    assert [entity["type_id"] for entity in starting_state["entities"]] == [
        "acolyte",
        "acolyte",
        "acolyte",
        "ghast",
        "ghast",
    ]
    assert [entity["entity_id"] for entity in starting_state["entities"]] == [
        "e_start_worker_01",
        "e_start_worker_02",
        "e_start_worker_03",
        "e_start_worker_04",
        "e_start_worker_05",
    ]


def test_every_artifact_reference_is_the_raw_locked_byte_hash(
    assemblies: Dict[Tuple[str, str], MatchInitAssembly],
) -> None:
    artifact_paths = {
        ("ruleset",): "catalogs/rules.duel-v1.json",
        ("map",): "maps/crossroads-duel-v1.json",
        ("artifacts", "protocol"): "VERSION",
        ("artifacts", "prompt"): "prompts/commander-system.v1.txt",
        ("artifacts", "helper"): "catalogs/actions.hybrid-v1.json",
        ("artifacts", "items"): "catalogs/items.duel-v1.json",
        ("artifacts", "neutrals"): "catalogs/neutrals.duel-v1.json",
        ("artifacts", "attack_armor"): "catalogs/attack-armor.duel-v1.json",
    }
    for faction_id in FACTIONS:
        decoded = strict_json_loads(
            assemblies[("fixed_simultaneous", faction_id)].canonical_bytes
        )
        expected = dict(artifact_paths)
        expected[("faction",)] = f"catalogs/factions/{faction_id}.json"
        for key_path, artifact_path in expected.items():
            reference: Any = decoded
            for key in key_path:
                reference = reference[key]
            assert reference["sha256"] == hashlib.sha256(
                PACKAGE.path(artifact_path).read_bytes()
            ).hexdigest()
        assert decoded["artifacts"]["engine_build"] == {
            "id": ENGINE_BUILD_ID,
            "sha256": ENGINE_BUILD_SHA256,
        }


def test_locked_reference_fixture_is_rebuilt_byte_for_byte() -> None:
    assembly = assemble_match_init(
        match_config("vanguard-v1", "fixed_simultaneous"),
        match_id="m_fixture_0042",
        engine_build_id="duel-engine-fixture-v1",
        engine_build_sha256=(
            "74ec380ae364d708c3cbc10a70113cf0588d1a8edae5d47899b145455b67daae"
        ),
        package=PACKAGE,
    )
    expected = canonical_json_bytes(
        strict_json_loads(PACKAGE.path("fixtures/match-init.valid.json").read_bytes())
    )
    assert assembly.canonical_bytes == expected


def test_maximal_provider_envelopes_fit_for_every_faction_and_mode() -> None:
    # Exercise the longest legal dynamic identifiers, not merely the short fixture values.
    match_id = "m_" + "m" * 120
    engine_build_id = "e" * 96
    sizes: Dict[Tuple[str, str], int] = {}
    assembler = MatchInitAssembler(PACKAGE)
    for mode in MODES:
        observation = PACKAGE.read_json("fixtures/observation.maximal.valid.json")
        observation["match_id"] = match_id
        observation["decision"]["mode"] = mode
        observation["decision"]["response_deadline_ms"] = (
            45_000 if mode == "fixed_simultaneous" else 8_000
        )
        observation["decision"]["valid_until_tick"] = (
            1_801 if mode == "fixed_simultaneous" else 1_900
        )
        hash_payload = dict(observation)
        hash_payload.pop("observation_hash")
        observation["observation_hash"] = canonical_sha256(hash_payload)
        DuelSchemaValidator(PACKAGE).validate(
            "observation.v1.schema.json", observation
        )
        observation_bytes = canonical_json_bytes(observation)
        for faction_id in FACTIONS:
            assembly = assembler.assemble(
                match_config(faction_id, mode),
                match_id=match_id,
                engine_build_id=engine_build_id,
                engine_build_sha256="3" * 64,
            )
            provider_input = FixedPlayerInput(
                player_slot=0,
                system_prompt=assembly.system_prompt,
                match_init_json=assembly.canonical_bytes,
                observation_json=observation_bytes,
                action_schema_json=assembly.action_schema_bytes,
                validation_context=object(),
            )
            size = len(canonical_provider_input_envelope_bytes(provider_input))
            sizes[(mode, faction_id)] = size
            assert size <= assembly.message.limits["max_input_bytes"]
            assert size <= MAX_CANONICAL_INPUT_BYTES

    assert max(sizes.items(), key=lambda item: item[1]) == (
        ("continuous_realtime", "grove-v1"),
        242_833,
    )
    assert MAX_CANONICAL_INPUT_BYTES - max(sizes.values()) == 19_311


def test_assembly_is_reproducible_and_player_payloads_are_static() -> None:
    config = match_config("warhost-v1", "continuous_realtime")
    first = MatchInitAssembler(PACKAGE).assemble(
        config,
        match_id="m_reproducible",
        engine_build_id=ENGINE_BUILD_ID,
        engine_build_sha256=ENGINE_BUILD_SHA256,
    )
    second = MatchInitAssembler(PACKAGE).assemble(
        config,
        match_id="m_reproducible",
        engine_build_id=ENGINE_BUILD_ID,
        engine_build_sha256=ENGINE_BUILD_SHA256,
    )
    assert first.canonical_bytes == second.canonical_bytes
    assert first.action_schema_bytes == second.action_schema_bytes
    assert first.system_prompt == second.system_prompt
    assert first.player_payloads[0] == first.player_payloads[1]


@pytest.mark.parametrize(
    "bad_config",
    [
        match_config("vanguard-v1", "fixed_simultaneous").model_copy(
            update={"mirror_faction": False}
        ),
        match_config("vanguard-v1", "fixed_simultaneous").model_copy(
            update={"faction_preset_id": "not-locked-v1"}
        ),
        match_config("vanguard-v1", "fixed_simultaneous").model_copy(
            update={"map_id": "not-locked-map-v1"}
        ),
        match_config(
            "vanguard-v1", "fixed_simultaneous", maximum_match_ticks=1_000
        ),
    ],
)
def test_bad_non_mirrored_or_non_official_configs_fail_closed(
    bad_config: MatchConfig,
) -> None:
    with pytest.raises(MatchInitAssemblyError):
        MatchInitAssembler(PACKAGE).assemble(
            bad_config,
            match_id="m_bad_config",
            engine_build_id=ENGINE_BUILD_ID,
            engine_build_sha256=ENGINE_BUILD_SHA256,
        )


@pytest.mark.parametrize(
    ("engine_build_id", "engine_build_sha256"),
    [
        ("Uppercase-is-not-canonical", ENGINE_BUILD_SHA256),
        (ENGINE_BUILD_ID, "A" * 64),
        (ENGINE_BUILD_ID, "0" * 63),
    ],
)
def test_bad_engine_references_fail_closed(
    engine_build_id: str, engine_build_sha256: str
) -> None:
    with pytest.raises(MatchInitAssemblyError):
        MatchInitAssembler(PACKAGE).assemble(
            match_config("vanguard-v1", "fixed_simultaneous"),
            match_id="m_bad_engine",
            engine_build_id=engine_build_id,
            engine_build_sha256=engine_build_sha256,
        )


def test_tampered_or_unlocked_package_fails_before_emitting_bytes(tmp_path: Path) -> None:
    copied_root = tmp_path / "duel_protocol"
    shutil.copytree(PACKAGE.root, copied_root)
    tampered_prompt = copied_root / "prompts" / "commander-system.v1.txt"
    tampered_prompt.write_bytes(tampered_prompt.read_bytes() + b"tampered")

    with pytest.raises(MatchInitAssemblyError, match="lock mismatch"):
        MatchInitAssembler(ProtocolPackage(copied_root)).assemble(
            match_config("vanguard-v1", "fixed_simultaneous"),
            match_id="m_tampered",
            engine_build_id=ENGINE_BUILD_ID,
            engine_build_sha256=ENGINE_BUILD_SHA256,
        )
