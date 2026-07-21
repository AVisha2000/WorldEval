extends SceneTree

const Codec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const Authority := preload("res://scripts/embodiment/authority/authority_orchestrator.gd")
const Verifier := preload("res://scripts/embodiment/replay/embodiment_replay_verifier.gd")

var _failures := PackedStringArray()


func _init() -> void:
	var replay := _replay()
	var payload := Codec.canonical_bytes(replay)
	var verified: Dictionary = Verifier.new().verify(payload)
	_check(bool(verified.ok), "valid replay failed: %s" % str(verified.get("code", "")))
	var tampered := replay.duplicate(true)
	tampered.steps[0].decision_window.duration_ticks = 9
	_resign(tampered)
	var changed: Dictionary = Verifier.new().verify(Codec.canonical_bytes(tampered))
	_check(not bool(changed.ok) and changed.code == "replay_result_mismatch", "tamper accepted")
	var incomplete := replay.duplicate(true)
	incomplete.steps.clear()
	_resign(incomplete)
	var missing: Dictionary = Verifier.new().verify(Codec.canonical_bytes(incomplete))
	_check(not bool(missing.ok) and missing.code == "replay_shape_invalid", "incomplete accepted")
	var noncanonical := Codec.canonical_json(replay).replace("{\"config\"", "{ \"config\"").to_utf8_buffer()
	_check(not bool(Verifier.new().verify(noncanonical).ok), "noncanonical replay accepted")
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("EMBODIMENT_REPLAY_FAILURE: " + failure)
		print("EMBODIMENT_REPLAY_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("EMBODIMENT_REPLAY_OK")
	quit(0)


func _replay() -> Dictionary:
	var episode_id := "ep_replay"
	var config := {
		"episode_id": episode_id,
		"maximum_episode_ticks": 10,
		"mode": "solo-curriculum-v0",
		"observation_profile": "text-visible-v1",
		"participant_ids": ["participant_0"],
		"protocol_version": "llm-controller/0.1.0",
		"seed": 0,
		"task_id": "orientation-v0",
		"timing_track": "step-locked-v1",
	}
	var authority := Authority.new()
	_check(authority.configure(config).is_empty(), "fixture config rejected")
	var initial_observations := {"participant_0": authority.observe()}
	var initial_hash: String = authority.checkpoint_hash()
	var window := {
		"decisions": {"participant_0": {
			"action": _action(episode_id), "disposition": "accepted", "fallback": "none",
			"no_input_reason": null,
		}},
		"duration_ticks": 10,
		"episode_id": episode_id,
		"mode": "solo-curriculum-v0",
		"observation_seq": 0,
		"start_tick": 0,
	}
	var result: Dictionary = authority.step_window(window)
	var replay := {
		"config": config,
		"config_sha256": Codec.sha256_bytes(Codec.canonical_bytes(config)),
		"final_state_hash": authority.checkpoint_hash(),
		"final_terminal": authority.terminal.duplicate(true),
		"initial_observations": initial_observations,
		"initial_state_hash": initial_hash,
		"ledger_sha256": "",
		"protocol_version": "llm-controller/0.1.0",
		"protocol_package_sha256": Verifier.PROTOCOL_PACKAGE_SHA256,
		"schema_version": "llm-controller/episode-replay/1.0.0",
		"steps": [{"decision_window": window, "result": result}],
	}
	_resign(replay)
	return replay


func _resign(replay: Dictionary) -> void:
	var body := replay.duplicate(true)
	body.erase("ledger_sha256")
	replay.ledger_sha256 = Codec.sha256_bytes(Codec.canonical_bytes(body))


func _action(episode_id: String) -> Dictionary:
	return {
		"action_id": "replay_action",
		"control": {
			"buttons": {
				"ability_1": false, "ability_2": false, "cancel": false,
				"cycle_item": false, "dash": false, "guard": false,
				"interact": false, "primary": false,
			},
			"duration_ticks": 10,
			"look_x": 0, "look_y": 0, "move_x": 0, "move_y": 0,
		},
		"episode_id": episode_id,
		"intent_label": "replay fixture",
		"memory_update": "",
		"observation_seq": 0,
		"protocol_version": "llm-controller/0.1.0",
	}


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
