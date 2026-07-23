class_name DuelReplayPresentationAdapter
extends RefCounted

## Visual-only bridge between DuelPresentation's request signals and an
## immutable DuelOfficialReplayPlayer.  It never receives live authority or
## simulation references, and it never derives a player view by filtering an
## omniscient view: seat projections come from that seat's recorded legal
## observation bytes.

var _presentation: Variant = null
var _player: Variant = null
var _bound := false


func bind(presentation: Variant, player: Variant) -> Dictionary:
	if _bound:
		return _failure("replay_adapter_already_bound", "replay presentation adapter is already bound")
	if presentation == null or player == null:
		return _failure("replay_adapter_invalid_target", "presentation and replay player are required")
	for method: String in [
		"apply_events", "apply_projection", "set_replay_state", "show_live",
	]:
		if not presentation.has_method(method):
			return _failure(
				"replay_adapter_invalid_presentation",
				"presentation is missing replay method %s" % method
			)
	for method: String in [
		"current_perspective_record", "replay_state", "seek_tick", "set_paused",
		"set_perspective", "set_playback_speed", "visible_public_events",
	]:
		if not player.has_method(method):
			return _failure(
				"replay_adapter_invalid_player", "player is missing replay method %s" % method
			)
	_presentation = presentation
	_player = player
	_presentation.pause_requested.connect(_on_pause_requested)
	_presentation.playback_speed_requested.connect(_on_playback_speed_requested)
	_presentation.replay_seek_requested.connect(_on_replay_seek_requested)
	_presentation.perspective_requested.connect(_on_perspective_requested)
	_player.state_changed.connect(_on_player_state_changed)
	_player.perspective_changed.connect(_on_player_perspective_changed)
	_bound = true
	_presentation.show_live()
	refresh()
	return {"code": "ok", "errors": PackedStringArray(), "ok": true}


func unbind() -> void:
	if not _bound:
		return
	_disconnect_if_connected(_presentation.pause_requested, _on_pause_requested)
	_disconnect_if_connected(
		_presentation.playback_speed_requested, _on_playback_speed_requested
	)
	_disconnect_if_connected(_presentation.replay_seek_requested, _on_replay_seek_requested)
	_disconnect_if_connected(_presentation.perspective_requested, _on_perspective_requested)
	_disconnect_if_connected(_player.state_changed, _on_player_state_changed)
	_disconnect_if_connected(_player.perspective_changed, _on_player_perspective_changed)
	_presentation = null
	_player = null
	_bound = false


func refresh() -> Dictionary:
	if not _bound:
		return _failure("replay_adapter_not_bound", "replay presentation adapter is not bound")
	_presentation.set_replay_state(_player.replay_state())
	var record: Dictionary = _player.current_perspective_record()
	if not bool(record.get("available", false)):
		# Do not manufacture an omniscient or arbitrary-tick state merely to fill
		# the board. The replay status retains the exact insufficiency code.
		_presentation.apply_events([])
		return {
			"code": str(record.get("code", "perspective_evidence_unavailable")),
			"errors": PackedStringArray([str(record.get("reason", "perspective unavailable"))]),
			"ok": false,
		}
	var projection: Dictionary
	var events: Array
	if str(record.get("kind", "")) == "verified_omniscient_authority":
		projection = (record["projection"] as Dictionary).duplicate(true)
		projection["requested_replay_tick"] = int(record["requested_tick"])
		projection["stale_ticks"] = int(record["stale_ticks"])
		events = _public_events(_player.visible_public_events())
	else:
		projection = _legal_observation_projection(record, _player.evidence_copy())
		events = _legal_events(record)
	_presentation.apply_projection(str(record["perspective_id"]), projection)
	_presentation.apply_events(events)
	return {"code": "ok", "errors": PackedStringArray(), "ok": true}


func _on_pause_requested(paused: bool) -> void:
	_player.set_paused(paused)


func _on_playback_speed_requested(speed: float) -> void:
	_player.set_playback_speed(speed)


