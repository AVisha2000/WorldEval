extends SceneTree

## Fast authority-only coverage for the credential-free two-minute Construction showcase.  The
## actual managed runtime renders a participant-filtered third-person scene; this runner verifies
## the same deterministic controller path without allocating a frame per tick.

const Authority := preload("res://scripts/embodiment/authority/authority_orchestrator.gd")

const PARTICIPANT_ID := "participant_0"
const EPISODE_ID := "ep_long_horizon_construction"
const BUILD_START_TICK := 1176
const MAXIMUM_TICKS := 1300
const OUTPUT_PREFIX := "EMBODIMENT_LONG_HORIZON_CONSTRUCTION="

var _failures := PackedStringArray()


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var authority := Authority.new()
	var errors: PackedStringArray = authority.configure_managed_hybrid(_config())
	_check(errors.is_empty(), "long-horizon configuration failed: %s" % str(errors))
	if not errors.is_empty():
		_finish({})
		return
	_check(
		int(authority.resource_units_remaining) == 25,
		"long-horizon construction did not provision the visible demo supply",
	)
	var task_counts := {}
	var wait_ticks := 0
	var active_task := ""
	while not bool(authority.terminal.ended) and int(authority.tick) < MAXIMUM_TICKS:
		if active_task.is_empty():
			active_task = _next_task(authority)
		var task := active_task
		task_counts[task] = int(task_counts.get(task, 0)) + 1
		if task == "wait":
			wait_ticks += 1
		var result: Dictionary = authority.step_window(_task_window(authority, task))
		var receipt: Dictionary = result.receipts[PARTICIPANT_ID]
		_check(bool(receipt.accepted), "long-horizon %s action was rejected" % task)
		for code: String in [
			"interaction_out_of_range", "interaction_misaligned", "construction_out_of_range",
			"construction_misaligned", "construction_insufficient_material",
		]:
			_check(code not in receipt.codes, "long-horizon %s emitted %s" % [task, code])
		if "autonomous_task_complete" in receipt.codes \
			or (task == "wait" and int(authority.tick) >= BUILD_START_TICK):
			active_task = ""
	_check(bool(authority.terminal.ended), "long-horizon construction did not terminate")
	_check(str(authority.terminal.outcome) == "success", "long-horizon construction did not succeed")
	_check(str(authority.terminal.reason) == "barricade_built", "long-horizon reason drifted")
	_check(
		int(authority.tick) >= BUILD_START_TICK and int(authority.tick) < 1200,
		"long-horizon construction did not finish at the advertised finale",
	)
	_check(wait_ticks <= 80, "long-horizon showcase idled for too long")
	_check(int(task_counts.get("gather_materials", 0)) > 500, "showcase did not gather visibly")
	_check(int(task_counts.get("deliver_materials", 0)) > 500, "showcase did not deliver visibly")
	_finish({
		"final_tick": int(authority.tick),
		"task_counts": task_counts,
		"wait_ticks": wait_ticks,
	})


func _config() -> Dictionary:
	return {
		"episode_id": EPISODE_ID,
		"maximum_episode_ticks": MAXIMUM_TICKS,
		"mode": "solo-curriculum-v0",
		"observation_profile": "hybrid-visible-v1",
		"participant_ids": [PARTICIPANT_ID],
		"protocol_version": "llm-controller/0.1.0",
		"seed": 20240520,
		"task_id": "construction-v0",
		"timing_track": "step-locked-v1",
	}


func _next_task(authority: Object) -> String:
	if int(authority.inventory_material_units) > 0:
		return "deliver_materials"
	if int(authority.resource_units_remaining) > 0:
		return "gather_materials"
	if int(authority.deposited_material_units) >= 2 and int(authority.tick) >= BUILD_START_TICK:
		return "build_barricade"
	return "wait"


func _task_window(authority: Object, task: String) -> Dictionary:
	var action := {
		"protocol_version": "llm-controller/0.1.0",
		"episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq,
		"action_id": "long_%s_%04d" % [task, authority.observation_seq],
		"control": {
			"move_x": 0,
			"move_y": 0,
			"look_x": 0,
			"look_y": 0,
			"duration_ticks": 1,
			"autonomous_task": task,
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
		},
		"intent_label": task.replace("_", " "),
		"memory_update": "",
	}
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


func _check(condition: bool, message: String) -> void:
	if not condition and message not in _failures:
		_failures.append(message)


func _finish(summary: Dictionary) -> void:
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("EMBODIMENT_LONG_HORIZON_FAILURE: %s" % failure)
		print("EMBODIMENT_LONG_HORIZON_CONSTRUCTION_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print(OUTPUT_PREFIX + JSON.stringify(summary))
	print("EMBODIMENT_LONG_HORIZON_CONSTRUCTION_OK")
	quit(0)
