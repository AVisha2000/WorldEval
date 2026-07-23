class_name DuelMatchBootstrap
extends RefCounted

const Rules := preload("res://scripts/duel/simulation/duel_rules.gd")
const Simulation := preload("res://scripts/duel/simulation/duel_simulation.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const RuntimeCatalog := preload("res://scripts/duel/protocol/duel_runtime_catalog.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const MAP_PATH := "res://../game/duel_protocol/maps/crossroads-duel-v1.json"
const VERSION_PATH := "res://../game/duel_protocol/VERSION"
const PROMPT_PATH := "res://../game/duel_protocol/prompts/commander-system.v1.txt"
const PROTOCOL_LOCK_PATH := "res://../game/duel_protocol/protocol-lock.json"

const HASH_KEYS: Array[String] = [
	"engine_build_hash",
	"faction_hash",
	"helper_hash",
	"item_hash",
	"map_hash",
	"neutral_hash",
	"prompt_hash",
	"protocol_hash",
	"ruleset_hash",
	"tie_key_commitment",
]


## Builds the official mirrored starting world from locked catalogs and the
## exact map artifact. `options` accepts only faction_id, match_seed, scored,
## and authoritative_hashes. Scored callers must provide all frozen hashes;
## known artifact hashes are cross-checked before any state is created.
static func create_official(options: Dictionary) -> Dictionary:
	var errors := PackedStringArray()
	_validate_options(options, errors)
	if not errors.is_empty():
		return _result(null, {}, {}, {}, errors)
	var faction_id := str(options.get("faction_id", "vanguard-v1"))
	var loaded := CatalogLoader.load_official_catalogs()
	_append_errors(errors, loaded.get("errors", []))
	if not bool(loaded.get("ok", false)):
		return _result(null, {}, {}, {}, errors)
	var runtime_result := RuntimeCatalog.compile_selected_faction(faction_id, loaded)
	_append_errors(errors, runtime_result.get("errors", []))
	if not bool(runtime_result.get("ok", false)):
		return _result(null, {}, {}, {}, errors)
	var lock_result := _read_protocol_lock()
	_append_errors(errors, lock_result["errors"])
	if not bool(lock_result["ok"]):
		return _result(null, {}, {}, {}, errors)
	var map_result := _read_locked_map(lock_result["entries"])
	_append_errors(errors, map_result["errors"])
	if not bool(map_result["ok"]):
		return _result(null, {}, {}, {}, errors)

	var expected_hashes := _known_hashes(
		loaded, faction_id, str(map_result["raw_hash"]), lock_result["entries"], errors
	)
	var scored := bool(options.get("scored", false))
	var authoritative_hashes: Dictionary = options.get("authoritative_hashes", {})
	if scored:
		_validate_scored_hashes(authoritative_hashes, expected_hashes, errors)
	if not errors.is_empty():
		return _result(null, {}, {}, {}, errors)
	var hashes := expected_hashes.duplicate(true)
	if scored:
		for key: String in HASH_KEYS:
			hashes[key] = str(authoritative_hashes[key])

	var map_manifest: Dictionary = map_result["manifest"]
	var config := {
		"engine_build_hash": str(hashes["engine_build_hash"]),
		"faction_hash": str(hashes["faction_hash"]),
		"grid_height": int(map_manifest["grid"]["height"]),
		"grid_width": int(map_manifest["grid"]["width"]),
		"helper_hash": str(hashes["helper_hash"]),
		"item_hash": str(hashes["item_hash"]),
		"map_hash": str(hashes["map_hash"]),
		"map_manifest": map_manifest,
		"match_seed": int(options.get("match_seed", 0)),
		"neutral_hash": str(hashes["neutral_hash"]),
		"prompt_hash": str(hashes["prompt_hash"]),
		"protocol_hash": str(hashes["protocol_hash"]),
		"ruleset_hash": str(hashes["ruleset_hash"]),
		"scored": scored,
		"tie_key_commitment": str(hashes["tie_key_commitment"]),
	}
	var sim := Simulation.new(config)
	_append_errors(errors, sim.last_errors)
	if not errors.is_empty():
		return _result(null, {}, {}, {}, errors)
	var runtime: Dictionary = runtime_result["runtime"]
	_append_errors(errors, sim.configure_economy(runtime["economy"]))
	_append_errors(errors, sim.configure_combat(
		loaded["catalogs"]["attack_armor"],
		loaded["catalogs"]["faction:%s" % faction_id],
		loaded["catalogs"]["rules"]
	))
	_append_errors(errors, sim.configure_heroes(
		loaded["catalogs"]["rules"],
		loaded["catalogs"]["faction:%s" % faction_id],
		loaded["catalogs"]["items"]
	))
	_append_errors(errors, sim.configure_terminal(
		loaded["catalogs"]["rules"], runtime["economy"]
	))
	for seat: int in [0, 1]:
		var receipt := sim.economy.configure_player(sim.state, seat, 500, 200, 1)
		if not bool(receipt.get("accepted", false)):
			errors.append("starting economy rejected seat %d" % seat)
	if not errors.is_empty():
		return _result(null, runtime, map_manifest, {}, errors)

	var registry := {
		"build_sites": _index_records(map_manifest["build_sites"]),
		"entity_id_by_map_id": {},
		"map_id_by_entity_id": {},
		"neutral_buildings": _index_records(map_manifest["neutral_buildings"]),
		"resource_sites": _index_records(map_manifest["resource_sites"]),
		"spawn_ids_by_seat": {0: [], 1: []},
		"tactical_slots": _index_records(map_manifest["tactical_slots"]),
	}
	var starting_types := _starting_types_by_spawn(map_manifest, runtime, errors)
	if errors.is_empty():
		_add_starting_entities(sim, map_manifest, runtime, starting_types, registry, errors)
	if errors.is_empty():
		_add_resource_entities(
			sim, map_manifest, loaded["catalogs"]["rules"], registry, errors
		)
	if errors.is_empty():
		_append_errors(errors, sim.validate())
	return _result(sim if errors.is_empty() else null, runtime, map_manifest, registry, errors)


static func _add_starting_entities(
	sim: Simulation,
	manifest: Dictionary,
	runtime: Dictionary,
	starting_types: Dictionary,
	registry: Dictionary,
	errors: PackedStringArray
) -> void:
	var spawns: Array = manifest["spawns"].duplicate(true)
	spawns.sort_custom(_record_id_less)
	for spawn_variant: Variant in spawns:
		var spawn: Dictionary = spawn_variant
		var entity_id := sim.state.next_entity_id
		var seat := int(spawn["seat"])
		var entity := EntityRecord.new(entity_id, seat, str(spawn["kind"]))
		entity.public_id = "e_bootstrap_%08d" % entity_id
		entity.facing_mdeg = 180_000 if seat == 0 else 0
		var position: Array = spawn["position_mt"]
		entity.set_position_mt(int(position[0]), int(position[1]))
		var role := ""
		if str(spawn["kind"]) == "structure":
			role = "stronghold" if str(spawn["entity_type"]) == "stronghold" else "food"
			entity.catalog_id = str(runtime["structure_type_by_role"][role])
			var definition: Dictionary = runtime["economy"]["structures"][entity.catalog_id]
			_apply_economic_definition(entity, definition)
			entity.tags = _merged_tags(entity.tags, spawn["tags"])
			if not sim.grid.reserve_ground_actor_cells(entity_id, spawn["footprint_cells"]):
				errors.append("could not reserve exact starting footprint: %s" % spawn["id"])
				return
			if sim.add_entity(entity, false) != entity_id:
				sim.grid.release_ground_actor(entity_id)
				errors.append("could not add starting structure: %s" % spawn["id"])
				return
		else:
			entity.catalog_id = str(starting_types[spawn["id"]])
			var definition: Dictionary = runtime["economy"]["units"][entity.catalog_id]
			_apply_economic_definition(entity, definition)
			entity.tags = _merged_tags(entity.tags, spawn["tags"])
			if sim.add_entity(entity, true) != entity_id:
				errors.append("could not add starting unit: %s" % spawn["id"])
				return
		_append_errors(errors, sim.economy.register_completed_entity(sim.state, entity_id))
		if not errors.is_empty():
			return
		var section := "structure" if str(spawn["kind"]) == "structure" else "unit"
		var combat_key := role if section == "structure" else entity.catalog_id
		_append_errors(errors, sim.register_combat_entity(entity_id, section, combat_key))
		if not errors.is_empty():
			return
		registry["entity_id_by_map_id"][str(spawn["id"])] = entity_id
		registry["map_id_by_entity_id"][entity_id] = str(spawn["id"])
		(registry["spawn_ids_by_seat"][seat] as Array).append(entity_id)


static func _add_resource_entities(
	sim: Simulation,
	manifest: Dictionary,
	rules: Dictionary,
	registry: Dictionary,
	errors: PackedStringArray
) -> void:
	var sites: Array = manifest["resource_sites"].duplicate(true)
	sites.sort_custom(_record_id_less)
	var gather: Dictionary = rules["resources"]["worker_gather"]
	for site_variant: Variant in sites:
		var site: Dictionary = site_variant
		var entity_id := sim.state.next_entity_id
		var entity := EntityRecord.new(entity_id, -1, "resource")
		entity.public_id = "e_bootstrap_%08d" % entity_id
		entity.catalog_id = str(site["kind"])
		var position: Array = site["position_mt"]
		entity.set_position_mt(int(position[0]), int(position[1]))
		entity.radius_mt = 0
		entity.hp = 1
		entity.max_hp = 1
		entity.tags = _merged_tags(["resource"], site["tags"])
		if sim.add_entity(entity, false) != entity_id:
			errors.append("could not add resource site: %s" % site["id"])
			return
		var is_gold := str(site["kind"]) == "gold_mine"
		var resource_type := "gold" if is_gold else "lumber"
		var slots := int(rules["resources"]["gold_mines"]["worker_slots"]) if is_gold \
			else mini(5, maxi(1, int((site["cells"] as Array).size())))
		var cargo := int(gather["gold_cargo"] if is_gold else gather["lumber_cargo"])
		var work_ticks := int(gather["gold_work_ticks"] if is_gold else gather["lumber_work_ticks"])
		_append_errors(errors, sim.economy.register_resource_node(
			sim.state, entity_id, resource_type, int(site["initial_amount"]),
			slots, cargo, work_ticks
		))
		if not errors.is_empty():
			return
		registry["entity_id_by_map_id"][str(site["id"])] = entity_id
		registry["map_id_by_entity_id"][entity_id] = str(site["id"])


static func _starting_types_by_spawn(
	manifest: Dictionary,
	runtime: Dictionary,
	errors: PackedStringArray
) -> Dictionary:
	var result: Dictionary = {}
	for seat: int in [0, 1]:
		var spawn_ids: Array[String] = []
		for spawn_variant: Variant in manifest["spawns"]:
			var spawn: Dictionary = spawn_variant
			if int(spawn["seat"]) == seat and str(spawn["entity_type"]) == "faction_worker":
				spawn_ids.append(str(spawn["id"]))
		spawn_ids.sort()
		var type_sequence: Array[String] = []
		for _index: int in int(runtime["starting_state"]["worker_count"]):
			type_sequence.append(str(runtime["starting_state"]["worker_type_id"]))
		for special_variant: Variant in runtime["starting_state"].get("special_units", []):
			var special: Dictionary = special_variant
			for _index: int in int(special["count"]):
				type_sequence.append(str(special["type_id"]))
		if type_sequence.size() != spawn_ids.size():
			errors.append("starting unit count does not match map spawns for seat %d" % seat)
			continue
		for index: int in spawn_ids.size():
			if not runtime["economy"]["units"].has(type_sequence[index]):
				errors.append("starting type is not in selected faction: %s" % type_sequence[index])
				continue
			result[spawn_ids[index]] = type_sequence[index]
	return result


static func _apply_economic_definition(entity: EntityRecord, definition: Dictionary) -> void:
	entity.max_hp = int(definition["max_hp"])
	entity.hp = entity.max_hp
	entity.max_mana = int(definition.get("max_mana", 0))
	entity.mana = entity.max_mana
	entity.radius_mt = int(definition["radius_mt"])
	entity.tags.assign(definition["tags"])
	entity.integer_attributes["speed_mt_per_tick"] = int(definition.get("speed_mt_per_tick", 0))


static func _read_locked_map(lock_entries: Dictionary) -> Dictionary:
	var errors := PackedStringArray()
	var file_result := _read_locked_file(
		MAP_PATH, "maps/crossroads-duel-v1.json", lock_entries
	)
	_append_errors(errors, file_result["errors"])
	if not bool(file_result["ok"]):
		return {"errors": errors, "ok": false}
	var bytes: PackedByteArray = file_result["bytes"]
	var text := bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != bytes:
		return {"errors": PackedStringArray(["official map is not exact UTF-8"]), "ok": false}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"errors": PackedStringArray(["official map is not a JSON object"]), "ok": false}
	var normalized := CatalogLoader.normalize_json_boundary(parsed)
	_append_errors(errors, normalized["errors"])
	return {
		"errors": errors,
		"manifest": normalized["value"] if bool(normalized["ok"]) else {},
		"ok": errors.is_empty(),
		"raw_hash": Codec.sha256_bytes(bytes),
	}


