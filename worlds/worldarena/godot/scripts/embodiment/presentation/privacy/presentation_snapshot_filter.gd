class_name EmbodimentPresentationSnapshotFilter
extends RefCounted

## Fail-closed boundary between authority state and participant presentation.
##
## Authority supplies a detached, integer-only presentation input and the exact IDs visible to a
## participant. This adapter never performs visibility or authority calculations. It copies only
## the participant's own entity and those explicitly visible IDs, then recursively freezes the
## resulting render snapshot. Player text is projected from that already-filtered value, so exact
## render coordinates cannot enter the semantic observation.

const INPUT_SCHEMA := "llm-controller/presentation-input/1.0.0"
const RENDER_SCHEMA := "llm-controller/render-snapshot/1.0.0"
const TEXT_SCHEMA := "llm-controller/visible-text-projection/1.0.0"
const BINDING_SCHEMA := "llm-controller/presentation-digest-binding/1.0.0"
const HYBRID_PROFILE := "hybrid-visible-v1"
const MAX_INTENT_UTF8_BYTES := 160
const MAX_RECEIPT_CODE_UTF8_BYTES := 80

const INPUT_FIELDS := [
	"schema_version", "protocol_version", "episode_id", "task_id", "observation_seq",
	"tick", "remaining_ticks", "goal", "authority_checkpoint_hash", "self_entity_id",
	"entities", "agency", "terminal",
]
const ENTITY_FIELDS := [
	"id", "kind", "position_mt", "heading_sector", "animation",
	"animation_progress_milli", "health_percent", "energy_percent", "status", "semantic",
]
const SEMANTIC_FIELDS := ["bearing", "distance", "affordances", "state"]
const TERMINAL_FIELDS := ["ended", "outcome", "reason"]
const RENDER_FIELDS := [
	"schema_version", "protocol_version", "episode_id", "participant_id", "task_id",
	"observation_seq", "tick", "remaining_ticks", "goal", "authority_checkpoint_hash",
	"self", "visible_entities", "agency", "terminal",
]
const AGENCY_FIELDS := ["controller", "receipt", "intent_label"]
const CONTROLLER_FIELDS := [
	"move_x", "move_y", "look_x", "look_y", "duration_ticks", "buttons",
]
const BUTTON_FIELDS := [
	"interact", "primary", "guard", "dash", "ability_1", "ability_2", "cycle_item",
	"cancel",
]
const RECEIPT_FIELDS := ["disposition", "accepted", "fallback", "applied_ticks", "codes"]
const TEXT_FIELDS := [
	"schema_version", "protocol_version", "episode_id", "participant_id", "observation_seq",
	"tick", "profile", "goal", "remaining_ticks", "self", "visible_entities", "terminal",
]
const BEARINGS := [
	"front", "front_right", "right", "back_right", "back", "back_left", "left",
	"front_left",
]
const DISTANCES := ["touching", "near", "medium", "far"]
const FACING_NAMES := [
	"north", "north_east", "east", "south_east", "south", "south_west", "west",
	"north_west",
]


static func filter_for_participant(
	internal_snapshot: Variant,
	participant_id: Variant,
	visible_entity_ids: Variant,
) -> Dictionary:
	var errors: Array[String] = []
	_validate_input(internal_snapshot, participant_id, visible_entity_ids, errors)
	if not errors.is_empty():
		return {"ok": false, "errors": errors}

	var source: Dictionary = internal_snapshot
	var self_id: String = source["self_entity_id"]
	var entity_by_id := {}
	for entity: Variant in source["entities"]:
		entity_by_id[entity["id"]] = entity

	var visible_set := {}
	for entity_id: Variant in visible_entity_ids:
		visible_set[entity_id] = true

	var visible_entities: Array = []
	for entity: Variant in source["entities"]:
		var entity_id: String = entity["id"]
		if entity_id != self_id and visible_set.has(entity_id):
			visible_entities.append(_copy_render_entity(entity))

	var render_snapshot := {
		"schema_version": RENDER_SCHEMA,
		"protocol_version": source["protocol_version"],
		"episode_id": source["episode_id"],
		"participant_id": participant_id,
		"task_id": source["task_id"],
		"observation_seq": source["observation_seq"],
		"tick": source["tick"],
		"remaining_ticks": source["remaining_ticks"],
		"goal": source["goal"],
		# This is an opaque binding supplied by authority. Presentation never interprets it.
		"authority_checkpoint_hash": source["authority_checkpoint_hash"],
		"self": _copy_render_entity(entity_by_id[self_id]),
		"visible_entities": visible_entities,
		# Authority supplies only this participant's controller evidence. It is deliberately absent
		# from visible-text semantics, but remains part of the immutable render digest and frame.
		"agency": source["agency"].duplicate(true),
		"terminal": source["terminal"].duplicate(true),
	}
	_freeze(render_snapshot)
	return {"ok": true, "snapshot": render_snapshot}


