class_name DuelPerceptionRuntime
extends RefCounted

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const KnowledgeState := preload("res://scripts/duel/knowledge/duel_agent_knowledge_state.gd")
const Projector := preload("res://scripts/duel/knowledge/duel_knowledge_projector.gd")
const Builder := preload("res://scripts/duel/observations/duel_observation_builder.gd")
const ObservationContract := preload("res://scripts/duel/observations/duel_observation_contract.gd")
const PerceptionContract := preload("res://scripts/duel/perception/duel_perception_contract.gd")


class SeatKnowledgeState:
	extends KnowledgeState

	var public_local_context: Array = []
	var phase_owned_internal_ids: Dictionary = {}

	func set_public_local_context(value: Array) -> void:
		public_local_context = value.duplicate(true)

	func set_phase_owned_internal_ids(value: Dictionary) -> void:
		phase_owned_internal_ids = value.duplicate()

	func is_phase_owned_internal_id(internal_id: int) -> bool:
		return phase_owned_internal_ids.has(internal_id)

	func public_projection() -> Dictionary:
		var projection := super.public_projection()
		projection["map_state"]["local_context"] = public_local_context.duplicate(true)
		return projection


var match_id: String = ""
var _knowledge_by_seat: Dictionary = {}
var _configured: bool = false


func configure(
	p_match_id: String,
	map_manifest: Dictionary,
	seat_zero_alias_salt: PackedByteArray,
	seat_one_alias_salt: PackedByteArray
) -> PackedStringArray:
	var errors := PackedStringArray()
	if not ObservationContract.is_match_id(p_match_id):
		errors.append("match_id is invalid")
	if seat_zero_alias_salt.size() < 16 or seat_one_alias_salt.size() < 16:
		errors.append("each observer alias salt must contain at least 16 bytes")
	if seat_zero_alias_salt == seat_one_alias_salt:
		errors.append("observer alias salts must be distinct")
	var next_states: Dictionary = {}
	for seat: int in 2:
		var state := SeatKnowledgeState.new()
		var salt := seat_zero_alias_salt if seat == 0 else seat_one_alias_salt
		errors.append_array(state.configure(seat, salt, map_manifest))
		next_states[seat] = state
	if not errors.is_empty():
		return errors
	match_id = p_match_id
	_knowledge_by_seat = next_states
	_configured = true
	return errors


func is_configured() -> bool:
	return _configured


func knowledge_state_for_checkpoint(seat: int) -> RefCounted:
	## Protected runner/checkpoint access only. Never pass this return value to a
	## provider transport; phase_12() returns the legal wire observations.
	return _knowledge_by_seat.get(seat)


func phase_12(phase_snapshot_input: Dictionary) -> Dictionary:
	var errors := PackedStringArray()
	if not _configured:
		errors.append("perception runtime is not configured")
		return _failure(errors)
	errors.append_array(PerceptionContract.validate_phase_snapshot(phase_snapshot_input))
	if not errors.is_empty():
		return _failure(errors)
	var phase := phase_snapshot_input.duplicate(true)
	var seat_snapshots := _seat_snapshot_index(phase["seat_snapshots"])
	var observations: Dictionary = {}
	var canonical_json: Dictionary = {}
	var observation_hashes: Dictionary = {}
	var knowledge_hashes: Dictionary = {}
	var byte_counts: Dictionary = {}

	## Both observers consume the exact same frozen world projection. The only
	## differences are their persistent knowledge, aliases, transforms, and own
	## public context.
	for seat: int in 2:
		var state: SeatKnowledgeState = _knowledge_by_seat[seat]
		var entity_snapshots := _prepare_entities_for_seat(
			state, phase["entity_snapshots"]
		)
		var projected := Projector.project_phase_12(
			state,
			int(phase["tick"]),
			str(phase["day_phase"]),
			phase["grid_snapshot"],
			entity_snapshots,
			phase["candidate_events"],
			seat_snapshots[seat].get("temporary_vision_sources", []),
			seat_snapshots[seat].get("revealed_entity_internal_ids", [])
		)
		if not bool(projected["ok"]):
			_append_prefixed(errors, projected["errors"], "seat %d projection: " % seat)
			continue
		var seat_snapshot: Dictionary = seat_snapshots[seat]
		var local_context := _project_local_context(
			state,
			seat_snapshot.get("local_context_candidates", []),
			projected["projection"]
		)
		state.set_public_local_context(local_context)
		var context_result := _build_public_context(state, phase, seat_snapshot)
		if not bool(context_result["ok"]):
			_append_prefixed(errors, context_result["errors"], "seat %d context: " % seat)
			continue
		var built := Builder.build(state, context_result["context"])
		if not bool(built["ok"]):
			_append_prefixed(errors, built["errors"], "seat %d observation: " % seat)
			continue
		if ObservationContract.contains_forbidden_key(built["observation"]):
			errors.append("seat %d observation contains a protected key" % seat)
			continue
		var json_text := str(built["canonical_json"])
		for forbidden_text: String in [
			"internal_id", "alias_salt", "provider_identity", "world_checkpoint",
		]:
			if forbidden_text in json_text:
				errors.append("seat %d observation contains protected text %s" % [
					seat, forbidden_text,
				])
		observations[str(seat)] = (built["observation"] as Dictionary).duplicate(true)
		canonical_json[str(seat)] = json_text
		observation_hashes[str(seat)] = str(built["observation_hash"])
		knowledge_hashes[str(seat)] = state.public_projection_hash()
		byte_counts[str(seat)] = int(built["byte_count"])

	if not errors.is_empty() or observations.size() != 2:
		return _failure(errors)
	return {
		"byte_counts": byte_counts,
		"canonical_json": canonical_json,
		"errors": errors,
		"knowledge_hashes": knowledge_hashes,
		"observation_hashes": observation_hashes,
		"observations": observations,
		"ok": true,
	}


