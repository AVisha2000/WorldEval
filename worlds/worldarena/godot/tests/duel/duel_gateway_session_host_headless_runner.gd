extends SceneTree

const Host := preload("res://scripts/duel/match/duel_gateway_session_host.gd")
const Controller := preload("res://scripts/duel/duel_match_controller.gd")
const GatewayCodec := preload("res://scripts/duel/protocol/duel_gateway_frame_codec.gd")
const Session := preload("res://scripts/duel/match/duel_match_session.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const SALT_ZERO := "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
const SALT_ONE := "f0e0d0c0b0a090807060504030201000ffeeddccbbaa99887766554433221100"
const EXPECTED_GOLDEN := "dbdb99b98e771ff2f0d67c2dc88a1e1d277329ca33e963dfe72957273923d811"

var _failures := PackedStringArray()


class FakeSimulation:
	var state: Dictionary = {
		"events": [],
		"terminal": {"ended": false},
		"tick": 0,
	}

	func terminal_result() -> Dictionary:
		if bool(state["terminal"].get("ended", false)):
			return {
				"ended": true,
				"reason": "gateway_infrastructure_failure",
				"result": "infrastructure_void",
				"winner_seat": -1,
			}
		return {"ended": false, "reason": "", "result": "running", "winner_seat": -1}


class FakeContinuousSession:
	var decision_mode: String = Session.CONTINUOUS_MODE
	var simulation := FakeSimulation.new()

	func advance_ticks(count: int) -> Dictionary:
		simulation.state["tick"] = int(simulation.state["tick"]) + count
		return {
			"errors": PackedStringArray(),
			"ok": true,
			"terminal": simulation.terminal_result(),
			"tick": int(simulation.state["tick"]),
		}

	func checkpoint_hash() -> String:
		return Codec.sha256_canonical({
			"terminal": simulation.state["terminal"],
			"tick": int(simulation.state["tick"]),
		})

	func declare_gateway_disposition(disposition: String) -> Dictionary:
		if disposition != "void_infrastructure":
			return {"errors": PackedStringArray(["unexpected disposition"]), "ok": false}
		simulation.state["terminal"] = {"ended": true}
		return {
			"errors": PackedStringArray(),
			"ok": true,
			"terminal": simulation.terminal_result(),
		}


func _init() -> void:
	var fixed := _run_fixed()
	var continuous := _run_continuous()
	var clock_start := _run_continuous_clock_start_policy()
	var dispositions := _run_gateway_dispositions()
	_check(bool(fixed.get("ok", false)), "fixed authenticated host scenario failed")
	_check(bool(continuous.get("ok", false)), "continuous authenticated host scenario failed")
	_check(bool(clock_start.get("ok", false)), "continuous clock-start policy scenarios failed")
	_check(bool(dispositions.get("ok", false)), "gateway disposition scenarios failed")
	var summary := {
		"clock_start": clock_start,
		"continuous": continuous,
		"dispositions": dispositions,
		"fixed": fixed,
	}
	var golden := Codec.sha256_canonical(summary)
	if not EXPECTED_GOLDEN.is_empty():
		_check(golden == EXPECTED_GOLDEN, "gateway host golden changed: " + golden)
	else:
		print("DUEL_GATEWAY_HOST_CANDIDATE_GOLDEN=" + golden)
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_GATEWAY_HOST_FAILURE: " + failure)
		print("DUEL_GATEWAY_HOST_FAILED count=%d hash=%s" % [_failures.size(), golden])
		quit(1)
		return
	print("DUEL_GATEWAY_HOST_OK hash=%s summary=%s" % [golden, JSON.stringify(summary)])
	quit(0)


func _run_fixed() -> Dictionary:
	var link := _configured_link("m_gateway-host-fixed", Session.FIXED_MODE)
	if not bool(link.get("ok", false)):
		return {"ok": false}
	var host: Variant = link["host"]
	var gateway: Variant = link["gateway"]
	var observation_event: Dictionary = host.emit_observation_pair()
	_check(bool(observation_event.get("ok", false)), "fixed observation emission failed")
	var observation_frame := _decode_only(gateway, observation_event, "fixed observation")
	if observation_frame.is_empty():
		return {"ok": false}
	var checkpoint_hash := str(observation_frame["boundary_hash"])
	var observations: Array = observation_frame["body"]["observations"]
	var batch_zero := _empty_batch(observations[0]["observation"], "fixed.zero", "memory-zero")
	var batch_one := _empty_batch(observations[1]["observation"], "fixed.one", "memory-one")
	var commit_request: Dictionary = gateway.encode("batch_commit_hashes", checkpoint_hash, {
		"boundary_tick": 0,
		"commits": [
			{
				"commit_hash": Session.action_batch_commit_hash(batch_zero, SALT_ZERO),
				"player_slot": 0,
			},
			{
				"commit_hash": Session.action_batch_commit_hash(batch_one, SALT_ONE),
				"player_slot": 1,
			},
		],
		"match_id": "m_gateway-host-fixed",
		"observation_seq": 0,
		"opportunity_id": "opp_00000000",
	})
	var commit_response: Dictionary = host.receive(commit_request["payload"])
	var commit_frame := _decode_only(gateway, commit_response, "fixed commit lock")
	_check(not commit_frame.is_empty() and bool(commit_frame["body"].get("locked", false)),
		"fixed commit acknowledgement was not locked")
	var reveal_request: Dictionary = gateway.encode("batch_reveal", checkpoint_hash, {
		"activation_tick": 1,
		"boundary_tick": 0,
		"disposition": "continue",
		"match_id": "m_gateway-host-fixed",
		"mode": Session.FIXED_MODE,
		"observation_seq": 0,
		"opportunity_id": "opp_00000000",
		"reveals": [
			{"batch": batch_zero, "player_slot": 0, "salt_hex": SALT_ZERO},
			{"batch": batch_one, "player_slot": 1, "salt_hex": SALT_ONE},
		],
	})
	var action_response: Dictionary = host.receive(reveal_request["payload"])
	var action_frames := _decode_frames(gateway, action_response, "fixed action pair")
	var receipt_frame := _frame_of_type(action_frames, "action_receipts")
	var action_frame := _frame_of_type(action_frames, "action_pair")
	_check(action_frames.size() == 2, "fixed application did not stream receipt evidence before ACK")
	_check(not receipt_frame.is_empty()
		and int(receipt_frame["body"].get("application_seq", -1)) == 0
		and (receipt_frame["body"].get("records", []) as Array).size() == 2,
		"fixed authenticated application evidence was invalid")
	_check(not Codec.canonical_json(receipt_frame.get("body", {})).contains("working_memory")
		and not Codec.canonical_json(receipt_frame.get("body", {})).contains("memory-zero"),
		"fixed application evidence leaked protected model memory")
	_check(not action_frame.is_empty() and bool(action_frame["body"].get("accepted", false)),
		"fixed action pair was not accepted")
	_check((action_frame.get("body", {}).get("actions", []) as Array).size() == 2,
		"fixed action pair did not contain both canonical seat receipts")
	var advanced: Dictionary = host.advance_ticks(1)
	_check(bool(advanced.get("ok", false)) and int(advanced.get("tick", -1)) == 1,
		"fixed host did not advance after the atomic pair")
	var fixed_advance_frames := _decode_frames(gateway, advanced, "fixed application checkpoint")
	var fixed_application_checkpoint := _frame_of_type(fixed_advance_frames, "checkpoint")
	_check(not fixed_application_checkpoint.is_empty()
		and int(fixed_application_checkpoint["body"].get("tick", -1)) == 1
		and str(fixed_application_checkpoint["body"].get("reason", "")) == "application",
		"fixed application tick did not emit a post-phase authoritative checkpoint")
	var protected_json := Codec.canonical_json(host.session.to_protected_canonical_dict())
	_check(not protected_json.contains("model-a") and not protected_json.contains("model-b"),
		"provider/model identity entered the authoritative session checkpoint")
	var wrong_mode_request: Dictionary = gateway.encode(
		"continuous_start", checkpoint_hash, _continuous_start_body("m_gateway-host-fixed")
	)
	var wrong_mode_result: Dictionary = host.receive(wrong_mode_request["payload"])
	_check(not bool(wrong_mode_result.get("ok", false))
		and str(wrong_mode_result.get("code", "")) == "bridge_phase_invalid",
		"fixed host accepted a continuous clock start")
	return {
		"action_records": (action_frame.get("body", {}).get("actions", []) as Array).size(),
		"checkpoint_hash": host.session.checkpoint_hash(),
		"frame_inbound_sequence": host.protected_status()["frame_inbound_sequence"],
		"frame_outbound_sequence": host.protected_status()["frame_outbound_sequence"],
		"ok": true,
		"tick": int(host.session.simulation.state.tick),
	}


func _run_continuous() -> Dictionary:
	var link := _configured_link("m_gateway-host-continuous", Session.CONTINUOUS_MODE)
	if not bool(link.get("ok", false)):
		return {"ok": false}
	var host: Variant = link["host"]
	var gateway: Variant = link["gateway"]
	var observation_event: Dictionary = host.emit_observation_pair()
	var observation_frame := _decode_only(gateway, observation_event, "continuous observation")
	if observation_frame.is_empty():
		return {"ok": false}
	var checkpoint_hash := str(observation_frame["boundary_hash"])
	var clock_start: Dictionary = _accept_continuous_start(
		host, gateway, checkpoint_hash, "m_gateway-host-continuous"
	)
	_check(bool(clock_start.get("ok", false)), "continuous clock did not start before actions")
	var observation: Dictionary = observation_frame["body"]["observations"][0]["observation"]
	var batch := _empty_batch(observation, "continuous.zero", "continuous-memory")
	var timing := {
		"application_gate_monotonic_ns": 900,
		"application_tick": 2,
		"completion_monotonic_ns": 400,
		"deadline_monotonic_ns": 1000,
		"dispatch_monotonic_ns": 100,
		"first_token_monotonic_ns": 200,
		"parse_completed_monotonic_ns": 600,
		"parse_started_monotonic_ns": 500,
		"ready_monotonic_ns": 700,
	}


	var action_request: Dictionary = gateway.encode("action", checkpoint_hash, {
		"actions": [{
			"batch": batch,
			"observation_seq": 0,
			"observation_tick": 0,
			"opportunity_id": "opp_00000000",
			"player_slot": 0,
			"timing": timing,
		}],
		"application_tick": 2,
		"match_id": "m_gateway-host-continuous",
		"mode": Session.CONTINUOUS_MODE,
	})
	var action_response: Dictionary = host.receive(action_request["payload"])
	var action_frames := _decode_frames(gateway, action_response, "continuous action pair")
	var receipt_frame := _frame_of_type(action_frames, "action_receipts")
	var action_frame := _frame_of_type(action_frames, "action_pair")
	_check(action_frames.size() == 2,
		"continuous application did not stream receipt evidence before ACK")
	_check(not receipt_frame.is_empty()
		and str(receipt_frame["body"].get("decision_mode", "")) == Session.CONTINUOUS_MODE
		and int(receipt_frame["body"].get("application_tick", -1)) == 2,
		"continuous authenticated application evidence was invalid")
	_check(not Codec.canonical_json(receipt_frame.get("body", {})).contains("continuous-memory"),
		"continuous application evidence leaked protected model memory")
	_check(not action_frame.is_empty() and bool(action_frame["body"].get("accepted", false)),
		"continuous action pair was not accepted")
	_check(host.protected_timing_transcript().size() == 1,
		"continuous protected timing record was not retained")
	_check(not Codec.canonical_json(host.session.to_protected_canonical_dict()).contains("monotonic_ns"),
		"wall-clock timing contaminated the deterministic simulation checkpoint")
	var periodic_advance: Dictionary = host.advance_ticks(300)
	var periodic_frames := _decode_frames(gateway, periodic_advance, "continuous periodic checkpoint")
	var checkpoint_frames := _frames_of_type(periodic_frames, "checkpoint")
	var checkpoint_frame := checkpoint_frames[-1] if not checkpoint_frames.is_empty() else {}
	var checkpoint_ticks: Array[int] = []
	for frame: Dictionary in checkpoint_frames:
		checkpoint_ticks.append(int(frame["body"].get("tick", -1)))
	_check(checkpoint_ticks == [2, 300],
		"continuous advancement did not split at application tick before periodic checkpoint")
	var event_frames := _frames_of_type(periodic_frames, "tick_events")
	var previous_event_seq := 0
	for event_frame: Dictionary in event_frames:
		_check(str(event_frame["body"].get("checkpoint_hash", ""))
			== str(event_frame.get("boundary_hash", "")),
			"continuous tick event frame was not checkpoint-bound")
		for event: Dictionary in event_frame["body"].get("events", []):
			_check(int(event.get("event_seq", -1)) == previous_event_seq + 1
				and str(event.get("audience", "")) == "omniscient",
				"continuous replay events were not legal and contiguous")
			previous_event_seq = int(event.get("event_seq", -1))
	_check(not checkpoint_frame.is_empty()
		and str(checkpoint_frame["body"].get("checkpoint_hash", ""))
		== str(checkpoint_frame.get("boundary_hash", "")),
		"continuous 300-tick checkpoint frame was inconsistent")
	_check(int(checkpoint_frame.get("body", {}).get("tick", -1)) == 300,
		"continuous periodic checkpoint was not emitted at tick 300")
	var terminal_frame := _declare_gateway_disposition(
		host, gateway, str(checkpoint_frame["boundary_hash"]), "m_gateway-host-continuous",
		"technical_forfeit_slot_1", "model_failure_threshold"
	)
	_check(not terminal_frame.is_empty()
		and str(terminal_frame["body"].get("disposition", "")) == "technical_forfeit"
		and int(terminal_frame["body"].get("winner_slot", -1)) == 0,
		"continuous terminal frame did not preserve the authority result")
	var artifact_hash := "d".repeat(64)
	var artifact_request: Dictionary = gateway.encode("artifact_ready", artifact_hash, {
		"artifact_hash": artifact_hash,
		"manifest": {"format": "worldeval-duel-replay-v1"},
	})
	var artifact_result: Dictionary = host.receive(artifact_request["payload"])
	_check(bool(artifact_result.get("ok", false)) and host.phase() == Host.PHASE_COMPLETE,
		"artifact completion did not close the authenticated host")
	return {
		"checkpoint_count": host.checkpoint_transcript().size(),
		"continuous_clock_started": host.protected_status()["continuous_clock_started"],
		"frame_inbound_sequence": host.protected_status()["frame_inbound_sequence"],
		"frame_outbound_sequence": host.protected_status()["frame_outbound_sequence"],
		"ok": true,
		"terminal_result_hash": str(terminal_frame.get("boundary_hash", "")),
		"timing_records": host.protected_timing_transcript().size(),
	}


func _run_continuous_clock_start_policy() -> Dictionary:
	var match_id := "m_gateway-clock-policy"
	var link := _lightweight_clock_link(match_id, Session.CONTINUOUS_MODE)
	var host: Variant = link["host"]
	var gateway: Variant = link["gateway"]
	var boundary_hash := str(link["boundary_hash"])
	var body := _continuous_start_body(match_id)
	var request: Dictionary = gateway.encode("continuous_start", boundary_hash, body)
	var result: Dictionary = host.receive(request["payload"])
	_check(bool(result.get("ok", false)), "authenticated continuous clock start was rejected")
	var acknowledgement := _decode_only(gateway, result, "continuous clock start acknowledgement")
	_check(str(acknowledgement.get("message_type", "")) == "continuous_start_accepted"
		and bool(acknowledgement.get("body", {}).get("accepted", false)),
		"continuous clock start acknowledgement was invalid")
	var controller := Controller.new()
	controller.host = host
	_check(not controller.continuous_clock_active(),
		"controller clock activated before the acknowledged host event was delivered")
	var before_event := Time.get_ticks_usec()
	controller._on_host_events(result.get("events", []))
	_check(controller.continuous_clock_active(),
		"controller clock did not activate on the post-ACK host event")
	_check(controller.next_tick_deadline_usec() >= before_event + Controller.TICK_PERIOD_USEC,
		"controller first continuous deadline was not now plus one 100-ms tick")
	controller.set_process(false)
	controller.free()

	var duplicate: Dictionary = gateway.encode("continuous_start", boundary_hash, body)
	var duplicate_result: Dictionary = host.receive(duplicate["payload"])
	_check(not bool(duplicate_result.get("ok", false))
		and str(duplicate_result.get("code", "")) == "continuous_clock_already_started",
		"host did not fail closed on a duplicate continuous clock start")

	var stale_link := _lightweight_clock_link(
		"m_gateway-clock-stale", Session.CONTINUOUS_MODE
	)
	var stale_request: Dictionary = stale_link["gateway"].encode(
		"continuous_start", "a".repeat(64),
		_continuous_start_body("m_gateway-clock-stale")
	)
	var stale_result: Dictionary = stale_link["host"].receive(stale_request["payload"])
	_check(not bool(stale_result.get("ok", false))
		and str(stale_result.get("code", "")) == "checkpoint_hash_mismatch",
		"host accepted a stale continuous clock boundary")

	var wrong_mode_link := _lightweight_clock_link(
		"m_gateway-clock-wrong-mode", Session.FIXED_MODE
	)
	var wrong_mode_request: Dictionary = wrong_mode_link["gateway"].encode(
		"continuous_start", str(wrong_mode_link["boundary_hash"]),
		_continuous_start_body("m_gateway-clock-wrong-mode")
	)
	var wrong_mode_result: Dictionary = wrong_mode_link["host"].receive(
		wrong_mode_request["payload"]
	)
	_check(not bool(wrong_mode_result.get("ok", false))
		and str(wrong_mode_result.get("code", "")) == "bridge_phase_invalid",
		"fixed-mode host accepted a continuous clock start")

	var lag_link := _lightweight_clock_link(
		"m_gateway-clock-sustained-lag", Session.CONTINUOUS_MODE
	)
	var lag_start := _accept_continuous_start(
		lag_link["host"], lag_link["gateway"], str(lag_link["boundary_hash"]),
		"m_gateway-clock-sustained-lag"
	)
	var lag_controller := Controller.new()
	lag_controller.host = lag_link["host"]
	lag_controller._on_host_events(lag_start.get("events", []))
	lag_controller.set_process(false)
	lag_controller.set(
		"_next_tick_deadline_usec",
		Time.get_ticks_usec() - Controller.MAX_CONTINUOUS_LATE_USEC - 1
	)
	lag_controller._process(0.0)
	_check(lag_link["host"].phase() == Host.PHASE_RUNNING
		and int(lag_link["host"].session.simulation.state["tick"]) == 1,
		"one delayed continuous deadline voided instead of recovering one tick")
	lag_controller.set(
		"_next_tick_deadline_usec",
		Time.get_ticks_usec() - Controller.MAX_CONTINUOUS_LATE_USEC - 1
	)
	lag_controller._process(0.0)
	_check(lag_link["host"].phase() == Host.PHASE_TERMINAL
		and bool(lag_link["host"].session.simulation.state["terminal"]["ended"]),
		"two consecutive delayed continuous deadlines did not fail closed")
	lag_controller.free()
	return {
		"ack_message_type": str(acknowledgement.get("message_type", "")),
		"controller_activated_after_event": true,
		"duplicate_code": str(duplicate_result.get("code", "")),
		"ok": true,
		"stale_code": str(stale_result.get("code", "")),
		"wrong_mode_code": str(wrong_mode_result.get("code", "")),
	}


func _lightweight_clock_link(match_id: String, mode: String) -> Dictionary:
	var token := _vector_token()
	var host := Host.new()
	var gateway := GatewayCodec.new()
	var host_codec: Variant = host.get("_codec")
	_check(host_codec.configure(match_id, token, "godot").is_empty(),
		"lightweight host codec configuration failed")
	_check(gateway.configure(match_id, token, "gateway").is_empty(),
		"lightweight gateway codec configuration failed")
	var boundary_hash := "b".repeat(64)
	host.set("_match_id", match_id)
	host.set("_phase", Host.PHASE_RUNNING)
	host.set("_decision_mode", mode)
	host.set("_gateway_boundary_hash", boundary_hash)
	host.set("_latest_observation_seq", 0)
	host.set("_latest_observation_tick", 0)
	host.session = FakeContinuousSession.new()
	return {"boundary_hash": boundary_hash, "gateway": gateway, "host": host}


func _accept_continuous_start(
	host: Variant, gateway: Variant, boundary_hash: String, match_id: String
) -> Dictionary:
	var request: Dictionary = gateway.encode(
		"continuous_start", boundary_hash, _continuous_start_body(match_id)
	)
	var result: Dictionary = host.receive(request["payload"])
	var acknowledgement := _decode_only(gateway, result, "continuous clock start")
	return {
		"events": result.get("events", []),
		"ok": str(acknowledgement.get("message_type", "")) == "continuous_start_accepted"
			and bool(acknowledgement.get("body", {}).get("accepted", false)),
	}


func _continuous_start_body(match_id: String) -> Dictionary:
	var body := {"match_id": match_id, "observation_seq": 0, "tick": 0}
	body["start_id"] = Codec.sha256_canonical(body)
	return body


func _run_gateway_dispositions() -> Dictionary:
	var cases: Array[Dictionary] = [
		{
			"code": "model_failure_threshold",
			"disposition": "technical_forfeit_slot_0",
			"expected_terminal": "technical_forfeit",
			"expected_winner": 1,
		},
		{
			"code": "model_failure_threshold",
			"disposition": "draw_double_technical_forfeit",
			"expected_terminal": "draw",
			"expected_winner": null,
		},
		{
			"code": "dispatch_grid_drift",
			"disposition": "void_infrastructure",
			"expected_terminal": "infrastructure_void",
			"expected_winner": null,
		},
	]
	var records: Array = []
	for index: int in cases.size():
		var row: Dictionary = cases[index]
		var match_id := "m_gateway-disposition-%d" % index
		var link := _configured_link(match_id, Session.CONTINUOUS_MODE)
		if not bool(link.get("ok", false)):
			return {"ok": false}
		var host: Variant = link["host"]
		var gateway: Variant = link["gateway"]
		var observation: Dictionary = host.emit_observation_pair()
		var observation_frame := _decode_only(
			gateway, observation, "gateway disposition observation %d" % index
		)
		if observation_frame.is_empty():
			return {"ok": false}
		var boundary_hash := str(observation_frame["boundary_hash"])
		var terminal := _declare_gateway_disposition(
			host, gateway, boundary_hash, match_id,
			str(row["disposition"]), str(row["code"])
		)
		_check(str(terminal.get("body", {}).get("disposition", ""))
			== str(row["expected_terminal"]),
			"gateway disposition terminal type was wrong for " + str(row["disposition"]))
		_check(terminal.get("body", {}).get("winner_slot") == row["expected_winner"],
			"gateway disposition winner was wrong for " + str(row["disposition"]))
		if str(row["disposition"]) == "draw_double_technical_forfeit":
			_check(not terminal.get("body", {}).has("failure"),
				"double technical forfeit exposed a single-seat failure classification")
		else:
			_check(str(terminal.get("body", {}).get("failure", {}).get("code", ""))
				== str(row["code"]), "gateway disposition terminal code was not preserved")
		if index == 0:
			var first_observation_hash := str(
				observation_frame["body"]["observations"][0]["observation_hash"]
			)
			var late_status_request: Dictionary = gateway.encode(
				"thinking_status", first_observation_hash, {
					"observation_seq": 0,
					"player_slot": 0,
					"status": "ready",
				}
			)
			var late_status_result: Dictionary = host.receive(late_status_request["payload"])
			_check(
				bool(late_status_result.get("ok", false))
				and host.phase() == Host.PHASE_TERMINAL
				and str(late_status_result.get("events", [{}])[0].get("kind", ""))
					== "thinking_status_recorded_after_terminal",
				"validated terminal-adjacent thinking telemetry was not drained safely: %s"
				% str(late_status_result)
			)
			var duplicate_body := _gateway_disposition_body(
				match_id, str(row["disposition"]), str(row["code"])
			)
			var duplicate_request: Dictionary = gateway.encode(
				"gateway_disposition", boundary_hash, duplicate_body
			)
			var duplicate_result: Dictionary = host.receive(duplicate_request["payload"])
			var duplicate_ack := _decode_only(
				gateway, duplicate_result, "duplicate gateway disposition"
			)
			_check(str(duplicate_ack.get("message_type", ""))
				== "gateway_disposition_accepted" and host.phase() == Host.PHASE_TERMINAL,
				"identical gateway disposition was not idempotently acknowledged")
			var conflict_body := _gateway_disposition_body(
				match_id, "technical_forfeit_slot_1", "model_failure_threshold"
			)
			var conflict_request: Dictionary = gateway.encode(
				"gateway_disposition", boundary_hash, conflict_body
			)
			var conflict_result: Dictionary = host.receive(conflict_request["payload"])
			_check(not bool(conflict_result.get("ok", false))
				and str(conflict_result.get("code", "")) == "gateway_disposition_conflict",
				"terminal host did not fail closed on a conflicting duplicate disposition")
		elif index == 1:
			var stale_body := _gateway_disposition_body(
				match_id, str(row["disposition"]), str(row["code"])
			)
			var stale_request: Dictionary = gateway.encode(
				"gateway_disposition", "a".repeat(64), stale_body
			)
			var stale_result: Dictionary = host.receive(stale_request["payload"])
			_check(not bool(stale_result.get("ok", false))
				and str(stale_result.get("code", "")) == "checkpoint_hash_mismatch",
				"host accepted a stale gateway disposition boundary")
		elif index == 2:
			var invalid_body := _gateway_disposition_body(
				match_id, str(row["disposition"]), str(row["code"])
			)
			invalid_body["raw_model_output"] = "must-never-cross"
			var invalid_request: Dictionary = gateway.encode(
				"gateway_disposition", boundary_hash, invalid_body
			)
			var invalid_result: Dictionary = host.receive(invalid_request["payload"])
			_check(not bool(invalid_result.get("ok", false))
				and str(invalid_result.get("code", "")) == "gateway_disposition_invalid",
				"host accepted a non-exact disposition body containing model data")
		records.append({
			"code": str(row["code"]),
			"disposition": str(row["disposition"]),
			"result_hash": str(terminal.get("boundary_hash", "")),
			"terminal": str(terminal.get("body", {}).get("disposition", "")),
			"winner": terminal.get("body", {}).get("winner_slot"),
		})
	return {"cases": records, "ok": true}


func _declare_gateway_disposition(
	host: Variant,
	gateway: Variant,
	boundary_hash: String,
	match_id: String,
	disposition: String,
	code: String
) -> Dictionary:
	var request: Dictionary = gateway.encode(
		"gateway_disposition", boundary_hash,
		_gateway_disposition_body(match_id, disposition, code)
	)
	_check(bool(request.get("ok", false)), "gateway disposition request encoding failed")
	var result: Dictionary = host.receive(request["payload"])
	_check(bool(result.get("ok", false)), "gateway disposition host request failed: " + _errors(result))
	var frames := _decode_frames(gateway, result, "gateway disposition response")
	_check(frames.size() >= 2, "gateway disposition did not emit ACK before terminal")
	if frames.size() < 2:
		return {}
	var ack_frame: Dictionary = frames[0]
	_check(str(ack_frame.get("message_type", "")) == "gateway_disposition_accepted"
		and bool(ack_frame.get("body", {}).get("accepted", false)),
		"gateway disposition acknowledgement was not first")
	var terminal_frame: Dictionary = frames[-1]
	_check(str(terminal_frame.get("message_type", "")) == "terminal",
		"gateway disposition did not immediately emit terminal")
	var terminal_checkpoint: Dictionary = frames[-2]
	_check(str(terminal_checkpoint.get("message_type", "")) == "checkpoint"
		and str(terminal_checkpoint.get("body", {}).get("reason", "")) == "terminal"
		and int(terminal_checkpoint.get("body", {}).get("tick", -1))
		== int(terminal_frame.get("body", {}).get("terminal_tick", -2)),
		"terminal was not preceded by its exact authoritative final-state checkpoint")
	for index: int in range(1, frames.size() - 2):
		_check(str(frames[index].get("message_type", "")) == "tick_events",
			"only bounded tick event evidence may appear between disposition ACK and terminal")
	return terminal_frame


func _gateway_disposition_body(match_id: String, disposition: String, code: String) -> Dictionary:
	var reasons := {
		"draw_double_technical_forfeit": "double_technical_forfeit",
		"technical_forfeit_slot_0": "model_failure",
		"technical_forfeit_slot_1": "model_failure",
		"void_infrastructure": "gateway_infrastructure_failure",
	}
	var body := {
		"code": code,
		"disposition": disposition,
		"match_id": match_id,
		"reason": str(reasons.get(disposition, "")),
	}
	body["request_id"] = Codec.sha256_canonical(body)
	return body


func _configured_link(match_id: String, mode: String) -> Dictionary:
	var token := _vector_token()
	var host := Host.new()
	var gateway := GatewayCodec.new()
	var host_errors := host.configure(match_id, token, "godot-host-integration", {
		"alias_salt_seat_0": "gateway-host-observer-zero".to_utf8_buffer(),
		"alias_salt_seat_1": "gateway-host-observer-one".to_utf8_buffer(),
		"authoritative_hashes": {},
		"scored": false,
		"tie_key": "gateway-host-protected-tie-key".to_utf8_buffer(),
	})
	_check(host_errors.is_empty(), "%s host configure failed: %s" % [mode, "; ".join(host_errors)])
	var gateway_errors := gateway.configure(match_id, token, "gateway")
	_check(gateway_errors.is_empty(), "%s gateway configure failed" % mode)
	if not host_errors.is_empty() or not gateway_errors.is_empty():
		return {"ok": false}
	var hello_result: Dictionary = host.begin_handshake()
	var hello_frame := _decode_only(gateway, hello_result, mode + " hello")
	_check(not hello_frame.is_empty()
		and str(hello_frame.get("message_type", "")) == "hello",
		mode + " host did not emit hello")
	var auth := gateway.encode("auth", GatewayCodec.SESSION_BOUNDARY_HASH, {
		"accepted": true,
		"connection_id": "godot-host-integration",
	})
	var auth_result: Dictionary = host.receive(auth["payload"])
	_check(bool(auth_result.get("ok", false)), mode + " host rejected gateway auth")
	var config := _config(mode)
	var config_hash := Codec.sha256_canonical(config)
	var config_request := gateway.encode("match_config", config_hash, {
		"config": config,
		"config_hash": config_hash,
	})
	var config_result: Dictionary = host.receive(config_request["payload"])
	var config_frame := _decode_only(gateway, config_result, mode + " config acknowledgement")
	_check(not config_frame.is_empty()
		and bool(config_frame["body"].get("accepted", false))
		and host.phase() == Host.PHASE_RUNNING,
		mode + " host did not enter the running phase")
	return {"gateway": gateway, "host": host, "ok": host.phase() == Host.PHASE_RUNNING}


func _decode_only(gateway: Variant, result: Dictionary, label: String) -> Dictionary:
	_check(bool(result.get("ok", false)), label + " host operation failed: " + _errors(result))
	var outbound: Array = result.get("outbound", [])
	_check(outbound.size() == 1, label + " did not emit exactly one frame")
	if outbound.size() != 1:
		return {}
	var decoded: Dictionary = gateway.decode(outbound[0])
	_check(bool(decoded.get("ok", false)), label + " gateway decode failed: " + _errors(decoded))
	return decoded.get("frame", {}) if bool(decoded.get("ok", false)) else {}


func _decode_frames(gateway: Variant, result: Dictionary, label: String) -> Array[Dictionary]:
	var frames: Array[Dictionary] = []
	_check(bool(result.get("ok", false)), label + " host operation failed: " + _errors(result))
	for payload: PackedByteArray in result.get("outbound", []):
		var decoded: Dictionary = gateway.decode(payload)
		_check(bool(decoded.get("ok", false)), label + " gateway decode failed: " + _errors(decoded))
		if bool(decoded.get("ok", false)):
			frames.append(decoded["frame"])
	return frames


func _frame_of_type(frames: Array[Dictionary], message_type: String) -> Dictionary:
	for frame: Dictionary in frames:
		if str(frame.get("message_type", "")) == message_type:
			return frame
	return {}


func _frames_of_type(frames: Array[Dictionary], message_type: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for frame: Dictionary in frames:
		if str(frame.get("message_type", "")) == message_type:
			result.append(frame)
	return result


func _config(mode: String) -> Dictionary:
	return {
		"cadence_profile_id": null,
		"control_profile": "hybrid-v1",
		"decision_mode": mode,
		"decision_period_ticks": 100 if mode == Session.FIXED_MODE else 50,
		"faction_preset_id": "vanguard-v1",
		"map_id": "crossroads-duel-v1",
		"maximum_match_ticks": 18_000,
		"memory_policy": "fresh-match-with-bounded-scratchpad",
		"mirror_faction": true,
		"observation_profile": "full-belief-v1",
		"players": [
			{"model": "model-a", "provider_adapter": null, "reasoning": "medium", "slot": 0},
			{"model": "model-b", "provider_adapter": null, "reasoning": "medium", "slot": 1},
		],
		"protocol_version": "worldeval-rts/1.0.0",
		"response_deadline_ms": 45_000 if mode == Session.FIXED_MODE else 8_000,
		"ruleset_id": "duel-rules-v1",
		"seed": 91_337 if mode == Session.FIXED_MODE else 91_338,
		"simulation_hz": 10,
		"spectator": null,
	}


func _empty_batch(observation: Dictionary, batch_id: String, memory: String) -> Dictionary:
	return {
		"based_on_observation_hash": str(observation["observation_hash"]),
		"client_batch_id": batch_id,
		"commands": [],
		"match_id": str(observation["match_id"]),
		"message_type": "action_batch",
		"observation_seq": int(observation["observation_seq"]),
		"protocol_version": "worldeval-rts/1.0.0",
		"valid_until_tick": int(observation["decision"]["valid_until_tick"]),
		"working_memory": memory,
	}


func _vector_token() -> PackedByteArray:
	var token := PackedByteArray()
	for value: int in 32:
		token.append(value)
	return token


func _errors(result: Dictionary) -> String:
	var messages := PackedStringArray()
	for value: Variant in result.get("errors", []):
		messages.append(str(value))
	return "; ".join(messages)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
