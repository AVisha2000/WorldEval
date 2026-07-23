class_name PrimitiveSandboxAuthority
extends RefCounted

## Godot is the gameplay authority for the semantic-grid Primitive Sandbox.
## It follows only the direct target or explicit waypoint selected by the agent.
## No pathfinding, detour selection, target substitution, or opaque skill execution
## exists in this class.

const PROTOCOL := "worldeval-agent/0.1.0"
const REPLAY_SCHEMA := "replay-bundle.v1"
const DEFAULT_DYNAMIC_PROFILE := {
	"schema_version": "decision-profile.v1",
	"protocol": PROTOCOL,
	"profile_id": "dynamic-step-locked-v1",
	"kind": "dynamic-step-locked",
	"minimum_ticks": 1,
	"maximum_ticks": 5,
	"default_ticks": 3,
	"simulation_pauses_during_inference": true,
	"observation_policy": "every_boundary",
	"interrupt_events": [
		"movement_blocked",
		"target_disappeared",
		"hostile_near_target",
		"inventory_changed",
		"health_threshold_crossed",
		"objective_revised",
		"plan_precondition_false",
	],
	"explicit_response_required": true,
	"missing_response_behavior": "neutral_noop",
}

var scenario: Dictionary = {}
var decision_profile: Dictionary = {}
var profile_interrupts: Dictionary = {}
var tick := 0
var agent: Dictionary = {}
var inventory: Array = []
var equipped = null
var objects: Dictionary = {}
var used_object_ids: Dictionary = {}
var fired_triggers: Dictionary = {}
var hostile_triggered := false
var hostile_attacks := 0
var forbidden_autonomy_count := 0
var path_distance := 0
var terminal := false
var outcome = null

var initialization_hash := ""
var initial_state_hash := ""
var initialization_acknowledged := false
var observation_seq := 0
var event_seq := 0
var receipt_seq := 0
var active_plan: Dictionary = {}
var plan_step_index := 0
var plan_status := ""
var interrupt_events: Array = []
var last_events: Array = []
var decision_reason := "initial"
var observations: Array = []
var receipts: Array = []
var decisions: Array = []


func configure(
	value: Dictionary,
	expected_initialization_hash: String = "",
	configured_decision_profile: Dictionary = {},
) -> void:
	_validate_scenario(value)
	var selected_profile: Dictionary = (
		DEFAULT_DYNAMIC_PROFILE.duplicate(true)
		if configured_decision_profile.is_empty()
		else configured_decision_profile.duplicate(true)
	)
	_validate_decision_profile(selected_profile)
	scenario = _integerize(value)
	decision_profile = _integerize(selected_profile)
	profile_interrupts = {}
	for event_kind in decision_profile["interrupt_events"]:
		profile_interrupts[event_kind] = true
	tick = 0
	agent = scenario["agent"].duplicate(true)
	inventory = agent["inventory"].duplicate(true)
	agent.erase("inventory")
	equipped = null
	objects = {}
	used_object_ids = {}
	for item in scenario["objects"]:
		_spawn_object(item)
	fired_triggers = {}
	hostile_triggered = false
	hostile_attacks = 0
	forbidden_autonomy_count = 0
	path_distance = 0
	terminal = false
	outcome = null
	observation_seq = 0
	event_seq = 0
	receipt_seq = 0
	active_plan = {}
	plan_step_index = 0
	plan_status = ""
	interrupt_events = []
	last_events = []
	decision_reason = "initial"
	observations = []
	receipts = []
	decisions = []
	initialization_acknowledged = false
	initialization_hash = expected_initialization_hash if not expected_initialization_hash.is_empty() else _hash_value({
		"protocol": PROTOCOL,
		"scenario": scenario,
	})
	initial_state_hash = state_hash()
	_record_observation()


func acknowledge_initialization(value: String) -> bool:
	initialization_acknowledged = value == initialization_hash
	return initialization_acknowledged


func current_source() -> Dictionary:
	return {
		"observation_seq": observation_seq,
		"tick": tick,
		"state_hash": state_hash(),
	}


func current_observation() -> Dictionary:
	return observations[-1].duplicate(true)


func decision_contract_status(response) -> Dictionary:
	var schema_valid := response is Dictionary and _valid_response_envelope(response)
	return {
		"schema_valid": schema_valid,
		"contract_admissible": schema_valid and _response_contract_admissible(response),
	}


