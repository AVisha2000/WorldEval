extends SceneTree

const Session := preload("res://scripts/duel/match/duel_match_session.gd")
const ActionContract := preload("res://scripts/duel/actions/duel_action_contract.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const EXPECTED_GOLDEN := "0cdb1e86b438a06228ce97d7179023c3c39e54502ee550428aafe9754aacc96c"
const FIXED_TIE_KEY := "match-session-fixed-protected-tie-key"
const CONTINUOUS_TIE_KEY := "match-session-continuous-protected-tie-key"
const SALT_ZERO := "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
const SALT_ONE := "f0e0d0c0b0a090807060504030201000ffeeddccbbaa99887766554433221100"

var _failures := PackedStringArray()


func _init() -> void:
	_test_cross_runtime_commit_vector()
	_test_partial_application_replay_filter()
	var fixed := _run_fixed(false)
	var fixed_reversed := _run_fixed(true)
	_check(bool(fixed.get("ok", false)), "fixed match session scenario failed")
	_check(bool(fixed_reversed.get("ok", false)), "reversed fixed scenario failed")
	_check(
		str(fixed.get("hash", "")) == str(fixed_reversed.get("hash", "")),
		"fixed commit/reveal input order changed the protected match checkpoint"
	)
	var continuous := _run_continuous()
	_check(bool(continuous.get("ok", false)), "continuous match session scenario failed")
	_test_commit_tamper()
	_test_technical_forfeit()
	var golden_document := {
		"continuous": continuous,
		"fixed": fixed,
	}
	var golden := Codec.sha256_canonical(golden_document)
	if not EXPECTED_GOLDEN.is_empty():
		_check(golden == EXPECTED_GOLDEN, "match-session golden changed: %s" % golden)
	else:
		print("DUEL_MATCH_SESSION_CANDIDATE_GOLDEN=%s" % golden)
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_MATCH_SESSION_FAILURE: %s" % failure)
		print("DUEL_MATCH_SESSION_FAILED count=%d hash=%s" % [_failures.size(), golden])
		quit(1)
		return
	print("DUEL_MATCH_SESSION_OK hash=%s summary=%s" % [
		golden, JSON.stringify({"continuous": continuous["summary"], "fixed": fixed["summary"]}),
	])
	quit(0)


func _test_partial_application_replay_filter() -> void:
	var intents := [
		{
			"operation": "move",
			"source": {"batch_id": "partial.batch", "command_id": "partial", "expansion_index": 0},
		},
		{
			"operation": "move",
			"source": {"batch_id": "partial.batch", "command_id": "partial", "expansion_index": 1},
		},
	]
	var execution_receipts := [
		{"intent_ref": _intent_ref(intents[0]), "status": "rejected"},
		{"intent_ref": _intent_ref(intents[1]), "status": "applied"},
	]
	var replay_intents := Session.applied_compiled_intents_for_replay(intents, execution_receipts)
	_check(replay_intents.size() == 1
		and int(replay_intents[0]["source"]["expansion_index"]) == 1
		and _intent_ref(replay_intents[0]) == str(execution_receipts[1]["intent_ref"]),
		"partial application replay evidence did not retain exactly the applied primitive intent")
	var fully_rejected := Session.applied_compiled_intents_for_replay(
		intents, [
			{"intent_ref": _intent_ref(intents[0]), "status": "rejected"},
			{"intent_ref": _intent_ref(intents[1]), "status": "rejected"},
		]
	)
	_check(fully_rejected.is_empty(),
		"fully rejected command leaked compiled primitive orders into replay evidence")


func _intent_ref(intent: Dictionary) -> String:
	var source: Dictionary = intent["source"]
	return "intent.%s" % Codec.sha256_canonical({
		"batch_id": str(source["batch_id"]),
		"command_id": str(source["command_id"]),
		"expansion_index": int(source["expansion_index"]),
		"operation": str(intent["operation"]),
	}).substr(0, 20)


func _test_cross_runtime_commit_vector() -> void:
	var batch := {
		"based_on_observation_hash": "0".repeat(64),
		"client_batch_id": "vector.batch",
		"commands": [],
		"match_id": "m_commit-vector",
		"message_type": "action_batch",
		"observation_seq": 0,
		"protocol_version": "worldeval-rts/1.0.0",
		"valid_until_tick": 1,
		"working_memory": "vector",
	}
	_check(
		Session.action_batch_commit_hash(batch, SALT_ZERO)
		== "afb111cea7e182183a0f805362dda469a361e471ac6b40c5b5472d9a33318dcc",
		"Godot fixed commit hash disagrees with the frozen Python vector"
	)


func _run_fixed(reverse_wire_rows: bool) -> Dictionary:
	var session := Session.new()
	var errors := session.configure_official(
		_config("m_session-fixed", "fixed_simultaneous", 88_101),
		_protected(FIXED_TIE_KEY)
	)
	_check(errors.is_empty(), "fixed session configure failed: %s" % "; ".join(errors))
	if not errors.is_empty():
		return {"hash": "", "ok": false, "summary": {}}
	var emitted := session.emit_observation_pair()
	_check(bool(emitted.get("ok", false)), "fixed initial observation failed: %s" % _errors(emitted))
	if not bool(emitted.get("ok", false)):
		return {"hash": "", "ok": false, "summary": {}}
	var observation_zero: Dictionary = emitted["observations"]["0"]
	var observation_one: Dictionary = emitted["observations"]["1"]
	_check(int(observation_zero["tick"]) == 0 and int(observation_one["tick"]) == 0,
		"fixed players did not observe the same boundary tick")
	_check(str(observation_zero["observation_hash"]) != str(observation_one["observation_hash"]),
		"fixed observer-specific observations unexpectedly shared one hash")
	var batch_zero := _stop_batch(observation_zero, "fixed.zero", "shared_command", "zero-memory")
	var batch_one := _stop_batch(observation_one, "fixed.one", "shared_command", "one-memory")
	var commit_rows: Array = [
		{
			"commit_hash": Session.action_batch_commit_hash(batch_zero, SALT_ZERO),
			"player_slot": 0,
		},
		{
			"commit_hash": Session.action_batch_commit_hash(batch_one, SALT_ONE),
			"player_slot": 1,
		},
	]
	if reverse_wire_rows:
		commit_rows.reverse()
	var locked := session.lock_fixed_commits({
		"boundary_tick": int(emitted["boundary_tick"]),
		"commits": commit_rows,
		"match_id": "m_session-fixed",
		"observation_seq": int(emitted["observation_seq"]),
		"opportunity_id": str(emitted["opportunity_id"]),
	})
	_check(bool(locked.get("ok", false)), "fixed commit lock failed: %s" % _errors(locked))
	var reveal_rows: Array = [
		{"batch": batch_zero, "player_slot": 0, "salt_hex": SALT_ZERO},
		{"batch": batch_one, "player_slot": 1, "salt_hex": SALT_ONE},
	]
	if reverse_wire_rows:
		reveal_rows.reverse()
	var applied := session.reveal_fixed_pair({
		"activation_tick": 1,
		"boundary_tick": 0,
		"disposition": "continue",
		"match_id": "m_session-fixed",
		"observation_seq": 0,
		"opportunity_id": "opp_00000000",
		"reveals": reveal_rows,
	})
	_check(bool(applied.get("ok", false)), "fixed reveal/apply failed: %s" % _errors(applied))
	if not bool(applied.get("ok", false)):
		return {"hash": "", "ok": false, "summary": {}}
	_check(
		str(applied["receipts"]["0"]["commands"][0]["status"]) == "applied"
		and str(applied["receipts"]["1"]["commands"][0]["status"]) == "applied",
		"same command_id across seats crossed receipt ownership"
	)
	var advanced: Dictionary = {}
	for chunk: int in 10:
		advanced = session.advance_ticks(10)
		if not bool(advanced.get("ok", false)):
			break
	_check(bool(advanced.get("ok", false)) and int(advanced.get("tick", -1)) == 100,
		"fixed session did not advance exactly one 100-tick cadence")
	var next := session.emit_observation_pair()
	_check(bool(next.get("ok", false)), "fixed next observation failed: %s" % _errors(next))
	if not bool(next.get("ok", false)):
		return {"hash": "", "ok": false, "summary": {}}
	_check(int(next["observation_seq"]) == 1 and int(next["boundary_tick"]) == 100,
		"fixed observation sequence/boundary did not advance exactly")
	_check(str(next["observations"]["0"]["working_memory"]) == "zero-memory"
		and str(next["observations"]["1"]["working_memory"]) == "one-memory",
		"fixed per-seat working memory did not persist independently")
	_check(next["observations"]["0"]["last_action_receipt"] != null
		and next["observations"]["1"]["last_action_receipt"] != null,
		"fixed previous receipts were not joined into the next observations")
	_check(not bool(session.advance_ticks(1).get("ok", false)),
		"fixed simulation advanced while the next decision was outstanding")
	var protected_json := Codec.canonical_json(session.to_protected_canonical_dict())
	_check(not protected_json.contains(FIXED_TIE_KEY), "fixed checkpoint leaked the protected tie key")
	var observation_json := str(next["canonical_json"]["0"])
	_check(not observation_json.contains("checkpoint_hash")
		and not observation_json.contains("tie_key"),
		"provider observation leaked protected authority state")
	var summary := {
		"applied_commands": 2,
		"next_observation_seq": int(next["observation_seq"]),
		"orders": int(session.simulation.state.orders.size()),
		"tick": int(session.simulation.state.tick),
	}
	return {"hash": session.checkpoint_hash(), "ok": true, "summary": summary}


func _run_continuous() -> Dictionary:
	var session := Session.new()
	var errors := session.configure_official(
		_config("m_session-continuous", "continuous_realtime", 88_102),
		_protected(CONTINUOUS_TIE_KEY)
	)
	_check(errors.is_empty(), "continuous session configure failed: %s" % "; ".join(errors))
	if not errors.is_empty():
		return {"hash": "", "ok": false, "summary": {}}
	var emitted := session.emit_observation_pair({1: true})
	_check(bool(emitted.get("ok", false)), "continuous initial observation failed: %s" % _errors(emitted))
	if not bool(emitted.get("ok", false)):
		return {"hash": "", "ok": false, "summary": {}}
	var observation: Dictionary = emitted["observations"]["0"]
	_check(observation["decision"]["commands_apply_tick"] == null,
		"continuous observation claimed to know the future arrival gate")
	_check(bool(emitted["observations"]["1"]["decision"].get("opportunity_skipped", false)),
		"continuous skipped in-flight opportunity was not marked")
	var batch := _stop_batch(observation, "continuous.zero", "continuous_stop", "fast-plan")
	var applied := session.apply_continuous_gate({
		"application_tick": 2,
		"applications": [{
			"batch": batch,
			"observation_seq": 0,
			"observation_tick": 0,
			"opportunity_id": "opp_00000000",
			"player_slot": 0,
		}],
		"match_id": "m_session-continuous",
	})
	_check(bool(applied.get("ok", false)), "continuous authoritative gate failed: %s" % _errors(applied))
	_check(str(applied.get("receipts", {}).get("0", {}).get("batch_status", "")) == "applied",
		"continuous valid batch did not receive an applied receipt")
	var repeated := batch.duplicate(true)
	repeated["client_batch_id"] = "continuous.repeated"
	var duplicate_opportunity := session.apply_continuous_gate({
		"application_tick": 3,
		"applications": [{
			"batch": repeated,
			"observation_seq": 0,
			"observation_tick": 0,
			"opportunity_id": "opp_00000000",
			"player_slot": 0,
		}],
		"match_id": "m_session-continuous",
	})
	_check(not bool(duplicate_opportunity.get("ok", false)),
		"continuous opportunity accepted a second response for one seat")
	var skipped_batch := _stop_batch(
		emitted["observations"]["1"], "continuous.skipped", "skipped_stop", "late"
	)
	var skipped_apply := session.apply_continuous_gate({
		"application_tick": 3,
		"applications": [{
			"batch": skipped_batch,
			"observation_seq": 0,
			"observation_tick": 0,
			"opportunity_id": "opp_00000000",
			"player_slot": 1,
		}],
		"match_id": "m_session-continuous",
	})
	_check(not bool(skipped_apply.get("ok", false)),
		"continuous skipped opportunity accepted a model batch")
	var advanced := session.advance_ticks(50)
	_check(bool(advanced.get("ok", false)) and int(advanced.get("tick", -1)) == 50,
		"continuous session did not advance independently while inference was external")
	var next := session.emit_observation_pair()
	_check(bool(next.get("ok", false)), "continuous grid observation failed: %s" % _errors(next))
	if bool(next.get("ok", false)):
		_check(int(next["boundary_tick"]) == 50 and int(next["observation_seq"]) == 1,
			"continuous observation did not land on the exact 50-tick grid")
		_check(str(next["observations"]["0"]["working_memory"]) == "fast-plan",
			"continuous valid response memory did not persist")
	var summary := {
		"accepted_gate_tick": int(applied.get("application_tick", -1)),
		"next_observation_seq": int(next.get("observation_seq", -1)),
		"orders": int(session.simulation.state.orders.size()),
		"tick": int(session.simulation.state.tick),
	}
	return {"hash": session.checkpoint_hash(), "ok": true, "summary": summary}


func _test_commit_tamper() -> void:
	var session := Session.new()
	_check(session.configure_official(
		_config("m_session-tamper", "fixed_simultaneous", 88_103),
		_protected("match-session-tamper-tie-key")
	).is_empty(), "tamper session configure failed")
	var emitted := session.emit_observation_pair()
	if not bool(emitted.get("ok", false)):
		_check(false, "tamper observation setup failed")
		return
	var zero := _stop_batch(emitted["observations"]["0"], "tamper.zero", "zero", "")
	var one := _stop_batch(emitted["observations"]["1"], "tamper.one", "one", "")
	var locked := session.lock_fixed_commits({
		"boundary_tick": 0,
		"commits": [
			{"commit_hash": Session.action_batch_commit_hash(zero, SALT_ZERO), "player_slot": 0},
			{"commit_hash": Session.action_batch_commit_hash(one, SALT_ONE), "player_slot": 1},
		],
		"match_id": "m_session-tamper",
		"observation_seq": 0,
		"opportunity_id": "opp_00000000",
	})
	_check(bool(locked.get("ok", false)), "tamper commits failed to lock")
	zero["working_memory"] = "changed-after-commit"
	var revealed := session.reveal_fixed_pair({
		"activation_tick": 1,
		"boundary_tick": 0,
		"disposition": "continue",
		"match_id": "m_session-tamper",
		"observation_seq": 0,
		"opportunity_id": "opp_00000000",
		"reveals": [
			{"batch": zero, "player_slot": 0, "salt_hex": SALT_ZERO},
			{"batch": one, "player_slot": 1, "salt_hex": SALT_ONE},
		],
	})
	_check(not bool(revealed.get("ok", false)), "modified fixed batch passed commit verification")


func _test_technical_forfeit() -> void:
	var session := Session.new()
	_check(session.configure_official(
		_config("m_session-forfeit", "continuous_realtime", 88_104),
		_protected("match-session-forfeit-tie-key")
	).is_empty(), "forfeit session configure failed")
	var result := session.declare_gateway_disposition("technical_forfeit_slot_1")
	_check(bool(result.get("ok", false))
		and bool(result["terminal"]["ended"])
		and int(result["terminal"]["winner_seat"]) == 0,
		"technical forfeit was not routed through Godot terminal authority")


static func _config(match_id: String, mode: String, seed: int) -> Dictionary:
	return {
		"authoritative_hashes": {},
		"decision_mode": mode,
		"faction_id": "vanguard-v1",
		"match_id": match_id,
		"match_seed": seed,
		"scored": false,
	}


static func _protected(tie_key: String) -> Dictionary:
	return {
		"alias_salt_seat_0": (tie_key + ":observer-zero").to_utf8_buffer(),
		"alias_salt_seat_1": (tie_key + ":observer-one").to_utf8_buffer(),
		"tie_key": tie_key.to_utf8_buffer(),
	}


static func _stop_batch(
	observation: Dictionary,
	batch_id: String,
	command_id: String,
	working_memory: String
) -> Dictionary:
	var owned: Array = observation["owned_entities"]
	var actor_id := str(owned[0]["entity_id"])
	return {
		"based_on_observation_hash": str(observation["observation_hash"]),
		"client_batch_id": batch_id,
		"commands": [{"actor_ids": [actor_id], "command_id": command_id, "op": "stop"}],
		"match_id": str(observation["match_id"]),
		"message_type": "action_batch",
		"observation_seq": int(observation["observation_seq"]),
		"protocol_version": ActionContract.PROTOCOL_VERSION,
		"valid_until_tick": int(observation["decision"]["valid_until_tick"]),
		"working_memory": working_memory,
	}


static func _errors(result: Dictionary) -> String:
	var messages := PackedStringArray()
	for message_variant: Variant in result.get("errors", []):
		messages.append(str(message_variant))
	return "; ".join(messages)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
