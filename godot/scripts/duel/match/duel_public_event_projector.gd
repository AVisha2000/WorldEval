class_name DuelPublicEventProjector
extends RefCounted

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const ObservationContract := preload(
	"res://scripts/duel/observations/duel_observation_contract.gd"
)

## Provider-free projection of authoritative Duel events into the frozen
## omniscient public-event wire shape. This intentionally owns no socket,
## provider, clock, display, audio, or presentation dependency.

const PUBLIC_EVENT_PAYLOAD_KEYS: Array[String] = [
	"ability_id", "amount", "batch_id", "code", "command_id", "compiled_order_id",
	"damage", "day_phase", "details", "healing", "item_id", "level", "offer_id",
	"position_mt", "progress_bp", "queue_entry_id", "region_id", "resource", "site_id",
	"status_id", "terminal_reason", "tier", "type_id", "upgrade_id", "winner", "xp",
]
const PUBLIC_EVENT_ID_FIELDS: Array[String] = [
	"ability_id", "batch_id", "command_id", "compiled_order_id", "item_id", "offer_id",
	"queue_entry_id", "region_id", "site_id", "status_id", "type_id", "upgrade_id",
]
const PUBLIC_EVENT_KINDS: Array[String] = [
	"entity_created", "entity_entered_vision", "entity_left_vision", "entity_reacquired",
	"entity_transformed", "entity_destroyed", "attack_observed", "damage_observed",
	"healing_observed", "cast_observed", "status_started", "status_ended", "item_picked_up",
	"item_dropped", "resource_deposited", "resource_spent", "resource_refunded",
	"upkeep_changed", "order_started", "order_completed", "order_cancelled", "order_paused",
	"order_failed", "construction_progress", "construction_completed", "repair_progress",
	"production_progress", "production_completed", "research_progress", "research_completed",
	"tier_completed", "revival_progress", "revival_completed", "hero_xp_gained",
	"hero_level_gained", "hero_skill_learned", "creep_camp_cleared", "camp_item_revealed",
	"shop_restocked", "shop_purchase", "day_phase_changed", "resource_depleted",
	"terrain_changed", "pathing_changed", "batch_timeout", "batch_schema_failed",
	"command_applied", "command_rejected", "terminal_win", "terminal_loss", "terminal_draw",
	"terminal_forfeit", "terminal_infrastructure_void",
]


func project_from_cursor(session: Variant, cursor: int) -> Dictionary:
	var errors := PackedStringArray()
	if session == null or session.simulation == null:
		errors.append("event projection requires a configured match session")
		return _failure(errors)
	var state_events: Array = session.simulation.state.events
	if cursor < 0 or cursor > state_events.size():
		errors.append("authoritative event cursor is outside the event stream")
		return _failure(errors)
	var projected: Array[Dictionary] = []
	for index: int in range(cursor, state_events.size()):
		var event: Variant = state_events[index]
		var event_seq := index + 1
		if int(event.event_seq) != event_seq:
			errors.append("authoritative event sequence is not contiguous")
			return _failure(errors)
		var result := _project_one(session, event, event_seq)
		_append_errors(errors, result.get("errors", []))
		if not bool(result.get("ok", false)):
			return _failure(errors)
		projected.append(result["event"])
	return {
		"cursor": state_events.size(),
		"errors": errors,
		"events": projected,
		"ok": true,
	}


func _project_one(session: Variant, event: Variant, event_seq: int) -> Dictionary:
	var errors := PackedStringArray()
	var raw_kind := str(event.event_kind)
	var terminal: Dictionary = session.simulation.terminal_result()
	var kind := _public_event_kind(raw_kind, terminal)
	var raw_payload: Dictionary = (
		event.payload if typeof(event.payload) == TYPE_DICTIONARY else {}
	)
	var projected := {
		"audience": "omniscient",
		"event_seq": event_seq,
		"kind": kind,
		"payload": _public_event_payload(
			session,
			raw_kind,
			raw_payload,
			int(event.source_internal_id),
			int(event.target_internal_id)
		),
		"tick": int(event.tick),
	}
	_append_errors(errors, Codec.validate_canonical_value(projected, "$.public_event"))
	if event_seq < 1 or int(event.tick) < 0 or kind not in PUBLIC_EVENT_KINDS:
		errors.append("projected public event identity is invalid")
	return {
		"errors": errors,
		"event": projected if errors.is_empty() else {},
		"ok": errors.is_empty(),
	}