static func project_visible_text(render_snapshot: Variant) -> Dictionary:
	var errors: Array[String] = []
	_validate_render_snapshot(render_snapshot, errors)
	if not errors.is_empty():
		return {"ok": false, "errors": errors}

	var source: Dictionary = render_snapshot
	var self_entity: Dictionary = source["self"]
	var visible_entities: Array = []
	for entity: Variant in source["visible_entities"]:
		visible_entities.append({
			"id": entity["id"],
			"kind": entity["kind"],
			"bearing": entity["semantic"]["bearing"],
			"distance": entity["semantic"]["distance"],
			"affordances": entity["semantic"]["affordances"].duplicate(),
			"state": entity["semantic"]["state"],
		})

	var projection := {
		"schema_version": TEXT_SCHEMA,
		"protocol_version": source["protocol_version"],
		"episode_id": source["episode_id"],
		"participant_id": source["participant_id"],
		"observation_seq": source["observation_seq"],
		"tick": source["tick"],
		"profile": HYBRID_PROFILE,
		"goal": source["goal"],
		"remaining_ticks": source["remaining_ticks"],
		"self": {
			"health_percent": self_entity["health_percent"],
			"energy_percent": self_entity["energy_percent"],
			"facing": FACING_NAMES[self_entity["heading_sector"]],
			"status": self_entity["status"].duplicate(),
		},
		"visible_entities": visible_entities,
		"terminal": source["terminal"].duplicate(true),
	}
	_freeze(projection)
	return {"ok": true, "projection": projection, "canonical_text": canonical_json(projection)}


static func safe_snapshot_digest(render_snapshot: Variant) -> String:
	var errors: Array[String] = []
	_validate_render_snapshot(render_snapshot, errors)
	if not errors.is_empty():
		return ""
	return _sha256(canonical_json(render_snapshot))


static func text_projection_digest(text_projection: Variant) -> String:
	var errors: Array[String] = []
	_validate_text_projection(text_projection, errors)
	if not errors.is_empty():
		return ""
	return _sha256(canonical_json(text_projection))


static func bind_digests(render_snapshot: Variant, text_projection: Variant) -> Dictionary:
	var render_errors: Array[String] = []
	var text_errors: Array[String] = []
	_validate_render_snapshot(render_snapshot, render_errors)
	_validate_text_projection(text_projection, text_errors)
	var errors: Array[String] = []
	for error: String in render_errors:
		errors.append("render: %s" % error)
	for error: String in text_errors:
		errors.append("text: %s" % error)
	if errors.is_empty():
		for field: String in [
			"protocol_version", "episode_id", "participant_id", "observation_seq", "tick",
		]:
			if render_snapshot[field] != text_projection[field]:
				errors.append("render/text %s mismatch" % field)
	if not errors.is_empty():
		return {"ok": false, "errors": errors}

	var binding := {
		"schema_version": BINDING_SCHEMA,
		"authority_checkpoint_hash": render_snapshot["authority_checkpoint_hash"],
		"participant_id": render_snapshot["participant_id"],
		"observation_seq": render_snapshot["observation_seq"],
		"render_snapshot_sha256": safe_snapshot_digest(render_snapshot),
		"text_projection_sha256": text_projection_digest(text_projection),
	}
	_freeze(binding)
	return {"ok": true, "binding": binding}


static func canonical_json(value: Variant) -> String:
	match typeof(value):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT:
			return str(value)
		TYPE_STRING:
			return JSON.stringify(value)
		TYPE_ARRAY:
			var items := PackedStringArray()
			for item: Variant in value:
				items.append(canonical_json(item))
			return "[" + ",".join(items) + "]"
		TYPE_DICTIONARY:
			var keys := PackedStringArray()
			for key: Variant in value.keys():
				if typeof(key) != TYPE_STRING:
					return ""
				keys.append(key)
			keys.sort()
			var items := PackedStringArray()
			for key: String in keys:
				items.append(JSON.stringify(key) + ":" + canonical_json(value[key]))
			return "{" + ",".join(items) + "}"
	return ""


