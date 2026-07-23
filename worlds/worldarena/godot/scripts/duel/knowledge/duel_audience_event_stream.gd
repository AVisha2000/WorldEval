class_name DuelAudienceEventStream
extends RefCounted

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const ALLOWED_PAYLOAD_KEYS: Array[String] = [
	"ability_id",
	"amount",
	"batch_id",
	"code",
	"command_id",
	"compiled_order_id",
	"damage",
	"day_phase",
	"details",
	"healing",
	"item_id",
	"level",
	"offer_id",
	"position_mt",
	"progress_bp",
	"queue_entry_id",
	"region_id",
	"resource",
	"site_id",
	"status_id",
	"terminal_reason",
	"tier",
	"type_id",
	"upgrade_id",
	"winner",
	"xp",
]

## Converts omniscient replay candidates into one legal audience stream.  A
## candidate should carry public/player payloads plus protected entity refs;
## arbitrary internal IDs in payload data are never forwarded.


static func project(
	knowledge_state: RefCounted,
	candidate_events_input: Array,
	grid_snapshot: Dictionary
) -> Dictionary:
	var errors := PackedStringArray()
	for error: String in Codec.validate_canonical_value(candidate_events_input, "$.candidate_events"):
		errors.append(error)
	if not errors.is_empty():
		return {"errors": errors, "events": [], "ok": false}
	var candidates: Array = candidate_events_input.duplicate(true)
	for index: int in candidates.size():
		if typeof(candidates[index]) != TYPE_DICTIONARY:
			errors.append("candidate_events[%d] must be an object" % index)
	if not errors.is_empty():
		return {"errors": errors, "events": [], "ok": false}
	candidates.sort_custom(_candidate_less)

	var events: Array = []
	for candidate_variant: Variant in candidates:
		var candidate: Dictionary = candidate_variant
		if not _is_legal_for_observer(knowledge_state, candidate, grid_snapshot):
			continue
		var event_result := _project_one(knowledge_state, candidate)
		if not bool(event_result["ok"]):
			errors.append_array(event_result["errors"])
			continue
		events.append(event_result["event"])
	return {"errors": errors, "events": events, "ok": errors.is_empty()}


static func _is_legal_for_observer(
	state: RefCounted,
	candidate: Dictionary,
	grid_snapshot: Dictionary
) -> bool:
	var seat := int(state.observer_seat)
	if candidate.has("audience_seats"):
		var audience_seats: Variant = candidate["audience_seats"]
		if typeof(audience_seats) != TYPE_ARRAY or not (audience_seats as Array).has(seat):
			return false
	if candidate.has("audience_mask"):
		var player_bit := 1 << seat
		if (int(candidate["audience_mask"]) & player_bit) == 0:
			return false

	var rule := str(candidate.get("visibility_rule", "source_or_target_visible"))
	match rule:
		"always", "explicit":
			return true
		"never", "omniscient":
			return false
		"owner":
			return int(candidate.get("owner_seat", -2)) == seat
		"position_visible":
			var node_id := _candidate_position_node_id(candidate, grid_snapshot)
			return node_id >= 0 and state.is_cell_currently_visible(node_id)
		"source_or_target_visible":
			for key: String in ["source_internal_id", "target_internal_id", "entity_internal_id"]:
				var internal_id := int(candidate.get(key, 0))
				if internal_id > 0 and (
					state.is_owned_internal_id(internal_id)
					or state.is_currently_visible_internal_id(internal_id)
				):
					return true
			return false
	return false