func respond(response, missing_reason: String = "missing") -> Dictionary:
	assert(initialization_acknowledged, "environment initialization must be acknowledged")
	var schema_valid := response is Dictionary and _valid_response_envelope(response)
	var normalized_decision = _integerize(response) if schema_valid else null
	decisions.append(normalized_decision.duplicate(true) if normalized_decision is Dictionary else null)
	var source := current_source()
	var receipt: Dictionary
	var execution = null
	if response == null:
		receipt = _neutral_receipt(source, _normalize_missing_reason(missing_reason), null)
	elif not schema_valid:
		receipt = _neutral_receipt(source, "invalid", null)
	else:
		var response_type: String = response["type"]
		var supplied_source = response["plan"].get("source") if response_type == "plan.replace" else response.get("source")
		var stale_reason := _stale_reason(supplied_source, source)
		if not stale_reason.is_empty():
			receipt = _neutral_receipt(source, stale_reason, response_type)
		elif response_type == "plan.replace":
			var replacement := _replace_plan(response, source)
			receipt = replacement["receipt"]
			execution = replacement.get("execution")
		elif response_type == "plan.continue":
			var continuation := _continue_plan(response, source)
			receipt = continuation["receipt"]
			execution = continuation.get("execution")
		elif response_type == "plan.abort":
			receipt = _abort_plan(response, source)
		elif response_type == "wait":
			var wait_ticks: int = int(response["maximum_ticks"])
			if not _lease_allowed(wait_ticks):
				receipt = _rejected_receipt(source, response_type, "invalid_wait")
			else:
				receipt = _accepted_receipt(source, response_type, _active_plan_id(), null)
				execution = _execute_action("wait", {}, wait_ticks)
		else:
			receipt = _neutral_receipt(source, "invalid", response_type)

	if execution != null:
		receipt["end_tick"] = execution["end_tick"]
		receipt["applied_ticks"] = execution["applied_ticks"]
		for code in execution["codes"]:
			if not receipt["codes"].has(code):
				receipt["codes"].append(code)
		receipt["codes"].sort()
		receipt["effects"] = execution["effects"].duplicate(true)
		last_events = execution["events"].duplicate(true)
		_record_boundary(execution)
		if terminal:
			decision_reason = "terminal"
		elif not interrupt_events.is_empty():
			decision_reason = "interrupt"
		elif execution["completed"]:
			decision_reason = "step_boundary"
		else:
			decision_reason = "lease_expired"
	else:
		last_events = []
		decision_reason = "terminal" if terminal else "step_boundary"
	receipts.append(receipt.duplicate(true))
	observation_seq += 1
	_record_observation()
	return {"receipt": receipt.duplicate(true), "observation": current_observation()}


func state_payload() -> Dictionary:
	var live_objects: Array = []
	var object_ids := objects.keys()
	object_ids.sort()
	for object_id in object_ids:
		live_objects.append(objects[object_id].duplicate(true))
	var triggers := fired_triggers.keys()
	triggers.sort()
	return {
		"tick": tick,
		"agent": {
			"object_id": agent["object_id"],
			"generation": agent["generation"],
			"position": agent["position"].duplicate(true),
			"inventory": inventory.duplicate(true),
			"equipped": equipped,
		},
		"objects": live_objects,
		"fired_triggers": triggers,
		"forbidden_autonomy_count": forbidden_autonomy_count,
		"hostile_attacks": hostile_attacks,
		"terminal": terminal,
		"outcome": outcome,
	}


func state_hash() -> String:
	return _hash_value(state_payload())


func native_replay(run_id: String, offline_verified := false) -> Dictionary:
	return {
		"schema_version": REPLAY_SCHEMA,
		"protocol": PROTOCOL,
		"run_id": run_id,
		"environment_id": scenario["environment_id"],
		"scenario_id": scenario["scenario_id"],
		"initialization_hash": initialization_hash,
		"initial_state_hash": initial_state_hash,
		"terminal_state_hash": state_hash(),
		"terminal_outcome": outcome if outcome != null else "incomplete",
		"terminal_tick": tick,
		"authority_metrics": {
			"forbidden_autonomy_count": forbidden_autonomy_count,
			"hostile_attacks": hostile_attacks,
		},
		"observations": observations.duplicate(true),
		"decisions": decisions.duplicate(true),
		"receipts": receipts.duplicate(true),
		"provider_calls": 0,
		"offline_verified": offline_verified,
	}