static func _validate_input(
	value: Variant,
	participant_id: Variant,
	visible_entity_ids: Variant,
	errors: Array[String],
) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("snapshot must be an object")
		return
	var snapshot: Dictionary = value
	_validate_exact_fields(snapshot, INPUT_FIELDS, "snapshot", errors)
	if not errors.is_empty():
		return
	_validate_nonempty_string(snapshot["schema_version"], "snapshot.schema_version", errors)
	if snapshot["schema_version"] != INPUT_SCHEMA:
		errors.append("snapshot.schema_version is unsupported")
	for field: String in ["protocol_version", "episode_id", "task_id", "goal", "self_entity_id"]:
		_validate_nonempty_string(snapshot[field], "snapshot.%s" % field, errors)
	_validate_hash(snapshot["authority_checkpoint_hash"], "snapshot.authority_checkpoint_hash", errors)
	for field: String in ["observation_seq", "tick", "remaining_ticks"]:
		_validate_nonnegative_int(snapshot[field], "snapshot.%s" % field, errors)
	_validate_terminal(snapshot["terminal"], "snapshot.terminal", errors)
	_validate_agency(snapshot["agency"], "snapshot.agency", errors)
	if typeof(participant_id) != TYPE_STRING or participant_id.is_empty():
		errors.append("participant_id must be a non-empty string")
	if typeof(snapshot["entities"]) != TYPE_ARRAY or snapshot["entities"].is_empty():
		errors.append("snapshot.entities must be a non-empty array")
		return
	var known_ids := {}
	for index: int in range(snapshot["entities"].size()):
		var entity: Variant = snapshot["entities"][index]
		_validate_entity(entity, "snapshot.entities[%d]" % index, errors)
		if typeof(entity) == TYPE_DICTIONARY and typeof(entity.get("id")) == TYPE_STRING:
			var entity_id: String = entity["id"]
			if known_ids.has(entity_id):
				errors.append("snapshot.entities contains duplicate id %s" % entity_id)
			known_ids[entity_id] = true
	if typeof(snapshot["self_entity_id"]) == TYPE_STRING \
		and not known_ids.has(snapshot["self_entity_id"]):
		errors.append("snapshot.self_entity_id does not identify an entity")
	_validate_visibility_ids(visible_entity_ids, known_ids, errors)


static func _validate_render_snapshot(value: Variant, errors: Array[String]) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("snapshot must be an object")
		return
	var snapshot: Dictionary = value
	_validate_exact_fields(snapshot, RENDER_FIELDS, "snapshot", errors)
	if not errors.is_empty():
		return
	if snapshot["schema_version"] != RENDER_SCHEMA:
		errors.append("snapshot.schema_version is unsupported")
	for field: String in ["protocol_version", "episode_id", "participant_id", "task_id", "goal"]:
		_validate_nonempty_string(snapshot[field], "snapshot.%s" % field, errors)
	_validate_hash(snapshot["authority_checkpoint_hash"], "snapshot.authority_checkpoint_hash", errors)
	for field: String in ["observation_seq", "tick", "remaining_ticks"]:
		_validate_nonnegative_int(snapshot[field], "snapshot.%s" % field, errors)
	_validate_entity(snapshot["self"], "snapshot.self", errors)
	if typeof(snapshot["visible_entities"]) != TYPE_ARRAY:
		errors.append("snapshot.visible_entities must be an array")
	else:
		var seen_ids := {}
		if typeof(snapshot["self"]) == TYPE_DICTIONARY:
			seen_ids[snapshot["self"].get("id")] = true
		for index: int in range(snapshot["visible_entities"].size()):
			var entity: Variant = snapshot["visible_entities"][index]
			_validate_entity(entity, "snapshot.visible_entities[%d]" % index, errors)
			if typeof(entity) == TYPE_DICTIONARY and typeof(entity.get("id")) == TYPE_STRING:
				if seen_ids.has(entity["id"]):
					errors.append("snapshot contains duplicate entity id %s" % entity["id"])
				seen_ids[entity["id"]] = true
	_validate_terminal(snapshot["terminal"], "snapshot.terminal", errors)
	_validate_agency(snapshot["agency"], "snapshot.agency", errors)


