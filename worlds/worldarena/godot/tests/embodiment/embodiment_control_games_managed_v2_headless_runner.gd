extends SceneTree

const CanonicalCodec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const CodecV2 := preload("res://scripts/embodiment/v2/transport/embodiment_frame_codec_v2.gd")
const HostV2 := preload("res://scripts/embodiment/v2/transport/embodiment_managed_session_host_v2.gd")
const DispatcherV2 := preload("res://scripts/embodiment/v2/transport/control_game_dispatcher_v2.gd")
const ReplayDispatcher := preload("res://scripts/embodiment/v2/replay/embodiment_replay_dispatcher.gd")
const ProtocolIdentity := preload("res://scripts/embodiment/v2/protocol/embodiment_protocol_package_identity_v2.gd")
const TICKET := "0123456789abcdef0123456789abcdef0123456789a"

var _failures := PackedStringArray()


func _init() -> void:
	_test_v2_codec_and_version_rejection()
	_test_host_launch_boundaries()
	_test_managed_invalid_neutral_window()
	_test_offline_replay_dispatch_and_determinism()
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("CONTROL_GAMES_MANAGED_V2_FAILURE: %s" % failure)
		print("CONTROL_GAMES_MANAGED_V2_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("CONTROL_GAMES_MANAGED_V2_OK")
	quit(0)


func _secret() -> PackedByteArray:
	var secret := PackedByteArray()
	secret.resize(32)
	for index: int in 32:
		secret[index] = index + 1
	return secret


func _config(task_id: String, episode_id: String = "ep_control_game_v2") -> Dictionary:
	return {
		"protocol_version": ProtocolIdentity.PROTOCOL_VERSION,
		"episode_id": episode_id,
		"mode": "solo-curriculum-v0",
		"task_id": task_id,
		"seed": 7,
		"observation_profile": "text-visible-v1",
		"timing_track": "step-locked-v1",
		"maximum_episode_ticks": 300,
		"participant_ids": ["participant_0"],
	}


func _launch(config: Dictionary) -> Dictionary:
	return {
		"attachment_ticket": TICKET,
		"config": config,
		"config_sha256": CanonicalCodec.sha256_bytes(CanonicalCodec.canonical_bytes(config)),
		"connection_id": "control_game_connection",
		"protocol_package_sha256": ProtocolIdentity.SHA256,
	}


func _test_v2_codec_and_version_rejection() -> void:
	var python := CodecV2.new()
	var godot := CodecV2.new()
	_check(python.configure("ep_codec_v2", _secret(), "python").is_empty(), "python v2 codec configure failed")
	_check(godot.configure("ep_codec_v2", _secret(), "godot").is_empty(), "godot v2 codec configure failed")
	var encoded: Dictionary = python.encode("auth", CodecV2.ZERO_HASH, {"attachment_ticket": TICKET})
	_check(bool(encoded.ok), "v2 auth did not encode")
	_check(bool(godot.decode(encoded.payload).ok), "v2 auth did not authenticate")
	var legacy := CanonicalCodec.new()
	_check(legacy.configure("ep_codec_v2", _secret(), "godot").is_empty(), "legacy codec setup failed")
	var rejected: Dictionary = legacy.decode(encoded.payload)
	_check(not bool(rejected.ok) and rejected.code == "frame_version_invalid", "legacy codec accepted a v2 frame")


func _test_host_launch_boundaries() -> void:
	var config := _config("movement-maze-v0", "ep_host_boundaries")
	var wrong_hash := _launch(config)
	wrong_hash.protocol_package_sha256 = "0".repeat(64)
	_check(not HostV2.new().configure(wrong_hash, _secret()).is_empty(), "host accepted wrong package hash")
	var hybrid_config := config.duplicate(true)
	hybrid_config.observation_profile = "hybrid-visible-v1"
	var hybrid_launch := _launch(hybrid_config)
	_check("hybrid_participant_frame_adapter_unavailable" in HostV2.new().configure(hybrid_launch, _secret()), "hybrid launched without participant frame adapter")
	var dispatcher := DispatcherV2.new()
	_check(dispatcher.configure(config).is_empty(), "dispatcher rejected valid maze config")
	var source_text := JSON.stringify(dispatcher.participant_presentation_source("participant_0"))
	_check("participant_1" not in source_text and "spectator" not in source_text, "participant render source exposed spectator data")
	_check(dispatcher.participant_presentation_source("participant_1").is_empty(), "unknown participant received render source")


func _test_managed_invalid_neutral_window() -> void:
	var config := _config("movement-maze-v0", "ep_managed_control_v2")
	var host := HostV2.new()
	var launch := _launch(config)
	_check(host.configure(launch, _secret()).is_empty(), "v2 host rejected valid launch")
	var python := CodecV2.new()
	_check(python.configure(config.episode_id, _secret(), "python").is_empty(), "v2 peer configure failed")
	var hello: Dictionary = host.begin_handshake()
	_check(bool(python.decode(hello.payload).ok), "v2 hello decode failed")
	var auth := python.encode("auth", CodecV2.ZERO_HASH, {"attachment_ticket": TICKET})
	var ready: Dictionary = host.receive(auth.payload)
	_check(bool(ready.ok), "v2 host authentication failed")
	var ready_frame: Dictionary = python.decode(ready.payload)
	_check(bool(ready_frame.ok), "v2 ready decode failed")
	if not bool(ready_frame.get("ok", false)):
		return
	_check(ready_frame.frame.body.protocol_package_sha256 == ProtocolIdentity.SHA256, "ready frame omitted v2 package hash")
	var malformed_action := _action(config.episode_id, 0, {"move_y": 1000}, "malformed")
	malformed_action["extra"] = 1
	var window := _window(config.episode_id, 0, 0, 3, malformed_action)
	var request := python.encode("decision_window", ready_frame.frame.body.state_hash, {"window": window})
	var stepped: Dictionary = host.receive(request.payload)
	_check(bool(stepped.ok), "invalid managed action failed the session")
	var step_frame: Dictionary = python.decode(stepped.payload)
	_check(bool(step_frame.ok), "invalid managed step did not decode")
	if bool(step_frame.get("ok", false)):
		var receipt: Dictionary = step_frame.frame.body.result.receipts.participant_0
		_check(receipt.disposition == "no_input" and receipt.applied_ticks == 3, "invalid managed action did not record a three-tick neutral window")
		_check(step_frame.frame.body.result.observations.participant_0.tick == 3, "invalid managed input stalled authority")
		var mismatched_action := _action(config.episode_id, 1, {"move_y": 1000}, "duration_mismatch")
		var mismatched_window := _window(config.episode_id, 1, 3, 3, mismatched_action)
		var mismatch_request := python.encode("decision_window", step_frame.frame.boundary_hash, {"window": mismatched_window})
		var mismatch_response: Dictionary = host.receive(mismatch_request.payload)
		_check(bool(mismatch_response.ok), "duration mismatch failed the managed session")
		var mismatch_frame: Dictionary = python.decode(mismatch_response.payload)
		_check(bool(mismatch_frame.ok), "duration mismatch response did not decode")
		if bool(mismatch_frame.get("ok", false)):
			var mismatch_receipt: Dictionary = mismatch_frame.frame.body.result.receipts.participant_0
			_check(mismatch_receipt.disposition == "no_input" and mismatch_receipt.applied_ticks == 3, "duration mismatch did not consume a neutral window")


func _test_offline_replay_dispatch_and_determinism() -> void:
	var config := _config("operator-action-course-v0", "ep_course_replay_v2")
	var dispatcher := DispatcherV2.new()
	_check(dispatcher.configure(config).is_empty(), "course dispatcher configure failed")
	var body := {
		"schema_version": "llm-controller/episode-replay/1.0.0",
		"protocol_version": ProtocolIdentity.PROTOCOL_VERSION,
		"protocol_package_sha256": ProtocolIdentity.SHA256,
		"config": config,
		"config_sha256": CanonicalCodec.sha256_bytes(CanonicalCodec.canonical_bytes(config)),
		"initial_observations": dispatcher.observe_all(),
		"initial_state_hash": dispatcher.checkpoint_hash(),
		"steps": [],
		"final_terminal": {},
		"final_state_hash": "",
	}
	var controls := [
		{"move_y": 1000}, {"look_x": 1000}, {"interact": true}, {"interact": true},
		{"move_y": 1000}, {"interact": true}, {"interact": true}, {"interact": true},
		{"dash": true}, {"guard": true}, {"primary": true}, {"interact": true},
		{"cancel": true}, {}, {"ability_1": true},
	]
	for values: Dictionary in controls:
		var sequence: int = dispatcher.authority.observation_seq
		var action := _action(config.episode_id, sequence, values, "course_%d" % sequence)
		var window := _window(config.episode_id, sequence, dispatcher.authority.tick, 1, action)
		_check(dispatcher.decision_window_schema_valid(window), "generated replay window was not v2-valid")
		var result: Dictionary = dispatcher.step_window(window)
		body.steps.append({"decision_window": window, "result": result})
	body.final_terminal = dispatcher.terminal()
	body.final_state_hash = dispatcher.checkpoint_hash()
	var replay := body.duplicate(true)
	replay["ledger_sha256"] = CanonicalCodec.sha256_bytes(CanonicalCodec.canonical_bytes(body))
	var payload := CanonicalCodec.canonical_bytes(replay)
	var first: Dictionary = ReplayDispatcher.new().verify(payload)
	var second: Dictionary = ReplayDispatcher.new().verify(payload)
	_check(bool(first.ok), "v2 replay dispatcher rejected deterministic replay: %s" % str(first.get("code")))
	_check(first == second, "v2 offline replay verification was nondeterministic")
	var wrong_package := replay.duplicate(true)
	wrong_package.protocol_package_sha256 = "0".repeat(64)
	var rejected: Dictionary = ReplayDispatcher.new().verify(CanonicalCodec.canonical_bytes(wrong_package))
	_check(not bool(rejected.ok) and rejected.code == "replay_protocol_package_unsupported", "version/hash dispatcher accepted wrong v2 package")


func _window(episode_id: String, sequence: int, start_tick: int, duration: int, action: Dictionary) -> Dictionary:
	return {
		"episode_id": episode_id,
		"observation_seq": sequence,
		"mode": "solo-curriculum-v0",
		"start_tick": start_tick,
		"duration_ticks": duration,
		"decisions": {"participant_0": {
			"disposition": "accepted", "action": action, "fallback": "none", "no_input_reason": null,
		}},
	}


func _action(episode_id: String, sequence: int, values: Dictionary, action_id: String) -> Dictionary:
	var buttons := {}
	for button: String in ["interact", "primary", "guard", "dash", "ability_1", "ability_2", "cycle_item", "cancel"]:
		buttons[button] = bool(values.get(button, false))
	return {
		"protocol_version": ProtocolIdentity.PROTOCOL_VERSION,
		"episode_id": episode_id,
		"observation_seq": sequence,
		"action_id": action_id,
		"control": {
			"move_x": int(values.get("move_x", 0)), "move_y": int(values.get("move_y", 0)),
			"look_x": int(values.get("look_x", 0)), "look_y": 0, "duration_ticks": 1,
			"buttons": buttons,
		},
		"intent_label": "Complete visible control-game target",
		"memory_update": "",
	}


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