func _build_public_context(
	state: SeatKnowledgeState,
	phase: Dictionary,
	seat_snapshot: Dictionary
) -> Dictionary:
	var errors := PackedStringArray()
	var context := {
		"day_phase": str(phase["day_phase"]),
		"decision": (seat_snapshot["decision"] as Dictionary).duplicate(true),
		"economy": (seat_snapshot["economy"] as Dictionary).duplicate(true),
		"food": (seat_snapshot["food"] as Dictionary).duplicate(true),
		"last_action_receipt": _deep_copy_variant(seat_snapshot["last_action_receipt"]),
		"match_id": match_id,
		"match_state": _match_state_for_seat(
			int(state.observer_seat), int(phase["no_progress_ticks"]), phase["terminal"]
		),
		"observation_seq": int(seat_snapshot["observation_seq"]),
		"remaining_match_ticks": int(phase["remaining_match_ticks"]),
		"squads": _project_squads(state, seat_snapshot["squad_candidates"], errors),
		"technology": _project_technology(state, seat_snapshot["own_technology"], errors),
		"upkeep": (seat_snapshot["upkeep"] as Dictionary).duplicate(true),
		"visible_items": _project_visible_items(
			state, phase["grid_snapshot"], seat_snapshot.get("visible_item_candidates", [])
		),
		"visible_shops": _project_visible_shops(
			state, phase["grid_snapshot"], seat_snapshot.get("visible_shop_candidates", [])
		),
		"working_memory": str(seat_snapshot["working_memory"]),
	}
	for optional: String in [
		"include_brief", "maximum_observation_bytes", "structure_type_ids",
	]:
		if seat_snapshot.has(optional):
			context[optional] = _deep_copy_variant(seat_snapshot[optional])
	errors.append_array(ObservationContract.validate_public_context(context))
	return {"context": context, "errors": errors, "ok": errors.is_empty()}


func _prepare_entities_for_seat(state: SeatKnowledgeState, source: Array) -> Array:
	var entities: Array = source.duplicate(true)
	var phase_owned: Dictionary = {}
	for entity_variant: Variant in entities:
		var entity: Dictionary = entity_variant
		if int(entity["owner_seat"]) == int(state.observer_seat):
			var internal_id := int(entity["internal_id"])
			phase_owned[internal_id] = true
			state.ensure_alias(internal_id)
	state.set_phase_owned_internal_ids(phase_owned)
	for index: int in entities.size():
		var entity: Dictionary = entities[index]
		if int(entity["owner_seat"]) != int(state.observer_seat) \
			or not entity.has("owned_observation"):
			continue
		entity["owned_observation"] = _project_owned_observation(
			state, entity["owned_observation"]
		)
		entities[index] = entity
	return entities


