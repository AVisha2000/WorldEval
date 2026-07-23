extends SceneTree

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const KnowledgeState := preload("res://scripts/duel/knowledge/duel_agent_knowledge_state.gd")
const Contract := preload("res://scripts/duel/observations/duel_observation_contract.gd")
const Builder := preload("res://scripts/duel/observations/duel_observation_builder.gd")

const FIXTURE_PATH := "res://../game/duel_protocol/fixtures/observation.maximal.valid.json"
const SCHEMA_PATH := "res://../game/duel_protocol/schemas/observation.v1.schema.json"
const GOLDEN_OBSERVATION_HASH := "81746f58deb51686d2fe3e7e5b3715804c34ed61b9f074e6473c95203e2cac8a"


class FixtureKnowledgeState:
	extends KnowledgeState

	var projection_payload: Dictionary = {}
	var hidden_world_payload: Dictionary = {}

	func public_projection() -> Dictionary:
		return projection_payload.duplicate(true)


var _failures := PackedStringArray()
var _fixture: Dictionary = {}
var _projection: Dictionary = {}
var _context: Dictionary = {}


func _init() -> void:
	_fixture = _load_json(FIXTURE_PATH)
	_check(not _fixture.is_empty(), "maximal observation fixture could not be loaded")
	if not _fixture.is_empty():
		_projection = _projection_from_fixture(_fixture)
		_context = _context_from_fixture(_fixture)
		_test_locked_schema_surface()
		_test_maximal_fixture_parity()
		_test_repeatability_and_order_independence()
		_test_knowledge_only_type_boundary_and_hidden_leaks()
		_test_immutable_inputs_and_hash_scope()
		_test_deterministic_truncation_order()
		_test_caps_and_fail_closed_behavior()
	var golden_hash := _fresh_process_hash()
	if not GOLDEN_OBSERVATION_HASH.is_empty():
		_check(golden_hash == GOLDEN_OBSERVATION_HASH, "observation golden hash changed")
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_OBSERVATION_FAILURE: %s" % failure)
		print("DUEL_OBSERVATION_FAILED count=%d hash=%s" % [_failures.size(), golden_hash])
		quit(1)
		return
	print("DUEL_OBSERVATION_OK hash=%s" % golden_hash)
	quit(0)


func _test_locked_schema_surface() -> void:
	var schema := _load_json(SCHEMA_PATH)
	_check(not schema.is_empty(), "locked observation schema could not be loaded")
	if schema.is_empty():
		return
	_check(
		_sorted_strings(schema.get("required", [])) == _sorted_strings(Contract.TOP_LEVEL_REQUIRED),
		"Godot required top-level fields drifted from observation.v1 schema"
	)
	var schema_properties := _sorted_strings((schema.get("properties", {}) as Dictionary).keys())
	var contract_properties: Array = Contract.TOP_LEVEL_REQUIRED.duplicate()
	contract_properties.append_array(Contract.TOP_LEVEL_OPTIONAL)
	_check(
		schema_properties == _sorted_strings(contract_properties),
		"Godot top-level allowlist drifted from observation.v1 schema"
	)
	_check(bool(schema.get("additionalProperties", true)) == false, "locked schema is no longer closed")
	var observation_properties: Dictionary = schema["properties"]
	_check(
		int(observation_properties["owned_entities"]["maxItems"]) == 100
		and int(observation_properties["visible_contacts"]["maxItems"]) == 180
		and int(observation_properties["remembered_contacts"]["maxItems"]) == 256
		and int(observation_properties["events_since_previous"]["maxItems"]) == 2048,
		"locked observation collection caps drifted"
	)


func _test_maximal_fixture_parity() -> void:
	var state := _state_with(_projection)
	var built := Builder.build(state, _context)
	_check(bool(built["ok"]), "maximal fixture build failed: %s" % _error_text(built))
	if not bool(built["ok"]):
		return
	var expected := _fixture.duplicate(true)
	expected["observation_hash"] = Contract.observation_hash(expected)
	_check(
		built["observation"] == expected,
		"builder did not reproduce the complete locked maximal wire fixture"
	)
	_check(
		Contract.validate_observation(built["observation"]).is_empty(),
		"maximal output failed the engine-side locked schema subset"
	)
	var observation: Dictionary = built["observation"]
	_check((observation["heroes"] as Array).size() == 1, "Hero was not separated from ordinary owned units")
	_check((observation["owned_structures"] as Array).size() == 1, "structure was not separated from owned units")
	_check((observation["visible_neutrals"] as Array).size() == 1, "neutral contact was not separated")
	_check((observation["visible_contacts"] as Array).size() == 1, "opponent contact was not retained")
	_check(
		((observation["map_state"] as Dictionary)["local_context"] as Array).size() == 1,
		"detailed local surroundings were omitted"
	)
	_check(
		observation["last_action_receipt"] == _fixture["last_action_receipt"],
		"latest required action receipt changed"
	)
	_check(
		str(observation["observation_hash"]) == Contract.observation_hash(observation),
		"observation hash did not omit only its own field"
	)
	_check(
		int(built["byte_count"]) == str(built["canonical_json"]).to_utf8_buffer().size(),
		"reported canonical byte count is wrong"
	)
	if OS.get_environment("DUEL_OBSERVATION_EMIT_JSON") == "1":
		print("DUEL_OBSERVATION_JSON=" + str(built["canonical_json"]))