static func _validate_text_projection(value: Variant, errors: Array[String]) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("projection must be an object")
		return
	var projection: Dictionary = value
	_validate_exact_fields(projection, TEXT_FIELDS, "projection", errors)
	if not errors.is_empty():
		return
	if projection["schema_version"] != TEXT_SCHEMA:
		errors.append("projection.schema_version is unsupported")
	if projection["profile"] != HYBRID_PROFILE:
		errors.append("projection.profile is unsupported")
	for field: String in ["protocol_version", "episode_id", "participant_id", "goal"]:
		_validate_nonempty_string(projection[field], "projection.%s" % field, errors)
	for field: String in ["observation_seq", "tick", "remaining_ticks"]:
		_validate_nonnegative_int(projection[field], "projection.%s" % field, errors)
	if typeof(projection["self"]) != TYPE_DICTIONARY:
		errors.append("projection.self must be an object")
	else:
		_validate_exact_fields(
			projection["self"], ["health_percent", "energy_percent", "facing", "status"],
			"projection.self", errors,
		)
		_validate_percent(projection["self"].get("health_percent"), "projection.self.health_percent", errors)
		_validate_percent(projection["self"].get("energy_percent"), "projection.self.energy_percent", errors)
		if projection["self"].get("facing") not in FACING_NAMES:
			errors.append("projection.self.facing is invalid")
		_validate_string_array(projection["self"].get("status"), "projection.self.status", errors)
	if typeof(projection["visible_entities"]) != TYPE_ARRAY:
		errors.append("projection.visible_entities must be an array")
	else:
		for index: int in range(projection["visible_entities"].size()):
			_validate_text_entity(
				projection["visible_entities"][index],
				"projection.visible_entities[%d]" % index,
				errors,
			)
	_validate_terminal(projection["terminal"], "projection.terminal", errors)
	if _contains_float(projection):
		errors.append("projection contains a float")


static func _validate_entity(value: Variant, path: String, errors: Array[String]) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("%s must be an object" % path)
		return
	var entity: Dictionary = value
	_validate_exact_fields(entity, ENTITY_FIELDS, path, errors)
	if not _has_all_fields(entity, ENTITY_FIELDS):
		return
	for field: String in ["id", "kind", "animation"]:
		_validate_nonempty_string(entity[field], "%s.%s" % [path, field], errors)
	if typeof(entity["position_mt"]) != TYPE_ARRAY or entity["position_mt"].size() != 2:
		errors.append("%s.position_mt must be a two-integer array" % path)
	else:
		for coordinate: Variant in entity["position_mt"]:
			if typeof(coordinate) != TYPE_INT:
				errors.append("%s.position_mt must be a two-integer array" % path)
				break
	if typeof(entity["heading_sector"]) != TYPE_INT \
		or entity["heading_sector"] < 0 or entity["heading_sector"] > 7:
		errors.append("%s.heading_sector must be an integer from 0 to 7" % path)
	_validate_milli(entity["animation_progress_milli"], "%s.animation_progress_milli" % path, errors)
	_validate_percent(entity["health_percent"], "%s.health_percent" % path, errors)
	_validate_percent(entity["energy_percent"], "%s.energy_percent" % path, errors)
	_validate_string_array(entity["status"], "%s.status" % path, errors)
	_validate_semantic(entity["semantic"], "%s.semantic" % path, errors)
	if _contains_float(entity):
		errors.append("%s contains a float" % path)


static func _validate_semantic(value: Variant, path: String, errors: Array[String]) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("%s must be an object" % path)
		return
	var semantic: Dictionary = value
	_validate_exact_fields(semantic, SEMANTIC_FIELDS, path, errors)
	if not _has_all_fields(semantic, SEMANTIC_FIELDS):
		return
	if semantic["bearing"] not in BEARINGS:
		errors.append("%s.bearing is invalid" % path)
	if semantic["distance"] not in DISTANCES:
		errors.append("%s.distance is invalid" % path)
	_validate_string_array(semantic["affordances"], "%s.affordances" % path, errors)
	if typeof(semantic["state"]) != TYPE_STRING:
		errors.append("%s.state must be a string" % path)


static func _validate_text_entity(value: Variant, path: String, errors: Array[String]) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("%s must be an object" % path)
		return
	var entity: Dictionary = value
	var fields := ["id", "kind", "bearing", "distance", "affordances", "state"]
	_validate_exact_fields(entity, fields, path, errors)
	if not _has_all_fields(entity, fields):
		return
	_validate_nonempty_string(entity["id"], "%s.id" % path, errors)
	_validate_nonempty_string(entity["kind"], "%s.kind" % path, errors)
	if entity["bearing"] not in BEARINGS:
		errors.append("%s.bearing is invalid" % path)
	if entity["distance"] not in DISTANCES:
		errors.append("%s.distance is invalid" % path)
	_validate_string_array(entity["affordances"], "%s.affordances" % path, errors)
	if typeof(entity["state"]) != TYPE_STRING:
		errors.append("%s.state must be a string" % path)


