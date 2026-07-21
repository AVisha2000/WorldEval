class_name EmbodimentDuelAuthority
extends RefCounted

## Deterministic two-Operator authority for the embodiment MVP duel modes.
## This namespace is independent of the frozen worldeval-rts Duel implementation.

const CheckpointSerializer := preload(
	"res://scripts/embodiment/authority/checkpoint_serializer.gd"
)
const ArenaMap := preload("res://scripts/embodiment/authority/arena_map.gd")
const Visibility := preload("res://scripts/embodiment/authority/visibility.gd")

const PROTOCOL_VERSION := "llm-controller/0.1.0"
const MODES := ["scripted-duel-v0", "model-duel-v0"]
const PARTICIPANTS := ["participant_0", "participant_1"]
const PROFILE := "text-visible-v1"
const HYBRID_PROFILE := "hybrid-visible-v1"
const DECISION_TICKS := 10
const MAXIMUM_TICKS := 1800
const OPERATOR_MAX_HEALTH := 1000
const OPERATOR_MAX_ENERGY := 1000
const OPERATOR_SPEED_MT := 200
const OPERATOR_COLLISION_RADIUS_MT := 450
const ENERGY_RECOVERY := 25
const GUARD_COST := 40
const PRIMARY_DAMAGE := 250
const PRIMARY_RANGE_MT := 1600
const PRIMARY_COOLDOWN := 5
const DASH_DISTANCE_MT := 900
const DASH_COST := 300
const DASH_COOLDOWN := 10
const RELAY_RADIUS_MT := 1200
const RELAY_HOLD_TICKS := 100
const MAX_INTENT_UTF8_BYTES := 160
const FORWARD_BASIS := [
	Vector2i(0, -1000), Vector2i(707, -707), Vector2i(1000, 0), Vector2i(707, 707),
	Vector2i(0, 1000), Vector2i(-707, 707), Vector2i(-1000, 0), Vector2i(-707, -707),
]
const FACING_NAMES := [
	"north", "north_east", "east", "south_east",
	"south", "south_west", "west", "north_west",
]

var episode_id := ""
var mode := "model-duel-v0"
var observation_profile := PROFILE
var _managed_hybrid_enabled := false
var tick := 0
var observation_seq := 0
var event_seq := 0
var operators: Dictionary = {}
var relay_controller: Variant = null
var relay_hold_ticks := 0
var winner_id: Variant = null
var terminal := {"ended": false, "outcome": "running", "reason": "running"}
var recent_events: Array[Dictionary] = []
var previous_receipts: Dictionary = {}
## Participant-indexed presentation evidence only; excluded from checkpoint() by design.
var presentation_agency_by_participant: Dictionary = {}


func configure(config: Dictionary) -> PackedStringArray:
	_managed_hybrid_enabled = false
	return _configure(config)


func configure_managed_hybrid(config: Dictionary) -> PackedStringArray:
	_managed_hybrid_enabled = true
	return _configure(config)


