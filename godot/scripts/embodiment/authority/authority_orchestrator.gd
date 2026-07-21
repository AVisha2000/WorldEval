class_name EmbodimentAuthorityOrchestrator
extends RefCounted

## Deterministic Stage-A authority for the LLM Controller embodiment track.
##
## This class deliberately owns no Node, physics body, navigation server, or render state. The
## presentation will interpolate its integer authority state, while live and headless episodes use
## the exact same `step` method.

const AuthorityState := preload("res://scripts/embodiment/authority/authority_state.gd")
const ArenaMap := preload("res://scripts/embodiment/authority/arena_map.gd")
const ControllerExecutor := preload("res://scripts/embodiment/authority/controller_executor.gd")
const ObservationProjector := preload("res://scripts/embodiment/authority/observation_projector.gd")
const TerminalEvaluator := preload("res://scripts/embodiment/authority/terminal_evaluator.gd")
const CheckpointSerializer := preload("res://scripts/embodiment/authority/checkpoint_serializer.gd")
const EventLedger := preload("res://scripts/embodiment/authority/event_ledger.gd")
const InteractionSystem := preload("res://scripts/embodiment/authority/interaction_system.gd")
const ConstructionSystem := preload("res://scripts/embodiment/authority/construction_system.gd")
const CombatSystem := preload("res://scripts/embodiment/authority/combat_system.gd")
const NeutralController := preload("res://scripts/embodiment/authority/neutral_controller.gd")

const PROTOCOL_VERSION := "llm-controller/0.1.0"
const TICK_HZ := 10
const ARENA_HALF_EXTENT_MT := 10_000
const OPERATOR_SPEED_MT_PER_TICK := 200
const BEACON_RADIUS_MT := 1_200
const BEACON_HOLD_TICKS := 10
const MAX_ACTION_TICKS := 20
const DEFAULT_ACTION_TICKS := 10
const DUEL_ACTION_TICKS := 10
const MAX_MEMORY_UTF8_BYTES := 2048
const MAX_INTENT_UTF8_BYTES := 160
const IMPLEMENTED_MODE := "solo-curriculum-v0"
const IMPLEMENTED_TASKS := [
	"orientation-v0", "interaction-v0", "construction-v0", "neutral-encounter-v0",
]
const IMPLEMENTED_PROFILE := "text-visible-v1"
const PARTICIPANT_ID := "participant_0"
const REQUIRED_WINDOW_FIELDS := [
	"episode_id", "observation_seq", "mode", "start_tick", "duration_ticks", "decisions",
]
const REQUIRED_ACTION_FIELDS := [
	"protocol_version", "episode_id", "observation_seq", "action_id", "control",
	"intent_label", "memory_update",
]
const REQUIRED_CONTROL_FIELDS := [
	"move_x", "move_y", "look_x", "look_y", "duration_ticks", "buttons",
]
const REQUIRED_BUTTON_FIELDS := [
	"interact", "primary", "guard", "dash", "ability_1", "ability_2", "cycle_item", "cancel",
]
const AUTHORITY_EVENT_KINDS := [
	"beacon_entered", "beacon_exited", "episode_succeeded", "episode_failed",
]
const FACING_NAMES := [
	"north", "north_east", "east", "south_east",
	"south", "south_west", "west", "north_west",
]
const RELATIVE_BEARINGS := [
	"front", "front_right", "right", "back_right",
	"back", "back_left", "left", "front_left",
]
const FORWARD_BASIS := [
	Vector2i(0, -1000), Vector2i(707, -707), Vector2i(1000, 0), Vector2i(707, 707),
	Vector2i(0, 1000), Vector2i(-707, 707), Vector2i(-1000, 0), Vector2i(-707, -707),
]