func _replace_plan(response: Dictionary, source: Dictionary) -> Dictionary:
	var replaces = response.get("replaces_plan_id")
	if not active_plan.is_empty() and replaces != active_plan["plan_id"]:
		return {"receipt": _rejected_receipt(source, response["type"], "replacement_plan_mismatch")}
	if active_plan.is_empty() and replaces != null:
		return {"receipt": _rejected_receipt(source, response["type"], "no_plan_to_replace")}
	var plan: Dictionary = response["plan"]
	if not _valid_plan(plan):
		return {"receipt": _rejected_receipt(source, response["type"], "invalid_plan")}
	active_plan = plan.duplicate(true)
	plan_step_index = 0
	plan_status = "active"
	interrupt_events = []
	var authorization := _authorize_current_step(int(plan["lease_ticks"]), source, response["type"])
	return authorization


func _continue_plan(response: Dictionary, source: Dictionary) -> Dictionary:
	if active_plan.is_empty() or response["plan_id"] != active_plan["plan_id"]:
		return {"receipt": _rejected_receipt(source, response["type"], "unknown_plan")}
	if plan_status == "revoked":
		return {"receipt": _rejected_receipt(source, response["type"], "plan_revoked")}
	if plan_step_index >= active_plan["steps"].size():
		return {"receipt": _rejected_receipt(source, response["type"], "plan_complete")}
	var lease_ticks: int = int(response["lease_ticks"])
	if not _lease_allowed(lease_ticks):
		return {"receipt": _rejected_receipt(source, response["type"], "invalid_continuation")}
	plan_status = "active"
	interrupt_events = []
	return _authorize_current_step(lease_ticks, source, response["type"])


func _authorize_current_step(lease_ticks: int, source: Dictionary, response_type: String) -> Dictionary:
	var step: Dictionary = active_plan["steps"][plan_step_index]
	if not _preconditions_hold(step):
		plan_status = "suspended"
		interrupt_events = ["plan_precondition_false"]
		return {"receipt": _rejected_receipt(source, response_type, "plan_precondition_false")}
	var action_call: Dictionary = step["action"]
	var receipt := _accepted_receipt(source, response_type, active_plan["plan_id"], step["step_id"])
	return {
		"receipt": receipt,
		"execution": _execute_action(action_call["action"], action_call["arguments"], lease_ticks),
	}


func _abort_plan(response: Dictionary, source: Dictionary) -> Dictionary:
	if active_plan.is_empty() or response["plan_id"] != active_plan["plan_id"]:
		return _rejected_receipt(source, response["type"], "unknown_plan")
	var plan_id = active_plan["plan_id"]
	var step_id = null
	if plan_step_index < active_plan["steps"].size():
		step_id = active_plan["steps"][plan_step_index]["step_id"]
	active_plan = {}
	plan_step_index = 0
	plan_status = ""
	interrupt_events = []
	return _accepted_receipt(source, response["type"], plan_id, step_id)


func _record_boundary(execution: Dictionary) -> void:
	if active_plan.is_empty():
		return
	var material: Array = []
	for event in execution["events"]:
		if _is_material_interrupt(event["kind"]):
			material.append(event["kind"])
	if not material.is_empty():
		interrupt_events = []
		for event_kind in material:
			if not interrupt_events.has(event_kind):
				interrupt_events.append(event_kind)
		interrupt_events.sort()
		plan_status = "revoked" if interrupt_events.has("hostile_near_target") or interrupt_events.has("target_disappeared") or interrupt_events.has("objective_revised") else "suspended"
		return
	if execution["completed"]:
		plan_step_index += 1
		plan_status = "awaiting_confirmation"
	elif execution["applied_ticks"] > 0:
		plan_status = "awaiting_confirmation"