func _configure(config: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if typeof(config.get("episode_id")) != TYPE_STRING or not str(config.episode_id).begins_with("ep_"):
		errors.append("episode_id_invalid")
	if typeof(config.get("mode")) != TYPE_STRING or config.mode not in MODES:
		errors.append("mode_unsupported")
	if config.get("participant_ids", []) != PARTICIPANTS:
		errors.append("participant_ids_unsupported")
	if config.get("task_id", "central-relay-v0") != "central-relay-v0":
		errors.append("task_unsupported")
	if config.get("observation_profile") != PROFILE \
		and not (_managed_hybrid_enabled and config.get("observation_profile") == HYBRID_PROFILE):
		errors.append("observation_profile_unsupported")
	if typeof(config.get("maximum_episode_ticks")) != TYPE_INT \
		or config.maximum_episode_ticks != MAXIMUM_TICKS:
		errors.append("maximum_episode_ticks_invalid")
	if not errors.is_empty():
		return errors
	episode_id = config.episode_id
	mode = config.mode
	observation_profile = str(config.observation_profile)
	reset()
	return errors


func reset() -> Dictionary:
	tick = 0
	observation_seq = 0
	event_seq = 0
	relay_controller = null
	relay_hold_ticks = 0
	winner_id = null
	terminal = {"ended": false, "outcome": "running", "reason": "running"}
	recent_events.clear()
	previous_receipts.clear()
	presentation_agency_by_participant.clear()
	operators = {
		"participant_0": _new_operator(Vector2i(0, 7000), 0),
		"participant_1": _new_operator(Vector2i(0, -7000), 4),
	}
	for participant_id: String in PARTICIPANTS:
		presentation_agency_by_participant[participant_id] = _presentation_agency(
			_neutral_control(), null, "", 0
		)
	return observe_all()


func decision_window_duration(_mode: String, _requested: Variant) -> int:
	return DECISION_TICKS


func step_window(window: Dictionary) -> Dictionary:
	var global_codes := _validate_window(window)
	var decisions: Dictionary = window.get("decisions", {}) if window.get("decisions") is Dictionary else {}
	var controls := {}
	var accepted := {}
	var action_ids := {}
	var no_input_reasons := {}
	var receipt_codes := {}
	var intent_labels := {}
	for participant_id: String in PARTICIPANTS:
		var decision: Variant = decisions.get(participant_id)
		var local_codes := PackedStringArray(global_codes)
		var action: Variant = decision.get("action") if decision is Dictionary else null
		var valid: bool = local_codes.is_empty() and _valid_decision(decision) \
			and decision.disposition == "accepted" and _valid_action(action)
		if decision is Dictionary and _valid_decision(decision) and decision.disposition == "no_input":
			valid = false
			_append_unique(local_codes, "no_input")
		elif not valid:
			_append_unique(local_codes, "decision_invalid")
		controls[participant_id] = action.control if valid else _neutral_control()
		intent_labels[participant_id] = str(action.intent_label) if valid else ""
		accepted[participant_id] = valid
		no_input_reasons[participant_id] = null if valid else (
			decision.no_input_reason
			if decision is Dictionary and _valid_decision(decision) and decision.disposition == "no_input"
			else "invalid"
		)
		action_ids[participant_id] = str(action.get("action_id", "no_input_%d" % observation_seq)) \
			if action is Dictionary else "no_input_%d" % observation_seq
		receipt_codes[participant_id] = local_codes
	var start_tick := tick
	var before := {}
	for participant_id: String in PARTICIPANTS:
		before[participant_id] = _effect_snapshot(operators[participant_id])
	var events: Array[Dictionary] = []
	var applied_ticks := 0
	for local_tick: int in DECISION_TICKS:
		if bool(terminal.ended):
			break
		_apply_joint_tick(controls, local_tick == 0, events, receipt_codes)
		tick += 1
		applied_ticks += 1
		_resolve_terminal(events)
	var receipts := {}
	for participant_id: String in PARTICIPANTS:
		var codes: Array = Array(receipt_codes[participant_id])
		if bool(accepted[participant_id]):
			codes.push_front("applied")
		elif "no_input" not in codes:
			codes.append("no_input")
		var receipt := {
			"action_id": action_ids[participant_id],
			"observation_seq": observation_seq,
			"accepted": accepted[participant_id],
			"disposition": "accepted" if accepted[participant_id] else "no_input",
			"fallback": "none" if accepted[participant_id] else "neutral",
			"no_input_reason": no_input_reasons[participant_id],
			"start_tick": start_tick,
			"end_tick": tick,
			"applied_ticks": applied_ticks,
			"codes": codes,
			"effects": _effects(before[participant_id], operators[participant_id]),
		}
		receipts[participant_id] = receipt
		previous_receipts[participant_id] = receipt.duplicate(true)
		presentation_agency_by_participant[participant_id] = _presentation_agency(
			controls[participant_id], receipt, intent_labels[participant_id], DECISION_TICKS
		)
	recent_events = events
	observation_seq += 1
	return {
		"observations": observe_all(),
		"receipts": receipts,
		"public_events": events.duplicate(true),
		"state_hash": checkpoint_hash(),
		"terminal": terminal.duplicate(true),
	}


func _apply_joint_tick(
	controls: Dictionary, first_tick: bool, events: Array[Dictionary], receipt_codes: Dictionary
) -> void:
	var proposed := {}
	for participant_id: String in PARTICIPANTS:
		var operator: Dictionary = operators[participant_id]
		var control: Dictionary = controls[participant_id]
		_tick_cooldowns(operator)
		_apply_heading(operator, int(control.look_x))
		var position: Vector2i = _walk_candidate(operator, control)
		if first_tick and bool(control.buttons.dash):
			if operator.dash_cooldown_ticks > 0:
				_append_unique(receipt_codes[participant_id], "dash_cooldown")
			elif operator.energy < DASH_COST:
				_append_unique(receipt_codes[participant_id], "dash_energy_insufficient")
			else:
				position = _dash_candidate(position, int(operator.heading))
				operator.energy -= DASH_COST
				operator.dash_cooldown_ticks = DASH_COOLDOWN
				_append_unique(receipt_codes[participant_id], "dash_applied")
		proposed[participant_id] = position
	_resolve_body_collision(proposed, receipt_codes)
	for participant_id: String in PARTICIPANTS:
		operators[participant_id].position_mt = proposed[participant_id]

	for participant_id: String in PARTICIPANTS:
		var operator: Dictionary = operators[participant_id]
		var guard := bool(controls[participant_id].buttons.guard)
		if guard and operator.energy >= GUARD_COST:
			operator.energy -= GUARD_COST
			operator.guarding = true
			_append_unique(receipt_codes[participant_id], "guard_active")
		else:
			operator.guarding = false
			if guard:
				_append_unique(receipt_codes[participant_id], "guard_energy_depleted")
		if not guard and operator.energy < OPERATOR_MAX_ENERGY:
			operator.energy = mini(OPERATOR_MAX_ENERGY, int(operator.energy) + ENERGY_RECOVERY)

	var pending_damage := {"participant_0": 0, "participant_1": 0}
	# Objective occupation is sampled from the common post-movement state before simultaneous
	# damage is committed. A relay capture and opposing knockout on this tick are therefore both
	# terminal claims and resolve as a draw.
	_update_relay(events)
	if first_tick:
		for participant_id: String in PARTICIPANTS:
			if not bool(controls[participant_id].buttons.primary):
				continue
			var operator: Dictionary = operators[participant_id]
			var rival_id := _rival(participant_id)
			if operator.primary_cooldown_ticks > 0:
				_append_unique(receipt_codes[participant_id], "primary_cooldown")
				continue
			operator.primary_cooldown_ticks = PRIMARY_COOLDOWN
			if _can_hit(operator, operators[rival_id]):
				pending_damage[rival_id] += PRIMARY_DAMAGE
				_append_unique(receipt_codes[participant_id], "primary_hit")
				events.append(_event("primary_hit", [participant_id, rival_id], {
					"attacker": participant_id, "target": rival_id, "damage": PRIMARY_DAMAGE,
				}))
			else:
				_append_unique(receipt_codes[participant_id], "primary_missed")
				events.append(_event("primary_missed", [participant_id], {"attacker": participant_id}))
	for participant_id: String in PARTICIPANTS:
		var damage: int = pending_damage[participant_id]
		if damage <= 0:
			continue
		var operator: Dictionary = operators[participant_id]
		if bool(operator.guarding) and _can_guard(operator, operators[_rival(participant_id)]):
			damage = ArenaMap.divide_toward_zero(damage, 2)
			_append_unique(receipt_codes[participant_id], "guard_reduced_damage")
		operator.health = maxi(0, int(operator.health) - damage)
		_append_unique(receipt_codes[participant_id], "damage_taken")
		events.append(_event("operator_damaged", [participant_id], {
			"participant_id": participant_id, "damage": damage,
		}))


func _update_relay(events: Array[Dictionary]) -> void:
	var occupants: Array[String] = []
	for participant_id: String in PARTICIPANTS:
		var operator: Dictionary = operators[participant_id]
		if operator.health > 0 and _within(operator.position_mt, Vector2i.ZERO, RELAY_RADIUS_MT):
			occupants.append(participant_id)
	if occupants.size() != 1:
		if relay_controller != null or relay_hold_ticks != 0:
			events.append(_event("relay_hold_reset", PARTICIPANTS, {}))
		relay_controller = null
		relay_hold_ticks = 0
		return
	var participant_id := occupants[0]
	if relay_controller != participant_id:
		relay_controller = participant_id
		relay_hold_ticks = 0
		events.append(_event("relay_control_changed", PARTICIPANTS, {"controller": participant_id}))
	relay_hold_ticks += 1
	if relay_hold_ticks == RELAY_HOLD_TICKS:
		events.append(_event("relay_captured", PARTICIPANTS, {"controller": participant_id}))


func _resolve_terminal(events: Array[Dictionary]) -> void:
	var claims: Array[String] = []
	var zero_0 := int(operators.participant_0.health) == 0
	var zero_1 := int(operators.participant_1.health) == 0
	if zero_0 and zero_1:
		claims.assign(PARTICIPANTS)
	elif zero_0:
		claims.append("participant_1")
	elif zero_1:
		claims.append("participant_0")
	if relay_hold_ticks >= RELAY_HOLD_TICKS and relay_controller not in claims:
		claims.append(relay_controller)
	if claims.size() == 1:
		winner_id = claims[0]
		terminal = {
			"ended": true, "outcome": "win",
			"reason": "relay_hold" if relay_hold_ticks >= RELAY_HOLD_TICKS else "knockout",
		}
		events.append(_event("episode_won", PARTICIPANTS, {
			"winner": claims[0], "reason": terminal.reason,
		}))
	elif claims.size() > 1:
		winner_id = null
		terminal = {"ended": true, "outcome": "draw", "reason": "simultaneous_terminal"}
		events.append(_event("episode_drawn", PARTICIPANTS, {"reason": terminal.reason}))
	elif tick >= MAXIMUM_TICKS:
		winner_id = null
		terminal = {"ended": true, "outcome": "draw", "reason": "time_limit"}
		events.append(_event("episode_drawn", PARTICIPANTS, {"reason": "time_limit"}))


func observe_all() -> Dictionary:
	return {
		"participant_0": observe("participant_0"),
		"participant_1": observe("participant_1"),
	}


func observe(participant_id: String) -> Dictionary:
	var operator: Dictionary = operators[participant_id]
	var rival_id := _rival(participant_id)
	var rival: Dictionary = operators[rival_id]
	var entities: Array[Dictionary] = []
	if _camera_visible(operator, rival.position_mt):
		entities.append(_project_entity(operator, "v_rival", "operator", rival.position_mt,
			["hostile"], _health_band(int(rival.health))))
	if _camera_visible(operator, Vector2i.ZERO):
		entities.append(_project_entity(operator, "v_relay", "relay", Vector2i.ZERO,
			["capture"], _relay_band(participant_id)))
	return {
		"protocol_version": PROTOCOL_VERSION,
		"episode_id": episode_id,
		"observation_seq": observation_seq,
		"tick": tick,
		"profile": observation_profile,
		"goal": "Hold the central relay uncontested or knock out the rival Operator.",
		"remaining_ticks": maxi(MAXIMUM_TICKS - tick, 0),
		"self": {
			"health_percent": ArenaMap.divide_toward_zero(int(operator.health) * 100, OPERATOR_MAX_HEALTH),
			"energy_percent": ArenaMap.divide_toward_zero(int(operator.energy) * 100, OPERATOR_MAX_ENERGY),
			"facing": FACING_NAMES[int(operator.heading)],
			"contact": operator.contact,
			"inventory": [],
			"status": ["guarding"] if operator.guarding else [],
		},
		"visible_entities": entities,
		"recent_events": _events_for(participant_id),
		"previous_receipt": previous_receipts.get(participant_id),
		"memory": str(operator.memory),
		"terminal": _participant_terminal(participant_id),
	}


func checkpoint() -> Dictionary:
	var operator_values := {}
	for participant_id: String in PARTICIPANTS:
		var operator: Dictionary = operators[participant_id]
		operator_values[participant_id] = {
			"position_mt": [operator.position_mt.x, operator.position_mt.y],
			"heading": operator.heading, "look_accumulator": operator.look_accumulator,
			"health": operator.health, "energy": operator.energy, "guarding": operator.guarding,
			"primary_cooldown_ticks": operator.primary_cooldown_ticks,
			"dash_cooldown_ticks": operator.dash_cooldown_ticks,
			"contact": operator.contact,
		}
	return {
		"episode_id": episode_id, "mode": mode, "tick": tick,
		"observation_seq": observation_seq, "event_seq": event_seq,
		"operators": operator_values, "relay_controller": relay_controller,
		"relay_hold_ticks": relay_hold_ticks, "winner_id": winner_id,
		"terminal": terminal.duplicate(true),
	}


func checkpoint_hash() -> String:
	return CheckpointSerializer.hash_checkpoint(checkpoint())


func capability_status() -> Dictionary:
	return {
		"implemented_modes": MODES.duplicate(),
		"implemented_observation_profiles": (
			[PROFILE, HYBRID_PROFILE] if _managed_hybrid_enabled else [PROFILE]
		),
		"implemented_tasks": ["central-relay-v0"],
		"certified_modes": [],
		"certified_observation_profiles": [],
		"scored_observation_profiles": [],
	}


func presentation_source_snapshot_for(participant_id: String) -> Dictionary:
	var observation: Dictionary = observe(participant_id)
	var rival_id := _rival(participant_id)
	var operator: Dictionary = operators[participant_id]
	var rival: Dictionary = operators[rival_id]
	var self_id := "operator_%s" % participant_id
	var entities: Array[Dictionary] = [
		_presentation_entity(
			self_id, "operator", operator.position_mt, int(operator.heading),
			int(observation.self.health_percent), int(observation.self.energy_percent),
			observation.self.status, "guard" if operator.guarding else "idle", {
				"bearing": "front", "distance": "touching", "affordances": [],
				"state": "active",
			}
		),
	]
	for semantic: Dictionary in observation.visible_entities:
		if semantic.id == "v_rival":
			entities.append(_presentation_entity(
				"v_rival", "operator", rival.position_mt, int(rival.heading),
				0 if int(rival.health) == 0 else 100, 100, [],
				"guard" if rival.guarding else "idle", semantic
			))
		elif semantic.id == "v_relay":
			entities.append(_presentation_entity(
				"v_relay", "relay", Vector2i.ZERO, 0, 100, 0, [], "idle", semantic
			))
	return {
		"schema_version": "llm-controller/presentation-input/1.0.0",
		"protocol_version": PROTOCOL_VERSION,
		"episode_id": episode_id,
		"task_id": "central-relay-v0",
		"observation_seq": observation_seq,
		"tick": tick,
		"remaining_ticks": maxi(MAXIMUM_TICKS - tick, 0),
		"goal": observation.goal,
		"authority_checkpoint_hash": checkpoint_hash(),
		"self_entity_id": self_id,
		"entities": entities,
		"agency": presentation_agency_by_participant[participant_id].duplicate(true),
		"terminal": terminal.duplicate(true),
	}


func _presentation_agency(
	control: Dictionary, receipt: Variant, intent_label: String, duration_ticks: int
) -> Dictionary:
	var projected_receipt: Variant = null
	if receipt is Dictionary:
		projected_receipt = {
			"disposition": str(receipt.disposition),
			"accepted": bool(receipt.accepted),
			"fallback": str(receipt.fallback),
			"applied_ticks": int(receipt.applied_ticks),
			"codes": receipt.codes.duplicate(),
		}
	var source_buttons: Dictionary = control.get("buttons", {}) \
		if control.get("buttons", {}) is Dictionary else {}
	var buttons := {}
	for button: String in [
		"interact", "primary", "guard", "dash", "ability_1", "ability_2", "cycle_item", "cancel",
	]:
		buttons[button] = bool(source_buttons.get(button, false))
	return {
		"controller": {
			"move_x": int(control.get("move_x", 0)),
			"move_y": int(control.get("move_y", 0)),
			"look_x": int(control.get("look_x", 0)),
			"look_y": int(control.get("look_y", 0)),
			"duration_ticks": duration_ticks,
			"buttons": buttons,
		},
		"receipt": projected_receipt,
		"intent_label": intent_label,
	}


func presentation_visible_entity_ids_for(participant_id: String) -> Array[String]:
	assert(participant_id in PARTICIPANTS)
	var ids: Array[String] = []
	for entity: Dictionary in observe(participant_id).visible_entities:
		ids.append(str(entity.id))
	return ids


func _presentation_entity(
	id: String, kind: String, position: Vector2i, heading: int,
	health_percent: int, energy_percent: int, status: Array, animation: String,
	semantic_source: Dictionary,
) -> Dictionary:
	return {
		"id": id,
		"kind": kind,
		"position_mt": [position.x, position.y],
		"heading_sector": heading,
		"animation": animation,
		"animation_progress_milli": 0,
		"health_percent": health_percent,
		"energy_percent": energy_percent,
		"status": status.duplicate(),
		"semantic": {
			"bearing": semantic_source.bearing,
			"distance": semantic_source.distance,
			"affordances": semantic_source.affordances.duplicate(),
			"state": semantic_source.state,
		},
	}


func _health_band(value: int) -> String:
	if value <= 0:
		return "knocked_out"
	if value * 4 <= OPERATOR_MAX_HEALTH:
		return "critical"
	if value * 4 <= OPERATOR_MAX_HEALTH * 3:
		return "wounded"
	return "ready"


func _relay_band(participant_id: String) -> String:
	if relay_controller == null or relay_hold_ticks <= 0:
		return "uncontrolled"
	var relation := "self" if relay_controller == participant_id else "rival"
	var progress := "started"
	if relay_hold_ticks * 4 >= RELAY_HOLD_TICKS * 3:
		progress = "near_complete"
	elif relay_hold_ticks * 2 >= RELAY_HOLD_TICKS:
		progress = "building"
	return "%s_%s" % [relation, progress]


func _new_operator(position: Vector2i, heading: int) -> Dictionary:
	return {
		"position_mt": position, "heading": heading, "look_accumulator": 0,
		"health": OPERATOR_MAX_HEALTH, "energy": OPERATOR_MAX_ENERGY, "guarding": false,
		"primary_cooldown_ticks": 0, "dash_cooldown_ticks": 0,
		"contact": "clear", "memory": "",
	}


func _validate_window(window: Dictionary) -> PackedStringArray:
	var codes := PackedStringArray()
	if window.get("episode_id") != episode_id:
		codes.append("episode_id_mismatch")
	if window.get("mode") != mode:
		codes.append("mode_mismatch")
	if typeof(window.get("observation_seq")) != TYPE_INT or window.observation_seq != observation_seq:
		codes.append("observation_seq_mismatch")
	if typeof(window.get("start_tick")) != TYPE_INT or window.start_tick != tick:
		codes.append("start_tick_mismatch")
	if typeof(window.get("duration_ticks")) != TYPE_INT or window.duration_ticks != DECISION_TICKS:
		codes.append("duration_ticks_invalid")
	if not window.get("decisions") is Dictionary or set_keys(window.decisions) != PARTICIPANTS:
		codes.append("participant_decisions_invalid")
	return codes


func _valid_decision(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	if value.get("disposition") == "accepted":
		return value.get("action") is Dictionary and value.get("fallback") == "none" \
			and value.get("no_input_reason") == null
	return value.get("disposition") == "no_input" and value.get("action") == null \
		and value.get("fallback") == "neutral" \
		and value.get("no_input_reason") in ["missing", "invalid", "timeout", "stale_observation"]


func _valid_action(value: Variant) -> bool:
	if not value is Dictionary or value.get("protocol_version") != PROTOCOL_VERSION \
		or value.get("episode_id") != episode_id \
		or typeof(value.get("observation_seq")) != TYPE_INT \
		or value.observation_seq != observation_seq or not value.get("control") is Dictionary:
		return false
	var control: Dictionary = value.control
	if typeof(control.get("duration_ticks")) != TYPE_INT or control.duration_ticks != DECISION_TICKS \
		or not control.get("buttons") is Dictionary:
		return false
	for axis: String in ["move_x", "move_y", "look_x", "look_y"]:
		if typeof(control.get(axis)) != TYPE_INT or control[axis] < -1000 or control[axis] > 1000:
			return false
	for button: String in ["interact", "primary", "guard", "dash", "ability_1", "ability_2", "cycle_item", "cancel"]:
		if typeof(control.buttons.get(button)) != TYPE_BOOL:
			return false
	return typeof(value.get("action_id")) == TYPE_STRING \
		and typeof(value.get("intent_label")) == TYPE_STRING \
		and value.intent_label.to_utf8_buffer().size() <= MAX_INTENT_UTF8_BYTES \
		and typeof(value.get("memory_update")) == TYPE_STRING \
		and value.memory_update.to_utf8_buffer().size() <= 2048


func _neutral_control() -> Dictionary:
	return {"move_x": 0, "move_y": 0, "look_x": 0, "look_y": 0,
		"duration_ticks": DECISION_TICKS, "buttons": {
			"interact": false, "primary": false, "guard": false, "dash": false,
			"ability_1": false, "ability_2": false, "cycle_item": false, "cancel": false,
		}}


func _apply_heading(operator: Dictionary, look_x: int) -> void:
	operator.look_accumulator += look_x
	while operator.look_accumulator >= 1000:
		operator.heading = posmod(int(operator.heading) + 1, 8)
		operator.look_accumulator -= 1000
	while operator.look_accumulator <= -1000:
		operator.heading = posmod(int(operator.heading) - 1, 8)
		operator.look_accumulator += 1000


func _walk_candidate(operator: Dictionary, control: Dictionary) -> Vector2i:
	var forward: Vector2i = FORWARD_BASIS[int(operator.heading)]
	var right: Vector2i = FORWARD_BASIS[posmod(int(operator.heading) + 2, 8)]
	var raw_x := ArenaMap.divide_toward_zero(right.x * int(control.move_x) + forward.x * int(control.move_y), 1000)
	var raw_y := ArenaMap.divide_toward_zero(right.y * int(control.move_x) + forward.y * int(control.move_y), 1000)
	var greatest := maxi(abs(raw_x), abs(raw_y))
	if greatest > 1000:
		raw_x = ArenaMap.divide_toward_zero(raw_x * 1000, greatest)
		raw_y = ArenaMap.divide_toward_zero(raw_y * 1000, greatest)
	var candidate := Vector2i(operator.position_mt) + Vector2i(
		ArenaMap.divide_toward_zero(raw_x * OPERATOR_SPEED_MT, 1000),
		ArenaMap.divide_toward_zero(raw_y * OPERATOR_SPEED_MT, 1000))
	var clamped := _clamp(candidate)
	operator.contact = "clear" if candidate == clamped else "blocked_front"
	return clamped


func _dash_candidate(position: Vector2i, heading: int) -> Vector2i:
	var forward: Vector2i = FORWARD_BASIS[heading]
	return _clamp(position + Vector2i(
		ArenaMap.divide_toward_zero(forward.x * DASH_DISTANCE_MT, 1000),
		ArenaMap.divide_toward_zero(forward.y * DASH_DISTANCE_MT, 1000)))


func _clamp(value: Vector2i) -> Vector2i:
	return Vector2i(clampi(value.x, -ArenaMap.ARENA_HALF_EXTENT_MT, ArenaMap.ARENA_HALF_EXTENT_MT),
		clampi(value.y, -ArenaMap.ARENA_HALF_EXTENT_MT, ArenaMap.ARENA_HALF_EXTENT_MT))


func _resolve_body_collision(proposed: Dictionary, receipt_codes: Dictionary) -> void:
	if not _within(proposed.participant_0, proposed.participant_1, OPERATOR_COLLISION_RADIUS_MT * 2):
		return
	for participant_id: String in PARTICIPANTS:
		proposed[participant_id] = operators[participant_id].position_mt
		operators[participant_id].contact = "blocked_front"
		_append_unique(receipt_codes[participant_id], "movement_blocked")


func _tick_cooldowns(operator: Dictionary) -> void:
	if operator.primary_cooldown_ticks > 0:
		operator.primary_cooldown_ticks -= 1
	if operator.dash_cooldown_ticks > 0:
		operator.dash_cooldown_ticks -= 1
	operator.contact = "clear"


func _can_hit(attacker: Dictionary, target: Dictionary) -> bool:
	if int(target.health) <= 0 or not _within(attacker.position_mt, target.position_mt, PRIMARY_RANGE_MT):
		return false
	var offset: Vector2i = target.position_mt - attacker.position_mt
	var forward: Vector2i = FORWARD_BASIS[int(attacker.heading)]
	var dot := forward.x * offset.x + forward.y * offset.y
	var cross := forward.x * offset.y - forward.y * offset.x
	return dot > 0 and abs(cross) <= dot


func _can_guard(defender: Dictionary, attacker: Dictionary) -> bool:
	var offset: Vector2i = attacker.position_mt - defender.position_mt
	var forward: Vector2i = FORWARD_BASIS[int(defender.heading)]
	return forward.x * offset.x + forward.y * offset.y > 0


func _within(first: Vector2i, second: Vector2i, radius: int) -> bool:
	var offset := second - first
	return offset.x * offset.x + offset.y * offset.y <= radius * radius


func _project_entity(
	observer: Dictionary, id: String, kind: String, position: Vector2i,
	affordances: Array, state: String
) -> Dictionary:
	var offset: Vector2i = position - observer.position_mt
	return {"id": id, "kind": kind,
		"bearing": Visibility.relative_bearing(offset, int(observer.heading)),
		"distance": Visibility.distance_band(offset, RELAY_RADIUS_MT),
		"affordances": affordances, "state": state}


func _camera_visible(observer: Dictionary, position: Vector2i) -> bool:
	# The participant camera has a 62-degree horizontal field of view. The integer semantic
	# projector uses eight 45-degree sectors, so only the front sector is unambiguously inside the
	# same camera frustum. The arena currently has no opaque authority geometry to occlude it.
	var offset: Vector2i = position - Vector2i(observer.position_mt)
	return offset != Vector2i.ZERO \
		and Visibility.relative_bearing(offset, int(observer.heading)) == "front"


func _participant_terminal(_participant_id: String) -> Dictionary:
	# The shared terminal boundary must be byte-identical in both observations and the joint result
	# for replay verification. Winner identity is authority state and is published by episode_won.
	return terminal.duplicate(true)


func _events_for(participant_id: String) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for event: Dictionary in recent_events:
		if participant_id in event.participant_ids:
			output.append(event.duplicate(true))
	return output


func _event(kind: String, participant_ids: Array, data: Dictionary) -> Dictionary:
	var value := {"event_id": "evt_%d_%d" % [tick, event_seq], "tick": tick,
		"kind": kind, "summary": kind.replace("_", " ").capitalize() + ".",
		"participant_ids": participant_ids.duplicate(), "data": data.duplicate(true)}
	event_seq += 1
	return value


func _effect_snapshot(operator: Dictionary) -> Dictionary:
	return {"health": operator.health, "energy": operator.energy,
		"position_x": operator.position_mt.x, "position_y": operator.position_mt.y}


func _effects(before: Dictionary, operator: Dictionary) -> Array[Dictionary]:
	return [
		{"kind": "health_delta", "value": int(operator.health) - int(before.health)},
		{"kind": "energy_delta", "value": int(operator.energy) - int(before.energy)},
		{"kind": "movement_x_mt", "value": int(operator.position_mt.x) - int(before.position_x)},
		{"kind": "movement_y_mt", "value": int(operator.position_mt.y) - int(before.position_y)},
	]


func _rival(participant_id: String) -> String:
	return "participant_1" if participant_id == "participant_0" else "participant_0"


func _append_unique(values: Variant, value: String) -> void:
	if value not in values:
		values.append(value)


func set_keys(value: Dictionary) -> Array:
	var keys: Array = value.keys()
	keys.sort()
	return keys