var episode_id := ""
var mode := IMPLEMENTED_MODE
var task_id := "orientation-v0"
var observation_profile := "text-visible-v1"
var participant_ids: Array[String] = [PARTICIPANT_ID]
var maximum_episode_ticks := 600
var tick := 0
var observation_seq := 0
var event_seq := 0
var operator_position_mt := Vector2i(0, 7000)
var operator_heading := 0
var look_accumulator := 0
var beacon_position_mt := Vector2i(0, -7000)
var beacon_hold_ticks := 0
var contact := "clear"
var memory := ""
var terminal := {"ended": false, "outcome": "running", "reason": "running"}
var previous_receipt: Variant = null
## Participant-local presentation evidence. It is intentionally excluded from AuthorityState and
## checkpoint hashing; presentation may display it but cannot treat the intent as authority input.
var presentation_agency: Dictionary = {}
var recent_events: Array[Dictionary] = []
var resource_position_mt := Vector2i(0, -3000)
var relay_position_mt := Vector2i(0, 7000)
var build_pad_position_mt := Vector2i(3000, 5000)
var resource_units_remaining := 0
var gather_progress_ticks := 0
var inventory_material_units := 0
var deposited_material_units := 0
var active_interaction := "none"
var barricade_progress_ticks := 0
var barricade_complete := false
var construction_active := false
var operator_health := 1000
var operator_energy := 1000
var operator_guarding := false
var operator_knocked_out := false
var primary_cooldown_ticks := 0
var dash_cooldown_ticks := 0
var neutral_position_mt := Vector2i(0, -1000)
var neutral_home_position_mt := Vector2i(0, -1000)
var neutral_health := 750
var neutral_state := "idle"
var neutral_state_ticks := 0
var neutral_attack_cooldown_ticks := 0
var relay_activation_ticks := 0
var relay_activated := false
var _managed_hybrid_enabled := false


func configure(config: Dictionary) -> PackedStringArray:
	_managed_hybrid_enabled = false
	return _configure(config)


func configure_managed_hybrid(config: Dictionary) -> PackedStringArray:
	_managed_hybrid_enabled = true
	return _configure(config)


