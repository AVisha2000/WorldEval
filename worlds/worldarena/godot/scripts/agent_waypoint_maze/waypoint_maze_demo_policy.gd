class_name WaypointMazeDemoPolicy
extends RefCounted

## Credential-free agent-side policy used by the accepted deterministic demo.
## It expands a declarative skill from the player-visible observation into
## ordinary move_to plan steps. There is no execute_skill world command.

const PROTOCOL := "worldeval-agent/0.1.0"


static func run(authority, skill_manifest: Dictionary) -> Dictionary:
	assert(skill_manifest.get("execution") == "agent_expands_to_visible_actions")
	assert(skill_manifest.get("suggested_actions") == ["move_to"])
	assert(
		skill_manifest.get("compatible_action_profiles", []).has("semantic-grid-actions-v1")
	)
	var initial_observation: Dictionary = authority.current_observation()
	var markers := _ordered_route_markers(initial_observation)
	assert(markers.size() == 5, "all five ordered route markers must be visible")
	var steps: Array = []
	for marker in markers:
		steps.append(_move_step(marker))
	var plan_id := "skill-expanded-visible-waypoint-route"
	var calls := 0
	while not authority.terminal and calls < 16:
		calls += 1
		var active = authority.current_observation().get("active_plan")
		if active == null:
			authority.respond(_replace(authority, plan_id, steps))
		else:
			authority.respond(
				{
					"type": "plan.continue",
					"plan_id": active["plan_id"],
					"source": authority.current_source(),
					"lease_ticks": 50,
				}
			)
	assert(authority.terminal, "waypoint Demo agent did not reach a terminal boundary")
	return {
		"schema_version": "skill-expansion-evidence.v1",
		"skill_id": skill_manifest["skill_id"],
		"execution": skill_manifest["execution"],
		"source_observation_seq": initial_observation["observation_seq"],
		"source_state_hash": initial_observation["state_hash"],
		"expanded_plan_id": plan_id,
		"expanded_steps": steps.duplicate(true),
		"decision_calls": calls,
	}


static func _ordered_route_markers(observation: Dictionary) -> Array:
	var markers: Array = []
	for item in observation["visible_objects"]:
		if not item.get("affordances", []).has("ordered_route_marker"):
			continue
		markers.append(item.duplicate(true))
	markers.sort_custom(
		func(left: Dictionary, right: Dictionary) -> bool:
			return int(left["state"]["order"]) < int(right["state"]["order"])
	)
	return markers


static func _replace(authority, plan_id: String, steps: Array) -> Dictionary:
	return {
		"type": "plan.replace",
		"replaces_plan_id": null,
		"plan": {
			"schema_version": "action-plan.v1",
			"protocol": PROTOCOL,
			"plan_id": plan_id,
			"source": authority.current_source(),
			"lease_ticks": 50,
			"execution_policy": "confirm_each_boundary",
			"steps": steps,
			"abort_behavior": "cancel_current_action",
		},
	}


static func _move_step(marker: Dictionary) -> Dictionary:
	var object_id: String = marker["object_id"]
	return {
		"step_id": "visit-%s" % object_id,
		"action": {
			"action": "move_to",
			"arguments": {
				"target": {"object_id": object_id, "generation": marker["generation"]},
				"navigation": "direct_only",
			},
		},
		"preconditions": [
			{"kind": "target_visible", "subject": object_id, "parameters": {"generation": marker["generation"]}},
		],
		"expected_completion": {
			"kind": "agent_at_target",
			"subject": object_id,
			"parameters": {},
		},
		"interrupt_on": ["waypoint_reached", "movement_blocked", "target_disappeared"],
	}