func _test_repeatability_and_order_independence() -> void:
	var baseline := Builder.build(_state_with(_projection), _context)
	var repeated := Builder.build(_state_with(_projection), _context)
	_check(bool(baseline["ok"]) and bool(repeated["ok"]), "repeatability setup failed")
	if not bool(baseline["ok"]) or not bool(repeated["ok"]):
		return
	_check(
		baseline["canonical_json"] == repeated["canonical_json"],
		"identical public knowledge did not produce identical canonical bytes"
	)

	var permuted := _projection.duplicate(true)
	for field: String in ["owned_entities", "visible_contacts", "remembered_contacts", "events_since_previous"]:
		(permuted[field] as Array).reverse()
	var first_owned: Dictionary = (permuted["owned_entities"] as Array)[0]
	(first_owned["tags"] as Array).reverse()
	var context_permuted := _context.duplicate(true)
	(context_permuted["visible_items"] as Array).reverse()
	(context_permuted["visible_shops"] as Array).reverse()
	(context_permuted["squads"] as Array).reverse()
	var reordered := Builder.build(_state_with(permuted), context_permuted)
	_check(bool(reordered["ok"]), "permuted public projection failed: %s" % _error_text(reordered))
	if bool(reordered["ok"]):
		_check(
			reordered["canonical_json"] == baseline["canonical_json"],
			"insertion order changed canonical observation bytes"
		)


func _test_knowledge_only_type_boundary_and_hidden_leaks() -> void:
	var wrong_type := Builder.build(RefCounted.new(), _context)
	_check(not bool(wrong_type["ok"]), "non-knowledge object crossed the observation boundary")

	var forbidden_projection := _projection.duplicate(true)
	forbidden_projection["omniscient_state_hash"] = "a".repeat(64)
	var forbidden_result := Builder.build(_state_with(forbidden_projection), _context)
	_check(not bool(forbidden_result["ok"]), "omniscient hash was silently redacted instead of rejected")

	var nested_forbidden := _projection.duplicate(true)
	var first_visible: Dictionary = (nested_forbidden["visible_contacts"] as Array)[0]
	first_visible["opponent_resources"] = {"gold": 999_999}
	var nested_result := Builder.build(_state_with(nested_forbidden), _context)
	_check(not bool(nested_result["ok"]), "nested opponent economy crossed the knowledge boundary")

	var forbidden_context := _context.duplicate(true)
	forbidden_context["world_checkpoint_hash"] = "b".repeat(64)
	var context_result := Builder.build(_state_with(_projection), forbidden_context)
	_check(not bool(context_result["ok"]), "world checkpoint hash crossed the public-context boundary")

	var state := _state_with(_projection)
	state.hidden_world_payload = {
		"enemy_hp": 1,
		"enemy_position_mt": [191_999, 127_999],
		"world_checkpoint_hash": "f".repeat(64),
	}
	var before := Builder.build(state, _context)
	state.hidden_world_payload["enemy_hp"] = 999_999
	state.hidden_world_payload["enemy_position_mt"] = [0, 0]
	var after := Builder.build(state, _context)
	_check(bool(before["ok"]) and bool(after["ok"]), "hidden-state invariance setup failed")
	if bool(before["ok"]) and bool(after["ok"]):
		_check(
			before["observation_hash"] == after["observation_hash"],
			"hidden state changed provider-visible observation hash"
		)
		_check(
			not Contract.contains_forbidden_key(after["observation"]),
			"protected key survived into provider-visible output"
		)


