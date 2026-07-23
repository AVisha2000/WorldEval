"""Fail-closed assembly of immutable WorldArena Duel ``MATCH_INIT`` payloads.

The assembler is deliberately a consumer of the locked protocol package.  It does not carry a
second copy of unit costs, map coordinates, timing limits, or starting-state values in Python.
Every public gameplay value is loaded from an artifact whose raw bytes are covered by
``protocol-lock.json``; the resulting message is then checked by both Pydantic and the frozen
Draft 2020-12 schema before canonical bytes are exposed to a provider adapter.
"""

from __future__ import annotations

# ruff: noqa: UP045 -- Keep runtime-compatible public annotations for Python 3.9.
import copy
import hashlib
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Tuple, Union

from pydantic import ValidationError

from .canonical import canonical_json_bytes, strict_json_loads
from .models import MatchConfig, MatchInit
from .protocol import ProtocolPackage, ProtocolPackageError
from .schema_validation import DuelSchemaValidator, ProtocolSchemaError

_ENGINE_BUILD_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_.:-]{0,95}$")
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

_RULES_PATH = "catalogs/rules.duel-v1.json"
_ACTIONS_PATH = "catalogs/actions.hybrid-v1.json"
_ATTACK_ARMOR_PATH = "catalogs/attack-armor.duel-v1.json"
_ITEMS_PATH = "catalogs/items.duel-v1.json"
_NEUTRALS_PATH = "catalogs/neutrals.duel-v1.json"
_MAP_PATH = "maps/crossroads-duel-v1.json"
_ACTION_SCHEMA_PATH = "schemas/action-batch.v1.schema.json"
_PROMPT_PATH = "prompts/commander-system.v1.txt"
_TEMPLATE_PATH = "fixtures/match-init.valid.json"


class MatchInitAssemblyError(ProtocolPackageError):
    """A config or locked artifact set cannot produce one trustworthy match init."""


@dataclass(frozen=True)
class MatchInitAssembly:
    """Validated provider-facing static inputs for one mirrored match.

    ``player_payloads`` contains the same immutable bytes twice by construction.  Player model
    identities, provider adapters, seat assignment, and hidden seed state never enter the message.
    """

    message: MatchInit
    canonical_bytes: bytes
    player_payloads: Tuple[bytes, bytes]
    system_prompt: str
    action_schema_bytes: bytes


@dataclass(frozen=True)
class _LockedDigest:
    size_bytes: int
    sha256: str


class _LockedSnapshot:
    """Read artifacts against one already-verified lock, including post-verify byte checks."""

    def __init__(self, package: ProtocolPackage) -> None:
        self.package = package
        lock = package.verify_lock()
        self._digests: Dict[str, _LockedDigest] = {}
        for artifact in lock["artifacts"]:
            relative_path = artifact["path"]
            self._digests[relative_path] = _LockedDigest(
                size_bytes=artifact["size_bytes"],
                sha256=artifact["sha256"],
            )

    def read_bytes(self, relative_path: str) -> bytes:
        digest = self._digests.get(relative_path)
        if digest is None:
            raise MatchInitAssemblyError(
                f"artifact is not covered by protocol lock: {relative_path}"
            )
        payload = self.package.path(relative_path).read_bytes()
        actual_sha256 = hashlib.sha256(payload).hexdigest()
        if len(payload) != digest.size_bytes or actual_sha256 != digest.sha256:
            raise MatchInitAssemblyError(
                f"locked artifact changed while assembling MATCH_INIT: {relative_path}"
            )
        return payload

    def read_json(self, relative_path: str) -> Dict[str, Any]:
        try:
            value = strict_json_loads(self.read_bytes(relative_path))
        except ValueError as exc:
            raise MatchInitAssemblyError(
                f"locked artifact is not strict Duel JSON: {relative_path}"
            ) from exc
        if not isinstance(value, dict):
            raise MatchInitAssemblyError(f"locked artifact root is not an object: {relative_path}")
        return value

    def sha256(self, relative_path: str) -> str:
        # Read again so a hash reference is never emitted for bytes that were not actually checked.
        self.read_bytes(relative_path)
        return self._digests[relative_path].sha256