func _project_owned_observation(state: SeatKnowledgeState, source: Dictionary) -> Dictionary:
	var result := source.duplicate(true)
	if result.has("builder_internal_ids"):
		result["builders"] = _aliases_for_owned_ids(state, result["builder_internal_ids"])
		result.erase("builder_internal_ids")
	if result.has("current_order"):
		result["current_order"] = _project_order(state, result["current_order"])
	if result.has("queued_orders") and typeof(result["queued_orders"]) == TYPE_ARRAY:
		var orders: Array = []
		for order_variant: Variant in result["queued_orders"]:
			orders.append(_project_order(state, order_variant))
		result["queued_orders"] = orders
	for status_field: String in ["statuses", "buffs", "debuffs"]:
		if result.has(status_field):
			result[status_field] = _project_statuses(state, result[status_field])
	if result.has("revival_state") and typeof(result["revival_state"]) == TYPE_DICTIONARY:
		var revival: Dictionary = result["revival_state"]
		if revival.has("reviver_internal_id"):
			var alias := _known_alias(state, int(revival["reviver_internal_id"]))
			revival.erase("reviver_internal_id")
			if not alias.is_empty():
				revival["reviver_id"] = alias
		result["revival_state"] = revival
	return result


func _project_order(state: SeatKnowledgeState, value: Variant) -> Variant:
	if value == null or typeof(value) != TYPE_DICTIONARY:
		return _deep_copy_variant(value)
	var order: Dictionary = value.duplicate(true)
	if order.has("target_internal_id"):
		var alias := _known_alias(state, int(order["target_internal_id"]))
		order.erase("target_internal_id")
		if not alias.is_empty():
			order["target_entity_id"] = alias
	return order


func _project_statuses(state: SeatKnowledgeState, value: Variant) -> Array:
	var result: Array = []
	if typeof(value) != TYPE_ARRAY:
		return result
	for status_variant: Variant in value:
		if typeof(status_variant) != TYPE_DICTIONARY:
			continue
		var status: Dictionary = status_variant.duplicate(true)
		if status.has("source_internal_id"):
			var alias := _known_alias(state, int(status["source_internal_id"]))
			status.erase("source_internal_id")
			if alias.is_empty():
				continue
			status["source_entity_id"] = alias
		result.append(status)
	result.sort_custom(_status_less)
	return result


func _project_technology(
	state: SeatKnowledgeState, value: Variant, errors: PackedStringArray
) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("own_technology must be an object")
		return {}
	var source: Dictionary = value
	var result := {
		"completed_upgrades": _sorted_unique_strings(source.get("completed_upgrades", [])),
		"hero_slots": _deep_copy_variant(source.get("hero_slots", {})),
		"researching": [],
		"tier": int(source.get("tier", 0)),
	}
	if typeof(source.get("researching")) != TYPE_ARRAY:
		errors.append("own_technology.researching must be an array")
		return result
	for row_variant: Variant in source["researching"]:
		if typeof(row_variant) != TYPE_DICTIONARY:
			errors.append("own_technology researching row must be an object")
			continue
		var row: Dictionary = row_variant
		if _sorted_keys(row) != ["entry", "producer_internal_id"]:
			errors.append("own_technology researching row has an unknown field")
			continue
		var producer_id := int(row.get("producer_internal_id", 0))
		if not state.is_phase_owned_internal_id(producer_id):
			errors.append("technology producer is not owned by the observing seat")
			continue
		result["researching"].append({
			"entry": _deep_copy_variant(row["entry"]),
			"producer_id": state.alias_if_known(producer_id),
		})
	(result["researching"] as Array).sort_custom(_producer_less)
	return result


func _project_squads(
	state: SeatKnowledgeState, value: Variant, errors: PackedStringArray
) -> Array:
	var result: Array = []
	if typeof(value) != TYPE_ARRAY:
		errors.append("squad_candidates must be an array")
		return result
	for row_variant: Variant in value:
		if typeof(row_variant) != TYPE_DICTIONARY:
			errors.append("squad candidate must be an object")
			continue
		var row: Dictionary = row_variant
		var allowed := [
			"current_order", "formation", "member_internal_ids",
			"retreat_hp_threshold_bp", "squad_id", "stance",
		]
		if not _only_keys(row, allowed):
			errors.append("squad candidate has an unknown field")
			continue
		var member_ids := _aliases_for_owned_ids(state, row.get("member_internal_ids", []))
		if member_ids.is_empty():
			errors.append("squad candidate must contain at least one owned member")
			continue
		var projected := {
			"current_order": _project_order(state, row.get("current_order", null)),
			"formation": str(row.get("formation", "none")),
			"member_ids": member_ids,
			"squad_id": str(row.get("squad_id", "")),
			"stance": str(row.get("stance", "defensive")),
		}
		if row.has("retreat_hp_threshold_bp"):
			projected["retreat_hp_threshold_bp"] = int(row["retreat_hp_threshold_bp"])
		result.append(projected)
	result.sort_custom(_squad_less)
	return result