static func _project_one(state: RefCounted, candidate: Dictionary) -> Dictionary:
	var errors := PackedStringArray()
	var kind := str(candidate.get("kind", candidate.get("event_kind", "")))
	if kind.is_empty():
		errors.append("observable event kind must not be empty")
	var tick_value: Variant = candidate.get("tick", state.current_tick)
	if typeof(tick_value) != TYPE_INT or int(tick_value) < 0:
		errors.append("observable event tick must be non-negative")
	var payload_source: Variant = candidate.get("public_payload", candidate.get("payload", {}))
	if candidate.has("player_payloads"):
		var player_payloads: Variant = candidate["player_payloads"]
		if typeof(player_payloads) == TYPE_DICTIONARY:
			var seat_key := str(state.observer_seat)
			if (player_payloads as Dictionary).has(seat_key):
				payload_source = player_payloads[seat_key]
	if typeof(payload_source) != TYPE_DICTIONARY:
		errors.append("observable event payload must be an object")
		return {"errors": errors, "event": {}, "ok": false}

	var payload: Dictionary = {}
	for key: String in ALLOWED_PAYLOAD_KEYS:
		if (payload_source as Dictionary).has(key):
			payload[key] = (payload_source as Dictionary)[key]
	if payload.has("position_mt"):
		var transformed: Array = state.coordinate_frame.world_point_to_self(payload["position_mt"])
		if transformed.is_empty():
			errors.append("event position_mt is outside the self-canonical frame")
		else:
			payload["position_mt"] = transformed
	if payload.has("region_id"):
		payload["region_id"] = state.coordinate_frame.world_public_id_to_self(
			str(payload["region_id"])
		)

	var reference_fields := {
		"entity_id": "entity_internal_id",
		"source_entity_id": "source_internal_id",
		"target_entity_id": "target_internal_id",
	}
	for public_key_variant: Variant in reference_fields.keys():
		var public_key := str(public_key_variant)
		var protected_key := str(reference_fields[public_key])
		var internal_id := int(candidate.get(protected_key, 0))
		if internal_id <= 0:
			continue
		if state.is_owned_internal_id(internal_id) \
			or state.is_currently_visible_internal_id(internal_id) \
			or kind == "entity_destroyed":
			var alias: String = state.alias_if_known(internal_id)
			if not alias.is_empty():
				payload[public_key] = alias

	for error: String in Codec.validate_canonical_value(payload, "$.event.payload"):
		errors.append(error)
	if not errors.is_empty():
		return {"errors": errors, "event": {}, "ok": false}
	return {
		"errors": errors,
		"event": {
			"kind": kind,
			"payload": payload.duplicate(true),
			"tick": int(tick_value),
		},
		"ok": true,
	}


static func _candidate_position_node_id(candidate: Dictionary, grid: Dictionary) -> int:
	var payload: Variant = candidate.get("public_payload", candidate.get("payload", {}))
	if typeof(payload) != TYPE_DICTIONARY:
		return -1
	var point: Variant = (payload as Dictionary).get("position_mt", null)
	if typeof(point) != TYPE_ARRAY or (point as Array).size() != 2 \
		or typeof(point[0]) != TYPE_INT or typeof(point[1]) != TYPE_INT:
		return -1
	@warning_ignore("integer_division")
	var x: int = int(point[0]) / int(grid["cell_size_mt"])
	@warning_ignore("integer_division")
	var y: int = int(point[1]) / int(grid["cell_size_mt"])
	if x < 0 or y < 0 or x >= int(grid["width"]) or y >= int(grid["height"]):
		return -1
	return y * int(grid["width"]) + x


static func _candidate_less(left: Dictionary, right: Dictionary) -> bool:
	var left_key := _candidate_key(left)
	var right_key := _candidate_key(right)
	for index: int in left_key.size():
		if left_key[index] != right_key[index]:
			return left_key[index] < right_key[index]
	return false


static func _candidate_key(candidate: Dictionary) -> Array:
	return [
		int(candidate.get("tick", 0)),
		int(candidate.get("phase", 0)),
		int(candidate.get("world_event_seq", candidate.get("event_seq", 0))),
		str(candidate.get("kind", candidate.get("event_kind", ""))),
		Codec.sha256_canonical(candidate),
	]
