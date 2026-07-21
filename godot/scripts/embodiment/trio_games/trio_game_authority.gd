class_name EmbodimentTrioGameAuthority
extends RefCounted

## Deterministic, exactly-three-participant authority shared by the trio games.
##
## World positions are integer axial coordinates.  The order-three transform
## R(q, r) = (-q-r, q) is exact, so spawn/seat symmetry never depends on a
## floating-point rotation or rounding policy.  Every joint tick is proposed in
## immutable participant order and committed simultaneously.

const CheckpointSerializer := preload(
	"res://scripts/embodiment/authority/checkpoint_serializer.gd"
)

const PROTOCOL_VERSION := "llm-controller/0.3.0"
const PARTICIPANTS := ["participant_0", "participant_1", "participant_2"]
const DECISION_TICKS := 10
const MAXIMUM_TICKS := 1200
const ARENA_RADIUS_MT := 8000
const SPEED_MT := 200
const MAX_HEALTH := 1000
const MAX_ENERGY := 1000
const ENERGY_RECOVERY := 25
const DASH_DISTANCE_MT := 900
const DASH_COST := 300
const DASH_COOLDOWN_TICKS := 20
const PRIMARY_RANGE_MT := 1700
const PRIMARY_DAMAGE := 250
const PRIMARY_COOLDOWN_TICKS := 20
const GUARD_COST := 40
const RELAY_RADIUS_MT := 1000
const RELAY_HOLD_TARGET := 60
const VISIBILITY_RANGE_MT := 8000
const MAX_INTENT_UTF8_BYTES := 160
const BUTTONS := [
	"interact", "primary", "guard", "dash", "ability_1", "ability_2", "cycle_item", "cancel",
]
const AXIAL_DIRECTIONS := [
	Vector2i(0, -1000), Vector2i(1000, -1000), Vector2i(1000, 0),
	Vector2i(0, 1000), Vector2i(-1000, 1000), Vector2i(-1000, 0),
]
const FACING_NAMES := ["north", "north_east", "south_east", "south", "south_west", "north_west"]
const SPAWN_ORBIT := [Vector2i(0, -6000), Vector2i(6000, 0), Vector2i(-6000, 6000)]

var task_id := ""
var episode_id := ""
var seat_rotation := 0
var tick := 0
var observation_seq := 0
var event_seq := 0
var operators: Dictionary = {}
var previous_receipts: Dictionary = {}
var recent_events: Array[Dictionary] = []
var replay_windows: Array[Dictionary] = []
var terminal := {"ended": false, "outcome": "running", "reason": "in_progress"}
var winner_id: Variant = null
var placements: Array[Dictionary] = []
var relay_controller: Variant = null
var relay_hold_ticks := 0
var relay_total_ticks := {"participant_0": 0, "participant_1": 0, "participant_2": 0}
var invalid_windows := {"participant_0": 0, "participant_1": 0, "participant_2": 0}


func expected_task_id() -> String:
	return ""


func combat_enabled() -> bool:
	return false