func _configure(config: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	var candidate_episode: Variant = config.get("episode_id")
	if typeof(candidate_episode) != TYPE_STRING or not _valid_episode_id(candidate_episode):
		errors.append("episode_id_invalid")
	var candidate_mode: Variant = config.get("mode")
	if typeof(candidate_mode) != TYPE_STRING or candidate_mode != IMPLEMENTED_MODE:
		errors.append("mode_unsupported")
	var candidate_task: Variant = config.get("task_id")
	if typeof(candidate_task) != TYPE_STRING or candidate_task not in IMPLEMENTED_TASKS:
		errors.append("task_unsupported")
	var profile: Variant = config.get("observation_profile")
	if typeof(profile) != TYPE_STRING or (
		profile != IMPLEMENTED_PROFILE \
		and not (_managed_hybrid_enabled and profile == "hybrid-visible-v1")
	):
		errors.append("observation_profile_unsupported")
	var configured_participants: Variant = config.get("participant_ids", [PARTICIPANT_ID])
	if not configured_participants is Array or configured_participants != [PARTICIPANT_ID]:
		errors.append("participant_ids_unsupported")
	var maximum_ticks: Variant = config.get("maximum_episode_ticks", 0)
	if typeof(maximum_ticks) != TYPE_INT or maximum_ticks < 1 or maximum_ticks > 18_000:
		errors.append("maximum_episode_ticks_invalid")
	if not errors.is_empty():
		return errors
	episode_id = candidate_episode
	mode = candidate_mode
	task_id = candidate_task
	observation_profile = profile
	participant_ids.assign(configured_participants)
	maximum_episode_ticks = maximum_ticks
	reset()
	return errors


func capability_status() -> Dictionary:
	return {
		"implemented_modes": [IMPLEMENTED_MODE],
		"implemented_observation_profiles": (
			[IMPLEMENTED_PROFILE, "hybrid-visible-v1"]
			if _managed_hybrid_enabled else [IMPLEMENTED_PROFILE]
		),
		"implemented_tasks": IMPLEMENTED_TASKS.duplicate(),
		"certified_modes": [],
		"certified_observation_profiles": [],
		"scored_observation_profiles": [],
	}


func decision_window_duration(mode_id: String, requested_duration: Variant) -> int:
	if mode_id in ["scripted-duel-v0", "model-duel-v0"]:
		return DUEL_ACTION_TICKS
	if mode_id == IMPLEMENTED_MODE and typeof(requested_duration) == TYPE_INT \
		and requested_duration >= 1 and requested_duration <= MAX_ACTION_TICKS:
		return requested_duration
	return DEFAULT_ACTION_TICKS


func reset() -> Dictionary:
	AuthorityState.reset(self)
	presentation_agency = _presentation_agency(_neutral_control(0), null, "")
	return observe()


func step(action: Dictionary) -> Dictionary:
	var requested_duration := DEFAULT_ACTION_TICKS
	if action.get("control") is Dictionary:
		var candidate_duration: Variant = action.control.get("duration_ticks")
		if typeof(candidate_duration) == TYPE_INT and candidate_duration >= 1 \
			and candidate_duration <= MAX_ACTION_TICKS:
			requested_duration = candidate_duration
	return step_window({
		"episode_id": episode_id,
		"observation_seq": observation_seq,
		"mode": mode,
		"start_tick": tick,
		"duration_ticks": requested_duration,
		"decisions": {PARTICIPANT_ID: {
			"disposition": "accepted",
			"action": action,
			"fallback": "none",
			"no_input_reason": null,
		}},
	})


func step_window(window: Dictionary) -> Dictionary:
	var window_errors := _validate_window(window)
	var duration_ticks := _window_duration(window)
	var decisions: Dictionary = window.get("decisions", {}) \
		if window.get("decisions", {}) is Dictionary else {}
	var candidate_decision: Variant = decisions.get(PARTICIPANT_ID)
	var decision: Dictionary = candidate_decision if candidate_decision is Dictionary else {}
	var candidate_action: Variant = decision.get("action")
	var action: Dictionary = candidate_action if candidate_action is Dictionary else {}
	var errors := PackedStringArray()
	errors.append_array(window_errors)
	if not _valid_participant_decision(decision):
		_append_unique(errors, "decision_invalid")
	elif decision.disposition == "no_input":
		_append_unique(errors, "no_input")
	else:
		for error: String in _validate_action(action, duration_ticks):
			_append_unique(errors, error)
	if bool(terminal.ended):
		_append_unique(errors, "episode_ended")
	if not errors.is_empty():
		return _apply_neutral_window(action, duration_ticks, errors, _no_input_reason(decision, errors))
	return _apply_action_window(action, duration_ticks)


func _apply_action_window(action: Dictionary, duration_ticks: int) -> Dictionary:
	var control: Dictionary = action.control
	var start_tick := tick
	var effects := {"distance_moved_mt": 0, "heading_steps": 0, "beacon_hold_ticks": 0}
	var task_before := _task_effect_snapshot()
	var task_codes := PackedStringArray()
	var detailed_task_effects := {}
	var events: Array[Dictionary] = []
	var applied_ticks := 0
	for action_tick: int in duration_ticks:
		if bool(terminal.ended):
			break
		var before := operator_position_mt
		var heading_before := operator_heading
		ControllerExecutor.apply_tick(self, control, action_tick == 0)
		for code: String in _apply_task_tick(
			control, action_tick == 0, events, detailed_task_effects
		):
			_append_unique(task_codes, code)
		effects.distance_moved_mt += (
			abs(operator_position_mt.x - before.x) + abs(operator_position_mt.y - before.y)
		)
		effects.heading_steps += _heading_distance(heading_before, operator_heading)
		tick += 1
		applied_ticks += 1
		TerminalEvaluator.update_goal(self, events)
		TerminalEvaluator.enforce_time_limit(self, events)
	effects.beacon_hold_ticks = beacon_hold_ticks
	# memory_update is validated as controller input but owned by the Python episode runner.
	# Authority checkpoints and player observations therefore never retain provider scratchpad.
	memory = ""
	var receipt_effects: Array[Dictionary] = []
	var common_effect_kinds: Array[String] = ["distance_moved_mt", "heading_steps"]
	if task_id == "orientation-v0":
		common_effect_kinds.append("beacon_hold_ticks")
	for effect_kind: String in common_effect_kinds:
		receipt_effects.append({"kind": effect_kind, "value": int(effects[effect_kind])})
	var detailed_kinds: Array = detailed_task_effects.keys()
	detailed_kinds.sort()
	for effect_kind: String in detailed_kinds:
		receipt_effects.append({
			"kind": effect_kind, "value": int(detailed_task_effects[effect_kind]),
		})
	var codes: Array = ["applied"]
	for code: String in task_codes:
		if code not in codes and not code.ends_with("_idle"):
			codes.append(code)
	if contact != "clear":
		codes.append("movement_blocked")
	if bool(terminal.ended) and str(terminal.reason) not in codes:
		codes.append(str(terminal.reason))
	for effect: Dictionary in _task_receipt_effects(task_before):
		receipt_effects.append(effect)
	var receipt := _receipt(
		str(action.action_id), true, start_tick, tick, applied_ticks, codes, receipt_effects
	)
	previous_receipt = receipt
	presentation_agency = _presentation_agency(control, receipt, str(action.intent_label))
	recent_events = events
	observation_seq += 1
	return _step_result(receipt, events)


func _apply_task_tick(
	control: Dictionary,
	first_tick: bool,
	events: Array[Dictionary],
	detailed_effects: Dictionary = {},
) -> PackedStringArray:
	var buttons: Dictionary = control.buttons
	var codes := PackedStringArray()
	if task_id == "interaction-v0":
		codes = InteractionSystem.apply_tick(
			self, bool(buttons.interact), first_tick and bool(buttons.cancel), events
		)
	elif task_id == "construction-v0":
		var pad_offset := build_pad_position_mt - operator_position_mt
		var pad_in_range := pad_offset.x * pad_offset.x + pad_offset.y * pad_offset.y \
			<= ConstructionSystem.BUILD_RANGE_SQUARED
		# Once a construction channel is active, leaving its pad must resolve through the
		# construction system. Routing by current context alone would strand construction_active and
		# omit the interruption/out-of-range evidence.
		if construction_active and not pad_in_range:
			codes = ConstructionSystem.apply_tick(self, true, false, events)
		elif pad_in_range:
			codes = ConstructionSystem.apply_tick(
				self, bool(buttons.interact), first_tick and bool(buttons.cancel), events
			)
		else:
			codes = InteractionSystem.apply_tick(
				self, bool(buttons.interact), first_tick and bool(buttons.cancel), events
			)
	elif task_id == "neutral-encounter-v0":
		var event_start := events.size()
		var result: Dictionary = NeutralController.apply_tick(self, control, first_tick, events)
		_wrap_event_descriptors(events, event_start)
		codes = PackedStringArray(result.codes)
		for effect: Dictionary in result.effects:
			var effect_kind := str(effect.get("kind", ""))
			if effect_kind not in [
				"primary_damage", "dash_distance_mt", "damage_taken",
				"damage_prevented", "energy_recovered",
			]:
				continue
			detailed_effects[effect_kind] = int(detailed_effects.get(effect_kind, 0)) \
				+ int(effect.get("value", 0))
	_append_unavailable_input_evidence(buttons, first_tick, events, codes)
	return codes


func _append_unavailable_input_evidence(
	buttons: Dictionary,
	first_tick: bool,
	events: Array[Dictionary],
	codes: PackedStringArray,
) -> void:
	if not first_tick:
		return
	for button: String in ["ability_1", "ability_2", "cycle_item"]:
		if not bool(buttons.get(button, false)):
			continue
		_append_unique(codes, "%s_unavailable" % button)
		EventLedger.append(
			self,
			events,
			"controller_input_unavailable",
			"Controller input %s is unavailable in this task." % button,
			{"input": button},
		)


func _task_effect_snapshot() -> Dictionary:
	if task_id in ["interaction-v0", "construction-v0"]:
		return {
			"barricade_progress_ticks": barricade_progress_ticks,
			"deposited_material_units": deposited_material_units,
			"gather_progress_ticks": gather_progress_ticks,
			"inventory_material_units": inventory_material_units,
			"resource_units_remaining": resource_units_remaining,
		}
	if task_id == "neutral-encounter-v0":
		return {
			"neutral_health": neutral_health,
			"operator_energy": operator_energy,
			"operator_health": operator_health,
			"relay_activation_ticks": relay_activation_ticks,
		}
	return {}


func _task_receipt_effects(before: Dictionary) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for field: String in before:
		var current := int(get(field))
		var change := current - int(before[field])
		if change != 0:
			output.append({"kind": field, "value": change})
	return output


func _wrap_event_descriptors(events: Array[Dictionary], start_index: int) -> void:
	for index: int in range(start_index, events.size()):
		var descriptor: Dictionary = events[index]
		if descriptor.has("event_id"):
			continue
		assert(EventLedger.is_registered(str(descriptor.get("kind", ""))))
		events[index] = {
			"event_id": "evt_%d_%d" % [tick, event_seq],
			"tick": tick,
			"kind": str(descriptor.kind),
			"summary": str(descriptor.summary),
			"participant_ids": [PARTICIPANT_ID],
			"data": descriptor.data.duplicate(true),
		}
		event_seq += 1


func _apply_neutral_window(
	action: Dictionary, duration_ticks: int, errors: PackedStringArray, no_input_reason: String
) -> Dictionary:
	var start_tick := tick
	var events: Array[Dictionary] = []
	var applied_ticks := 0
	var neutral_control := _neutral_control(duration_ticks)
	if not bool(terminal.ended):
		for action_tick: int in duration_ticks:
			if bool(terminal.ended):
				break
			ControllerExecutor.apply_tick(self, neutral_control, action_tick == 0)
			_apply_task_tick(neutral_control, action_tick == 0, events)
			tick += 1
			applied_ticks += 1
			TerminalEvaluator.update_goal(self, events)
			TerminalEvaluator.enforce_time_limit(self, events)
	var codes: Array = Array(errors)
	if "no_input" not in codes:
		codes.append("no_input")
	var action_id := _safe_action_id(action)
	var rejected := _receipt(
		action_id, false, start_tick, tick, applied_ticks, codes,
		[{"kind": "neutral_ticks", "value": applied_ticks}],
		no_input_reason,
	)
	previous_receipt = rejected
	presentation_agency = _presentation_agency(neutral_control, rejected, "")
	recent_events = events
	observation_seq += 1
	return _step_result(rejected, events)


func _neutral_control(duration_ticks: int) -> Dictionary:
	return {
		"move_x": 0,
		"move_y": 0,
		"look_x": 0,
		"look_y": 0,
		"duration_ticks": duration_ticks,
		"buttons": {
			"interact": false,
			"primary": false,
			"guard": false,
			"dash": false,
			"ability_1": false,
			"ability_2": false,
			"cycle_item": false,
			"cancel": false,
		},
	}


func observe() -> Dictionary:
	return ObservationProjector.project(self)


func checkpoint() -> Dictionary:
	return AuthorityState.checkpoint(self)


func checkpoint_hash() -> String:
	return CheckpointSerializer.hash_checkpoint(checkpoint())


func presentation_source_snapshot() -> Dictionary:
	## Internal exact-position projection source. It is consumed only by the presentation privacy
	## filter and must never be returned as a participant observation or replay artifact.
	var observation := observe()
	var entities: Array[Dictionary] = [_presentation_entity(
		"operator_0", "operator", operator_position_mt, operator_heading,
		int(observation.self.health_percent), int(observation.self.energy_percent),
		observation.self.status, {
			"bearing": "front", "distance": "touching", "affordances": [], "state": "active",
		},
	)]
	for visible: Dictionary in observation.visible_entities:
		entities.append(_presentation_entity(
			str(visible.id), str(visible.kind), _presentation_position(str(visible.id)), 0,
			_presentation_health(str(visible.id)), 0, [], {
				"bearing": visible.bearing,
				"distance": visible.distance,
				"affordances": visible.affordances.duplicate(),
				"state": visible.state,
			},
		))
	return {
		"schema_version": "llm-controller/presentation-input/1.0.0",
		"protocol_version": PROTOCOL_VERSION,
		"episode_id": episode_id,
		"task_id": task_id,
		"observation_seq": observation_seq,
		"tick": tick,
		"remaining_ticks": maxi(maximum_episode_ticks - tick, 0),
		"goal": observation.goal,
		"authority_checkpoint_hash": checkpoint_hash(),
		"self_entity_id": "operator_0",
		"entities": entities,
		"agency": presentation_agency.duplicate(true),
		"terminal": terminal.duplicate(true),
	}


func _presentation_agency(control: Dictionary, receipt: Variant, intent_label: String) -> Dictionary:
	var projected_receipt: Variant = null
	if receipt is Dictionary:
		projected_receipt = {
			"disposition": str(receipt.disposition),
			"accepted": bool(receipt.accepted),
			"fallback": str(receipt.fallback),
			"applied_ticks": int(receipt.applied_ticks),
			"codes": receipt.codes.duplicate(),
		}
	return {
		"controller": control.duplicate(true),
		"receipt": projected_receipt,
		"intent_label": intent_label,
	}


func presentation_visible_entity_ids() -> Array[String]:
	var output: Array[String] = []
	for entity: Dictionary in observe().visible_entities:
		output.append(str(entity.id))
	return output


func _presentation_entity(
	id: String,
	kind: String,
	position_mt: Vector2i,
	heading_sector: int,
	health_percent: int,
	energy_percent: int,
	status: Array,
	semantic: Dictionary,
) -> Dictionary:
	return {
		"id": id,
		"kind": kind,
		"position_mt": [position_mt.x, position_mt.y],
		"heading_sector": heading_sector,
		"animation": _presentation_animation(kind, status),
		"animation_progress_milli": 0,
		"health_percent": health_percent,
		"energy_percent": energy_percent,
		"status": status.duplicate(),
		"semantic": semantic.duplicate(true),
	}


func _presentation_position(entity_id: String) -> Vector2i:
	match entity_id:
		"v_beacon_1":
			return beacon_position_mt
		"v_resource_1":
			return resource_position_mt
		"v_relay_1":
			return relay_position_mt
		"v_build_pad_1":
			return build_pad_position_mt
		"v_neutral_1":
			return neutral_position_mt
	return Vector2i.ZERO


func _presentation_health(entity_id: String) -> int:
	if entity_id == "v_neutral_1":
		return ArenaMap.divide_toward_zero(
			neutral_health * 100, NeutralController.NEUTRAL_MAX_HEALTH
		)
	return 100


func _presentation_animation(kind: String, status: Array) -> String:
	if bool(terminal.ended):
		return "celebrate" if terminal.outcome == "success" else "defeat"
	if kind == "neutral":
		return neutral_state
	if "guarding" in status:
		return "guard"
	var event_kinds: Array[String] = []
	for event: Dictionary in recent_events:
		event_kinds.append(str(event.get("kind", "")))
	if "operator_damaged" in event_kinds:
		return "hit"
	if "primary_hit" in event_kinds or "primary_missed" in event_kinds:
		return "attack"
	if "construction_progressed" in event_kinds or "construction_completed" in event_kinds:
		return "build"
	if "resource_gather_progressed" in event_kinds or "resource_gathered" in event_kinds:
		return "gather"
	if previous_receipt is Dictionary:
		for effect: Dictionary in previous_receipt.get("effects", []):
			var effect_kind := str(effect.get("kind", ""))
			var effect_value: int = absi(int(effect.get("value", 0)))
			if effect_kind == "dash_distance_mt" and effect_value > 0:
				return "dash"
			if effect_kind == "distance_moved_mt" and effect_value > 0:
				return "run" if effect_value >= 2000 else "walk"
	return "idle"


func _apply_controller_tick(control: Dictionary, first_tick: bool) -> void:
	ControllerExecutor.apply_tick(self, control, first_tick)


func _update_goal(events: Array[Dictionary]) -> void:
	TerminalEvaluator.update_goal(self, events)


func _validate_action(action: Dictionary, window_duration_ticks: int) -> PackedStringArray:
	var errors := PackedStringArray()
	if not _has_exact_fields(action, REQUIRED_ACTION_FIELDS):
		errors.append("action_shape_invalid")
		return errors
	if typeof(action.protocol_version) != TYPE_STRING or action.protocol_version != PROTOCOL_VERSION:
		errors.append("protocol_version_mismatch")
	if typeof(action.episode_id) != TYPE_STRING or action.episode_id != episode_id:
		errors.append("episode_id_mismatch")
	if typeof(action.observation_seq) != TYPE_INT or action.observation_seq != observation_seq:
		errors.append("observation_seq_mismatch")
	if typeof(action.action_id) != TYPE_STRING or not _valid_action_id(action.action_id):
		errors.append("action_id_invalid")
	if not action.control is Dictionary:
		errors.append("control_invalid")
		return errors
	var control: Dictionary = action.control
	if not _has_exact_fields(control, REQUIRED_CONTROL_FIELDS):
		errors.append("control_shape_invalid")
		return errors
	for axis: String in ["move_x", "move_y", "look_x", "look_y"]:
		if typeof(control[axis]) != TYPE_INT or control[axis] < -1000 or control[axis] > 1000:
			errors.append("%s_invalid" % axis)
	if typeof(control.duration_ticks) != TYPE_INT or int(control.duration_ticks) < 1 \
		or int(control.duration_ticks) > MAX_ACTION_TICKS:
		errors.append("duration_ticks_invalid")
	elif control.duration_ticks != window_duration_ticks:
		errors.append("duration_ticks_mismatch")
	if not control.buttons is Dictionary:
		errors.append("buttons_invalid")
		return errors
	var buttons: Dictionary = control.buttons
	if not _has_exact_fields(buttons, REQUIRED_BUTTON_FIELDS):
		errors.append("buttons_shape_invalid")
	else:
		for button: String in REQUIRED_BUTTON_FIELDS:
			if typeof(buttons[button]) != TYPE_BOOL:
				errors.append("%s_invalid" % button)
	if typeof(action.intent_label) != TYPE_STRING:
		errors.append("intent_label_invalid")
	elif action.intent_label.to_utf8_buffer().size() > MAX_INTENT_UTF8_BYTES:
		errors.append("intent_label_too_large")
	if typeof(action.memory_update) != TYPE_STRING:
		errors.append("memory_update_invalid")
	elif action.memory_update.to_utf8_buffer().size() > MAX_MEMORY_UTF8_BYTES:
		errors.append("memory_update_too_large")
	return errors


func _validate_window(window: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if not _has_exact_fields(window, REQUIRED_WINDOW_FIELDS):
		errors.append("decision_window_shape_invalid")
		return errors
	if typeof(window.episode_id) != TYPE_STRING or window.episode_id != episode_id:
		errors.append("episode_id_mismatch")
	if typeof(window.observation_seq) != TYPE_INT or window.observation_seq != observation_seq:
		errors.append("observation_seq_mismatch")
	if typeof(window.mode) != TYPE_STRING or window.mode != mode:
		errors.append("mode_mismatch")
	if typeof(window.start_tick) != TYPE_INT or window.start_tick != tick:
		errors.append("start_tick_mismatch")
	if typeof(window.duration_ticks) != TYPE_INT or window.duration_ticks < 1 \
		or window.duration_ticks > MAX_ACTION_TICKS:
		errors.append("duration_ticks_invalid")
	if not window.decisions is Dictionary:
		errors.append("decisions_invalid")
	elif window.decisions.size() != participant_ids.size():
		errors.append("participant_decisions_invalid")
	else:
		for participant_id: String in participant_ids:
			if not window.decisions.has(participant_id):
				errors.append("participant_decisions_invalid")
	return errors


func _window_duration(window: Dictionary) -> int:
	var requested: Variant = window.get("duration_ticks")
	return decision_window_duration(mode, requested)


func _has_exact_fields(value: Dictionary, expected: Array) -> bool:
	if value.size() != expected.size():
		return false
	for field: String in expected:
		if not value.has(field):
			return false
	return true


func _relative_bearing(offset: Vector2i) -> String:
	var world_sector := _world_sector(offset)
	return RELATIVE_BEARINGS[posmod(world_sector - operator_heading, 8)]


func _world_sector(offset: Vector2i) -> int:
	var x: int = offset.x
	var y: int = offset.y
	var ax: int = abs(x)
	var ay: int = abs(y)
	if ax * 2 < ay:
		return 0 if y < 0 else 4
	if ay * 2 < ax:
		return 2 if x > 0 else 6
	if x >= 0 and y < 0:
		return 1
	if x > 0 and y >= 0:
		return 3
	if x <= 0 and y > 0:
		return 5
	return 7


func _distance_band(offset: Vector2i) -> String:
	var distance := maxi(abs(offset.x), abs(offset.y))
	if distance <= BEACON_RADIUS_MT:
		return "touching"
	if distance <= 3500:
		return "near"
	if distance <= 9000:
		return "medium"
	return "far"


func _heading_distance(before: int, after: int) -> int:
	var clockwise := posmod(after - before, 8)
	return mini(clockwise, 8 - clockwise)


func _event(kind: String, summary: String) -> Dictionary:
	assert(kind in AUTHORITY_EVENT_KINDS, "unregistered authority event kind")
	assert(not summary.is_empty() and summary.to_utf8_buffer().size() <= 240)
	var event := {
		"event_id": "evt_%d_%d" % [tick, event_seq],
		"tick": tick,
		"kind": kind,
		"summary": summary,
		"participant_ids": [PARTICIPANT_ID],
		"data": {},
	}
	event_seq += 1
	return event


func _receipt(
	action_id: String,
	accepted: bool,
	start_tick: int,
	end_tick: int,
	applied_ticks: int,
	codes: Array,
	effects: Array,
	no_input_reason: Variant = null,
) -> Dictionary:
	return {
		"action_id": action_id,
		"observation_seq": observation_seq,
		"accepted": accepted,
		"disposition": "accepted" if accepted else "no_input",
		"fallback": "none" if accepted else "neutral",
		"no_input_reason": null if accepted else no_input_reason,
		"start_tick": start_tick,
		"end_tick": end_tick,
		"applied_ticks": applied_ticks,
		"codes": codes,
		"effects": effects,
	}


func _step_result(receipt: Dictionary, events: Array) -> Dictionary:
	return {
		"observations": {PARTICIPANT_ID: observe()},
		"receipts": {PARTICIPANT_ID: receipt.duplicate(true)},
		"public_events": events.duplicate(true),
		"state_hash": checkpoint_hash(),
		"terminal": terminal.duplicate(true),
	}


func _safe_action_id(action: Dictionary) -> String:
	var candidate: Variant = action.get("action_id")
	if typeof(candidate) == TYPE_STRING and _valid_action_id(candidate):
		return candidate
	return "no_input_%d" % observation_seq


func _valid_participant_decision(decision: Dictionary) -> bool:
	var required := ["disposition", "action", "fallback", "no_input_reason"]
	if not _has_exact_fields(decision, required):
		return false
	if typeof(decision.disposition) != TYPE_STRING or typeof(decision.fallback) != TYPE_STRING:
		return false
	if decision.disposition == "accepted":
		return decision.action is Dictionary and decision.fallback == "none" \
			and decision.no_input_reason == null
	if decision.disposition == "no_input":
		return decision.action == null and decision.fallback == "neutral" \
			and decision.no_input_reason in ["missing", "invalid", "timeout", "stale_observation"]
	return false


func _no_input_reason(decision: Dictionary, errors: PackedStringArray) -> String:
	if _valid_participant_decision(decision) and decision.disposition == "no_input":
		return decision.no_input_reason
	if "observation_seq_mismatch" in errors:
		return "stale_observation"
	return "invalid"


func _append_unique(values: PackedStringArray, value: String) -> void:
	if value not in values:
		values.append(value)


func _valid_episode_id(value: String) -> bool:
	if not value.begins_with("ep_") or value.length() < 4 or value.length() > 123:
		return false
	return _is_ascii_token(value.substr(3), 1, 120, true)


func _valid_action_id(value: String) -> bool:
	return _is_ascii_token(value, 1, 64, false)


func _is_ascii_token(value: String, minimum: int, maximum: int, allow_leading_punctuation: bool) -> bool:
	if value.length() < minimum or value.length() > maximum:
		return false
	for index: int in value.length():
		var code := value.unicode_at(index)
		var alphanumeric := (code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
			or (code >= 97 and code <= 122)
		var punctuation := code in [45, 46, 95]
		if not alphanumeric and not punctuation:
			return false
		if index == 0 and not allow_leading_punctuation and not alphanumeric:
			return false
	return true


func _divide_toward_zero(numerator: int, denominator: int) -> int:
	assert(denominator != 0)
	var positive_denominator := absi(denominator)
	@warning_ignore("integer_division")
	var quotient: int = absi(numerator) / positive_denominator
	return -quotient if (numerator < 0) != (denominator < 0) else quotient


func _canonical_json(value: Variant) -> String:
	return CheckpointSerializer.canonical_json(value)