static func _validate_terminal(value: Variant, path: String, errors: Array[String]) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("%s must be an object" % path)
		return
	var terminal: Dictionary = value
	_validate_exact_fields(terminal, TERMINAL_FIELDS, path, errors)
	if not _has_all_fields(terminal, TERMINAL_FIELDS):
		return
	if typeof(terminal["ended"]) != TYPE_BOOL:
		errors.append("%s.ended must be a boolean" % path)
	for field: String in ["outcome", "reason"]:
		_validate_nonempty_string(terminal[field], "%s.%s" % [path, field], errors)


static func _validate_agency(value: Variant, path: String, errors: Array[String]) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("%s must be an object" % path)
		return
	var agency: Dictionary = value
	_validate_exact_fields(agency, AGENCY_FIELDS, path, errors)
	if not _has_all_fields(agency, AGENCY_FIELDS):
		return
	_validate_controller(agency["controller"], "%s.controller" % path, errors)
	if agency["receipt"] != null:
		_validate_agency_receipt(agency["receipt"], "%s.receipt" % path, errors)
	if typeof(agency["intent_label"]) != TYPE_STRING:
		errors.append("%s.intent_label must be a string" % path)
	elif agency["intent_label"].to_utf8_buffer().size() > MAX_INTENT_UTF8_BYTES:
		errors.append("%s.intent_label exceeds UTF-8 byte limit" % path)
	if _contains_float(agency):
		errors.append("%s contains a float" % path)


static func _validate_controller(value: Variant, path: String, errors: Array[String]) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("%s must be an object" % path)
		return
	var controller: Dictionary = value
	_validate_exact_fields(controller, CONTROLLER_FIELDS, path, errors)
	if not _has_all_fields(controller, CONTROLLER_FIELDS):
		return
	for axis: String in ["move_x", "move_y", "look_x", "look_y"]:
		if typeof(controller[axis]) != TYPE_INT or controller[axis] < -1000 \
			or controller[axis] > 1000:
			errors.append("%s.%s must be an integer from -1000 to 1000" % [path, axis])
	if typeof(controller["duration_ticks"]) != TYPE_INT or controller["duration_ticks"] < 0 \
		or controller["duration_ticks"] > 20:
		errors.append("%s.duration_ticks must be an integer from 0 to 20" % path)
	if typeof(controller["buttons"]) != TYPE_DICTIONARY:
		errors.append("%s.buttons must be an object" % path)
		return
	var buttons: Dictionary = controller["buttons"]
	_validate_exact_fields(buttons, BUTTON_FIELDS, "%s.buttons" % path, errors)
	if not _has_all_fields(buttons, BUTTON_FIELDS):
		return
	for button: String in BUTTON_FIELDS:
		if typeof(buttons[button]) != TYPE_BOOL:
			errors.append("%s.buttons.%s must be a boolean" % [path, button])


static func _validate_agency_receipt(value: Variant, path: String, errors: Array[String]) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("%s must be an object or null" % path)
		return
	var receipt: Dictionary = value
	_validate_exact_fields(receipt, RECEIPT_FIELDS, path, errors)
	if not _has_all_fields(receipt, RECEIPT_FIELDS):
		return
	if receipt["disposition"] not in ["accepted", "no_input"]:
		errors.append("%s.disposition is invalid" % path)
	if typeof(receipt["accepted"]) != TYPE_BOOL:
		errors.append("%s.accepted must be a boolean" % path)
	if receipt["fallback"] not in ["none", "neutral"]:
		errors.append("%s.fallback is invalid" % path)
	if receipt.get("disposition") == "accepted" \
		and (receipt.get("accepted") != true or receipt.get("fallback") != "none"):
		errors.append("%s accepted disposition is inconsistent" % path)
	if receipt.get("disposition") == "no_input" \
		and (receipt.get("accepted") != false or receipt.get("fallback") != "neutral"):
		errors.append("%s no_input disposition is inconsistent" % path)
	if typeof(receipt["applied_ticks"]) != TYPE_INT or receipt["applied_ticks"] < 0 \
		or receipt["applied_ticks"] > 20:
		errors.append("%s.applied_ticks must be an integer from 0 to 20" % path)
	_validate_string_array(receipt["codes"], "%s.codes" % path, errors)
	if receipt["codes"] is Array:
		for index: int in range(receipt["codes"].size()):
			var code: Variant = receipt["codes"][index]
			if typeof(code) == TYPE_STRING and (
				code.is_empty() or code.to_utf8_buffer().size() > MAX_RECEIPT_CODE_UTF8_BYTES
			):
				errors.append("%s.codes[%d] is empty or exceeds UTF-8 byte limit" % [path, index])