func _project_visible_items(
	state: SeatKnowledgeState, grid: Dictionary, candidates: Array
) -> Array:
	var result: Array = []
	for candidate_variant: Variant in candidates:
		var candidate: Dictionary = candidate_variant
		if not _position_is_visible(state, grid, candidate["position_mt"]):
			continue
		var record := {
			"charges": int(candidate["charges"]),
			"item_entity_id": state.ensure_alias(int(candidate["entity_internal_id"])),
			"item_type_id": str(candidate["item_type_id"]),
			"position_mt": state.coordinate_frame.world_point_to_self(candidate["position_mt"]),
			"region_id": state.coordinate_frame.world_public_id_to_self(str(candidate["region_id"])),
		}
		if candidate.has("despawn_tick"):
			record["despawn_tick"] = candidate["despawn_tick"]
		result.append(record)
	result.sort_custom(_item_less)
	return result


func _project_visible_shops(
	state: SeatKnowledgeState, grid: Dictionary, candidates: Array
) -> Array:
	var result: Array = []
	for candidate_variant: Variant in candidates:
		var candidate: Dictionary = candidate_variant
		if not _position_is_visible(state, grid, candidate["position_mt"]):
			continue
		var shop_id := state.ensure_alias(int(candidate["entity_internal_id"]))
		result.append({
			"offers": (candidate["offers"] as Array).duplicate(true),
			"position_mt": state.coordinate_frame.world_point_to_self(candidate["position_mt"]),
			"region_id": state.coordinate_frame.world_public_id_to_self(str(candidate["region_id"])),
			"shop_id": shop_id,
			"shop_type": str(candidate["shop_type"]),
			"site_id": state.coordinate_frame.world_public_id_to_self(str(candidate["site_id"])),
		})
	result.sort_custom(_shop_less)
	return result


func _project_local_context(
	state: SeatKnowledgeState, candidates: Array, projection: Dictionary
) -> Array:
	var owned_by_alias := _records_by_alias(projection["owned_entities"])
	var visible: Array = projection["visible_contacts"]
	var remembered: Array = projection["remembered_contacts"]
	var result: Array = []
	for candidate_variant: Variant in candidates:
		var candidate: Dictionary = candidate_variant
		var anchor_internal_id := int(candidate["anchor_internal_id"])
		if not state.is_owned_internal_id(anchor_internal_id):
			continue
		var anchor_alias := state.alias_if_known(anchor_internal_id)
		if not owned_by_alias.has(anchor_alias):
			continue
		var anchor: Dictionary = owned_by_alias[anchor_alias]
		var anchor_position: Array = anchor["position_mt"]
		var visibility_radius := int(candidate["visibility_radius_mt"])
		var contact_rows: Array = []
		for contact_variant: Variant in visible:
			var contact: Dictionary = contact_variant
			var distance := _point_distance_mt(anchor_position, contact["position_mt"])
			if distance > visibility_radius:
				continue
			contact_rows.append({
				"bearing": _bearing(anchor_position, contact["position_mt"]),
				"distance_mt": distance,
				"entity_id": str(contact["entity_id"]),
				"known_path_distance_mt": null,
				"line_of_sight": true,
			})
		contact_rows.sort_custom(_entity_id_less)
		var threat_rows: Array = []
		for remembered_variant: Variant in remembered:
			var remembered_contact: Dictionary = remembered_variant
			if str(remembered_contact.get("owner_category", "")) != "opponent":
				continue
			var last_observed: Dictionary = remembered_contact["last_observed"]
			var distance := _point_distance_mt(anchor_position, last_observed["position_mt"])
			threat_rows.append({
				"age_ticks": int(remembered_contact["memory_age_ticks"]),
				"bearing": _bearing(anchor_position, last_observed["position_mt"]),
				"distance_mt": distance,
				"entity_id": str(remembered_contact["entity_id"]),
			})
		threat_rows.sort_custom(_entity_id_less)
		result.append({
			"anchor_id": anchor_alias,
			"detection_radius_mt": int(candidate["detection_radius_mt"]),
			"elevation": int(candidate["elevation"]),
			"exits": _transform_exits(state, candidate["exits"]),
			"nearby_features": _transform_features(state, candidate["nearby_features"]),
			"position_mt": anchor_position.duplicate(),
			"region_id": str(anchor["region_id"]),
			"remembered_threats": threat_rows,
			"retreat_route": _transform_public_ids(state, candidate["retreat_route"]),
			"tactical_slot": candidate["tactical_slot"],
			"terrain": str(candidate["terrain"]),
			"visibility_radius_mt": visibility_radius,
			"visible_contacts": contact_rows,
		})
	result.sort_custom(_anchor_less)
	return result