func _execute_action(action: String, arguments: Dictionary, maximum_ticks: int) -> Dictionary:
	var start_tick := tick
	var codes: Array = []
	var effects: Array = []
	var events: Array = []
	var completed := false
	if terminal:
		return _execution(start_tick, true, ["episode_terminal"], [], [])
	if action == "move_to":
		var resolved := _resolve_target(arguments.get("target", {}))
		if not resolved["ok"]:
			codes.append("target_missing")
			events.append(_event("target_disappeared", resolved.get("object_id"), {}))
		else:
			var target: Dictionary = resolved["position"]
			for _index in range(maximum_ticks):
				if _same_position(agent["position"], target):
					completed = true
					codes.append("target_reached")
					break
				tick += 1
				_fire_triggers(events)
				var next_position := _direct_step(agent["position"], target)
				var blocker := _blocking_object(next_position)
				if not blocker.is_empty():
					codes.append("movement_blocked")
					events.append(_event("movement_blocked", blocker["object_id"], {"at": next_position}))
					break
				var old_position: Dictionary = agent["position"].duplicate(true)
				agent["position"] = next_position
				path_distance += 1
				effects.append({"kind": "agent_moved", "object_id": agent["object_id"], "data": {"from": old_position, "to": next_position.duplicate(true)}})
				_fire_triggers(events)
				_check_terminal()
				if terminal or _has_material_event(events):
					if _has_material_event(events) and not codes.has("material_interrupt"):
						codes.append("material_interrupt")
					break
			if _same_position(agent["position"], target):
				completed = true
				if not codes.has("target_reached"):
					codes.append("target_reached")
			elif codes.is_empty():
				codes.append("lease_expired")
	elif action == "equip":
		tick += 1
		var item = arguments.get("item")
		if not inventory.has(item):
			codes.append("item_unavailable")
		else:
			equipped = item
			completed = true
			codes.append("item_equipped")
			effects.append({"kind": "item_equipped", "object_id": agent["object_id"], "data": {"item": item}})
		_fire_triggers(events)
	elif action == "use_tool":
		tick += 1
		var target_ref: Dictionary = arguments.get("target", {})
		var target_id: String = str(target_ref.get("object_id", ""))
		if not objects.has(target_id) or (target_ref.has("generation") and int(target_ref["generation"]) != int(objects[target_id]["generation"])):
			codes.append("target_missing")
			events.append(_event("target_disappeared", target_id, {}))
		else:
			var target_object: Dictionary = objects[target_id]
			if equipped != arguments.get("tool"):
				codes.append("tool_not_equipped")
			elif _distance(agent["position"], target_object["position"]) > 1:
				codes.append("target_out_of_range")
			elif target_object["type_id"] == "tree" and arguments.get("tool") == "axe":
				objects.erase(target_id)
				completed = true
				codes.append("target_destroyed")
				effects.append({"kind": "object_despawned", "object_id": target_id, "data": {"generation": target_object["generation"]}})
			elif target_object["type_id"] == "enemy":
				hostile_attacks += 1
				codes.append("forbidden_hostile_attack")
			else:
				codes.append("tool_has_no_effect")
		_fire_triggers(events)
		_check_terminal()
	elif action == "wait" or action == "cancel":
		var wait_ticks := maximum_ticks if action == "wait" else 1
		for _index in range(wait_ticks):
			tick += 1
			_fire_triggers(events)
			_check_terminal()
			if terminal or _has_material_event(events):
				break
		completed = true
		codes.append("wait_complete" if action == "wait" else "action_cancelled")
	else:
		codes.append("unknown_action")
	_check_terminal()
	return _execution(start_tick, completed, codes, effects, events)


func _execution(start_tick: int, completed: bool, codes: Array, effects: Array, events: Array) -> Dictionary:
	return {
		"start_tick": start_tick,
		"end_tick": tick,
		"applied_ticks": tick - start_tick,
		"completed": completed,
		"codes": codes,
		"effects": effects,
		"events": events,
	}


func _resolve_target(target: Dictionary) -> Dictionary:
	if target.has("position") and target["position"] is Dictionary:
		return {"ok": true, "position": target["position"].duplicate(true)}
	var object_id: String = str(target.get("object_id", ""))
	if not objects.has(object_id):
		return {"ok": false, "object_id": object_id}
	if target.has("generation") and int(target["generation"]) != int(objects[object_id]["generation"]):
		return {"ok": false, "object_id": object_id}
	return {"ok": true, "position": objects[object_id]["position"].duplicate(true)}


func _direct_step(current: Dictionary, target: Dictionary) -> Dictionary:
	var dx: int = int(target["x"]) - int(current["x"])
	var dy: int = int(target["y"]) - int(current["y"])
	if absi(dx) >= absi(dy) and dx != 0:
		return {"x": int(current["x"]) + (1 if dx > 0 else -1), "y": int(current["y"])}
	if dy != 0:
		return {"x": int(current["x"]), "y": int(current["y"]) + (1 if dy > 0 else -1)}
	return current.duplicate(true)


func _blocking_object(position: Dictionary) -> Dictionary:
	for value in objects.values():
		if _same_position(value["position"], position) and value["state"].get("blocks_movement") == true:
			return value
	return {}


