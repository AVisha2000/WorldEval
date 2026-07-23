extends SceneTree

const Codec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const Host := preload("res://scripts/embodiment/transport/embodiment_managed_session_host.gd")
const Client := preload("res://scripts/embodiment/transport/embodiment_gateway_client.gd")
const TICKET := "0123456789abcdef0123456789abcdef0123456789a"

var _failures := PackedStringArray()


func _init() -> void:
	_test_codec_round_trip()
	_test_codec_rejections()
	await _test_managed_host_episode()
	_test_loopback_policy()
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("EMBODIMENT_MANAGED_FAILURE: " + failure)
		print("EMBODIMENT_MANAGED_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("EMBODIMENT_MANAGED_OK")
	quit(0)


func _secret() -> PackedByteArray:
	var value := PackedByteArray()
	value.resize(32)
	for index: int in 32:
		value[index] = index + 1
	return value


func _pair(episode_id: String) -> Array:
	var python := Codec.new()
	var godot := Codec.new()
	_check(python.configure(episode_id, _secret(), "python").is_empty(), "python codec configure")
	_check(godot.configure(episode_id, _secret(), "godot").is_empty(), "godot codec configure")
	return [python, godot]


func _test_codec_round_trip() -> void:
	var pair := _pair("ep_codec")
	var encoded: Dictionary = pair[0].encode("auth", Codec.ZERO_HASH, {
		"attachment_ticket": TICKET,
	})
	_check(bool(encoded.ok), "valid auth did not encode")
	var decoded: Dictionary = pair[1].decode(encoded.payload)
	_check(bool(decoded.ok), "valid auth did not decode")
	if bool(decoded.get("ok", false)):
		_check(decoded.frame.body.attachment_ticket == TICKET, "body drifted")


func _test_codec_rejections() -> void:
	var pair := _pair("ep_tamper")
	var encoded: Dictionary = pair[0].encode("auth", Codec.ZERO_HASH, {
		"attachment_ticket": TICKET,
	})
	var text: String = encoded.payload.get_string_from_utf8()
	var tampered := text.replace(TICKET, "1123456789abcdef0123456789abcdef0123456789a").to_utf8_buffer()
	var rejected: Dictionary = pair[1].decode(tampered)
	_check(not bool(rejected.ok) and rejected.code == "authentication_failed", "tamper accepted")
	var duplicate := (
		'{"a":1,"a":2}'.to_utf8_buffer()
	)
	_check(not bool(Codec.parse_canonical(duplicate).ok), "duplicate JSON key accepted")
	_check(not bool(Codec.parse_canonical('{"x":1.0}'.to_utf8_buffer()).ok), "float JSON accepted")


func _test_managed_host_episode() -> void:
	var episode_id := "ep_managed"
	_check(Host._ascii_token(TICKET, 43, 43), "ticket token helper rejected")
	var config := {
		"episode_id": episode_id,
		"maximum_episode_ticks": 30,
		"mode": "solo-curriculum-v0",
		"observation_profile": "text-visible-v1",
		"participant_ids": ["participant_0"],
		"protocol_version": "llm-controller/0.1.0",
		"seed": 0,
		"task_id": "orientation-v0",
		"timing_track": "step-locked-v1",
	}
	var config_hash := Codec.sha256_bytes(Codec.canonical_bytes(config))
	var launch := {
		"attachment_ticket": TICKET,
		"config": config,
		"config_sha256": config_hash,
		"connection_id": "connection_1",
	}
	var host := Host.new()
	var host_errors: PackedStringArray = host.configure(launch, _secret())
	_check(host_errors.is_empty(), "host rejected valid launch: %s" % str(host_errors))
	if not host_errors.is_empty():
		return
	var python := Codec.new()
	_check(python.configure(episode_id, _secret(), "python").is_empty(), "peer configure failed")
	var hello: Dictionary = host.begin_handshake()
	_check(bool(hello.ok), "hello failed")
	_check(bool(python.decode(hello.payload).ok), "hello peer decode failed")
	var auth: Dictionary = python.encode("auth", Codec.ZERO_HASH, {
		"attachment_ticket": TICKET,
	})
	var ready: Dictionary = await host.receive(auth.payload)
	_check(bool(ready.ok), "auth failed")
	var ready_frame: Dictionary = python.decode(ready.payload)
	_check(bool(ready_frame.ok), "ready decode failed")
	if not bool(ready_frame.get("ok", false)):
		return
	_check(ready_frame.frame.boundary_hash == config_hash, "ready config boundary drifted")
	var initial_hash: String = ready_frame.frame.body.state_hash
	var action := _action(episode_id, 0, 10)
	var window := {
		"decisions": {"participant_0": {
			"action": action, "disposition": "accepted", "fallback": "none",
			"no_input_reason": null,
		}},
		"duration_ticks": 10,
		"episode_id": episode_id,
		"mode": "solo-curriculum-v0",
		"observation_seq": 0,
		"start_tick": 0,
	}
	var decision: Dictionary = python.encode("decision_window", initial_hash, {"window": window})
	var stepped: Dictionary = await host.receive(decision.payload)
	_check(bool(stepped.ok), "managed step failed")
	var step_frame: Dictionary = python.decode(stepped.payload)
	_check(bool(step_frame.ok), "step result decode failed")
	if not bool(step_frame.get("ok", false)):
		return
	_check(step_frame.frame.body.result.observations.participant_0.tick == 10, "step tick drifted")
	var close: Dictionary = python.encode("close_episode", step_frame.frame.boundary_hash, {})
	var closed: Dictionary = await host.receive(close.payload)
	_check(bool(closed.ok), "managed close failed")
	_check(bool(python.decode(closed.payload).ok), "closed frame decode failed")
	_check(host.phase() == "complete", "host did not complete")


func _test_loopback_policy() -> void:
	_check(Client.is_loopback_websocket_url("ws://127.0.0.1:8123/session"), "IPv4 loopback rejected")
	_check(Client.is_loopback_websocket_url("ws://[::1]:8123/session"), "IPv6 loopback rejected")
	_check(not Client.is_loopback_websocket_url("ws://0.0.0.0:8123/session"), "wildcard accepted")
	_check(not Client.is_loopback_websocket_url("wss://localhost:8123/session"), "TLS URL accepted")


func _action(episode_id: String, sequence: int, duration: int) -> Dictionary:
	return {
		"action_id": "managed_action_%d" % sequence,
		"control": {
			"buttons": {
				"ability_1": false, "ability_2": false, "cancel": false,
				"cycle_item": false, "dash": false, "guard": false,
				"interact": false, "primary": false,
			},
			"duration_ticks": duration,
			"look_x": 0, "look_y": 0, "move_x": 0, "move_y": -1000,
		},
		"episode_id": episode_id,
		"intent_label": "managed test",
		"memory_update": "",
		"observation_seq": sequence,
		"protocol_version": "llm-controller/0.1.0",
	}


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
