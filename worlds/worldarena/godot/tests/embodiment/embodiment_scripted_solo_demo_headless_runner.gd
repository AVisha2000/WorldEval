extends SceneTree

## Deterministic, credential-free coverage for the non-Construction solo demos.
##
## Construction has its dedicated managed task-plan runner.  This runner covers the ordinary
## direct-controller contract used by the scripted Orientation, Interaction, and Neutral Encounter
## demos: every decision window is one authority tick, all target selection consumes public
## semantic observations only, and the recorded transcript replays to the identical checkpoint.

const Authority := preload("res://scripts/embodiment/authority/authority_orchestrator.gd")

const OUTPUT_PREFIX := "EMBODIMENT_SCRIPTED_SOLO_DEMO_EVIDENCE="
const PARTICIPANT_ID := "participant_0"
const TASKS := ["orientation-v0", "interaction-v0", "neutral-encounter-v0"]
const EXPECTED_REASONS := {
	"orientation-v0": "beacon_held",
	"interaction-v0": "resource_deposited",
	"neutral-encounter-v0": "relay_activated",
}
const BUTTON_NAMES := [
	"interact", "primary", "guard", "dash", "ability_1", "ability_2", "cycle_item", "cancel",
]
const TURN_RIGHT := ["front_right", "right", "back_right", "back"]
const TURN_LEFT := ["front_left", "left", "back_left"]
const SAFE_NEUTRAL_STATES := ["retreat", "recovery", "defeated"]

var _failures := PackedStringArray()


func _init() -> void:
	_run()