func _on_replay_seek_requested(tick: int) -> void:
	_player.seek_tick(tick)


func _on_perspective_requested(perspective_id: String) -> void:
	_player.set_perspective(perspective_id)


func _on_player_state_changed(state: Dictionary) -> void:
	if _bound:
		_presentation.set_replay_state(state.duplicate(true))


func _on_player_perspective_changed(_perspective_id: String, _record: Dictionary) -> void:
	if _bound:
		refresh()


func _legal_observation_projection(record: Dictionary, evidence: Dictionary) -> Dictionary:
	var observation: Dictionary = record["observation"]
	var perspective_id := str(record["perspective_id"])
	var self_seat := 0 if perspective_id == "seat_0" else 1
	var opponent_seat := 1 - self_seat
	var entities: Array = []
	_append_entities(entities, observation.get("owned_entities", []), self_seat, false, "unit")
	_append_entities(
		entities, observation.get("owned_structures", []), self_seat, false, "structure"
	)
	_append_entities(entities, observation.get("heroes", []), self_seat, false, "hero")
	_append_entities(
		entities, observation.get("visible_contacts", []), opponent_seat, false, "unit"
	)
	_append_entities(
		entities, observation.get("remembered_contacts", []), opponent_seat, true, "unit"
	)
	_append_entities(entities, observation.get("visible_neutrals", []), -1, false, "unit")

	var map_manifest: Dictionary = evidence.get("match_init", {}).get("map_manifest", {})
	var coordinate_system: Dictionary = map_manifest.get("coordinate_system", {})
	var bounds: Dictionary = coordinate_system.get("bounds_mt", {})
	var maximum: Array = bounds.get("max_exclusive", [192_000, 128_000])
	var own_stronghold := _stronghold(observation.get("owned_structures", []))
	var enemy_stronghold := _stronghold(observation.get("visible_contacts", []))
	var own_player := _player_row(
		"Model %s knowledge" % ("A" if self_seat == 0 else "B"),
		observation, own_stronghold
	)
	var hidden_player := {
		"heroes": [],
		"label": "Model %s (unobserved)" % ("A" if opponent_seat == 0 else "B"),
		"resources": {},
		"stronghold": enemy_stronghold,
		"tier": 0,
	}
	var players: Array = [hidden_player.duplicate(true), hidden_player.duplicate(true)]
	players[self_seat] = own_player
	players[opponent_seat] = hidden_player
	var decision: Dictionary = observation.get("decision", {})
	var validity: Variant = decision.get("valid_until_tick")
	var remaining := 0 if validity == null else maxi(
		0, int(validity) - int(observation.get("tick", 0))
	)
	return {
		"day_phase": str(observation.get("day_phase", "day")),
		"decision_mode": str(evidence.get("decision_mode", "fixed_simultaneous")),
		"decision_ticks_remaining": remaining,
		"entities": entities,
		"map": {
			"height_mt": int(maximum[1]) if maximum.size() == 2 else 128_000,
			"width_mt": int(maximum[0]) if maximum.size() == 2 else 192_000,
		},
		"maximum_match_ticks": int(evidence.get("maximum_tick", 0)),
		"objective": "Destroy the opposing Stronghold",
		"perspective_id": perspective_id,
		"players": players,
		"projection_kind": "recorded_legal_observation",
		"requested_replay_tick": int(record["requested_tick"]),
		"simulation_hz": 10,
		"stale_ticks": int(record["stale_ticks"]),
		"tick": int(record["recorded_tick"]),
	}


func _legal_events(record: Dictionary) -> Array:
	var observation: Dictionary = record["observation"]
	var result: Array = []
	for index: int in (observation.get("events_since_previous", []) as Array).size():
		var event_variant: Variant = observation["events_since_previous"][index]
		if typeof(event_variant) != TYPE_DICTIONARY:
			continue
		var event: Dictionary = event_variant
		var event_id := str(event.get(
			"event_id",
			"obs_%08d_event_%04d" % [int(record["observation_seq"]), index],
		))
		result.append({
			"category": _event_category(str(event.get("kind", "protocol"))),
			"event_id": event_id,
			"kind": str(event.get("kind", "protocol")),
			"payload": event.get("payload", {}).duplicate(true),
			"text": str(event.get("kind", "event")).replace("_", " ").capitalize(),
			"tick": int(event.get("tick", record["recorded_tick"])),
		})
	return result