func _test_immutable_inputs_and_hash_scope() -> void:
	var projection_input := _projection.duplicate(true)
	var context_input := _context.duplicate(true)
	var projection_before := Codec.sha256_canonical(projection_input)
	var context_before := Codec.sha256_canonical(context_input)
	var built := Builder.build(_state_with(projection_input), context_input)
	_check(bool(built["ok"]), "immutability setup failed: %s" % _error_text(built))
	_check(
		Codec.sha256_canonical(projection_input) == projection_before,
		"builder mutated caller-owned knowledge projection"
	)
	_check(
		Codec.sha256_canonical(context_input) == context_before,
		"builder mutated caller-owned public context"
	)
	if not bool(built["ok"]):
		return
	var frozen_json := str(built["canonical_json"])
	context_input["working_memory"] = "mutated after build"
	((projection_input["owned_entities"] as Array)[0] as Dictionary)["hp"] = 1
	_check(str(built["canonical_json"]) == frozen_json, "built result retained a live input reference")

	var tampered: Dictionary = (built["observation"] as Dictionary).duplicate(true)
	tampered["economy"]["gold"] = int(tampered["economy"]["gold"]) + 1
	_check(
		not Contract.validate_observation(tampered, true).is_empty(),
		"tampered legal field did not invalidate observation hash"
	)
	var hash_only: Dictionary = (built["observation"] as Dictionary).duplicate(true)
	hash_only["observation_hash"] = "f".repeat(64)
	_check(
		Contract.observation_hash(hash_only) == str(built["observation_hash"]),
		"observation_hash field incorrectly entered its own hash scope"
	)


func _test_deterministic_truncation_order() -> void:
	var baseline := Builder.build(_state_with(_projection), _context)
	_check(bool(baseline["ok"]), "truncation baseline failed")
	if not bool(baseline["ok"]):
		return
	var brief_context := _context.duplicate(true)
	brief_context["maximum_observation_bytes"] = int(baseline["byte_count"]) - 1
	var brief_trimmed := Builder.build(_state_with(_projection), brief_context)
	_check(bool(brief_trimmed["ok"]), "brief truncation failed: %s" % _error_text(brief_trimmed))
	if bool(brief_trimmed["ok"]):
		var observation: Dictionary = brief_trimmed["observation"]
		_check(not observation.has("brief"), "brief was not the first truncation category")
		_check(int(observation["omitted_counts"]["brief"]) == 2, "brief omitted count is not exact")
		_check((observation["remembered_contacts"] as Array).size() == 1, "remembered unit trimmed before brief")

	var no_brief_context := _context.duplicate(true)
	no_brief_context["include_brief"] = false
	var no_brief := Builder.build(_state_with(_projection), no_brief_context)
	_check(bool(no_brief["ok"]), "no-brief baseline failed")
	if bool(no_brief["ok"]):
		var unit_context := no_brief_context.duplicate(true)
		unit_context["maximum_observation_bytes"] = int(no_brief["byte_count"]) - 1
		var unit_trimmed := Builder.build(_state_with(_projection), unit_context)
		_check(bool(unit_trimmed["ok"]), "remembered-unit truncation failed: %s" % _error_text(unit_trimmed))
		if bool(unit_trimmed["ok"]):
			_check(
				int(unit_trimmed["observation"]["omitted_counts"]["remembered_units"]) == 1,
				"oldest ordinary remembered unit was not second truncation category"
			)

	var building_projection := _projection.duplicate(true)
	var remembered_building: Dictionary = (building_projection["remembered_contacts"] as Array)[0]
	remembered_building["type_id"] = "garrison"
	var building_base := Builder.build(_state_with(building_projection), no_brief_context)
	_check(bool(building_base["ok"]), "remembered-building baseline failed")
	if bool(building_base["ok"]):
		var building_context := no_brief_context.duplicate(true)
		building_context["maximum_observation_bytes"] = int(building_base["byte_count"]) - 1
		var building_trimmed := Builder.build(_state_with(building_projection), building_context)
		_check(bool(building_trimmed["ok"]), "remembered-building truncation failed: %s" % _error_text(building_trimmed))
		if bool(building_trimmed["ok"]):
			_check(
				int(building_trimmed["observation"]["omitted_counts"]["remembered_buildings"]) == 1,
				"remembered building was not third truncation category"
			)

	var path_projection := _projection.duplicate(true)
	path_projection["remembered_contacts"] = []
	var path_base := Builder.build(_state_with(path_projection), no_brief_context)
	_check(bool(path_base["ok"]), "local-path baseline failed")
	if bool(path_base["ok"]):
		var path_context := no_brief_context.duplicate(true)
		path_context["maximum_observation_bytes"] = int(path_base["byte_count"]) - 1
		var path_trimmed := Builder.build(_state_with(path_projection), path_context)
		_check(bool(path_trimmed["ok"]), "local-path truncation failed: %s" % _error_text(path_trimmed))
		if bool(path_trimmed["ok"]):
			_check(
				int(path_trimmed["observation"]["omitted_counts"]["local_context_paths"]) == 1,
				"redundant local path was not the final truncation category"
			)