func _fire_triggers(events: Array) -> void:
	for trigger in scenario["triggers"]:
		if fired_triggers.has(trigger["trigger_id"]) or int(agent["position"]["x"]) < int(trigger["threshold_x"]):
			continue
		_spawn_object(trigger["object"])
		fired_triggers[trigger["trigger_id"]] = true
		if trigger["kind"] == "spawn_barrier_after_x":
			events.append(_event("barrier_appeared", trigger["object"]["object_id"], {}))
		else:
			hostile_triggered = true
			events.append(_event("hostile_near_target", trigger["object"]["object_id"], {}))


func _check_terminal() -> void:
	if tick >= int(scenario["tick_budget"]):
		terminal = true
		outcome = "timeout"
		return
	var tree_exists := objects.has("tree-7")
	if scenario["expected_outcome"] == "tree_destroyed" and not tree_exists:
		terminal = true
		outcome = "tree_destroyed"
	elif scenario["expected_outcome"] == "safe_return" and hostile_triggered and _same_position(agent["position"], scenario["base_position"]):
		terminal = true
		outcome = "safe_return" if tree_exists and hostile_attacks == 0 else "unsafe_return"


func _preconditions_hold(step: Dictionary) -> bool:
	for predicate in step.get("preconditions", []):
		var kind: String = str(predicate.get("kind", ""))
		var subject: String = str(predicate.get("subject", ""))
		if kind == "target_visible" and not objects.has(subject):
			return false
		if kind == "item_in_inventory" and not inventory.has(predicate.get("parameters", {}).get("item")):
			return false
		if kind == "target_in_range":
			if not objects.has(subject) or _distance(agent["position"], objects[subject]["position"]) > 1:
				return false
	return true


func _valid_response_envelope(response: Dictionary) -> bool:
	if not response.has("type") or not response["type"] is String:
		return false
	var response_type: String = response["type"]
	if response_type == "plan.replace":
		return (
			_has_exact_keys(response, ["type", "replaces_plan_id", "plan"])
			and (
				response["replaces_plan_id"] == null
				or _is_identifier(response["replaces_plan_id"])
			)
			and response["plan"] is Dictionary
			and _valid_plan_wire(response["plan"])
		)
	if response_type == "plan.continue":
		return (
			_has_exact_keys(response, ["type", "plan_id", "source", "lease_ticks"])
			and _is_identifier(response["plan_id"])
			and _valid_source(response["source"])
			and _is_json_integer_in_range(response["lease_ticks"], 1, 50)
		)
	if response_type == "plan.abort":
		return (
			_has_exact_keys(response, ["type", "plan_id", "source", "reason"])
			and _is_identifier(response["plan_id"])
			and _valid_source(response["source"])
			and response["reason"] is String
			and not response["reason"].is_empty()
			and response["reason"].length() <= 500
		)
	if response_type == "wait":
		if not (
			_has_exact_keys(response, ["type", "source", "maximum_ticks", "until"])
			and _valid_source(response["source"])
			and _is_json_integer_in_range(response["maximum_ticks"], 1, 50)
			and response["until"] is Array
			and response["until"].size() <= 32
		):
			return false
		for event_kind in response["until"]:
			if not _is_identifier(event_kind):
				return false
		return true
	return false


func _valid_plan(plan: Dictionary) -> bool:
	if not _valid_plan_wire(plan) or not _lease_allowed(int(plan["lease_ticks"])):
		return false
	for step in plan["steps"]:
		if not _valid_action_arguments(step["action"]):
			return false
	return true


func _valid_plan_wire(plan: Dictionary) -> bool:
	if not _has_exact_keys(
		plan,
		[
			"schema_version",
			"protocol",
			"plan_id",
			"source",
			"lease_ticks",
			"execution_policy",
			"steps",
			"abort_behavior",
		],
	):
		return false
	if (
		plan["schema_version"] != "action-plan.v1"
		or plan["protocol"] != PROTOCOL
		or not _is_identifier(plan["plan_id"])
		or not _valid_source(plan["source"])
		or not _is_json_integer_in_range(plan["lease_ticks"], 1, 50)
		or plan["execution_policy"] != "confirm_each_boundary"
		or not plan["steps"] is Array
		or plan["steps"].is_empty()
		or plan["steps"].size() > 64
		or not plan["abort_behavior"] in ["neutral", "cancel_current_action"]
	):
		return false
	var step_ids: Dictionary = {}
	for step in plan["steps"]:
		if not step is Dictionary or not _valid_plan_step(step):
			return false
		if step_ids.has(step["step_id"]):
			return false
		step_ids[step["step_id"]] = true
	return true