static func _known_hashes(
	loaded: Dictionary,
	faction_id: String,
	map_hash: String,
	lock_entries: Dictionary,
	errors: PackedStringArray
) -> Dictionary:
	var raw: Dictionary = loaded["raw_hashes"]
	var prompt := _read_locked_file(
		PROMPT_PATH, "prompts/commander-system.v1.txt", lock_entries
	)
	var version := _read_locked_file(VERSION_PATH, "VERSION", lock_entries)
	_append_errors(errors, prompt["errors"])
	_append_errors(errors, version["errors"])
	return {
		"engine_build_hash": "",
		"faction_hash": raw["catalogs/factions/%s.json" % faction_id],
		"helper_hash": raw["catalogs/actions.hybrid-v1.json"],
		"item_hash": raw["catalogs/items.duel-v1.json"],
		"map_hash": map_hash,
		"neutral_hash": raw["catalogs/neutrals.duel-v1.json"],
		"prompt_hash": str(prompt.get("raw_hash", "")),
		"protocol_hash": str(version.get("raw_hash", "")),
		"ruleset_hash": raw["catalogs/rules.duel-v1.json"],
		"tie_key_commitment": "",
	}


static func _validate_scored_hashes(
	provided: Dictionary,
	expected: Dictionary,
	errors: PackedStringArray
) -> void:
	for key: String in HASH_KEYS:
		if not provided.has(key) or typeof(provided[key]) != TYPE_STRING \
			or not _is_sha256(str(provided.get(key, ""))):
			errors.append("scored bootstrap requires lowercase SHA-256 %s" % key)
	for key_variant: Variant in provided.keys():
		if typeof(key_variant) != TYPE_STRING or str(key_variant) not in HASH_KEYS:
			errors.append("unknown scored authoritative hash: %s" % str(key_variant))
	for key: String in expected.keys():
		if str(expected[key]).is_empty() or not provided.has(key):
			continue
		if str(provided[key]) != str(expected[key]):
			errors.append("scored bootstrap %s does not match locked artifact" % key)