func _transform_exits(state: SeatKnowledgeState, value: Array) -> Array:
	var result: Array = value.duplicate(true)
	for index: int in result.size():
		var row: Dictionary = result[index]
		row["to_region_id"] = state.coordinate_frame.world_public_id_to_self(
			str(row["to_region_id"])
		)
		row["bearing"] = _transform_bearing(int(state.observer_seat), str(row["bearing"]))
		result[index] = row
	result.sort_custom(_exit_less)
	return result


func _transform_features(state: SeatKnowledgeState, value: Array) -> Array:
	var result: Array = value.duplicate(true)
	for index: int in result.size():
		var row: Dictionary = result[index]
		row["site_id"] = state.coordinate_frame.world_public_id_to_self(str(row["site_id"]))
		row["bearing"] = _transform_bearing(int(state.observer_seat), str(row["bearing"]))
		result[index] = row
	result.sort_custom(_feature_less)
	return result


func _transform_public_ids(state: SeatKnowledgeState, value: Array) -> Array:
	var result: Array = []
	for id_variant: Variant in value:
		result.append(state.coordinate_frame.world_public_id_to_self(str(id_variant)))
	return result


static func _match_state_for_seat(seat: int, no_progress_ticks: int, value: Variant) -> Dictionary:
	if value == null:
		return {"no_progress_ticks": no_progress_ticks, "status": "active"}
	var terminal: Dictionary = value
	var kind := str(terminal["kind"])
	var result := "draw"
	if kind == "victory":
		result = "win" if int(terminal["winner_seat"]) == seat else "loss"
	elif kind == "forfeit":
		result = "win" if int(terminal["winner_seat"]) == seat else "forfeit"
	elif kind == "infrastructure_void":
		result = "infrastructure_void"
	return {
		"no_progress_ticks": no_progress_ticks,
		"status": "terminal",
		"terminal": {
			"reason": str(terminal["reason"]),
			"result": result,
			"terminal_tick": int(terminal["terminal_tick"]),
		},
	}


static func _position_is_visible(
	state: SeatKnowledgeState, grid: Dictionary, position_mt: Array
) -> bool:
	@warning_ignore("integer_division")
	var x: int = int(position_mt[0]) / int(grid["cell_size_mt"])
	@warning_ignore("integer_division")
	var y: int = int(position_mt[1]) / int(grid["cell_size_mt"])
	if x < 0 or y < 0 or x >= int(grid["width"]) or y >= int(grid["height"]):
		return false
	return state.is_cell_currently_visible(y * int(grid["width"]) + x)


static func _known_alias(state: SeatKnowledgeState, internal_id: int) -> String:
	if internal_id <= 0:
		return ""
	if state.is_owned_internal_id(internal_id):
		return state.alias_if_known(internal_id)
	return state.alias_if_known(internal_id)


static func _aliases_for_owned_ids(state: SeatKnowledgeState, value: Variant) -> Array:
	var result: Array[String] = []
	if typeof(value) != TYPE_ARRAY:
		return []
	for id_variant: Variant in value:
		var internal_id := int(id_variant)
		if not state.is_phase_owned_internal_id(internal_id):
			continue
		var alias := state.alias_if_known(internal_id)
		if not alias.is_empty() and not result.has(alias):
			result.append(alias)
	result.sort()
	var untyped: Array = []
	untyped.assign(result)
	return untyped


