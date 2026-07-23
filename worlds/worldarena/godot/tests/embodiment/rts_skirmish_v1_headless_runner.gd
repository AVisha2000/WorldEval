extends SceneTree

const Authority := preload("res://scripts/embodiment/rts_skirmish/rts_skirmish_v1_authority.gd")
const TaskPlan := preload("res://scripts/embodiment/rts_skirmish/rts_v1_task_plan_contract.gd")

var failures := PackedStringArray()


func _init() -> void:
	var authority = Authority.new()
	var errors := authority.configure({"protocol_version": "llm-controller/0.2.0", "task_id": "rts-skirmish-v1", "episode_id": "ep_rts_v1_test", "participant_ids": ["participant_0", "participant_1"], "maximum_episode_ticks": 1200})
	_check(errors.is_empty(), "v1 configuration failed: %s" % str(errors))
	_check(authority.units.size() == 6, "v1 must start with three independently-commandable workers per side")
	var valid := _plan(authority, "participant_0", [{"unit_id": "blue_0", "task": "gather", "target_id": "blue_tree_0"}])
	var invalid := _plan(authority, "participant_1", [{"unit_id": "red_0", "task": "gather", "target_id": "blue_tree_0"}])
	_check(authority.task_plan_schema_valid("participant_0", valid), "visible owned gather order rejected")
	_check(not authority.task_plan_schema_valid("participant_1", invalid), "enemy resource target accepted")
	authority.step_task_plan_window(_window(authority, valid, invalid))
	_check(authority.tick == 10, "task-plan window did not apply exactly ten ticks")
	_check(authority.last_task_plans.has("participant_0") and not authority.last_task_plans.has("participant_1"), "only valid v1 plans may enter replay evidence")
	_check(authority.story_phase == "live_command", "v1 authority entered the sealed cinematic story")
	_check(authority.units.blue_0.target_id == "blue_tree_0", "accepted plan did not change the worker state")
	if failures.is_empty():
		print("RTS_SKIRMISH_V1_OK")
		quit(0)
		return
	for failure: String in failures: push_error(failure)
	quit(1)


func _plan(authority, participant_id: String, assignments: Array) -> Dictionary:
	return {"protocol": TaskPlan.PROTOCOL, "episode_id": authority.episode_id, "observation_seq": authority.observation_seq, "intent_label": "live visible command", "memory_update": "", "assignments": assignments}


func _window(authority, blue: Dictionary, red: Dictionary) -> Dictionary:
	return {"episode_id": authority.episode_id, "observation_seq": authority.observation_seq, "mode": "model-duel-v0", "start_tick": authority.tick, "duration_ticks": 10, "plans": {"participant_0": blue, "participant_1": red}}


func _check(condition: bool, message: String) -> void:
	if not condition: failures.append(message)