func configure(config: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	var expected := expected_task_id()
	if expected not in ["trio-relay-v0", "trio-free-for-all-v0"]:
		errors.append("authority_task_invalid")
	if config.get("protocol_version") != PROTOCOL_VERSION:
		errors.append("protocol_version_invalid")
	if config.get("task_id") != expected:
		errors.append("task_id_invalid")
	if not config.get("episode_id") is String or not str(config.episode_id).begins_with("ep_"):
		errors.append("episode_id_invalid")
	if config.get("participant_ids") != PARTICIPANTS:
		errors.append("participant_ids_invalid")
	if not config.get("maximum_episode_ticks") is int \
		or config.get("maximum_episode_ticks") != MAXIMUM_TICKS:
		errors.append("maximum_episode_ticks_invalid")
	if not config.get("seat_rotation") is int or int(config.get("seat_rotation", -1)) not in [0, 1, 2]:
		errors.append("seat_rotation_invalid")
	if not errors.is_empty():
		return errors
	task_id = expected
	episode_id = str(config.episode_id)
	seat_rotation = int(config.seat_rotation)
	reset()
	return errors


func reset() -> Dictionary:
	tick = 0
	observation_seq = 0
	event_seq = 0
	previous_receipts = {}
	recent_events = []
	replay_windows = []
	terminal = {"ended": false, "outcome": "running", "reason": "in_progress"}
	winner_id = null
	placements = []
	relay_controller = null
	relay_hold_ticks = 0
	relay_total_ticks = {"participant_0": 0, "participant_1": 0, "participant_2": 0}
	invalid_windows = {"participant_0": 0, "participant_1": 0, "participant_2": 0}
	operators = {}
	for index: int in PARTICIPANTS.size():
		var participant_id: String = PARTICIPANTS[index]
		var spawn_index := posmod(index + seat_rotation, 3)
		# Every spawn faces the relay.  Headings form the same exact order-three orbit.
		operators[participant_id] = _new_operator(SPAWN_ORBIT[spawn_index], posmod(3 + spawn_index * 2, 6))
	return observe_all()


func decision_window_duration(_requested: Variant = null) -> int:
	return DECISION_TICKS


func step_window(window: Variant) -> Dictionary:
	assert(not episode_id.is_empty(), "configure before stepping")
	if terminal.ended:
		return _result({}, [])
	var global_codes := _validate_window(window)
	var decisions: Dictionary = window.get("decisions", {}) if window is Dictionary \
		and window.get("decisions") is Dictionary else {}
	var controls := {}
	var accepted := {}
	var action_ids := {}
	var reasons := {}
	var dispositions := {}
	var receipt_codes := {}
	var replay_decisions := {}
	for participant_id: String in PARTICIPANTS:
		var local_codes := PackedStringArray(global_codes)
		if not _is_active(participant_id):
			controls[participant_id] = _neutral_control()
			accepted[participant_id] = false
			action_ids[participant_id] = "eliminated_%d_%s" % [observation_seq, participant_id]
			reasons[participant_id] = "eliminated"
			dispositions[participant_id] = "eliminated"
			local_codes.append("eliminated")
			receipt_codes[participant_id] = local_codes
			replay_decisions[participant_id] = {
				"disposition": "eliminated", "action": null,
				"fallback": "neutral", "no_input_reason": "eliminated",
			}
			continue
		var decision: Variant = decisions.get(participant_id)
		var action: Variant = decision.get("action") if decision is Dictionary else null
		var valid := local_codes.is_empty() and _valid_accepted_decision(decision) \
			and _valid_action(action)
		if valid:
			controls[participant_id] = action.control.duplicate(true)
			accepted[participant_id] = true
			action_ids[participant_id] = str(action.action_id)
			reasons[participant_id] = null
			dispositions[participant_id] = "accepted"
			operators[participant_id].memory = str(action.memory_update)
			replay_decisions[participant_id] = decision.duplicate(true)
		else:
			invalid_windows[participant_id] = int(invalid_windows[participant_id]) + 1
			controls[participant_id] = _neutral_control()
			accepted[participant_id] = false
			action_ids[participant_id] = "no_input_%d_%s" % [observation_seq, participant_id]
			reasons[participant_id] = _no_input_reason(decision)
			dispositions[participant_id] = "no_input"
			_append_unique(local_codes, "no_input")
			replay_decisions[participant_id] = {
				"disposition": "no_input", "action": null,
				"fallback": "neutral", "no_input_reason": reasons[participant_id],
			}
		receipt_codes[participant_id] = local_codes
	var start_tick := tick
	var before := {}
	for participant_id: String in PARTICIPANTS:
		before[participant_id] = _effect_snapshot(operators[participant_id])
	var window_events: Array[Dictionary] = []
	var applied_ticks := 0
	for local_tick: int in DECISION_TICKS:
		if terminal.ended:
			break
		_apply_joint_tick(controls, local_tick == 0, receipt_codes, window_events)
		tick += 1
		applied_ticks += 1
		_resolve_terminal(window_events)
	var receipts := {}
	for participant_id: String in PARTICIPANTS:
		var codes: Array = Array(receipt_codes[participant_id])
		codes.push_front("applied" if accepted[participant_id] else "neutral_applied")
		var disposition: String = dispositions[participant_id]
		var receipt := {
			"action_id": action_ids[participant_id], "observation_seq": observation_seq,
			"accepted": accepted[participant_id], "disposition": disposition,
			"fallback": "none" if accepted[participant_id] else "neutral",
			"no_input_reason": reasons[participant_id], "start_tick": start_tick,
			"end_tick": tick, "applied_ticks": applied_ticks, "codes": codes,
			"effects": _effects(before[participant_id], operators[participant_id]),
		}
		receipts[participant_id] = receipt
		previous_receipts[participant_id] = receipt.duplicate(true)
	recent_events = window_events.duplicate(true)
	observation_seq += 1
	var replay_window := {
		"start_tick": start_tick, "end_tick": tick,
		"decisions": replay_decisions, "receipts": receipts.duplicate(true),
		"events": window_events.duplicate(true), "checkpoint_hash": checkpoint_hash(),
	}
	replay_windows.append(replay_window)
	return _result(receipts, window_events)


func _apply_joint_tick(
	controls: Dictionary, first_tick: bool, receipt_codes: Dictionary,
	window_events: Array[Dictionary],
) -> void:
	var proposed := {}
	for participant_id: String in PARTICIPANTS:
		var operator: Dictionary = operators[participant_id]
		if not _is_active(participant_id):
			proposed[participant_id] = operator.position_axial
			continue
		_tick_cooldowns(operator)
		var control: Dictionary = controls[participant_id]
		_apply_heading(operator, int(control.look_x))
		var candidate := _walk_candidate(operator, control)
		if first_tick and not combat_enabled():
			if bool(control.buttons.primary):
				_append_unique(receipt_codes[participant_id], "primary_disabled")
			if bool(control.buttons.guard):
				_append_unique(receipt_codes[participant_id], "guard_disabled")
		if first_tick and bool(control.buttons.dash):
			if not combat_enabled():
				_append_unique(receipt_codes[participant_id], "dash_disabled")
			elif operator.dash_cooldown_ticks > 0:
				_append_unique(receipt_codes[participant_id], "dash_cooldown")
			elif operator.energy < DASH_COST:
				_append_unique(receipt_codes[participant_id], "dash_energy_insufficient")
			else:
				var pre_dash: Vector2i = candidate
				candidate = _dash_candidate(candidate, int(operator.heading))
				operator.distance_travelled_mt += _axial_distance(pre_dash, candidate)
				operator.energy -= DASH_COST
				operator.dash_cooldown_ticks = DASH_COOLDOWN_TICKS
				_append_unique(receipt_codes[participant_id], "dash_applied")
		proposed[participant_id] = candidate
	for participant_id: String in PARTICIPANTS:
		operators[participant_id].position_axial = proposed[participant_id]
	_update_relay(window_events)
	if combat_enabled():
		_update_combat(controls, first_tick, receipt_codes, window_events)


func _update_relay(window_events: Array[Dictionary]) -> void:
	var occupants: Array[String] = []
	for participant_id: String in PARTICIPANTS:
		if _is_active(participant_id) and _axial_norm(operators[participant_id].position_axial) <= RELAY_RADIUS_MT:
			occupants.append(participant_id)
	if occupants.size() != 1:
		if relay_controller != null or relay_hold_ticks != 0:
			window_events.append(_event("relay_contested", PARTICIPANTS, {}))
		relay_controller = null
		relay_hold_ticks = 0
		return
	var controller: String = occupants[0]
	if relay_controller != controller:
		relay_controller = controller
		relay_hold_ticks = 0
		window_events.append(_event("relay_control_changed", PARTICIPANTS, {"controller": controller}))
	relay_hold_ticks += 1
	relay_total_ticks[controller] = int(relay_total_ticks[controller]) + 1
	if relay_hold_ticks == RELAY_HOLD_TARGET:
		window_events.append(_event("relay_secured", PARTICIPANTS, {"controller": controller}))


func _update_combat(
	controls: Dictionary, first_tick: bool, receipt_codes: Dictionary,
	window_events: Array[Dictionary],
) -> void:
	for participant_id: String in PARTICIPANTS:
		if not _is_active(participant_id):
			continue
		var operator: Dictionary = operators[participant_id]
		if bool(controls[participant_id].buttons.guard) and operator.energy >= GUARD_COST:
			operator.guarding = true
			operator.energy -= GUARD_COST
			_append_unique(receipt_codes[participant_id], "guard_active")
		else:
			operator.guarding = false
			if bool(controls[participant_id].buttons.guard):
				_append_unique(receipt_codes[participant_id], "guard_energy_depleted")
			operator.energy = mini(MAX_ENERGY, int(operator.energy) + ENERGY_RECOVERY)
	if not first_tick:
		return
	var pending_damage := {"participant_0": 0, "participant_1": 0, "participant_2": 0}
	var attackers_by_target := {"participant_0": [], "participant_1": [], "participant_2": []}
	for attacker_id: String in PARTICIPANTS:
		if not _is_active(attacker_id) or not bool(controls[attacker_id].buttons.primary):
			continue
		var attacker: Dictionary = operators[attacker_id]
		if attacker.primary_cooldown_ticks > 0:
			_append_unique(receipt_codes[attacker_id], "primary_cooldown")
			continue
		attacker.primary_cooldown_ticks = PRIMARY_COOLDOWN_TICKS
		var target_id := _select_target(attacker_id)
		if target_id.is_empty():
			_append_unique(receipt_codes[attacker_id], "primary_missed")
			window_events.append(_event("primary_missed", [attacker_id], {"attacker": attacker_id}))
			continue
		pending_damage[target_id] = int(pending_damage[target_id]) + PRIMARY_DAMAGE
		attackers_by_target[target_id].append(attacker_id)
		_append_unique(receipt_codes[attacker_id], "primary_hit")
		window_events.append(_event("primary_hit", [attacker_id, target_id], {
			"attacker": attacker_id, "target": target_id, "damage": PRIMARY_DAMAGE,
		}))
	for target_id: String in PARTICIPANTS:
		var damage := int(pending_damage[target_id])
		if damage == 0 or not _is_active(target_id):
			continue
		var defender: Dictionary = operators[target_id]
		if defender.guarding and _guard_blocks_any(defender, attackers_by_target[target_id]):
			damage = _divide_toward_zero(damage, 2)
			_append_unique(receipt_codes[target_id], "guard_reduced_damage")
		defender.health = maxi(0, int(defender.health) - damage)
		defender.damage_taken += damage
		_append_unique(receipt_codes[target_id], "damage_taken")
		window_events.append(_event("operator_damaged", [target_id], {
			"participant_id": target_id, "damage": damage,
		}))
	for participant_id: String in PARTICIPANTS:
		var operator: Dictionary = operators[participant_id]
		if operator.health == 0 and operator.eliminated_tick == null:
			operator.eliminated_tick = tick + 1
			operator.guarding = false
			window_events.append(_event("operator_eliminated", PARTICIPANTS, {
				"participant_id": participant_id,
			}))


func _resolve_terminal(window_events: Array[Dictionary]) -> void:
	var active := _active_participants()
	# Priority is explicit and deterministic: last-standing/simultaneous knockout,
	# then relay objective, then time limit.
	if combat_enabled() and active.size() <= 1:
		if active.size() == 1:
			_finish_with_winner(active[0], "last_standing", window_events)
		else:
			_finish_draw("simultaneous_knockout", window_events)
		return
	if relay_hold_ticks >= RELAY_HOLD_TARGET and relay_controller != null:
		_finish_with_winner(str(relay_controller), "relay_hold", window_events)
		return
	if tick >= MAXIMUM_TICKS:
		_finish_time_limit(window_events)


func _finish_with_winner(participant_id: String, reason: String, window_events: Array[Dictionary]) -> void:
	winner_id = participant_id
	terminal = {"ended": true, "outcome": "win", "reason": reason}
	placements = _winner_placements(participant_id, reason)
	window_events.append(_event("episode_won", PARTICIPANTS, {
		"winner": participant_id, "reason": reason, "placements": placements.duplicate(true),
	}))


func _finish_draw(reason: String, window_events: Array[Dictionary]) -> void:
	winner_id = null
	terminal = {"ended": true, "outcome": "draw", "reason": reason}
	placements = [{"place": 1, "participant_ids": PARTICIPANTS.duplicate(), "tie": true, "basis": reason}]
	window_events.append(_event("episode_drawn", PARTICIPANTS, {
		"reason": reason, "placements": placements.duplicate(true),
	}))


func _finish_time_limit(window_events: Array[Dictionary]) -> void:
	placements = _rank_time_limit()
	var leaders: Array = placements[0].participant_ids
	if leaders.size() == 1:
		winner_id = leaders[0]
		terminal = {"ended": true, "outcome": "win", "reason": "time_limit_ranking"}
		window_events.append(_event("episode_won", PARTICIPANTS, {
			"winner": winner_id, "reason": "time_limit_ranking", "placements": placements.duplicate(true),
		}))
	else:
		winner_id = null
		terminal = {"ended": true, "outcome": "draw", "reason": "time_limit_tie"}
		window_events.append(_event("episode_drawn", PARTICIPANTS, {
			"reason": "time_limit_tie", "placements": placements.duplicate(true),
		}))


func _winner_placements(winner: String, basis: String) -> Array[Dictionary]:
	var output: Array[Dictionary] = [{"place": 1, "participant_ids": [winner], "tie": false, "basis": basis}]
	var remaining: Array[String] = []
	for participant_id: String in PARTICIPANTS:
		if participant_id != winner:
			remaining.append(participant_id)
	remaining.sort_custom(func(a: String, b: String) -> bool:
		var tick_a := _elimination_rank(a)
		var tick_b := _elimination_rank(b)
		return tick_a > tick_b if tick_a != tick_b else a < b)
	var place := 2
	var index := 0
	while index < remaining.size():
		var rank := _elimination_rank(remaining[index])
		var group: Array[String] = []
		while index < remaining.size() and _elimination_rank(remaining[index]) == rank:
			group.append(remaining[index])
			index += 1
		output.append({"place": place, "participant_ids": group, "tie": group.size() > 1,
			"basis": "elimination_order"})
		place += group.size()
	return output


func _rank_time_limit() -> Array[Dictionary]:
	var ordered: Array[String] = []
	ordered.assign(PARTICIPANTS)
	ordered.sort_custom(func(a: String, b: String) -> bool:
		var score_a := _time_score(a)
		var score_b := _time_score(b)
		for index: int in score_a.size():
			if score_a[index] != score_b[index]:
				return score_a[index] > score_b[index]
		return a < b)
	var output: Array[Dictionary] = []
	var place := 1
	var index := 0
	while index < ordered.size():
		var score := _time_score(ordered[index])
		var group: Array[String] = []
		while index < ordered.size() and _time_score(ordered[index]) == score:
			group.append(ordered[index])
			index += 1
		output.append({"place": place, "participant_ids": group, "tie": group.size() > 1,
			"basis": "time_limit_score"})
		place += group.size()
	return output


func _time_score(participant_id: String) -> Array[int]:
	var operator: Dictionary = operators[participant_id]
	if combat_enabled():
		return [1 if _is_active(participant_id) else 0, int(operator.health),
			int(relay_total_ticks[participant_id])]
	return [int(relay_total_ticks[participant_id])]


func observe_all() -> Dictionary:
	var observations := {}
	for participant_id: String in PARTICIPANTS:
		observations[participant_id] = observe(participant_id)
	return observations


func observe(participant_id: String) -> Dictionary:
	assert(participant_id in PARTICIPANTS)
	var operator: Dictionary = operators[participant_id]
	var visible_entities: Array[Dictionary] = []
	visible_entities.append(_project_entity(operator, "v_relay", "relay", Vector2i.ZERO,
		["capture"], _relay_state(participant_id)))
	for other_id: String in PARTICIPANTS:
		if other_id == participant_id:
			continue
		var other: Dictionary = operators[other_id]
		if _visible(operator, other.position_axial):
			visible_entities.append(_project_entity(operator, "v_%s" % other_id, "operator",
				other.position_axial, ["attack", "guard"] if combat_enabled() else [],
				_health_band(other.health)))
	return {
		"protocol_version": PROTOCOL_VERSION, "episode_id": episode_id,
		"observation_seq": observation_seq, "tick": tick, "profile": "text-visible-v1",
		"goal": _goal(), "remaining_ticks": maxi(0, MAXIMUM_TICKS - tick),
		"self": {
			"health_percent": _divide_toward_zero(int(operator.health) * 100, MAX_HEALTH),
			"energy_percent": _divide_toward_zero(int(operator.energy) * 100, MAX_ENERGY),
			"facing": FACING_NAMES[int(operator.heading)], "contact": operator.contact,
			"inventory": [], "status": _status_for(operator),
		},
		"visible_entities": visible_entities, "recent_events": _events_for(participant_id),
		"previous_receipt": previous_receipts.get(participant_id), "memory": str(operator.memory),
		"terminal": terminal.duplicate(true),
	}


func checkpoint() -> Dictionary:
	var projected_operators := {}
	for participant_id: String in PARTICIPANTS:
		var operator: Dictionary = operators[participant_id]
		projected_operators[participant_id] = {
			"position_axial": [operator.position_axial.x, operator.position_axial.y],
			"heading": operator.heading, "look_accumulator": operator.look_accumulator,
			"health": operator.health, "energy": operator.energy, "guarding": operator.guarding,
			"primary_cooldown_ticks": operator.primary_cooldown_ticks,
			"dash_cooldown_ticks": operator.dash_cooldown_ticks,
			"distance_travelled_mt": operator.distance_travelled_mt,
			"damage_taken": operator.damage_taken, "contact": operator.contact,
			"eliminated_tick": operator.eliminated_tick,
		}
	return {
		"protocol_version": PROTOCOL_VERSION, "task_id": task_id, "episode_id": episode_id,
		"seat_rotation": seat_rotation, "tick": tick, "observation_seq": observation_seq,
		"event_seq": event_seq, "operators": projected_operators,
		"relay_controller": relay_controller, "relay_hold_ticks": relay_hold_ticks,
		"relay_total_ticks": relay_total_ticks.duplicate(true),
		"invalid_windows": invalid_windows.duplicate(true), "winner_id": winner_id,
		"placements": placements.duplicate(true), "terminal": terminal.duplicate(true),
	}


func checkpoint_hash() -> String:
	return CheckpointSerializer.hash_checkpoint(checkpoint())


func replay() -> Dictionary:
	return {
		"protocol_version": PROTOCOL_VERSION, "task_id": task_id, "episode_id": episode_id,
		"seat_rotation": seat_rotation, "participant_ids": PARTICIPANTS.duplicate(),
		"windows": replay_windows.duplicate(true), "final_checkpoint_hash": checkpoint_hash(),
		"terminal": terminal.duplicate(true), "placements": placements.duplicate(true),
		"authority_aggregates": authority_aggregates(),
	}


func replay_hash() -> String:
	return CheckpointSerializer.hash_checkpoint(replay())


func authority_aggregates() -> Dictionary:
	var participants := {}
	for participant_id: String in PARTICIPANTS:
		var operator: Dictionary = operators[participant_id]
		participants[participant_id] = {
			"distance_travelled_mt": int(operator.distance_travelled_mt),
			"damage_taken": int(operator.damage_taken), "health_remaining": int(operator.health),
			"relay_control_ticks": int(relay_total_ticks[participant_id]),
			"invalid_windows": int(invalid_windows[participant_id]),
			"eliminated_tick": operator.eliminated_tick,
		}
	return {
		"task_id": task_id, "seat_rotation": seat_rotation,
		"completion_tick": tick if terminal.ended else null,
		"terminal_outcome": terminal.outcome, "terminal_reason": terminal.reason,
		"winner_id": winner_id, "placements": placements.duplicate(true),
		"participants": participants,
	}


func _validate_window(window: Variant) -> PackedStringArray:
	var codes := PackedStringArray()
	if not window is Dictionary:
		codes.append("window_invalid")
		return codes
	if window.get("episode_id") != episode_id:
		codes.append("episode_id_mismatch")
	if not window.get("observation_seq") is int or window.get("observation_seq") != observation_seq:
		codes.append("observation_seq_mismatch")
	if not window.get("start_tick") is int or window.get("start_tick") != tick:
		codes.append("start_tick_mismatch")
	if not window.get("duration_ticks") is int or window.get("duration_ticks") != DECISION_TICKS:
		codes.append("duration_ticks_invalid")
	if not window.get("decisions") is Dictionary:
		codes.append("decisions_invalid")
	else:
		for key: Variant in window.decisions.keys():
			if key not in PARTICIPANTS:
				codes.append("unexpected_participant")
	return codes


func _valid_accepted_decision(value: Variant) -> bool:
	return value is Dictionary and value.get("disposition") == "accepted" \
		and value.get("action") is Dictionary and value.get("fallback") == "none" \
		and value.get("no_input_reason") == null \
		and _has_exact_keys(value, ["disposition", "action", "fallback", "no_input_reason"])


func _valid_action(value: Variant) -> bool:
	if not value is Dictionary or value.get("protocol_version") != PROTOCOL_VERSION \
		or value.get("episode_id") != episode_id or not value.get("observation_seq") is int \
		or value.get("observation_seq") != observation_seq:
		return false
	if not _has_exact_keys(value, ["protocol_version", "episode_id", "observation_seq", "action_id",
		"control", "intent_label", "memory_update"]):
		return false
	if not value.get("action_id") is String or not _valid_identifier(str(value.action_id), 64) \
		or not value.get("intent_label") is String \
		or value.intent_label.to_utf8_buffer().size() > MAX_INTENT_UTF8_BYTES \
		or not value.get("memory_update") is String \
		or value.memory_update.to_utf8_buffer().size() > 2048:
		return false
	if not value.get("control") is Dictionary:
		return false
	var control: Dictionary = value.control
	if not control.get("duration_ticks") is int or control.get("duration_ticks") != DECISION_TICKS \
		or not control.get("buttons") is Dictionary:
		return false
	if not _has_exact_keys(control, ["move_x", "move_y", "look_x", "look_y", "duration_ticks", "buttons"]) \
		or not _has_exact_keys(control.buttons, BUTTONS):
		return false
	for axis: String in ["move_x", "move_y", "look_x", "look_y"]:
		if not control.get(axis) is int or control[axis] < -1000 or control[axis] > 1000:
			return false
	for button: String in BUTTONS:
		if not control.buttons.get(button) is bool:
			return false
	return true


func _no_input_reason(decision: Variant) -> String:
	if decision is Dictionary and decision.get("disposition") == "no_input" \
		and decision.get("action") == null and decision.get("fallback") == "neutral" \
		and decision.get("no_input_reason") in ["missing", "invalid", "timeout", "stale_observation", "budget_exhausted"] \
		and _has_exact_keys(decision, ["disposition", "action", "fallback", "no_input_reason"]):
		return str(decision.no_input_reason)
	return "missing" if decision == null else "invalid"


func _new_operator(position: Vector2i, heading: int) -> Dictionary:
	return {
		"position_axial": position, "heading": heading, "look_accumulator": 0,
		"health": MAX_HEALTH, "energy": MAX_ENERGY, "guarding": false,
		"primary_cooldown_ticks": 0, "dash_cooldown_ticks": 0,
		"distance_travelled_mt": 0, "damage_taken": 0, "contact": "clear",
		"memory": "", "eliminated_tick": null,
	}


func _neutral_control() -> Dictionary:
	var buttons := {}
	for button: String in BUTTONS:
		buttons[button] = false
	return {"move_x": 0, "move_y": 0, "look_x": 0, "look_y": 0,
		"duration_ticks": DECISION_TICKS, "buttons": buttons}


func _tick_cooldowns(operator: Dictionary) -> void:
	operator.primary_cooldown_ticks = maxi(0, int(operator.primary_cooldown_ticks) - 1)
	operator.dash_cooldown_ticks = maxi(0, int(operator.dash_cooldown_ticks) - 1)
	operator.contact = "clear"


func _apply_heading(operator: Dictionary, look_x: int) -> void:
	operator.look_accumulator += look_x
	while operator.look_accumulator >= 1000:
		operator.heading = posmod(int(operator.heading) + 1, 6)
		operator.look_accumulator -= 1000
	while operator.look_accumulator <= -1000:
		operator.heading = posmod(int(operator.heading) - 1, 6)
		operator.look_accumulator += 1000


func _walk_candidate(operator: Dictionary, control: Dictionary) -> Vector2i:
	var forward: Vector2i = AXIAL_DIRECTIONS[int(operator.heading)]
	var right: Vector2i = AXIAL_DIRECTIONS[posmod(int(operator.heading) + 2, 6)]
	var raw_q := _divide_toward_zero(
		forward.x * int(control.move_y) + right.x * int(control.move_x), 1000)
	var raw_r := _divide_toward_zero(
		forward.y * int(control.move_y) + right.y * int(control.move_x), 1000)
	var greatest := _axial_norm(Vector2i(raw_q, raw_r))
	if greatest > 1000:
		raw_q = _divide_toward_zero(raw_q * 1000, greatest)
		raw_r = _divide_toward_zero(raw_r * 1000, greatest)
	var previous: Vector2i = operator.position_axial
	var candidate := previous + Vector2i(
		_divide_toward_zero(raw_q * SPEED_MT, 1000),
		_divide_toward_zero(raw_r * SPEED_MT, 1000))
	var clamped := _clamp_axial(candidate, previous)
	operator.contact = "clear" if candidate == clamped else "blocked_front"
	operator.distance_travelled_mt += _axial_distance(previous, clamped)
	return clamped


func _dash_candidate(position: Vector2i, heading: int) -> Vector2i:
	var forward: Vector2i = AXIAL_DIRECTIONS[heading]
	return _clamp_axial(position + Vector2i(
		_divide_toward_zero(forward.x * DASH_DISTANCE_MT, 1000),
		_divide_toward_zero(forward.y * DASH_DISTANCE_MT, 1000)), position)


func _clamp_axial(position: Vector2i, fallback: Vector2i) -> Vector2i:
	if _axial_norm(position) <= ARENA_RADIUS_MT:
		return position
	# Rejecting an overflowing move is exactly invariant under the order-three axial transform.
	# A component-wise projection would introduce an asymmetric integer-rounding tie policy.
	return fallback


func _select_target(attacker_id: String) -> String:
	var candidates: Array[String] = []
	for target_id: String in PARTICIPANTS:
		if target_id != attacker_id and _is_active(target_id) \
			and _can_hit(operators[attacker_id], operators[target_id]):
			candidates.append(target_id)
	if candidates.is_empty():
		return ""
	var closest_distance := 9223372036854775807
	var closest: Array[String] = []
	for candidate_id: String in candidates:
		var distance := _axial_distance(
			operators[attacker_id].position_axial, operators[candidate_id].position_axial)
		if distance < closest_distance:
			closest_distance = distance
			closest = [candidate_id]
		elif distance == closest_distance:
			closest.append(candidate_id)
	# An exactly ambiguous primary misses instead of privileging a participant ID.
	return closest[0] if closest.size() == 1 else ""


func _can_hit(attacker: Dictionary, target: Dictionary) -> bool:
	if target.health <= 0 or _axial_distance(attacker.position_axial, target.position_axial) > PRIMARY_RANGE_MT:
		return false
	return _bearing_index(attacker, target.position_axial) == 0


func _guard_blocks_any(defender: Dictionary, attacker_ids: Array) -> bool:
	for attacker_id: String in attacker_ids:
		if _bearing_index(defender, operators[attacker_id].position_axial) == 0:
			return true
	return false


func _visible(observer: Dictionary, position: Vector2i) -> bool:
	return _axial_distance(observer.position_axial, position) <= VISIBILITY_RANGE_MT \
		and _bearing_index(observer, position) in [0, 1, 5]


func _project_entity(
	observer: Dictionary, id: String, kind: String, position: Vector2i,
	affordances: Array, state: String,
) -> Dictionary:
	return {"id": id, "kind": kind, "bearing": _bearing_name(observer, position),
		"distance": _distance_band(observer.position_axial, position),
		"affordances": affordances.duplicate(), "state": state}


func _bearing_index(observer: Dictionary, position: Vector2i) -> int:
	var offset: Vector2i = position - observer.position_axial
	if offset == Vector2i.ZERO:
		return 0
	var best_heading := 0
	var best_dot := -9223372036854775807
	for heading: int in 6:
		var direction: Vector2i = AXIAL_DIRECTIONS[heading]
		# Convert axial vectors to an integer metric dot product: 2q+r, 3r.
		var dot := (2 * direction.x + direction.y) * (2 * offset.x + offset.y) \
			+ 3 * direction.y * offset.y
		if dot > best_dot or (dot == best_dot and heading % 2 == 0 and best_heading % 2 == 1):
			best_dot = dot
			best_heading = heading
	return posmod(best_heading - int(observer.heading), 6)


func _bearing_name(observer: Dictionary, position: Vector2i) -> String:
	var relative := _bearing_index(observer, position)
	return ["front", "front_right", "right", "behind", "left", "front_left"][relative]


func _distance_band(first: Vector2i, second: Vector2i) -> String:
	var distance := _axial_distance(first, second)
	if distance <= 700:
		return "touching"
	if distance <= 2200:
		return "near"
	if distance <= 5000:
		return "medium"
	return "far"


func _axial_norm(value: Vector2i) -> int:
	return maxi(absi(value.x), maxi(absi(value.y), absi(-value.x - value.y)))


func _axial_distance(first: Vector2i, second: Vector2i) -> int:
	return _axial_norm(second - first)


func rotate_axial_120(value: Vector2i) -> Vector2i:
	return Vector2i(-value.x - value.y, value.x)


func _relay_state(participant_id: String) -> String:
	if relay_controller == null:
		return "uncontrolled"
	return ("self" if relay_controller == participant_id else "rival") + "_holding"


func _health_band(value: int) -> String:
	if value <= 0:
		return "knocked_out"
	if value <= 250:
		return "critical"
	if value <= 750:
		return "wounded"
	return "ready"


func _goal() -> String:
	if combat_enabled():
		return "Secure the visible relay or become the last operator standing."
	return "Hold the visible central relay uncontested before either rival. Attacks are disabled."


func _status_for(operator: Dictionary) -> Array[String]:
	var output: Array[String] = []
	if operator.eliminated_tick != null:
		output.append("eliminated")
	elif operator.guarding:
		output.append("guarding")
	return output


func _events_for(participant_id: String) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for authority_event: Dictionary in recent_events:
		if participant_id in authority_event.participant_ids:
			output.append(authority_event.duplicate(true))
	return output


func _event(kind: String, participant_ids: Array, data: Dictionary) -> Dictionary:
	var authority_event := {
		"event_id": "evt_%d_%d" % [tick, event_seq], "tick": tick,
		"kind": kind, "summary": kind.replace("_", " ").capitalize() + ".",
		"participant_ids": participant_ids.duplicate(), "data": data.duplicate(true),
	}
	event_seq += 1
	return authority_event


func _effect_snapshot(operator: Dictionary) -> Dictionary:
	return {"health": operator.health, "energy": operator.energy,
		"distance_travelled_mt": operator.distance_travelled_mt}


func _effects(before: Dictionary, operator: Dictionary) -> Array[Dictionary]:
	return [
		{"kind": "health_delta", "value": int(operator.health) - int(before.health)},
		{"kind": "energy_delta", "value": int(operator.energy) - int(before.energy)},
		{"kind": "movement_distance_mt", "value": int(operator.distance_travelled_mt) \
			- int(before.distance_travelled_mt)},
	]


func _result(receipts: Dictionary, window_events: Array[Dictionary]) -> Dictionary:
	return {"observations": observe_all(), "receipts": receipts,
		"public_events": window_events.duplicate(true), "state_hash": checkpoint_hash(),
		"terminal": terminal.duplicate(true), "placements": placements.duplicate(true)}


func _active_participants() -> Array[String]:
	var output: Array[String] = []
	for participant_id: String in PARTICIPANTS:
		if _is_active(participant_id):
			output.append(participant_id)
	return output


func _is_active(participant_id: String) -> bool:
	return int(operators[participant_id].health) > 0


func _elimination_rank(participant_id: String) -> int:
	var eliminated_tick: Variant = operators[participant_id].eliminated_tick
	return MAXIMUM_TICKS + 1 if eliminated_tick == null else int(eliminated_tick)


func _append_unique(values: Variant, value: String) -> void:
	if value not in values:
		values.append(value)


func _has_exact_keys(value: Dictionary, expected: Array) -> bool:
	if value.size() != expected.size():
		return false
	for key: Variant in expected:
		if not value.has(key):
			return false
	return true


func _valid_identifier(value: String, maximum_bytes: int) -> bool:
	var bytes := value.to_utf8_buffer()
	if bytes.is_empty() or bytes.size() > maximum_bytes:
		return false
	for index: int in bytes.size():
		var code := int(bytes[index])
		var alpha_numeric := (code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
			or (code >= 97 and code <= 122)
		if not alpha_numeric and (index == 0 or code not in [45, 46, 95]):
			return false
	return true


func _divide_toward_zero(numerator: int, denominator: int) -> int:
	assert(denominator > 0)
	@warning_ignore("integer_division")
	var quotient: int = absi(numerator) / denominator
	return -quotient if numerator < 0 else quotient
