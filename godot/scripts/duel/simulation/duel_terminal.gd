class_name DuelTerminalSystem
extends RefCounted

const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")

var enabled: bool = false
var maximum_match_ticks: int = 0
var no_progress_draw_ticks: int = 0
var stronghold_catalog_ids: Dictionary = {}
var _events: Array[Dictionary] = []


func configure(rules_catalog: Dictionary, economy_catalog: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if not rules_catalog.has("termination") \
		or typeof(rules_catalog["termination"]) != TYPE_DICTIONARY:
		errors.append("rules catalog is missing termination")
	if not economy_catalog.has("structures") \
		or typeof(economy_catalog["structures"]) != TYPE_DICTIONARY:
		errors.append("economy catalog is missing structures")
	if not errors.is_empty():
		return errors
	var termination: Dictionary = rules_catalog["termination"]
	for field: String in [
		"maximum_match_ticks", "no_progress_draw_ticks", "victory_condition",
		"stronghold_rebuildable", "same_tick_double_stronghold_destruction",
		"time_limit_result",
	]:
		if not termination.has(field):
			errors.append("termination is missing %s" % field)
	if not errors.is_empty():
		return errors
	if int(termination["maximum_match_ticks"]) <= 0:
		errors.append("maximum_match_ticks must be positive")
	if int(termination["no_progress_draw_ticks"]) <= 0:
		errors.append("no_progress_draw_ticks must be positive")
	if str(termination["victory_condition"]) != "destroy_enemy_stronghold":
		errors.append("unsupported victory condition")
	if bool(termination["stronghold_rebuildable"]):
		errors.append("scored Duel strongholds must not be rebuildable")
	if str(termination["same_tick_double_stronghold_destruction"]) != "draw":
		errors.append("double stronghold destruction must be a draw")
	if str(termination["time_limit_result"]) != "draw":
		errors.append("time limit must be a draw")
	var catalog_ids: Dictionary = {}
	for type_variant: Variant in (economy_catalog["structures"] as Dictionary).keys():
		var type_id := str(type_variant)
		var definition: Dictionary = economy_catalog["structures"][type_variant]
		if str(definition.get("semantic_role", "")) == "stronghold":
			catalog_ids[type_id] = true
	if catalog_ids.is_empty():
		errors.append("economy catalog has no stronghold structure")
	if not errors.is_empty():
		return errors
	maximum_match_ticks = int(termination["maximum_match_ticks"])
	no_progress_draw_ticks = int(termination["no_progress_draw_ticks"])
	stronghold_catalog_ids = catalog_ids
	enabled = true
	clear_pending()
	return errors


func test(state: Variant, tick: int) -> void:
	if not enabled or state == null or bool(state.terminal["ended"]):
		return
	var present := {0: false, 1: false}
	var alive := {0: false, 1: false}
	for entity_id: int in state.sorted_entity_ids():
		var entity: EntityRecord = state.entities[entity_id]
		if not stronghold_catalog_ids.has(entity.catalog_id) or entity.owner_seat not in [0, 1]:
			continue
		present[entity.owner_seat] = true
		if entity.alive and entity.hp > 0:
			alive[entity.owner_seat] = true
	if bool(present[0]) and bool(present[1]):
		var seat_0_destroyed := not bool(alive[0])
		var seat_1_destroyed := not bool(alive[1])
		if seat_0_destroyed and seat_1_destroyed:
			_finish(state, tick, "draw", "double_stronghold_destruction", -1)
			return
		if seat_0_destroyed:
			_finish(state, tick, "normal", "stronghold_destroyed", 1)
			return
		if seat_1_destroyed:
			_finish(state, tick, "normal", "stronghold_destroyed", 0)
			return
	if int(state.no_progress_ticks) >= no_progress_draw_ticks:
		_finish(state, tick, "draw", "no_progress", -1)
		return
	if tick + 1 >= maximum_match_ticks:
		_finish(state, tick, "draw", "time_limit", -1)


func technical_forfeit(state: Variant, losing_seats: Array[int], tick: int) -> Dictionary:
	if not enabled or state == null or bool(state.terminal["ended"]):
		return {"accepted": false, "code": "already_terminal"}
	var unique: Dictionary = {}
	for seat: int in losing_seats:
		if seat not in [0, 1]:
			return {"accepted": false, "code": "invalid_seat"}
		unique[seat] = true
	if unique.is_empty():
		return {"accepted": false, "code": "invalid_request"}
	if unique.size() == 2:
		_finish(state, tick, "draw", "double_technical_forfeit", -1)
	else:
		var loser := int(unique.keys()[0])
		_finish(state, tick, "technical_forfeit", "model_failure", 1 - loser)
	return {"accepted": true, "code": "accepted"}


func infrastructure_void(state: Variant, tick: int, reason: String) -> Dictionary:
	if not enabled or state == null or bool(state.terminal["ended"]):
		return {"accepted": false, "code": "already_terminal"}
	if reason.is_empty():
		return {"accepted": false, "code": "invalid_reason"}
	_finish(state, tick, "infrastructure_void", reason, -1)
	return {"accepted": true, "code": "accepted"}


func take_events() -> Array[Dictionary]:
	var result := _events.duplicate(true)
	_events.clear()
	return result


func clear_pending() -> void:
	_events.clear()


func _finish(state: Variant, tick: int, result: String, reason: String, winner_seat: int) -> void:
	state.terminal = {
		"ended": true,
		"reason": reason,
		"result": result,
		"winner_seat": winner_seat,
	}
	_events.append({
		"event_kind": "match_ended",
		"payload": {
			"reason": reason,
			"result": result,
			"terminal_tick": tick,
			"winner_seat": winner_seat,
		},
		"source_internal_id": 0,
		"target_internal_id": 0,
	})