func _public_events(rows: Array) -> Array:
	var result: Array = []
	for row_variant: Variant in rows:
		if typeof(row_variant) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = row_variant
		var sequence := int(row.get("event_seq", result.size() + 1))
		var kind := str(row.get("kind", "protocol"))
		result.append({
			"category": _event_category(kind),
			"event_id": "public_event_%08d" % sequence,
			"kind": kind,
			"payload": row.get("payload", {}).duplicate(true),
			"text": kind.replace("_", " ").capitalize(),
			"tick": int(row.get("tick", 0)),
		})
	return result


static func _append_entities(
	target: Array,
	values: Variant,
	player_slot: int,
	last_known: bool,
	default_kind: String
) -> void:
	if typeof(values) != TYPE_ARRAY:
		return
	for value_variant: Variant in values:
		if typeof(value_variant) != TYPE_DICTIONARY:
			continue
		var value: Dictionary = value_variant
		var position: Array = value.get("position_mt", [])
		if last_known and typeof(value.get("last_observed")) == TYPE_DICTIONARY:
			position = value["last_observed"].get("position_mt", [])
		var row := value.duplicate(true)
		row["id"] = str(value.get("entity_id", ""))
		row["kind"] = (
			"structure" if value.has("structure_role") else default_kind
		)
		row["last_known"] = last_known
		row["player_slot"] = player_slot
		row["position_mt"] = position.duplicate()
		target.append(row)


static func _stronghold(values: Variant) -> Dictionary:
	if typeof(values) != TYPE_ARRAY:
		return {}
	for value_variant: Variant in values:
		if typeof(value_variant) != TYPE_DICTIONARY:
			continue
		var value: Dictionary = value_variant
		if str(value.get("structure_role", "")) == "stronghold" \
			or "stronghold" in value.get("tags", []):
			return {
				"hp": int(value.get("hp", 0)),
				"max_hp": int(value.get("max_hp", 0)),
			}
	return {}


static func _player_row(label: String, observation: Dictionary, stronghold: Dictionary) -> Dictionary:
	var economy: Dictionary = observation.get("economy", {})
	var food: Dictionary = observation.get("food", {})
	var resources := {
		"food_cap": int(food.get("cap", food.get("food_cap", 0))),
		"food_used": int(food.get("used", food.get("food_used", 0))),
		"gold": int(economy.get("gold", 0)),
		"lumber": int(economy.get("lumber", 0)),
		"upkeep": str(observation.get("upkeep", {}).get("tier", "none")),
	}
	return {
		"heroes": (observation.get("heroes", []) as Array).duplicate(true),
		"label": label,
		"resources": resources,
		"stronghold": stronghold.duplicate(true),
		"tier": int(observation.get("technology", {}).get("tier", 1)),
	}


static func _event_category(kind: String) -> String:
	if "attack" in kind or "damage" in kind or "healing" in kind:
		return "combat"
	if "hero" in kind or "ability" in kind or "cast" in kind:
		return "hero"
	if "resource" in kind or "production" in kind or "construction" in kind:
		return "economy"
	if "research" in kind or "tier" in kind:
		return "tech"
	if "creep" in kind or "camp" in kind:
		return "creep"
	if "item" in kind or "shop" in kind:
		return "item"
	if "terminal" in kind:
		return "terminal"
	return "protocol"


static func _disconnect_if_connected(signal_value: Signal, callable: Callable) -> void:
	if signal_value.is_connected(callable):
		signal_value.disconnect(callable)


static func _failure(code: String, message: String) -> Dictionary:
	return {"code": code, "errors": PackedStringArray([message]), "ok": false}