func _run() -> void:
	var summaries := {}
	for task_id: String in TASKS:
		var authority := Authority.new()
		var errors: PackedStringArray = authority.configure(_config(task_id))
		_check(errors.is_empty(), "%s configuration failed: %s" % [task_id, str(errors)])
		if not errors.is_empty():
			continue
		var transcript: Array[Dictionary] = []
		var hashes := PackedStringArray()
		for ignored_tick: int in 600:
			if bool(authority.terminal.ended):
				break
			var window := _window(authority, _action_for(authority, task_id))
			var result: Dictionary = authority.step_window(window)
			transcript.append(window.duplicate(true))
			hashes.append(str(result.state_hash))
			var receipt: Dictionary = result.receipts[PARTICIPANT_ID]
			_check(bool(receipt.accepted), "%s scripted direct action was rejected" % task_id)
			_check(int(receipt.applied_ticks) == 1, "%s did not use one-tick authority windows" % task_id)
			_check("no_input" not in receipt.codes, "%s unexpectedly used a neutral fallback" % task_id)
		_check(bool(authority.terminal.ended), "%s scripted demo did not terminate" % task_id)
		_check(str(authority.terminal.outcome) == "success", "%s scripted demo did not succeed" % task_id)
		_check(
			str(authority.terminal.reason) == EXPECTED_REASONS[task_id],
			"%s terminal reason drifted" % task_id,
		)
		_verify_replay(task_id, transcript, hashes, authority)
		summaries[task_id] = {
			"outcome": str(authority.terminal.outcome),
			"reason": str(authority.terminal.reason),
			"tick_count": hashes.size(),
		}
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("EMBODIMENT_SCRIPTED_SOLO_DEMO_FAILURE: %s" % failure)
		print("EMBODIMENT_SCRIPTED_SOLO_DEMO_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print(OUTPUT_PREFIX + JSON.stringify(summaries))
	print("EMBODIMENT_SCRIPTED_SOLO_DEMO_OK")
	quit(0)


func _config(task_id: String) -> Dictionary:
	return {
		"episode_id": "ep_scripted_%s" % task_id.trim_suffix("-v0"),
		"maximum_episode_ticks": 600,
		"mode": "solo-curriculum-v0",
		"observation_profile": "text-visible-v1",
		"participant_ids": [PARTICIPANT_ID],
		"task_id": task_id,
	}


func _action_for(authority: Object, task_id: String) -> Dictionary:
	var observation: Dictionary = authority.observe()
	var control: Dictionary = {}
	var label := ""
	match task_id:
		"orientation-v0":
			var beacon := _entity(observation, "v_beacon_1")
			if str(beacon.distance) == "touching":
				control = _control()
				label = "Demo: hold the visible beacon"
			else:
				var approach := _approach(beacon, "Demo: approach the visible beacon")
				control = approach.control
				label = approach.label
		"interaction-v0":
			var carrying := _carrying(observation)
			var target := _entity(observation, "v_relay_1" if carrying else "v_resource_1")
			if str(target.distance) == "touching" and str(target.bearing) == "front":
				control = _control(true)
				label = "Demo: deposit carried material" if carrying else "Demo: gather marked material"
			else:
				var approach := _approach(
					target,
					"Demo: return to the visible relay" if carrying else "Demo: approach marked material",
				)
				control = approach.control
				label = approach.label
		"neutral-encounter-v0":
			var pair := _neutral_action(observation)
			control = pair.control
			label = pair.label
		_:
			_fail("unsupported scripted task %s" % task_id)
			control = _control()
			label = "Demo: wait"
	return {
		"protocol_version": "llm-controller/0.1.0",
		"episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq,
		"action_id": "script_%s_%04d" % [task_id.trim_suffix("-v0"), authority.observation_seq],
		"control": control,
		"intent_label": label,
		"memory_update": "",
	}


func _neutral_action(observation: Dictionary) -> Dictionary:
	var neutral := _entity(observation, "v_neutral_1")
	var relay := _entity(observation, "v_relay_1")
	var state := _neutral_state(str(neutral.state))
	if state in SAFE_NEUTRAL_STATES:
		if str(relay.distance) == "touching" and str(relay.bearing) == "front":
			return {"control": _control(true), "label": "Demo: activate the now-safe relay"}
		return _approach(relay, "Demo: move to the now-safe relay", true)
	if str(neutral.distance) == "touching" and str(neutral.bearing) == "front":
		if "primary_cooldown" not in observation.self.status:
			return {
				"control": _control(false, false, false, false, 0, true, true),
				"label": "Demo: defend and strike the neutral",
			}
		return {"control": _control(false, false, false, false, 0, false, true), "label": "Demo: guard during primary cooldown"}
	return _approach(neutral, "Demo: approach the defending neutral", true)


func _approach(target: Dictionary, label: String, guard := false) -> Dictionary:
	var bearing := str(target.bearing)
	if bearing in TURN_RIGHT:
		return {"control": _control(false, false, false, false, 1000, false, guard), "label": label}
	if bearing in TURN_LEFT:
		return {"control": _control(false, false, false, false, -1000, false, guard), "label": label}
	if bearing == "front":
		return {"control": _control(false, true, false, false, 0, false, guard), "label": label}
	_fail("scripted demo received invalid visible bearing %s" % bearing)
	return {"control": _control(), "label": label}


func _control(
		interact := false,
		move_forward := false,
		_dash := false,
		_cancel := false,
		look_x := 0,
		primary := false,
		guard := false,
) -> Dictionary:
	var buttons := {}
	for button: String in BUTTON_NAMES:
		buttons[button] = false
	buttons.interact = interact
	buttons.primary = primary
	buttons.guard = guard
	return {
		"move_x": 0,
		"move_y": 1000 if move_forward else 0,
		"look_x": look_x,
		"look_y": 0,
		"duration_ticks": 1,
		"buttons": buttons,
	}


func _entity(observation: Dictionary, entity_id: String) -> Dictionary:
	for entity: Dictionary in observation.visible_entities:
		if str(entity.id) == entity_id:
			return entity
	_fail("scripted demo could not find visible entity %s" % entity_id)
	return {"bearing": "front", "distance": "far", "state": "invalid"}


func _carrying(observation: Dictionary) -> bool:
	for item: Dictionary in observation.self.inventory:
		if str(item.get("kind", "")) == "material" and int(item.get("count", 0)) > 0:
			return true
	return false


func _neutral_state(value: String) -> String:
	for state: String in ["idle", "chase", "telegraph", "attack", "retreat", "recovery", "defeated"]:
		if value == state or value.begins_with("%s_" % state):
			return state
	_fail("scripted demo received invalid neutral state %s" % value)
	return "idle"


func _window(authority: Object, action: Dictionary) -> Dictionary:
	return {
		"episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq,
		"mode": authority.mode,
		"start_tick": authority.tick,
		"duration_ticks": 1,
		"decisions": {PARTICIPANT_ID: {
			"disposition": "accepted",
			"action": action,
			"fallback": "none",
			"no_input_reason": null,
		}},
	}


func _verify_replay(
		task_id: String, transcript: Array[Dictionary], hashes: PackedStringArray, authority: Object
) -> void:
	var replay := Authority.new()
	var errors: PackedStringArray = replay.configure(_config(task_id))
	_check(errors.is_empty(), "%s replay configuration failed" % task_id)
	if not errors.is_empty():
		return
	for index: int in transcript.size():
		var result: Dictionary = replay.step_window(transcript[index])
		_check(
			str(result.state_hash) == hashes[index],
			"%s replay checkpoint drifted at observation %d" % [task_id, index],
		)
	_check(replay.checkpoint_hash() == authority.checkpoint_hash(), "%s replay final hash drifted" % task_id)
	_check(replay.terminal == authority.terminal, "%s replay terminal drifted" % task_id)


func _check(condition: bool, message: String) -> void:
	if not condition and message not in _failures:
		_failures.append(message)


func _fail(message: String) -> void:
	if message not in _failures:
		_failures.append(message)