static func _validate_options(options: Dictionary, errors: PackedStringArray) -> void:
	var allowed := ["authoritative_hashes", "faction_id", "match_seed", "scored"]
	for key_variant: Variant in options.keys():
		if typeof(key_variant) != TYPE_STRING or str(key_variant) not in allowed:
			errors.append("unknown bootstrap option: %s" % str(key_variant))
	if typeof(options.get("faction_id", "vanguard-v1")) != TYPE_STRING:
		errors.append("faction_id must be a string")
	if typeof(options.get("match_seed", 0)) != TYPE_INT or int(options.get("match_seed", 0)) < 0:
		errors.append("match_seed must be a non-negative integer")
	if typeof(options.get("scored", false)) != TYPE_BOOL:
		errors.append("scored must be a boolean")
	if typeof(options.get("authoritative_hashes", {})) != TYPE_DICTIONARY:
		errors.append("authoritative_hashes must be an object")


static func _index_records(records: Array) -> Dictionary:
	var result: Dictionary = {}
	var sorted := records.duplicate(true)
	sorted.sort_custom(_record_id_less)
	for record_variant: Variant in sorted:
		var record: Dictionary = record_variant
		result[str(record["id"])] = record
	return result


static func _merged_tags(first: Array, second: Array) -> Array[String]:
	var seen: Dictionary = {}
	for value: Variant in first + second:
		seen[str(value)] = true
	var result: Array[String] = []
	for key_variant: Variant in seen.keys():
		result.append(str(key_variant))
	result.sort()
	return result