class MatchInitAssembler:
    """Build schema-valid, self-canonical static match inputs from the frozen package."""

    def __init__(self, package: Optional[ProtocolPackage] = None) -> None:
        self.package = package or ProtocolPackage()

    def assemble(
        self,
        config: Union[MatchConfig, Mapping[str, Any]],
        *,
        match_id: str,
        engine_build_id: str,
        engine_build_sha256: str,
    ) -> MatchInitAssembly:
        """Assemble one match package and its byte-identical slot-0/slot-1 payloads."""

        try:
            snapshot = _LockedSnapshot(self.package)
        except MatchInitAssemblyError:
            raise
        except ProtocolPackageError as exc:
            raise MatchInitAssemblyError(
                f"protocol package is not completely locked: {exc}"
            ) from exc
        validator = DuelSchemaValidator(self.package)
        validated_config = self._validate_config(config, validator)
        self._validate_engine_reference(engine_build_id, engine_build_sha256)

        rules = snapshot.read_json(_RULES_PATH)
        actions = snapshot.read_json(_ACTIONS_PATH)
        attack_armor = snapshot.read_json(_ATTACK_ARMOR_PATH)
        items = snapshot.read_json(_ITEMS_PATH)
        neutrals = snapshot.read_json(_NEUTRALS_PATH)
        map_manifest = snapshot.read_json(_MAP_PATH)
        action_schema = snapshot.read_json(_ACTION_SCHEMA_PATH)
        template = snapshot.read_json(_TEMPLATE_PATH)
        faction_path = f"catalogs/factions/{validated_config.faction_preset_id}.json"
        faction = snapshot.read_json(faction_path)

        self._validate_catalog_identity(
            validated_config,
            rules=rules,
            actions=actions,
            attack_armor=attack_armor,
            items=items,
            neutrals=neutrals,
            faction=faction,
            map_manifest=map_manifest,
        )
        self._validate_template(template, validator)

        profile = _require_mapping(
            _require_mapping(rules, "official_profiles"),
            validated_config.decision_mode,
        )
        limits = self._build_limits(rules=rules, actions=actions, profile=profile)
        decision = self._build_decision(validated_config, profile)
        starting_state = self._build_starting_state(
            rules=rules,
            faction=faction,
            map_manifest=map_manifest,
            template=template,
        )

        prompt_bytes = snapshot.read_bytes(_PROMPT_PATH)
        try:
            system_prompt = prompt_bytes.decode("utf-8", errors="strict")
        except UnicodeDecodeError as exc:
            raise MatchInitAssemblyError("locked commander prompt is not valid UTF-8") from exc
        if not system_prompt or system_prompt.encode("utf-8") != prompt_bytes:
            raise MatchInitAssemblyError(
                "locked commander prompt did not round-trip as exact UTF-8"
            )

        payload: Dict[str, Any] = {
            "message_type": "match_init",
            "protocol_version": validated_config.protocol_version,
            "match_id": match_id,
            "perspective": "self",
            "artifacts": {
                "protocol": _hash_ref(
                    validated_config.protocol_version.replace("/", "-"),
                    snapshot.sha256("VERSION"),
                ),
                "engine_build": _hash_ref(engine_build_id, engine_build_sha256),
                "prompt": _hash_ref(
                    _artifact_id_from_filename(_PROMPT_PATH),
                    snapshot.sha256(_PROMPT_PATH),
                ),
                "helper": _hash_ref(
                    _helper_id(actions),
                    snapshot.sha256(_ACTIONS_PATH),
                ),
                "items": _hash_ref(
                    _require_string(items, "catalog_id"),
                    snapshot.sha256(_ITEMS_PATH),
                ),
                "neutrals": _hash_ref(
                    _require_string(neutrals, "catalog_id"),
                    snapshot.sha256(_NEUTRALS_PATH),
                ),
                "attack_armor": _hash_ref(
                    _require_string(attack_armor, "catalog_id"),
                    snapshot.sha256(_ATTACK_ARMOR_PATH),
                ),
            },
            "ruleset": _hash_ref(
                validated_config.ruleset_id,
                snapshot.sha256(_RULES_PATH),
            ),
            "faction": {
                **_hash_ref(validated_config.faction_preset_id, snapshot.sha256(faction_path)),
                "mirror_faction": True,
            },
            "map": _hash_ref(validated_config.map_id, snapshot.sha256(_MAP_PATH)),
            "decision": decision,
            "limits": limits,
            "coordinate_frame": self._coordinate_frame(rules, template),
            "victory_rules": self._victory_rules(rules, template),
            "draw_rules": self._draw_rules(validated_config, rules, template),
            "failure_rules": self._failure_rules(rules, actions, template),
            "observation_rules": self._observation_rules(
                validated_config, rules, template
            ),
            "memory_rules": self._memory_rules(validated_config, rules, actions, template),
            "scoring_rules": copy.deepcopy(template["scoring_rules"]),
            "action_schema": action_schema,
            "public_catalogs": {
                "rules": rules,
                "actions": actions,
                "attack_armor": attack_armor,
                "units": _require_mapping(faction, "units"),
                "buildings": _require_mapping(faction, "structures"),
                "heroes": _require_mapping(faction, "heroes"),
                "abilities": _require_mapping(faction, "abilities"),
                "items": items,
                "upgrades": _require_mapping(faction, "upgrades"),
                "neutrals": neutrals,
            },
            "map_manifest": map_manifest,
            "starting_state": starting_state,
        }

        try:
            message = MatchInit.model_validate(payload)
            normalized = message.model_dump(mode="json")
            validator.validate("match-init.v1.schema.json", normalized)
        except (ValidationError, ProtocolSchemaError, ValueError, TypeError) as exc:
            raise MatchInitAssemblyError(f"assembled MATCH_INIT failed closed: {exc}") from exc

        canonical_bytes = canonical_json_bytes(normalized)
        if strict_json_loads(canonical_bytes) != normalized:
            raise MatchInitAssemblyError("canonical MATCH_INIT did not round-trip exactly")
        action_schema_bytes = canonical_json_bytes(action_schema)
        return MatchInitAssembly(
            message=message,
            canonical_bytes=canonical_bytes,
            player_payloads=(canonical_bytes, canonical_bytes),
            system_prompt=system_prompt,
            action_schema_bytes=action_schema_bytes,
        )

    @staticmethod
    def _validate_config(
        config: Union[MatchConfig, Mapping[str, Any]],
        validator: DuelSchemaValidator,
    ) -> MatchConfig:
        try:
            if isinstance(config, MatchConfig):
                raw_config = config.model_dump(mode="json", exclude_none=True)
            elif isinstance(config, Mapping):
                raw_config = dict(config)
            else:
                raise TypeError("config must be MatchConfig or a mapping")
            validated = MatchConfig.model_validate(raw_config)
            validator.validate(
                "match-config.v1.schema.json",
                validated.model_dump(mode="json", exclude_none=True),
            )
        except (ValidationError, ProtocolSchemaError, ValueError, TypeError) as exc:
            raise MatchInitAssemblyError(f"invalid or non-mirrored match config: {exc}") from exc
        if validated.mirror_faction is not True:
            raise MatchInitAssemblyError("Duel MATCH_INIT requires one mirrored faction")
        return validated

    @staticmethod
    def _validate_engine_reference(engine_build_id: str, engine_build_sha256: str) -> None:
        if not isinstance(engine_build_id, str) or _ENGINE_BUILD_ID_RE.fullmatch(
            engine_build_id
        ) is None:
            raise MatchInitAssemblyError("engine_build_id is not a canonical public identifier")
        if not isinstance(engine_build_sha256, str) or _SHA256_RE.fullmatch(
            engine_build_sha256
        ) is None:
            raise MatchInitAssemblyError("engine_build_sha256 must be exact lowercase SHA-256")

    @staticmethod
    def _validate_catalog_identity(
        config: MatchConfig,
        *,
        rules: Mapping[str, Any],
        actions: Mapping[str, Any],
        attack_armor: Mapping[str, Any],
        items: Mapping[str, Any],
        neutrals: Mapping[str, Any],
        faction: Mapping[str, Any],
        map_manifest: Mapping[str, Any],
    ) -> None:
        for name, catalog in (
            ("rules", rules),
            ("actions", actions),
            ("attack_armor", attack_armor),
            ("items", items),
            ("neutrals", neutrals),
            ("faction", faction),
        ):
            _require_equal(
                _require_string(catalog, "protocol_version"),
                config.protocol_version,
                f"{name} protocol version",
            )
        for name, catalog in (
            ("rules", rules),
            ("attack_armor", attack_armor),
            ("items", items),
            ("neutrals", neutrals),
            ("faction", faction),
            ("map", map_manifest),
        ):
            _require_equal(
                _require_string(catalog, "ruleset_id"),
                config.ruleset_id,
                f"{name} ruleset",
            )
        _require_equal(
            _require_string(actions, "control_profile"),
            config.control_profile,
            "action control profile",
        )
        _require_equal(
            _require_string(faction, "faction_id"),
            config.faction_preset_id,
            "selected faction",
        )
        _require_equal(
            _require_string(map_manifest, "map_id"),
            config.map_id,
            "selected map",
        )

    @staticmethod
    def _validate_template(
        template: Mapping[str, Any], validator: DuelSchemaValidator
    ) -> None:
        try:
            MatchInit.model_validate(template)
            validator.validate("match-init.v1.schema.json", template)
        except (ValidationError, ProtocolSchemaError, ValueError, TypeError) as exc:
            raise MatchInitAssemblyError(
                f"locked MATCH_INIT invariant template is invalid: {exc}"
            ) from exc

    @staticmethod
    def _build_limits(
        *,
        rules: Mapping[str, Any],
        actions: Mapping[str, Any],
        profile: Mapping[str, Any],
    ) -> Dict[str, Any]:
        action_limits = _require_mapping(actions, "limits")
        observation = _require_mapping(rules, "observation")
        for key in (
            "maximum_output_bytes",
            "maximum_command_objects",
            "maximum_atomic_order_cost",
        ):
            action_key = {
                "maximum_output_bytes": "max_output_bytes",
                "maximum_command_objects": "max_command_objects",
                "maximum_atomic_order_cost": "max_atomic_order_cost",
            }[key]
            _require_equal(profile[key], action_limits[action_key], f"profile/action {key}")
        return {
            "max_input_bytes": observation["maximum_canonical_input_bytes"],
            "max_output_bytes": action_limits["max_output_bytes"],
            "max_command_objects": action_limits["max_command_objects"],
            "max_atomic_order_cost": action_limits["max_atomic_order_cost"],
            "max_actor_ids_per_command": action_limits["max_actor_ids_per_command"],
            "max_queue_entries_per_entity": action_limits["max_queue_entries_per_entity"],
            "max_working_memory_bytes": action_limits["max_working_memory_bytes"],
        }

    @staticmethod
    def _build_decision(config: MatchConfig, profile: Mapping[str, Any]) -> Dict[str, Any]:
        numeric_units = config.simulation_hz
        validity_ticks = profile["maximum_batch_age_ticks"]
        return {
            "mode": config.decision_mode,
            "simulation_hz": numeric_units,
            "decision_period_ticks": config.decision_period_ticks,
            "response_deadline_ms": config.response_deadline_ms,
            "control_profile": config.control_profile,
            "observation_profile": config.observation_profile,
            "validity_window_ticks": validity_ticks,
            "max_in_flight_calls_per_player": profile[
                "maximum_in_flight_calls_per_player"
            ],
        }

    @staticmethod
    def _coordinate_frame(
        rules: Mapping[str, Any], template: Mapping[str, Any]
    ) -> Dict[str, Any]:
        result = copy.deepcopy(_require_mapping(template, "coordinate_frame"))
        numeric = _require_mapping(rules, "numeric_units")
        _require_equal(result["position_unit"], numeric["position_unit"], "position unit")
        _require_equal(result["distance_unit"], numeric["position_unit"], "distance unit")
        _require_equal(result["facing_unit"], numeric["facing_unit"], "facing unit")
        _require_equal(result["percentage_unit"], numeric["percentage_unit"], "percentage unit")
        return result

    @staticmethod
    def _victory_rules(
        rules: Mapping[str, Any], template: Mapping[str, Any]
    ) -> Dict[str, Any]:
        result = copy.deepcopy(_require_mapping(template, "victory_rules"))
        termination = _require_mapping(rules, "termination")
        _require_equal(result["primary"], termination["victory_condition"], "victory condition")
        _require_equal(
            result["simultaneous_stronghold_destruction"],
            termination["same_tick_double_stronghold_destruction"],
            "simultaneous stronghold outcome",
        )
        return result

    @staticmethod
    def _draw_rules(
        config: MatchConfig,
        rules: Mapping[str, Any],
        template: Mapping[str, Any],
    ) -> Dict[str, Any]:
        result = copy.deepcopy(_require_mapping(template, "draw_rules"))
        termination = _require_mapping(rules, "termination")
        result["maximum_match_ticks"] = config.maximum_match_ticks
        _require_equal(
            result["maximum_match_ticks"],
            termination["maximum_match_ticks"],
            "maximum match ticks",
        )
        _require_equal(
            result["no_progress_ticks"],
            termination["no_progress_draw_ticks"],
            "no-progress ticks",
        )
        _require_equal(
            result["time_limit_tiebreak"],
            termination["time_limit_result"],
            "time-limit result",
        )
        return result

    @staticmethod
    def _failure_rules(
        rules: Mapping[str, Any],
        actions: Mapping[str, Any],
        template: Mapping[str, Any],
    ) -> Dict[str, Any]:
        result = copy.deepcopy(_require_mapping(template, "failure_rules"))
        failures = _require_mapping(rules, "model_failure")
        security = _require_mapping(rules, "security")
        _require_equal(
            result["participant_failed_opportunities_forfeit"],
            failures["consecutive_hard_failures_forfeit"],
            "consecutive failure limit",
        )
        _require_equal(
            result["participant_cumulative_failures_forfeit"],
            failures["cumulative_hard_failures_forfeit"],
            "cumulative failure limit",
        )
        _require_equal(result["no_same_window_retry"], not security["same_window_retry"], "retry")
        _require_equal(
            result["invalid_envelope_result"],
            {"whole_batch_no_op": "no_op_and_strike"}.get(actions["invalid_envelope_policy"]),
            "invalid-envelope result",
        )
        _require_equal(
            result["individual_illegal_command_result"],
            {"skip_command_continue_batch": "skip_command"}.get(
                actions["illegal_command_policy"]
            ),
            "illegal-command result",
        )
        _require_equal(
            result["infrastructure_failure_result"],
            {"void_infrastructure": "void_match"}.get(
                failures["organizer_infrastructure_result"]
            ),
            "infrastructure-failure result",
        )
        return result

    @staticmethod
    def _observation_rules(
        config: MatchConfig,
        rules: Mapping[str, Any],
        template: Mapping[str, Any],
    ) -> Dict[str, Any]:
        result = copy.deepcopy(_require_mapping(template, "observation_rules"))
        observation = _require_mapping(rules, "observation")
        result["profile"] = config.observation_profile
        _require_equal(result["profile"], observation["profile"], "observation profile")
        _require_equal(
            result["observation_hash_scope"],
            {
                "legal_observation_without_observation_hash_field": (
                    "legal_observation_without_hash_field"
                )
            }.get(observation["hash_scope"]),
            "observation hash scope",
        )
        return result

    @staticmethod
    def _memory_rules(
        config: MatchConfig,
        rules: Mapping[str, Any],
        actions: Mapping[str, Any],
        template: Mapping[str, Any],
    ) -> Dict[str, Any]:
        result = copy.deepcopy(_require_mapping(template, "memory_rules"))
        result["policy"] = config.memory_policy
        security = _require_mapping(rules, "security")
        action_limits = _require_mapping(actions, "limits")
        _require_equal(result["provider_memory"], "disabled", "provider-memory policy")
        _require_equal(security["provider_memory"], False, "provider-memory catalog policy")
        _require_equal(
            result["maximum_bytes"],
            action_limits["max_working_memory_bytes"],
            "working-memory limit",
        )
        return result

    @staticmethod
    def _build_starting_state(
        *,
        rules: Mapping[str, Any],
        faction: Mapping[str, Any],
        map_manifest: Mapping[str, Any],
        template: Mapping[str, Any],
    ) -> Dict[str, Any]:
        match_start = _require_mapping(rules, "match_start")
        faction_start = _require_mapping(faction, "starting_state")
        faction_units = _require_mapping(faction, "units")
        spawns = map_manifest.get("spawns")
        if not isinstance(spawns, list):
            raise MatchInitAssemblyError("map spawns must be an array")

        self_spawns = [
            spawn
            for spawn in spawns
            if isinstance(spawn, dict) and spawn.get("seat") == 0
        ]
        worker_spawns = sorted(
            (
                spawn
                for spawn in self_spawns
                if spawn.get("kind") == "unit"
                and spawn.get("entity_type") == "faction_worker"
            ),
            key=lambda spawn: spawn["id"],
        )
        worker_type_id = _require_string(faction_start, "worker_type_id")
        worker_count = faction_start.get("worker_count")
        if not isinstance(worker_count, int) or isinstance(worker_count, bool) or worker_count < 0:
            raise MatchInitAssemblyError("faction worker_count must be a non-negative integer")
        starting_types = [worker_type_id] * worker_count
        special_units = faction_start.get("special_units")
        if not isinstance(special_units, list):
            raise MatchInitAssemblyError("faction special_units must be an array")
        for special in special_units:
            special_mapping = _require_object(special, "starting special unit")
            type_id = _require_string(special_mapping, "type_id")
            count = special_mapping.get("count")
            if not isinstance(count, int) or isinstance(count, bool) or count < 1:
                raise MatchInitAssemblyError("starting special-unit count must be positive")
            starting_types.extend([type_id] * count)
        _require_equal(len(starting_types), len(worker_spawns), "frozen starting unit slots")
        _require_equal(len(starting_types), match_start["worker_count"], "starting unit count")

        template_entities = _starting_template_entities(template)
        entities = []
        for spawn, type_id in zip(worker_spawns, starting_types):
            entity_id = _entity_id_for_spawn(_require_string(spawn, "id"))
            unit = _require_mapping(faction_units, type_id)
            template_entity = _require_mapping(template_entities, entity_id)
            position = _require_point(spawn.get("position_mt"), f"spawn {spawn['id']} position")
            _require_equal(
                template_entity["position_mt"], position, f"spawn {spawn['id']} position"
            )
            entities.append(
                {
                    "entity_id": entity_id,
                    "type_id": type_id,
                    "position_mt": position,
                    "facing_mdeg": template_entity["facing_mdeg"],
                    "food": unit["food"],
                }
            )
        entities.sort(key=lambda entity: entity["entity_id"])

        structure_by_role: Dict[str, Mapping[str, Any]] = {}
        for structure_value in _require_mapping(faction, "structures").values():
            structure = _require_object(structure_value, "faction structure")
            role = _require_string(structure, "shared_role")
            if role in structure_by_role:
                raise MatchInitAssemblyError(f"duplicate faction structure role: {role}")
            structure_by_role[role] = structure
        structures = []
        spawn_role = {"food_structure": "food", "stronghold": "stronghold"}
        for spawn in self_spawns:
            if spawn.get("kind") != "structure" or spawn.get("entity_type") not in spawn_role:
                continue
            role = spawn_role[spawn["entity_type"]]
            structure = structure_by_role.get(role)
            if structure is None:
                raise MatchInitAssemblyError(f"selected faction has no {role} structure")
            entity_id = _entity_id_for_spawn(_require_string(spawn, "id"))
            template_entity = _require_mapping(template_entities, entity_id)
            position = _require_point(spawn.get("position_mt"), f"spawn {spawn['id']} position")
            _require_equal(
                template_entity["position_mt"], position, f"spawn {spawn['id']} position"
            )
            structures.append(
                {
                    "entity_id": entity_id,
                    "type_id": structure["type_id"],
                    "position_mt": position,
                    "facing_mdeg": template_entity["facing_mdeg"],
                    "food": 0,
                }
            )
        structures.sort(key=lambda structure: structure["entity_id"])
        _require_equal(
            len(structures),
            match_start["stronghold_count"] + match_start["food_structure_count"],
            "starting structure count",
        )

        food_used = sum(entity["food"] for entity in entities)
        _require_equal(food_used, match_start["food_used"], "starting food used")
        if "total_food_used" in faction_start:
            _require_equal(food_used, faction_start["total_food_used"], "faction starting food")

        home_regions = {
            spawn["region_id"]
            for spawn in self_spawns
            if spawn.get("entity_type") == "stronghold"
        }
        _require_equal(len(home_regions), 1, "self home region count")
        resource_sites = map_manifest.get("resource_sites")
        if not isinstance(resource_sites, list):
            raise MatchInitAssemblyError("map resource_sites must be an array")
        home_mines = [
            site
            for site in resource_sites
            if isinstance(site, dict)
            and site.get("region_id") in home_regions
            and site.get("kind") == "gold_mine"
            and "starting_resource" in site.get("tags", [])
        ]
        _require_equal(len(home_mines), 1, "self starting gold mine count")

        return {
            "gold": match_start["gold"],
            "lumber": match_start["lumber"],
            "food_used": food_used,
            "food_cap": match_start["food_cap"],
            "tier": match_start["technology_tier"],
            "entities": entities,
            "structures": structures,
            "home_mine_site_id": home_mines[0]["id"],
        }


