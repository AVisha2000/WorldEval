class_name PrimitiveSandboxDemoPolicy
extends RefCounted

## Credential-free deterministic policy. It emits the exact tagged decision
## responses used by provider adapters; it has no privileged authority access.

const PROTOCOL := "worldeval-agent/0.1.0"


static func run(authority) -> void:
	var calls: int = 0
	var aborted_unsafe_plan: bool = false
	while not authority.terminal and calls < 100:
		calls += 1
		var observation: Dictionary = authority.current_observation()
		var events: Array = _event_kinds(observation)
		var active: Variant = observation.get("active_plan")
		if active == null:
			if aborted_unsafe_plan:
				authority.respond(_replace(authority, "return-to-base", _return_steps(), null))
			else:
				authority.respond(_replace(authority, "approach-equip-chop", _tree_steps(), null))
			continue
		if events.has("hostile_near_target"):
			authority.respond({
				"type": "plan.abort",
				"plan_id": active["plan_id"],
				"source": authority.current_source(),
				"reason": "Hostile now occupies the protected target radius; retreat is required.",
			})
			aborted_unsafe_plan = true
			continue
		if events.has("movement_blocked"):
			authority.respond(_replace(authority, "explicit-barrier-detour", _detour_steps(), active["plan_id"]))
			continue
		authority.respond({
			"type": "plan.continue",
			"plan_id": active["plan_id"],
			"source": authority.current_source(),
			"lease_ticks": 3,
		})
	assert(authority.terminal, "deterministic Demo policy did not reach a terminal boundary")


static func _replace(authority, plan_id: String, steps: Array, replaces) -> Dictionary:
	return {
		"type": "plan.replace",
		"replaces_plan_id": replaces,
		"plan": {
			"schema_version": "action-plan.v1",
			"protocol": PROTOCOL,
			"plan_id": plan_id,
			"source": authority.current_source(),
			"lease_ticks": 3,
			"execution_policy": "confirm_each_boundary",
			"steps": steps,
			"abort_behavior": "cancel_current_action",
		},
	}


static func _tree_steps() -> Array:
	return [
		_step(
			"approach-tree",
			"move_to",
			{"target": {"object_id": "tree-7", "generation": 1}, "navigation": "direct_only"},
			[{"kind": "target_visible", "subject": "tree-7", "parameters": {}}],
			{"kind": "agent_at_target", "subject": "tree-7", "parameters": {}},
			["movement_blocked", "target_disappeared", "hostile_near_target"]
		),
		_step(
			"equip-axe",
			"equip",
			{"item": "axe"},
			[{"kind": "item_in_inventory", "subject": "worker-1", "parameters": {"item": "axe"}}],
			{"kind": "item_equipped", "subject": "worker-1", "parameters": {"item": "axe"}},
			["inventory_changed"]
		),
		_step(
			"chop-tree",
			"use_tool",
			{"tool": "axe", "target": {"object_id": "tree-7", "generation": 1}},
			[{"kind": "target_in_range", "subject": "tree-7", "parameters": {}}],
			{"kind": "object_destroyed", "subject": "tree-7", "parameters": {"generation": 1}},
			["target_disappeared", "hostile_near_target"]
		),
	]


static func _detour_steps() -> Array:
	return [
		_step(
			"waypoint-south",
			"move_to",
			{"target": {"position": {"x": 11, "y": 11}}, "navigation": "direct_only"},
			[],
			{"kind": "agent_at_coordinate", "subject": "worker-1", "parameters": {"x": 11, "y": 11}},
			["movement_blocked", "hostile_near_target"]
		),
		_step(
			"waypoint-past-barrier",
			"move_to",
			{"target": {"position": {"x": 14, "y": 11}}, "navigation": "direct_only"},
			[],
			{"kind": "agent_at_coordinate", "subject": "worker-1", "parameters": {"x": 14, "y": 11}},
			["movement_blocked", "hostile_near_target"]
		),
	]


static func _return_steps() -> Array:
	return [
		_step(
			"return-base",
			"move_to",
			{"target": {"object_id": "base-1", "generation": 1}, "navigation": "direct_only"},
			[{"kind": "target_visible", "subject": "base-1", "parameters": {}}],
			{"kind": "agent_at_target", "subject": "base-1", "parameters": {}},
			["movement_blocked", "health_threshold_crossed"]
		),
	]


static func _step(
	step_id: String,
	action: String,
	arguments: Dictionary,
	preconditions: Array,
	expected_completion: Dictionary,
	interrupt_on: Array,
) -> Dictionary:
	return {
		"step_id": step_id,
		"action": {"action": action, "arguments": arguments},
		"preconditions": preconditions,
		"expected_completion": expected_completion,
		"interrupt_on": interrupt_on,
	}


static func _event_kinds(observation: Dictionary) -> Array:
	var result: Array = []
	for event in observation["events"]:
		result.append(event["kind"])
	return result