static func _record_id_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left["id"]) < str(right["id"])


static func _read_protocol_lock() -> Dictionary:
	var errors := PackedStringArray()
	if not FileAccess.file_exists(PROTOCOL_LOCK_PATH):
		return {"entries": {}, "errors": PackedStringArray(["protocol lock is missing"]), "ok": false}
	var file := FileAccess.open(PROTOCOL_LOCK_PATH, FileAccess.READ)
	if file == null:
		return {"entries": {}, "errors": PackedStringArray(["protocol lock cannot be opened"]), "ok": false}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"entries": {}, "errors": PackedStringArray(["protocol lock is not a JSON object"]), "ok": false}
	var normalized := CatalogLoader.normalize_json_boundary(parsed)
	_append_errors(errors, normalized["errors"])
	if not bool(normalized["ok"]):
		return {"entries": {}, "errors": errors, "ok": false}
	var lock: Dictionary = normalized["value"]
	if str(lock.get("protocol_version", "")) != CatalogLoader.PROTOCOL_VERSION \
		or typeof(lock.get("artifacts", null)) != TYPE_ARRAY:
		errors.append("protocol lock has the wrong version or artifact list")
		return {"entries": {}, "errors": errors, "ok": false}
	var entries: Dictionary = {}
	for artifact_variant: Variant in lock["artifacts"]:
		if typeof(artifact_variant) != TYPE_DICTIONARY:
			errors.append("protocol lock artifact must be an object")
			continue
		var artifact: Dictionary = artifact_variant
		var relative_path := str(artifact.get("path", ""))
		if relative_path.is_empty() or entries.has(relative_path) \
			or not _is_sha256(str(artifact.get("sha256", ""))) \
			or typeof(artifact.get("size_bytes", null)) != TYPE_INT \
			or int(artifact.get("size_bytes", -1)) < 0:
			errors.append("protocol lock contains an invalid or duplicate artifact entry")
			continue
		entries[relative_path] = artifact
	return {"entries": entries, "errors": errors, "ok": errors.is_empty()}