func _valid_plan_step(step: Dictionary) -> bool:
	if not _has_exact_keys(
		step,
		["step_id", "action", "preconditions", "expected_completion", "interrupt_on"],
	):
		return false
	if (
		not _is_identifier(step["step_id"])
		or not step["action"] is Dictionary
		or not _has_exact_keys(step["action"], ["action", "arguments"])
		or not _is_identifier(step["action"]["action"])
		or not step["action"]["arguments"] is Dictionary
		or not step["preconditions"] is Array
		or step["preconditions"].size() > 32
		or not step["expected_completion"] is Dictionary
		or not _valid_predicate(step["expected_completion"])
		or not step["interrupt_on"] is Array
		or step["interrupt_on"].size() > 64
	):
		return false
	for predicate in step["preconditions"]:
		if not predicate is Dictionary or not _valid_predicate(predicate):
			return false
	for event_kind in step["interrupt_on"]:
		if not _is_identifier(event_kind):
			return false
	return true


func _valid_predicate(predicate: Dictionary) -> bool:
	return (
		_has_exact_keys(predicate, ["kind", "subject", "parameters"])
		and _is_identifier(predicate["kind"])
		and (predicate["subject"] == null or _is_identifier(predicate["subject"]))
		and predicate["parameters"] is Dictionary
	)


func _valid_source(source) -> bool:
	return (
		source is Dictionary
		and _has_exact_keys(source, ["observation_seq", "tick", "state_hash"])
		and _is_json_integer_in_range(source["observation_seq"], 0, 9223372036854775807)
		and _is_json_integer_in_range(source["tick"], 0, 9223372036854775807)
		and _is_sha256_hash(source["state_hash"])
	)


func _response_contract_admissible(response: Dictionary) -> bool:
	if not _valid_response_envelope(response):
		return false
	if response["type"] == "plan.replace":
		return _valid_plan(response["plan"])
	if response["type"] == "plan.continue":
		return _lease_allowed(int(response["lease_ticks"]))
	if response["type"] == "wait":
		return _lease_allowed(int(response["maximum_ticks"]))
	return true


func _valid_action_arguments(call: Dictionary) -> bool:
	var action: String = call["action"]
	var arguments: Dictionary = call["arguments"]
	if action == "move_to":
		return (
			_has_exact_keys(arguments, ["target", "navigation"])
			and arguments["navigation"] == "direct_only"
			and _valid_move_target(arguments["target"])
		)
	if action == "equip":
		return (
			_has_exact_keys(arguments, ["item"])
			and arguments["item"] in ["axe", "pickaxe"]
		)
	if action == "use_tool":
		return (
			_has_exact_keys(arguments, ["tool", "target"])
			and arguments["tool"] in ["axe", "pickaxe"]
			and _valid_object_target(arguments["target"])
		)
	if action == "wait" or action == "cancel":
		return arguments.is_empty()
	return false


func _valid_move_target(target) -> bool:
	if not target is Dictionary:
		return false
	if _has_exact_keys(target, ["position"]):
		var position = target["position"]
		return (
			position is Dictionary
			and _has_exact_keys(position, ["x", "y"])
			and _is_json_integer(position["x"])
			and _is_json_integer(position["y"])
		)
	return _valid_object_target(target)


func _valid_object_target(target) -> bool:
	return (
		target is Dictionary
		and _has_exact_keys(target, ["object_id", "generation"])
		and target["object_id"] is String
		and _is_json_integer_in_range(target["generation"], 1, 9223372036854775807)
	)


func _lease_allowed(value: int) -> bool:
	return (
		value >= int(decision_profile["minimum_ticks"])
		and value <= int(decision_profile["maximum_ticks"])
	)


func _stale_reason(supplied, actual: Dictionary) -> String:
	if not supplied is Dictionary:
		return "invalid"
	if supplied.get("observation_seq") != actual["observation_seq"]:
		return "stale_observation"
	if supplied.get("tick") != actual["tick"]:
		return "stale_tick"
	if supplied.get("state_hash") != actual["state_hash"]:
		return "stale_state"
	return ""