func _test_caps_and_fail_closed_behavior() -> void:
	var oversized_projection := _projection.duplicate(true)
	var contact_template: Dictionary = (oversized_projection["visible_contacts"] as Array)[0]
	var contacts: Array = []
	for index: int in 181:
		var contact := contact_template.duplicate(true)
		contact["entity_id"] = "e_cap_%03d" % index
		contacts.append(contact)
	oversized_projection["visible_contacts"] = contacts
	var oversized := Builder.build(_state_with(oversized_projection), _context)
	_check(not bool(oversized["ok"]), "current visible contacts were silently truncated past schema cap")

	var mandatory_projection := _projection.duplicate(true)
	mandatory_projection["remembered_contacts"] = []
	var local_context: Dictionary = mandatory_projection["map_state"]["local_context"][0]
	local_context["retreat_route"] = []
	local_context["visible_contacts"][0]["known_path_distance_mt"] = null
	var tiny_context := _context.duplicate(true)
	tiny_context["include_brief"] = false
	tiny_context["maximum_observation_bytes"] = 1_024
	var tiny := Builder.build(_state_with(mandatory_projection), tiny_context)
	_check(not bool(tiny["ok"]), "mandatory current state was truncated to satisfy an impossible byte cap")

	var bad_memory_context := _context.duplicate(true)
	bad_memory_context["working_memory"] = "x".repeat(4_097)
	var bad_memory := Builder.build(_state_with(_projection), bad_memory_context)
	_check(not bool(bad_memory["ok"]), "oversized working memory crossed the public boundary")


func _fresh_process_hash() -> String:
	if _fixture.is_empty():
		return ""
	var result := Builder.build(_state_with(_projection), _context)
	if not bool(result["ok"]):
		return ""
	return str(result["observation_hash"])


func _state_with(projection: Dictionary) -> FixtureKnowledgeState:
	var state := FixtureKnowledgeState.new()
	state.projection_payload = projection.duplicate(true)
	return state


func _projection_from_fixture(fixture: Dictionary) -> Dictionary:
	var owned: Array = []
	owned.append_array((fixture["owned_entities"] as Array).duplicate(true))
	owned.append_array((fixture["heroes"] as Array).duplicate(true))
	owned.append_array((fixture["owned_structures"] as Array).duplicate(true))
	var visible: Array = []
	visible.append_array((fixture["visible_contacts"] as Array).duplicate(true))
	visible.append_array((fixture["visible_neutrals"] as Array).duplicate(true))
	return {
		"destroyed_contacts": [],
		"events_since_previous": (fixture["events_since_previous"] as Array).duplicate(true),
		"map_state": (fixture["map_state"] as Dictionary).duplicate(true),
		"owned_entities": owned,
		"remembered_contacts": (fixture["remembered_contacts"] as Array).duplicate(true),
		"tick": int(fixture["tick"]),
		"visible_contacts": visible,
	}


func _context_from_fixture(fixture: Dictionary) -> Dictionary:
	return {
		"match_id": str(fixture["match_id"]),
		"observation_seq": int(fixture["observation_seq"]),
		"decision": (fixture["decision"] as Dictionary).duplicate(true),
		"working_memory": str(fixture["working_memory"]),
		"match_state": (fixture["match_state"] as Dictionary).duplicate(true),
		"day_phase": str(fixture["day_phase"]),
		"remaining_match_ticks": int(fixture["remaining_match_ticks"]),
		"economy": (fixture["economy"] as Dictionary).duplicate(true),
		"food": (fixture["food"] as Dictionary).duplicate(true),
		"upkeep": (fixture["upkeep"] as Dictionary).duplicate(true),
		"technology": (fixture["technology"] as Dictionary).duplicate(true),
		"squads": (fixture["squads"] as Array).duplicate(true),
		"visible_items": (fixture["visible_items"] as Array).duplicate(true),
		"visible_shops": (fixture["visible_shops"] as Array).duplicate(true),
		"last_action_receipt": (fixture["last_action_receipt"] as Dictionary).duplicate(true),
		"include_brief": true,
		"structure_type_ids": ["garrison"],
	}


func _load_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	var normalized := CatalogLoader.normalize_json_boundary(parsed)
	if not bool(normalized["ok"]):
		return {}
	return normalized["value"] if typeof(normalized["value"]) == TYPE_DICTIONARY else {}


func _sorted_strings(value: Variant) -> Array:
	var strings: Array[String] = []
	if typeof(value) == TYPE_ARRAY:
		for element: Variant in value:
			strings.append(str(element))
	strings.sort()
	var result: Array = []
	result.assign(strings)
	return result


func _error_text(result: Dictionary) -> String:
	return "; ".join(result.get("errors", PackedStringArray()))


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