def assemble_match_init(
    config: Union[MatchConfig, Mapping[str, Any]],
    *,
    match_id: str,
    engine_build_id: str,
    engine_build_sha256: str,
    package: Optional[ProtocolPackage] = None,
) -> MatchInitAssembly:
    """Convenience entry point for callers that do not need to retain an assembler."""

    return MatchInitAssembler(package).assemble(
        config,
        match_id=match_id,
        engine_build_id=engine_build_id,
        engine_build_sha256=engine_build_sha256,
    )


def _require_object(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise MatchInitAssemblyError(f"{label} must be an object")
    return value


def _require_mapping(parent: Mapping[str, Any], key: str) -> Mapping[str, Any]:
    value = parent.get(key)
    if not isinstance(value, dict):
        raise MatchInitAssemblyError(f"locked catalog field {key!r} must be an object")
    return value


def _require_string(parent: Mapping[str, Any], key: str) -> str:
    value = parent.get(key)
    if not isinstance(value, str) or not value:
        raise MatchInitAssemblyError(f"locked catalog field {key!r} must be a string")
    return value


def _require_equal(actual: Any, expected: Any, label: str) -> None:
    if actual != expected:
        raise MatchInitAssemblyError(
            f"locked artifacts disagree about {label}: {actual!r} != {expected!r}"
        )


def _require_point(value: Any, label: str) -> list[int]:
    if (
        not isinstance(value, list)
        or len(value) != 2
        or any(not isinstance(component, int) or isinstance(component, bool) for component in value)
    ):
        raise MatchInitAssemblyError(f"{label} must be an integer [x, y] point")
    return list(value)


def _hash_ref(identifier: str, sha256: str) -> Dict[str, str]:
    return {"id": identifier, "sha256": sha256}


def _artifact_id_from_filename(relative_path: str) -> str:
    stem = Path(relative_path).name
    if stem.endswith(".txt"):
        stem = stem[:-4]
    return stem.replace(".", "-")


def _helper_id(actions: Mapping[str, Any]) -> str:
    profile = _require_string(actions, "control_profile")
    base, separator, version = profile.rpartition("-")
    if not separator or not base or not version:
        raise MatchInitAssemblyError("control profile cannot derive a helper artifact ID")
    return f"{base}-helper-{version}"


def _entity_id_for_spawn(spawn_id: str) -> str:
    prefix = "spawn_self_"
    if not spawn_id.startswith(prefix):
        raise MatchInitAssemblyError(f"self-canonical spawn has invalid ID: {spawn_id}")
    return "e_start_" + spawn_id[len(prefix) :]


def _starting_template_entities(template: Mapping[str, Any]) -> Dict[str, Mapping[str, Any]]:
    starting_state = _require_mapping(template, "starting_state")
    result: Dict[str, Mapping[str, Any]] = {}
    for collection_name in ("entities", "structures"):
        values = starting_state.get(collection_name)
        if not isinstance(values, list):
            raise MatchInitAssemblyError(f"template starting {collection_name} must be an array")
        for value in values:
            entity = _require_object(value, f"template starting {collection_name} entry")
            entity_id = _require_string(entity, "entity_id")
            if entity_id in result:
                raise MatchInitAssemblyError(f"duplicate template starting entity: {entity_id}")
            result[entity_id] = entity
    return result