func _record_observation() -> void:
	var live_objects: Array = []
	var ids := objects.keys()
	ids.sort()
	for object_id in ids:
		live_objects.append(objects[object_id].duplicate(true))
	var controlled := agent.duplicate(true)
	controlled["state"] = controlled.get("state", {}).duplicate(true)
	controlled["state"]["inventory"] = inventory.duplicate(true)
	controlled["state"]["equipped"] = equipped
	var active_summary = null
	if not active_plan.is_empty():
		var step_id = null
		if plan_step_index < active_plan["steps"].size():
			step_id = active_plan["steps"][plan_step_index]["step_id"]
		active_summary = {"plan_id": active_plan["plan_id"], "step_id": step_id, "status": plan_status}
	var allowed: Array = [] if terminal else ["plan.continue", "plan.replace", "plan.abort", "wait"]
	observations.append({
		"schema_version": "observation.v1",
		"protocol": PROTOCOL,
		"environment_id": scenario["environment_id"],
		"session_id": scenario["session_id"],
		"observation_seq": observation_seq,
		"tick": tick,
		"state_hash": state_hash(),
		"coordinate_frame": scenario["coordinate_frame"],
		"controlled_assets": [controlled],
		"visible_objects": live_objects,
		"events": last_events.duplicate(true),
		"active_plan": active_summary,
		"decision_required": {
			"reason": decision_reason,
			"allowed_responses": allowed,
			"interrupt_events": interrupt_events.duplicate(true),
		},
		"terminal": terminal,
	})


func _accepted_receipt(source: Dictionary, response_type: String, plan_id, step_id) -> Dictionary:
	receipt_seq += 1
	return {
		"schema_version": "action-receipt.v1",
		"protocol": PROTOCOL,
		"receipt_id": "decision-%06d" % receipt_seq,
		"observation_seq": source["observation_seq"],
		"response_type": response_type,
		"plan_id": plan_id,
		"step_id": step_id,
		"accepted": true,
		"disposition": "accepted",
		"fallback": "none",
		"no_input_reason": null,
		"start_tick": source["tick"],
		"end_tick": source["tick"],
		"applied_ticks": 0,
		"codes": ["decision_accepted"],
		"effects": [],
	}


func _neutral_receipt(source: Dictionary, reason: String, response_type) -> Dictionary:
	receipt_seq += 1
	return {
		"schema_version": "action-receipt.v1",
		"protocol": PROTOCOL,
		"receipt_id": "decision-%06d" % receipt_seq,
		"observation_seq": source["observation_seq"],
		"response_type": response_type,
		"plan_id": _active_plan_id(),
		"step_id": _active_step_id(),
		"accepted": false,
		"disposition": "no_input",
		"fallback": "neutral",
		"no_input_reason": reason,
		"start_tick": source["tick"],
		"end_tick": source["tick"],
		"applied_ticks": 0,
		"codes": ["neutral_noop"],
		"effects": [],
	}


func _rejected_receipt(source: Dictionary, response_type: String, code: String) -> Dictionary:
	receipt_seq += 1
	return {
		"schema_version": "action-receipt.v1",
		"protocol": PROTOCOL,
		"receipt_id": "decision-%06d" % receipt_seq,
		"observation_seq": source["observation_seq"],
		"response_type": response_type,
		"plan_id": _active_plan_id(),
		"step_id": _active_step_id(),
		"accepted": false,
		"disposition": "rejected",
		"fallback": "none",
		"no_input_reason": null,
		"start_tick": source["tick"],
		"end_tick": source["tick"],
		"applied_ticks": 0,
		"codes": [code],
		"effects": [],
	}


func _active_plan_id():
	return null if active_plan.is_empty() else active_plan["plan_id"]


func _active_step_id():
	if active_plan.is_empty() or plan_step_index >= active_plan["steps"].size():
		return null
	return active_plan["steps"][plan_step_index]["step_id"]


func _event(kind: String, object_id, data: Dictionary) -> Dictionary:
	event_seq += 1
	return {"event_id": "event-%06d" % event_seq, "kind": kind, "object_id": object_id, "data": data}


func _spawn_object(value: Dictionary) -> void:
	var object_id: String = value["object_id"]
	assert(not used_object_ids.has(object_id), "object IDs cannot be reused")
	used_object_ids[object_id] = true
	objects[object_id] = value.duplicate(true)


func _has_material_event(events: Array) -> bool:
	for event in events:
		if _is_material_interrupt(event["kind"]):
			return true
	return false


func _is_material_interrupt(event_kind: String) -> bool:
	return profile_interrupts.has(event_kind)


func _normalize_missing_reason(value: String) -> String:
	return value if value in ["missing", "invalid", "timeout"] else "invalid"