static func _records_by_alias(value: Array) -> Dictionary:
	var result: Dictionary = {}
	for row_variant: Variant in value:
		if typeof(row_variant) == TYPE_DICTIONARY:
			result[str((row_variant as Dictionary).get("entity_id", ""))] = row_variant
	return result


static func _seat_snapshot_index(value: Array) -> Dictionary:
	var result: Dictionary = {}
	for row_variant: Variant in value:
		var row: Dictionary = row_variant
		result[int(row["seat"])] = row
	return result


static func _point_distance_mt(left: Array, right: Array) -> int:
	var delta_x := int(right[0]) - int(left[0])
	var delta_y := int(right[1]) - int(left[1])
	return _integer_sqrt(delta_x * delta_x + delta_y * delta_y)


static func _integer_sqrt(value: int) -> int:
	if value <= 0:
		return 0
	var bit: int = 1 << 62
	while bit > value:
		bit >>= 2
	var remainder := value
	var result := 0
	while bit != 0:
		if remainder >= result + bit:
			remainder -= result + bit
			result = (result >> 1) + bit
		else:
			result >>= 1
		bit >>= 2
	return result


static func _bearing(origin: Array, target: Array) -> String:
	var delta_x := int(target[0]) - int(origin[0])
	var delta_y := int(target[1]) - int(origin[1])
	if delta_x == 0 and delta_y == 0:
		return "same"
	var absolute_x := absi(delta_x)
	var absolute_y := absi(delta_y)
	if absolute_x * 10_000 <= absolute_y * 4_142:
		return "south" if delta_y > 0 else "north"
	if absolute_y * 10_000 <= absolute_x * 4_142:
		return "east" if delta_x > 0 else "west"
	if delta_y < 0:
		return "north_east" if delta_x > 0 else "north_west"
	return "south_east" if delta_x > 0 else "south_west"


static func _transform_bearing(seat: int, bearing: String) -> String:
	if seat == 0 or bearing == "same":
		return bearing
	var opposite := {
		"east": "west",
		"north": "south",
		"north_east": "south_west",
		"north_west": "south_east",
		"south": "north",
		"south_east": "north_west",
		"south_west": "north_east",
		"west": "east",
	}
	return str(opposite.get(bearing, bearing))


static func _sorted_unique_strings(value: Variant) -> Array:
	var typed: Array[String] = []
	if typeof(value) == TYPE_ARRAY:
		for element: Variant in value:
			var text := str(element)
			if not typed.has(text):
				typed.append(text)
	typed.sort()
	var result: Array = []
	result.assign(typed)
	return result


static func _deep_copy_variant(value: Variant) -> Variant:
	if typeof(value) == TYPE_DICTIONARY or typeof(value) == TYPE_ARRAY:
		return value.duplicate(true)
	return value


static func _sorted_keys(value: Dictionary) -> Array:
	var keys: Array = value.keys()
	keys.sort()
	return keys


static func _only_keys(value: Dictionary, allowed: Array) -> bool:
	for key_variant: Variant in value.keys():
		if not allowed.has(str(key_variant)):
			return false
	return true


static func _append_prefixed(
	errors: PackedStringArray, source: Variant, prefix: String
) -> void:
	for error: Variant in source:
		errors.append(prefix + str(error))


static func _status_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left.get("status_id", "")) < str(right.get("status_id", ""))


static func _producer_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left.get("producer_id", "")) < str(right.get("producer_id", ""))


static func _squad_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left.get("squad_id", "")) < str(right.get("squad_id", ""))


static func _item_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left.get("item_entity_id", "")) < str(right.get("item_entity_id", ""))


static func _shop_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left.get("site_id", "")) < str(right.get("site_id", ""))


static func _anchor_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left.get("anchor_id", "")) < str(right.get("anchor_id", ""))


static func _entity_id_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left.get("entity_id", "")) < str(right.get("entity_id", ""))


static func _exit_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left.get("to_region_id", "")) < str(right.get("to_region_id", ""))


static func _feature_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left.get("site_id", "")) < str(right.get("site_id", ""))


static func _failure(errors: PackedStringArray) -> Dictionary:
	return {
		"byte_counts": {},
		"canonical_json": {},
		"errors": errors,
		"knowledge_hashes": {},
		"observation_hashes": {},
		"observations": {},
		"ok": false,
	}
