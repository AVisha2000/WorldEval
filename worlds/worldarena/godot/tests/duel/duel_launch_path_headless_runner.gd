extends SceneTree

const LaunchClient := preload("res://scripts/duel/app/duel_launch_client.gd")
const MatchController := preload("res://scripts/duel/duel_match_controller.gd")

class FakeHttpTransport extends Node:
	signal completed(result: int, response_code: int, body: PackedByteArray)

	var requests: Array[Dictionary] = []
	var next_error: Error = OK

	func dispatch_post(
		url: String, headers: PackedStringArray, body: PackedByteArray
	) -> Error:
		if next_error != OK:
			var result := next_error
			next_error = OK
			return result
		requests.append({
			"url": url,
			"headers": headers.duplicate(),
			"body": body.duplicate(),
		})
		return OK

	func respond(response_code: int, value: Dictionary) -> void:
		completed.emit(
			HTTPRequest.RESULT_SUCCESS,
			response_code,
			JSON.stringify(value).to_utf8_buffer()
		)


var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(LaunchClient.is_loopback_http_url("http://127.0.0.1:8000"), "IPv4 loopback URL was rejected")
	_check(LaunchClient.is_loopback_http_url("http://[::1]:8000"), "IPv6 loopback URL was rejected")
	_check(not LaunchClient.is_loopback_http_url("http://127.0.0.1:8000@evil.example"), "userinfo URL escaped loopback boundary")
	_check(not LaunchClient.is_loopback_http_url("https://127.0.0.1:8000"), "unexpected launch URL scheme was accepted")
	var transport := FakeHttpTransport.new()
	root.add_child(transport)
	var client = LaunchClient.new()
	_check(client.set_http_transport(transport).is_empty(), "fake HTTP seam was rejected")
	root.add_child(client)
	await process_frame

	var dispatches := {"create": 0, "claim": 0}
	var launches: Array[Dictionary] = []
	client.create_request_dispatched.connect(func() -> void: dispatches["create"] += 1)
	client.claim_request_dispatched.connect(func() -> void: dispatches["claim"] += 1)
	client.launch_ready.connect(func(fields: Dictionary) -> void: launches.append(fields.duplicate(true)))

	var secret := "TOP-SECRET-NEVER-IN-DEBUG"
	var request := _launch_request(secret)
	_check(client.start_launch(request).is_empty(), "valid creation request was rejected")
	_check(request.is_empty(), "client retained caller credential dictionary after dispatch")
	_check(int(dispatches["create"]) == 1 and transport.requests.size() == 1, "create dispatch count changed")
	_check(str(transport.requests[0]["url"]).ends_with("/api/duel/matches"), "create endpoint changed")
	var wire_request: Variant = JSON.parse_string(
		(transport.requests[0]["body"] as PackedByteArray).get_string_from_utf8()
	)
	_check(typeof(wire_request) == TYPE_DICTIONARY, "create request was not JSON object")
	_check(_same_keys(wire_request, LaunchClient.REQUEST_FIELDS), "create request fields were not exact")
	_check(not (wire_request as Dictionary).has("fairness"), "fairness UI metadata leaked onto API wire")
	_check(not JSON.stringify(client.debug_state()).contains(secret), "credential leaked through launch debug state")

	var match_id := "m_" + "a".repeat(32)
	transport.respond(202, {
		"status": {"match_id": match_id},
		"launch_claim_token": "claim-capability-not-for-status",
	})
	_check(int(dispatches["claim"]) == 1 and transport.requests.size() == 2, "claim was not dispatched exactly once")
	_check(str(transport.requests[1]["url"]).ends_with("/api/duel/launch-claim"), "claim endpoint changed")
	var claim_wire: Dictionary = JSON.parse_string(
		(transport.requests[1]["body"] as PackedByteArray).get_string_from_utf8()
	)
	_check(claim_wire.size() == 1 and claim_wire.has("claim_token"), "claim body fields were not exact")

	transport.respond(200, _launch_response(match_id))
	_check(launches.size() == 1, "validated launch fields were not emitted exactly once")
	var fields := launches[0]
	_check(typeof(fields["token"]) == TYPE_PACKED_BYTE_ARRAY and fields["token"].size() == 32, "session token was not converted to protected bytes")
	_check(typeof(fields["match_init"]["seed"]) == TYPE_INT, "MATCH_INIT JSON integers were not normalized at the wire boundary")
	var authority: Dictionary = fields["authority"]
	for key: String in ["tie_key", "alias_salt_seat_0", "alias_salt_seat_1"]:
		_check(typeof(authority[key]) == TYPE_PACKED_BYTE_ARRAY and authority[key].size() == 32, key + " was not converted to protected bytes")
	var controller = MatchController.new()
	root.add_child(controller)
	await process_frame
	_check(controller.configure_launch(fields).is_empty(), "converted launch fields were rejected by DuelMatchController")
	_check(not client.start_launch(_launch_request("SECOND-SECRET")).is_empty(), "one-shot client accepted a second match launch")
	_check(transport.requests.size() == 2, "one-shot client dispatched more than one claim")

	var failed_transport := FakeHttpTransport.new()
	failed_transport.next_error = ERR_CANT_CONNECT
	root.add_child(failed_transport)
	var failed_client = LaunchClient.new()
	_check(failed_client.set_http_transport(failed_transport).is_empty(), "failed fake seam was rejected")
	root.add_child(failed_client)
	await process_frame
	var retained_request := _launch_request("RETRYABLE-SECRET")
	_check(not failed_client.start_launch(retained_request).is_empty(), "failed HTTP dispatch reported success")
	_check(not retained_request.is_empty(), "request was scrubbed before transport accepted dispatch")
	_check(not JSON.stringify(failed_client.debug_state()).contains("RETRYABLE-SECRET"), "failed credential leaked through debug state")

	client.queue_free()
	transport.queue_free()
	## configure_launch intentionally does not parent its gateway client until
	## start_match; this focused test stops before network start, so free it.
	controller.client.free()
	controller.queue_free()
	failed_client.queue_free()
	failed_transport.queue_free()
	await process_frame
	## Let the stack holding controller/host script references unwind before
	## quitting so the harness itself does not manufacture resource leaks.
	call_deferred("_finish")