static func _read_locked_file(
	path: String,
	relative_path: String,
	lock_entries: Dictionary
) -> Dictionary:
	var errors := PackedStringArray()
	if not lock_entries.has(relative_path):
		return {
			"bytes": PackedByteArray(),
			"errors": PackedStringArray(["artifact is not covered by protocol lock: %s" % relative_path]),
			"ok": false,
			"raw_hash": "",
		}
	if not FileAccess.file_exists(path):
		return {
			"bytes": PackedByteArray(),
			"errors": PackedStringArray(["locked artifact is missing: %s" % relative_path]),
			"ok": false,
			"raw_hash": "",
		}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {
			"bytes": PackedByteArray(),
			"errors": PackedStringArray(["locked artifact cannot be opened: %s" % relative_path]),
			"ok": false,
			"raw_hash": "",
		}
	var bytes := file.get_buffer(file.get_length())
	var raw_hash := Codec.sha256_bytes(bytes)
	var expected: Dictionary = lock_entries[relative_path]
	if raw_hash != str(expected["sha256"]) or bytes.size() != int(expected["size_bytes"]):
		errors.append("locked artifact bytes changed: %s" % relative_path)
	return {
		"bytes": bytes,
		"errors": errors,
		"ok": errors.is_empty(),
		"raw_hash": raw_hash,
	}


static func _is_sha256(value: String) -> bool:
	if value.length() != 64:
		return false
	for index: int in value.length():
		var code := value.unicode_at(index)
		if not (code >= 48 and code <= 57) and not (code >= 97 and code <= 102):
			return false
	return true


static func _append_errors(target: PackedStringArray, source: Variant) -> void:
	if typeof(source) == TYPE_PACKED_STRING_ARRAY or typeof(source) == TYPE_ARRAY:
		for error_variant: Variant in source:
			target.append(str(error_variant))
	elif source != null:
		target.append(str(source))


static func _result(
	sim: Variant,
	runtime: Dictionary,
	manifest: Dictionary,
	registry: Dictionary,
	errors: PackedStringArray
) -> Dictionary:
	return {
		"errors": errors,
		"map_manifest": manifest,
		"ok": errors.is_empty(),
		"registry": registry,
		"runtime": runtime,
		"simulation": sim,
	}