func _public_event_kind(raw_kind: String, terminal: Dictionary) -> String:
	if raw_kind in PUBLIC_EVENT_KINDS:
		return raw_kind
	if raw_kind == "match_ended":
		match str(terminal.get("result", "")):
			"draw":
				return "terminal_draw"
			"technical_forfeit":
				return "terminal_forfeit"
			"infrastructure_void":
				return "terminal_infrastructure_void"
		return "terminal_win"
	if raw_kind in [
		"economic_entity_destroyed", "construction_destroyed", "hero_died",
		"neutral_member_died", "summon_expired",
	]:
		return "entity_destroyed"
	if raw_kind == "hero_level_up":
		return "hero_level_gained"
	if raw_kind == "hero_ability_learned":
		return "hero_skill_learned"
	if raw_kind == "hero_xp_awarded":
		return "hero_xp_gained"
	if raw_kind == "hero_revival_started":
		return "revival_progress"
	if raw_kind == "hero_revived":
		return "revival_completed"
	if raw_kind == "neutral_camp_cleared":
		return "creep_camp_cleared"
	if raw_kind == "neutral_offer_purchased":
		return "shop_purchase"
	if raw_kind == "upgrade_completed":
		return "research_completed"
	if raw_kind in ["status_expired", "periodic_effect_interrupted"]:
		return "status_ended"
	if raw_kind == "item_spawned":
		return "item_dropped"
	if "heal" in raw_kind:
		return "healing_observed"
	if "impacted" in raw_kind or "damage" in raw_kind or raw_kind == "ground_attack_landed":
		return "damage_observed"
	if "attack" in raw_kind or "projectile" in raw_kind:
		return "attack_observed"
	if "ability" in raw_kind or "effect" in raw_kind:
		return "cast_observed"
	if raw_kind in ["arrived", "movement_arrived"]:
		return "order_completed"
	if raw_kind in ["movement_committed", "route_planned"]:
		return "order_started"
	if "route" in raw_kind or "movement" in raw_kind:
		return "pathing_changed"
	if "failed" in raw_kind or "invalid" in raw_kind or "cancelled" in raw_kind:
		return "command_rejected"
	return "command_applied"


func _public_event_payload(
	session: Variant,
	raw_kind: String,
	raw: Dictionary,
	source_internal_id: int,
	target_internal_id: int
) -> Dictionary:
	var payload: Dictionary = {}
	for field: String in PUBLIC_EVENT_PAYLOAD_KEYS:
		if not raw.has(field):
			continue
		var value: Variant = raw[field]
		if field in PUBLIC_EVENT_ID_FIELDS:
			if ObservationContract.is_id(value):
				payload[field] = value
		elif field == "code":
			if value == null or (typeof(value) == TYPE_STRING and str(value).length() <= 64):
				payload[field] = value
		elif field == "terminal_reason":
			if typeof(value) == TYPE_STRING and str(value).length() <= 80:
				payload[field] = value
		elif field == "resource":
			if typeof(value) == TYPE_STRING \
				and str(value) in ["gold", "lumber", "food", "mana", "hp"]:
				payload[field] = value
		elif field == "day_phase":
			if typeof(value) == TYPE_STRING \
				and str(value) in ["day", "night", "forced_night"]:
				payload[field] = value
		elif field == "winner":
			if typeof(value) == TYPE_STRING and str(value) in ["self", "opponent", "none"]:
				payload[field] = value
		elif field == "position_mt":
			if typeof(value) == TYPE_ARRAY and (value as Array).size() == 2 \
				and typeof(value[0]) == TYPE_INT and typeof(value[1]) == TYPE_INT:
				payload[field] = (value as Array).duplicate()
		elif field == "details":
			if typeof(value) == TYPE_ARRAY:
				var details: Array[String] = []
				for detail: Variant in value:
					if ObservationContract.is_id(detail) and str(detail) not in details:
						details.append(str(detail))
				details.sort()
				if details.size() <= 24:
					payload[field] = details
		elif typeof(value) == TYPE_INT:
			if field in ["damage", "healing", "progress_bp", "level", "tier", "xp"] \
				and int(value) < 0:
				continue
			if field == "progress_bp" and int(value) > 10_000:
				continue
			if field == "level" and int(value) not in range(1, 11):
				continue
			if field == "tier" and int(value) not in range(1, 4):
				continue
			payload[field] = value
	if not payload.has("damage") and typeof(raw.get("hp_damage")) == TYPE_INT \
		and int(raw["hp_damage"]) >= 0:
		payload["damage"] = int(raw["hp_damage"])
	if not payload.has("amount"):
		for candidate: String in ["delivered", "harvested", "amount"]:
			if typeof(raw.get(candidate)) == TYPE_INT:
				payload["amount"] = int(raw[candidate])
				break
	var source_id := _entity_public_id(session, source_internal_id)
	var target_id := _entity_public_id(session, target_internal_id)
	if not source_id.is_empty():
		payload["source_entity_id"] = source_id
	if not target_id.is_empty():
		payload["target_entity_id"] = target_id
	if not target_id.is_empty() or not source_id.is_empty():
		payload["entity_id"] = target_id if not target_id.is_empty() else source_id
	var details: Array = payload.get("details", [])
	if ObservationContract.is_id(raw_kind) and raw_kind not in details:
		details.append(raw_kind)
	details.sort()
	if details.size() > 24:
		details.resize(24)
	if not details.is_empty():
		payload["details"] = details
	if raw_kind == "match_ended":
		payload["terminal_reason"] = str(raw.get("reason", "match_ended")).left(80)
	return payload


func _entity_public_id(session: Variant, internal_id: int) -> String:
	if internal_id <= 0 or not session.simulation.state.entities.has(internal_id):
		return ""
	var entity: Variant = session.simulation.state.entities[internal_id]
	return str(entity.public_id) if ObservationContract.is_id(entity.public_id) else ""


static func _failure(errors: PackedStringArray) -> Dictionary:
	return {"errors": errors, "events": [], "ok": false}


static func _append_errors(errors: PackedStringArray, values: Variant) -> void:
	if typeof(values) == TYPE_PACKED_STRING_ARRAY:
		errors.append_array(values)
	elif typeof(values) == TYPE_ARRAY:
		for value: Variant in values:
			errors.append(str(value))