static func _validate_visibility_ids(value: Variant, known_ids: Dictionary, errors: Array[String]) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append("visible_entity_ids must be an array")
		return
	var seen := {}
	for index: int in range(value.size()):
		var entity_id: Variant = value[index]
		if typeof(entity_id) != TYPE_STRING or entity_id.is_empty():
			errors.append("visible_entity_ids[%d] must be a non-empty string" % index)
			continue
		if seen.has(entity_id):
			errors.append("visible_entity_ids contains duplicate id %s" % entity_id)
		if not known_ids.has(entity_id):
			errors.append("visible_entity_ids contains unknown id %s" % entity_id)
		seen[entity_id] = true


static func _validate_exact_fields(
	value: Dictionary,
	expected_fields: Array,
	path: String,
	errors: Array[String],
) -> void:
	for key: Variant in value.keys():
		if typeof(key) != TYPE_STRING:
			errors.append("%s contains a non-string field" % path)
		elif key not in expected_fields:
			errors.append("%s contains unknown field %s" % [path, key])
	for field: String in expected_fields:
		if not value.has(field):
			errors.append("%s is missing field %s" % [path, field])


static func _has_all_fields(value: Dictionary, fields: Array) -> bool:
	for field: String in fields:
		if not value.has(field):
			return false
	return true


static func _validate_nonempty_string(value: Variant, path: String, errors: Array[String]) -> void:
	if typeof(value) != TYPE_STRING or value.is_empty():
		errors.append("%s must be a non-empty string" % path)


static func _validate_nonnegative_int(value: Variant, path: String, errors: Array[String]) -> void:
	if typeof(value) != TYPE_INT or value < 0:
		errors.append("%s must be a non-negative integer" % path)


static func _validate_hash(value: Variant, path: String, errors: Array[String]) -> void:
	if typeof(value) != TYPE_STRING or value.length() != 64:
		errors.append("%s must be an opaque lowercase SHA-256 string" % path)
		return
	for character: String in value:
		if character not in "0123456789abcdef":
			errors.append("%s must be an opaque lowercase SHA-256 string" % path)
			return


static func _validate_percent(value: Variant, path: String, errors: Array[String]) -> void:
	if typeof(value) != TYPE_INT or value < 0 or value > 100:
		errors.append("%s must be an integer from 0 to 100" % path)


static func _validate_milli(value: Variant, path: String, errors: Array[String]) -> void:
	if typeof(value) != TYPE_INT or value < 0 or value > 1000:
		errors.append("%s must be an integer from 0 to 1000" % path)


static func _validate_string_array(value: Variant, path: String, errors: Array[String]) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append("%s must be an array" % path)
		return
	for index: int in range(value.size()):
		if typeof(value[index]) != TYPE_STRING:
			errors.append("%s[%d] must be a string" % [path, index])


static func _copy_render_entity(source: Dictionary) -> Dictionary:
	return {
		"id": source["id"],
		"kind": source["kind"],
		"position_mt": source["position_mt"].duplicate(),
		"heading_sector": source["heading_sector"],
		"animation": source["animation"],
		"animation_progress_milli": source["animation_progress_milli"],
		"health_percent": source["health_percent"],
		"energy_percent": source["energy_percent"],
		"status": source["status"].duplicate(),
		"semantic": source["semantic"].duplicate(true),
	}


static func _contains_float(value: Variant) -> bool:
	if typeof(value) == TYPE_FLOAT:
		return true
	if typeof(value) == TYPE_ARRAY:
		for item: Variant in value:
			if _contains_float(item):
				return true
	if typeof(value) == TYPE_DICTIONARY:
		for item: Variant in value.values():
			if _contains_float(item):
				return true
	return false


static func _freeze(value: Variant) -> void:
	if typeof(value) == TYPE_ARRAY:
		for item: Variant in value:
			_freeze(item)
		value.make_read_only()
	elif typeof(value) == TYPE_DICTIONARY:
		for item: Variant in value.values():
			_freeze(item)
		value.make_read_only()


static func _sha256(canonical_value: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(canonical_value.to_utf8_buffer())
	return context.finish().hex_encode()