func _launch_request(secret: String) -> Dictionary:
	return {
		"decision_mode": "fixed_simultaneous",
		"faction_preset_id": "vanguard-v1",
		"mirror_faction": true,
		"map_id": "crossroads-duel-v1",
		"seed": 847221,
		"decision_period_ticks": 100,
		"response_deadline_ms": 45000,
		"authority_launch_mode": "caller_owned",
		"players": [
			{
				"slot": 0,
				"provider": "openai",
				"model": "gpt-5.4",
				"reasoning": "high",
				"credential": secret,
			},
			{
				"slot": 1,
				"provider": "baseline.rush",
				"model": "baseline-rush-v1",
				"reasoning": "none",
			},
		],
		"maximum_match_ticks": 18000,
		"memory_policy": "fresh-match-with-bounded-scratchpad",
		"spectator": {
			"enabled": true,
			"initial_perspective": "omniscient",
			"record_replay": true,
		},
	}


func _launch_response(match_id: String) -> Dictionary:
	return {
		"authority": {
			"alias_salt_seat_0": _byte_values(1),
			"alias_salt_seat_1": _byte_values(33),
			"authoritative_hashes": {"protocol_hash": "a".repeat(64)},
			"scored": true,
			"tie_key": _byte_values(65),
		},
		"connection_id": "godot-" + match_id,
		"gateway_url": "ws://127.0.0.1:8000/ws/duel/ticket",
		"match_id": match_id,
		"match_init": {
			"message_type": "match_init",
			"match_id": match_id,
			"seed": 847221,
		},
		"protocol_hash": "a".repeat(64),
		"token": _byte_values(97),
	}


func _byte_values(start: int) -> Array[int]:
	var values: Array[int] = []
	for offset in 32:
		values.append((start + offset) % 256)
	return values


func _same_keys(value: Variant, expected: Array) -> bool:
	if typeof(value) != TYPE_DICTIONARY or (value as Dictionary).size() != expected.size():
		return false
	for key: Variant in expected:
		if not (value as Dictionary).has(str(key)):
			return false
	return true


func _finish() -> void:
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_LAUNCH_PATH_FAILURE: " + failure)
		print("DUEL_LAUNCH_PATH_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("DUEL_LAUNCH_PATH_OK create=1 claim=1 converted=4 controller=accepted")
	quit(0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
