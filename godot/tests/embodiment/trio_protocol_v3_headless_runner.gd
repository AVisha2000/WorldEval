extends SceneTree

const Dispatcher := preload(
	"res://scripts/embodiment/v3/transport/trio_game_dispatcher_v3.gd"
)
const Host := preload(
	"res://scripts/embodiment/v3/transport/embodiment_managed_session_host_v3.gd"
)
const CodecV3 := preload(
	"res://scripts/embodiment/v3/transport/embodiment_frame_codec_v3.gd"
)
const Canonical := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const Verifier := preload(
	"res://scripts/embodiment/v3/replay/embodiment_replay_verifier_v3.gd"
)
const Identity := preload(
	"res://scripts/embodiment/v3/protocol/embodiment_protocol_package_identity_v3.gd"
)

const PARTICIPANTS := ["participant_0", "participant_1", "participant_2"]

var _failures: Array[String] = []
var _replay_output := ""
var _movie_replay_output := ""


func _init() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--replay-output="):
			_replay_output = argument.trim_prefix("--replay-output=")
		elif argument.begins_with("--movie-replay-output="):
			_movie_replay_output = argument.trim_prefix("--movie-replay-output=")
	_test_dispatch_replay_and_determinism()
	_test_managed_text_handshake()
	if not _movie_replay_output.is_empty():
		var movie_replay := _build_quick_replay()
		var movie_file := FileAccess.open(_movie_replay_output, FileAccess.WRITE)
		if movie_file == null or movie_replay.is_empty():
			_check(false, "v3 movie replay output failed")
		else:
			movie_file.store_buffer(Canonical.canonical_bytes(movie_replay))
			movie_file.close()
	if _failures.is_empty():
		print("TRIO_PROTOCOL_V3_OK")
		quit(0)
		return
	for failure: String in _failures:
		push_error(failure)
	quit(1)


func _test_dispatch_replay_and_determinism() -> void:
	var first: Dictionary = _build_replay("trio-relay-v0", 0)
	var second: Dictionary = _build_replay("trio-relay-v0", 0)
	_check(not first.is_empty(), "v3 replay construction failed")
	_check(Canonical.canonical_bytes(first) == Canonical.canonical_bytes(second),
		"same trio seed/windows did not produce identical replay bytes")
	if first.is_empty():
		return
	var verified: Dictionary = Verifier.new().verify(Canonical.canonical_bytes(first))
	_check(bool(verified.get("ok", false)), "v3 replay verifier rejected deterministic replay")
	if not _replay_output.is_empty():
		var file := FileAccess.open(_replay_output, FileAccess.WRITE)
		if file == null:
			_check(false, "v3 replay output could not be opened")
		else:
			file.store_buffer(Canonical.canonical_bytes(first))
			file.close()
	var bad := first.duplicate(true)
	bad.config.participant_ids = ["participant_0", "participant_1"]
	bad.config_sha256 = Canonical.sha256_bytes(Canonical.canonical_bytes(bad.config))
	bad.erase("ledger_sha256")
	bad.ledger_sha256 = Canonical.sha256_bytes(Canonical.canonical_bytes(bad))
	_check(not bool(Verifier.new().verify(Canonical.canonical_bytes(bad)).get("ok", false)),
		"v3 verifier accepted a two-participant replay")


func _test_managed_text_handshake() -> void:
	var config := _config("trio-free-for-all-v0", 2, "ep_v3_managed")
	var secret := PackedByteArray()
	secret.resize(32)
	secret.fill(17)
	var launch := {
		"attachment_ticket": "a".repeat(43), "config": config,
		"config_sha256": Canonical.sha256_bytes(Canonical.canonical_bytes(config)),
		"connection_id": "v3-managed", "episode_id": config.episode_id,
		"gateway_url": "ws://127.0.0.1:1/ws/embodiment/%s" % "a".repeat(43),
		"protocol_package_sha256": Identity.SHA256,
	}
	var host := Host.new()
	_check(host.configure(launch, secret).is_empty(), "v3 managed host rejected text launch")
	var client := CodecV3.new()
	_check(client.configure(config.episode_id, secret, "python").is_empty(),
		"v3 client codec rejected secret")
	var hello: Dictionary = host.begin_handshake()
	_check(bool(hello.get("ok", false)), "v3 managed host did not emit hello")
	if not bool(hello.get("ok", false)):
		return
	_check(bool(client.decode(hello.payload).get("ok", false)), "v3 client rejected host hello")
	var auth := client.encode("auth", CodecV3.ZERO_HASH, {
		"attachment_ticket": "a".repeat(43),
	})
	var ready: Dictionary = host.receive(auth.payload)
	_check(bool(ready.get("ok", false)), "v3 host rejected authenticated client")
	var decoded_ready: Dictionary = client.decode(ready.payload)
	_check(bool(decoded_ready.get("ok", false)), "v3 client rejected episode_ready")
	if bool(decoded_ready.get("ok", false)):
		_check(decoded_ready.frame.body.observations.size() == 3,
			"v3 ready boundary did not contain exactly three observations")
	var window := _window(config, 0, 0)
	var request := client.encode("decision_window", host.checkpoint_hash(), {"window": window})
	var response: Dictionary = host.receive(request.payload)
	_check(bool(response.get("ok", false)), "v3 host rejected joint neutral window")
	var decoded_response: Dictionary = client.decode(response.payload)
	_check(bool(decoded_response.get("ok", false)), "v3 client rejected step_result")
	if bool(decoded_response.get("ok", false)):
		var result: Dictionary = decoded_response.frame.body.result
		_check(result.observations.size() == 3 and result.receipts.size() == 3,
			"v3 managed result lost a participant")
		_check(result.observations.participant_0.tick == 10,
			"v3 managed authority did not advance the fixed ten-tick window")
	host.close()
	client.close()
	secret.fill(0)


