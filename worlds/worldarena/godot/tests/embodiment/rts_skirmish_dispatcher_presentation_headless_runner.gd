extends SceneTree

const Dispatcher := preload("res://scripts/embodiment/v2/transport/control_game_dispatcher_v2.gd")
const Scene := preload("res://scripts/embodiment/presentation/rts/rts_skirmish_participant_scene.gd")


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_task_plan_dispatch_and_neutral_fallback()
	var dispatcher := Dispatcher.new()
	var config := {"protocol_version": "llm-controller/0.2.0", "episode_id": "ep_rts_dispatcher",
		"mode": "scripted-duel-v0", "task_id": "rts-skirmish-v0", "seed": 17,
		"observation_profile": "text-visible-v1", "timing_track": "step-locked-v1",
		"maximum_episode_ticks": 1200, "participant_ids": ["participant_0", "participant_1"]}
	if not dispatcher.configure(config).is_empty():
		_fail("dispatcher rejected rts skirmish")
		return
	var observations: Dictionary = dispatcher.observe_all()
	for participant_id: String in ["participant_0", "participant_1"]:
		var scene := Scene.new()
		root.add_child(scene)
		var team := "blue" if participant_id == "participant_0" else "red"
		if not scene.configure_participant(participant_id, team):
			_fail("scene configuration rejected")
			return
		var source: Dictionary = dispatcher.participant_presentation_source(participant_id)
		if source.get("participant_id") != participant_id or not source.get("own") is Dictionary \
			or not scene.apply_participant_projection(source, observations[participant_id]):
			_fail("participant presentation bridge rejected")
			return
		var other_participant := "participant_1" if participant_id == "participant_0" else "participant_0"
		if JSON.stringify(scene.snapshot_copy()).contains(other_participant):
			_fail("presentation bridge retained other participant identity")
			return
		scene.queue_free()
	print("RTS_SKIRMISH_DISPATCHER_PRESENTATION_OK")
	quit(0)


func _test_task_plan_dispatch_and_neutral_fallback() -> void:
	var dispatcher := Dispatcher.new()
	var config := {"protocol_version": "llm-controller/0.2.0", "episode_id": "ep_rts_task_dispatcher",
		"mode": "model-duel-v0", "task_id": "rts-skirmish-v0", "seed": 18,
		"observation_profile": "text-visible-v1", "timing_track": "step-locked-v1",
		"maximum_episode_ticks": 1200, "participant_ids": ["participant_0", "participant_1"]}
	if not dispatcher.configure(config).is_empty():
		_fail("dispatcher rejected task-plan configuration")
		return
	var valid := _task_window(dispatcher, "blue_tree_0", "red_tree_0")
	if not dispatcher.decision_window_schema_valid(valid):
		_fail("dispatcher rejected a valid RTS task window")
		return
	var accepted: Dictionary = dispatcher.step_window(valid)
	if int(dispatcher.authority.tick) != 10 or not bool(accepted.receipts.participant_0.accepted) \
		or dispatcher.last_replay_decision_window.get("decisions") == null \
		or dispatcher.last_rts_task_plan_window.get("plans") == null:
		_fail("accepted RTS task plan was not translated into replay-compatible evidence")
		return
	var invalid := _task_window(dispatcher, "red_tree_0", "red_tree_0")
	if dispatcher.decision_window_schema_valid(invalid):
		_fail("enemy resource task plan was accepted")
		return
	var neutral: Dictionary = dispatcher.step_window(invalid)
	if int(dispatcher.authority.tick) != 20 or neutral.receipts.participant_0.fallback != "neutral" \
		or int(neutral.receipts.participant_0.applied_ticks) != 10:
		_fail("invalid RTS task plan did not advance a recorded neutral ten-tick window")


func _task_window(dispatcher: Object, blue_target: String, red_target: String) -> Dictionary:
	var authority = dispatcher.authority
	return {"episode_id": authority.episode_id, "observation_seq": authority.observation_seq,
		"mode": "model-duel-v0", "start_tick": authority.tick, "duration_ticks": 10,
		"plans": {
			"participant_0": _plan(authority, "blue_0", blue_target),
			"participant_1": _plan(authority, "red_0", red_target),
		}}


func _plan(authority: Object, unit_id: String, target_id: String) -> Dictionary:
	return {"protocol": "rts-task-plan-v1", "episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq, "intent_label": "Gather resources",
		"memory_update": "", "assignments": [{"unit_id": unit_id, "task": "gather", "target_id": target_id}]}


func _fail(message: String) -> void:
	push_error("RTS_SKIRMISH_DISPATCHER_PRESENTATION_FAILED: %s" % message)
	quit(1)