func _has_exact_keys(value: Dictionary, expected: Array) -> bool:
	if value.size() != expected.size():
		return false
	for key in expected:
		if not value.has(key):
			return false
	return true


func _is_identifier(value) -> bool:
	if not value is String or value.is_empty() or value.length() > 128:
		return false
	for index in range(value.length()):
		var code: int = value.unicode_at(index)
		var is_alphanumeric := (
			(code >= 48 and code <= 57)
			or (code >= 65 and code <= 90)
			or (code >= 97 and code <= 122)
		)
		if not is_alphanumeric and (index == 0 or not code in [45, 46, 95]):
			return false
	return true


func _is_sha256_hash(value) -> bool:
	if not value is String or value.length() != 71 or not value.begins_with("sha256:"):
		return false
	for index in range(7, 71):
		var code: int = value.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 97 and code <= 102)):
			return false
	return true


func _is_json_integer(value) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	return typeof(value) == TYPE_FLOAT and value == floor(value)


func _is_json_integer_in_range(value, minimum: int, maximum: int) -> bool:
	if not _is_json_integer(value):
		return false
	var integer_value := int(value)
	return integer_value >= minimum and integer_value <= maximum


func _distance(left: Dictionary, right: Dictionary) -> int:
	return absi(int(left["x"]) - int(right["x"])) + absi(int(left["y"]) - int(right["y"]))


func _same_position(left: Dictionary, right: Dictionary) -> bool:
	return int(left.get("x", -1)) == int(right.get("x", -2)) and int(left.get("y", -1)) == int(right.get("y", -2))


func _hash_value(value) -> String:
	return "sha256:" + JSON.stringify(value, "", true, false).sha256_text()


func _integerize(value):
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value.keys():
			result[key] = _integerize(value[key])
		return result
	if value is Array:
		var result: Array = []
		for child in value:
			result.append(_integerize(child))
		return result
	if typeof(value) == TYPE_FLOAT:
		assert(value == floor(value), "sandbox JSON numbers must be integers")
		return int(value)
	return value


func _validate_scenario(value: Dictionary) -> void:
	assert(value.get("schema_version") == "primitive-grid-scenario.v1")
	assert(value.get("environment_id") == "worldarena-primitive-sandbox-v0")
	assert(int(value.get("width", 0)) == 30 and int(value.get("height", 0)) == 25)
	assert(value.get("coordinate_frame") == "world_grid")
	assert(int(value.get("tick_budget", 0)) == 200)
	assert(value.get("expected_outcome") in ["tree_destroyed", "safe_return"])
	assert(value.get("agent") is Dictionary and value.get("objects") is Array and value.get("triggers") is Array)


func _validate_decision_profile(value: Dictionary) -> void:
	var expected_keys := [
		"schema_version",
		"protocol",
		"profile_id",
		"kind",
		"minimum_ticks",
		"maximum_ticks",
		"default_ticks",
		"simulation_pauses_during_inference",
		"observation_policy",
		"interrupt_events",
		"explicit_response_required",
		"missing_response_behavior",
	]
	assert(_has_exact_keys(value, expected_keys), "decision profile fields are not exact")
	assert(value["schema_version"] == "decision-profile.v1")
	assert(value["protocol"] == PROTOCOL)
	assert(_is_identifier(value["profile_id"]))
	assert(value["minimum_ticks"] == 1)
	assert(value["simulation_pauses_during_inference"] == true)
	assert(value["explicit_response_required"] == true)
	assert(value["missing_response_behavior"] == "neutral_noop")
	assert(value["interrupt_events"] is Array)
	assert(not value["interrupt_events"].is_empty() and value["interrupt_events"].size() <= 64)
	var unique_interrupts: Dictionary = {}
	for event_kind in value["interrupt_events"]:
		assert(_is_identifier(event_kind))
		assert(not unique_interrupts.has(event_kind), "decision profile interrupts must be unique")
		unique_interrupts[event_kind] = true
	if value["kind"] == "dynamic-step-locked":
		assert(value["maximum_ticks"] == 5)
		assert(value["default_ticks"] == 3)
		assert(value["observation_policy"] == "every_boundary")
	elif value["kind"] == "static-event-gated":
		assert(value["maximum_ticks"] == 50)
		assert(_is_json_integer_in_range(value["default_ticks"], 1, 50))
		assert(value["observation_policy"] == "event_or_lease_expiry")
	else:
		assert(false, "unknown decision profile kind")