func _build_replay(task_id: String, rotation: int) -> Dictionary:
	var config := _config(task_id, rotation, "ep_v3_replay")
	var dispatcher := Dispatcher.new()
	if not dispatcher.configure(config).is_empty():
		return {}
	var initial_observations: Dictionary = dispatcher.observe_all()
	var initial_hash: String = dispatcher.checkpoint_hash()
	var steps: Array[Dictionary] = []
	while not bool(dispatcher.terminal().ended):
		var window := _window(config, steps.size(), steps.size() * 10)
		if not dispatcher.decision_window_schema_valid(window):
			return {}
		steps.append({"decision_window": window, "result": dispatcher.step_window(window)})
	var body := {
		"schema_version": "llm-controller/episode-replay/1.0.0",
		"protocol_version": Identity.PROTOCOL_VERSION,
		"protocol_package_sha256": Identity.SHA256,
		"config": config,
		"config_sha256": Canonical.sha256_bytes(Canonical.canonical_bytes(config)),
		"initial_observations": initial_observations,
		"initial_state_hash": initial_hash,
		"steps": steps,
		"final_terminal": dispatcher.terminal(),
		"final_result": steps[-1].result.trio_result,
		"final_state_hash": dispatcher.checkpoint_hash(),
	}
	var replay := body.duplicate(true)
	replay["ledger_sha256"] = Canonical.sha256_bytes(Canonical.canonical_bytes(body))
	return replay


func _build_quick_replay() -> Dictionary:
	var config := _config("trio-relay-v0", 0, "ep_v3_movie")
	var dispatcher := Dispatcher.new()
	if not dispatcher.configure(config).is_empty():
		return {}
	var initial_observations: Dictionary = dispatcher.observe_all()
	var initial_hash: String = dispatcher.checkpoint_hash()
	var steps: Array[Dictionary] = []
	while not bool(dispatcher.terminal().ended):
		var window := _window(config, steps.size(), steps.size() * 10)
		window.decisions.participant_0 = {
			"disposition": "accepted", "fallback": "none", "no_input_reason": null,
			"action": {
				"protocol_version": Identity.PROTOCOL_VERSION, "episode_id": config.episode_id,
				"observation_seq": steps.size(), "action_id": "advance_%d" % steps.size(),
				"control": {
					"move_x": 0, "move_y": 1000, "look_x": 0, "look_y": 0,
					"duration_ticks": 10,
					"buttons": {"interact": false, "primary": false, "guard": false,
						"dash": false, "ability_1": false, "ability_2": false,
						"cycle_item": false, "cancel": false},
				},
				"intent_label": "approach relay", "memory_update": "",
			},
		}
		if not dispatcher.decision_window_schema_valid(window):
			return {}
		steps.append({"decision_window": window, "result": dispatcher.step_window(window)})
	var body := {
		"schema_version": "llm-controller/episode-replay/1.0.0",
		"protocol_version": Identity.PROTOCOL_VERSION,
		"protocol_package_sha256": Identity.SHA256, "config": config,
		"config_sha256": Canonical.sha256_bytes(Canonical.canonical_bytes(config)),
		"initial_observations": initial_observations, "initial_state_hash": initial_hash,
		"steps": steps, "final_terminal": dispatcher.terminal(),
		"final_result": steps[-1].result.trio_result,
		"final_state_hash": dispatcher.checkpoint_hash(),
	}
	var replay := body.duplicate(true)
	replay.ledger_sha256 = Canonical.sha256_bytes(Canonical.canonical_bytes(body))
	return replay


func _config(task_id: String, rotation: int, episode_id: String) -> Dictionary:
	return {
		"protocol_version": Identity.PROTOCOL_VERSION, "episode_id": episode_id,
		"mode": "trio-game-v0", "task_id": task_id, "seed": 91,
		"observation_profile": "text-visible-v1", "timing_track": "step-locked-v1",
		"maximum_episode_ticks": 1200, "participant_ids": PARTICIPANTS.duplicate(),
		"seat_rotation": rotation,
	}


func _window(config: Dictionary, sequence: int, start_tick: int) -> Dictionary:
	var decisions := {}
	for participant_id: String in PARTICIPANTS:
		decisions[participant_id] = {
			"disposition": "no_input", "action": null, "fallback": "neutral",
			"no_input_reason": "missing",
		}
	return {
		"episode_id": config.episode_id, "observation_seq": sequence,
		"mode": "trio-game-v0", "start_tick": start_tick, "duration_ticks": 10,
		"decisions": decisions,
	}


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
