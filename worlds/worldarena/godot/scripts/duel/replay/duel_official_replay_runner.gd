class_name DuelOfficialReplayRunner
extends RefCounted

const Session := preload("res://scripts/duel/match/duel_match_session.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const ActionContract := preload("res://scripts/duel/actions/duel_action_contract.gd")
const PublicEventProjector := preload(
	"res://scripts/duel/match/duel_public_event_projector.gd"
)
const ProjectionBuilder := preload(
	"res://scripts/duel/replay/duel_official_replay_projection_builder.gd"
)

## Provider/network/render-free authoritative replay from genesis.  Every
## acknowledged canonical ActionBatch re-enters the same DuelMatchSession API
## used live; every observation, application receipt, public event, checkpoint,
## and terminal hash is compared before success is returned.

const MAXIMUM_TICK_LIMIT := 18_000
const ACK_SCHEMA := "worldeval-rts/acknowledged-action-batch/1.0.0"
const ACK_FIELDS: Array[String] = [
	"action_batch", "application_seq", "application_tick", "batch_digest", "batch_id",
	"decision_mode", "match_id", "observation_hash", "observation_seq",
	"observation_tick", "opportunity_id", "player_slot", "schema_version",
]
const RECEIPT_FRAME_FIELDS: Array[String] = [
	"application_seq", "application_tick", "checkpoint_hash", "checkpoint_tick",
	"decision_mode", "kind", "match_id", "records",
]
const RECEIPT_RECORD_FIELDS: Array[String] = [
	"batch_digest", "batch_id", "compiled_intents", "player_slot", "receipt",
]

var _event_projector := PublicEventProjector.new()
var _projection_builder := ProjectionBuilder.new()
var _event_cursor := 0
var _expected_events: Array = []
var _omniscient_frames: Array = []
var _seat_frames := {"seat_0": [], "seat_1": []}
var _requested_projection_ticks: Dictionary = {}


func verify(evidence_input: Dictionary, requested_projection_ticks: Array = []) -> Dictionary:
	_reset()
	var errors := PackedStringArray()
	for tick_variant: Variant in requested_projection_ticks:
		if typeof(tick_variant) != TYPE_INT \
			or int(tick_variant) < 0 \
			or int(tick_variant) > MAXIMUM_TICK_LIMIT:
			errors.append("requested omniscient projection tick is invalid")
			continue
		_requested_projection_ticks[int(tick_variant)] = true
	var evidence := evidence_input.duplicate(true)
	_validate_inputs(evidence, errors)
	if not errors.is_empty():
		return _failure("official_replay_input_invalid", errors)

	var match_init: Dictionary = evidence["match_init"]
	var authority: Dictionary = evidence["replay_authority"]
	var mode := str(evidence["decision_mode"])
	_expected_events = evidence["public_events"].duplicate(true)
	var observations_by_tick := _observation_pairs_by_tick(evidence["observations"], errors)
	var receipts_by_checkpoint_tick := _receipts_by_checkpoint_tick(
		evidence["action_receipts"], evidence, errors
	)
	var acknowledged_by_sequence := _acknowledged_by_sequence(
		evidence["acknowledged_action_batches"], evidence, errors
	)
	_validate_application_evidence_join(
		evidence["action_receipts"], acknowledged_by_sequence, evidence, errors
	)
	var checkpoints_by_tick := _checkpoints_by_tick(evidence["checkpoints"], errors)
	if not errors.is_empty():
		return _failure("official_replay_evidence_index_invalid", errors)

	var session := Session.new()
	var configure_errors := session.configure_official({
		"authoritative_hashes": _authoritative_hashes(match_init, authority),
		"decision_mode": mode,
		"faction_id": str(match_init["faction"]["id"]),
		"match_id": str(evidence["match_id"]),
		"match_seed": int(evidence["seed"]),
		"scored": true,
	}, {
		"alias_salt_seat_0": authority["alias_salt_seat_0"],
		"alias_salt_seat_1": authority["alias_salt_seat_1"],
		"tie_key": authority["tie_key"],
	})
	for message: String in configure_errors:
		errors.append("official replay bootstrap: " + message)
	if not errors.is_empty():
		return _failure("official_replay_bootstrap_failed", errors)
	if session.map_manifest != match_init["map_manifest"]:
		errors.append("replay MATCH_INIT map manifest differs from authority genesis")
		return _failure("official_replay_bootstrap_mismatch", errors)

	var terminal_tick := int(evidence["maximum_tick"])
	var next_observation_seq := 0
	_capture_omniscient(session, terminal_tick)
	while true:
		var current_tick := int(session.simulation.state.tick)
		if _requested_projection_ticks.has(current_tick):
			_capture_omniscient(session, terminal_tick)
		# Forced gateway dispositions mutate the terminal checkpoint at this
		# exact tick.  Verify that checkpoint after replaying the disposition,
		# not against the pre-disposition state at the top of the loop.
		var forced_at_current_tick := (
			current_tick == terminal_tick
			and not _forced_disposition(evidence["terminal"]).is_empty()
			and not bool(session.simulation.state.terminal["ended"])
		)
		if not forced_at_current_tick:
			_verify_checkpoint_at_tick(session, checkpoints_by_tick, current_tick, errors)
		if not errors.is_empty():
			return _failure("checkpoint_hash_mismatch", errors)
		if bool(session.simulation.state.terminal["ended"]):
			break
		if current_tick > terminal_tick:
			errors.append("replay authority advanced beyond the recorded terminal tick")
			return _failure("terminal_tick_mismatch", errors)

		if observations_by_tick.has(current_tick):
			var pair: Dictionary = observations_by_tick[current_tick]
			if int(pair["observation_seq"]) != next_observation_seq:
				errors.append("recorded observation sequence is not contiguous during replay")
				return _failure("observation_sequence_mismatch", errors)
			var emitted := session.emit_observation_pair(pair["skipped"])
			_append_result_errors(errors, emitted, "replayed observation")
			if not bool(emitted.get("ok", false)):
				return _failure("observation_replay_failed", errors)
			_compare_observation_pair(emitted, pair, errors)
			if not errors.is_empty():
				return _failure("observation_replay_mismatch", errors)
			_capture_seat_frames(pair)
			_capture_omniscient(session, terminal_tick)
			next_observation_seq += 1

		if receipts_by_checkpoint_tick.has(current_tick):
			var frames: Array = receipts_by_checkpoint_tick[current_tick]
			for frame_variant: Variant in frames:
				var frame: Dictionary = frame_variant
				var application_seq := int(frame["application_seq"])
				var acknowledged: Array = acknowledged_by_sequence.get(application_seq, [])
				if acknowledged.is_empty():
					errors.append("application receipt has no acknowledged ActionBatch evidence")
					return _failure("acknowledged_batch_missing", errors)
				var applied: Dictionary
				if mode == Session.FIXED_MODE:
					applied = _apply_fixed(session, frame, acknowledged)
				else:
					applied = _apply_continuous(session, frame, acknowledged)
				_append_result_errors(errors, applied, "replayed application")
				if not bool(applied.get("ok", false)):
					return _failure("application_replay_failed", errors)
				_compare_application_record(session, frame, errors)
				if not errors.is_empty():
					return _failure("application_replay_mismatch", errors)
				_capture_omniscient(session, terminal_tick)

		if not bool(session.simulation.state.terminal["ended"]) \
			and current_tick == terminal_tick:
			var disposition := _forced_disposition(evidence["terminal"])
			if not disposition.is_empty():
				var declared: Dictionary
				if mode == Session.FIXED_MODE:
					var pair: Dictionary = observations_by_tick.get(current_tick, {})
					# A fixed provider failure at an open decision is sealed through
					# commit/reveal so the outstanding opportunity is closed. A gateway
					# disposition between decision boundaries has no observation pair and
					# uses the same direct authority API as the live host.
					declared = (
						_apply_fixed_terminal(session, pair, disposition)
						if not pair.is_empty()
						else session.declare_gateway_disposition(disposition)
					)
				else:
					declared = session.declare_gateway_disposition(disposition)
				_append_result_errors(errors, declared, "terminal disposition replay")
				if not bool(declared.get("ok", false)):
					return _failure("terminal_disposition_replay_failed", errors)
				_capture_omniscient(session, terminal_tick)

		_capture_events(session, errors)
		if not errors.is_empty():
			return _failure("public_event_replay_mismatch", errors)
		if bool(session.simulation.state.terminal["ended"]):
			_verify_checkpoint_at_tick(session, checkpoints_by_tick, current_tick, errors)
			break
		if current_tick >= terminal_tick:
			errors.append("recorded terminal was not reproduced at its exact tick")
			return _failure("terminal_not_reproduced", errors)
		var advanced := session.advance_ticks(1)
		_append_result_errors(errors, advanced, "replay tick")
		if not bool(advanced.get("ok", false)):
			return _failure("replay_tick_failed", errors)
		_capture_events(session, errors)
		if not errors.is_empty():
			return _failure("public_event_replay_mismatch", errors)

	_capture_events(session, errors)
	var final_tick := int(session.simulation.state.tick)
	_verify_checkpoint_at_tick(session, checkpoints_by_tick, final_tick, errors)
	if final_tick != terminal_tick:
		errors.append("reproduced terminal tick differs from the replay manifest")
	if session.checkpoint_hash() != str(evidence["final_state_sha256"]):
		errors.append("reproduced final authority hash differs from the replay manifest")
	if _event_cursor != _expected_events.size():
		errors.append("reproduced public event stream ended at the wrong cursor")
	var terminal: Dictionary = session.simulation.terminal_result()
	_validate_terminal(terminal, evidence["terminal"], errors)
	if not errors.is_empty():
		return _failure("official_replay_final_mismatch", errors)
	_capture_omniscient(session, terminal_tick)
	return {
		"checkpoint_count": evidence["checkpoints"].size(),
		"errors": errors,
		"final_state_sha256": session.checkpoint_hash(),
		"ok": true,
		"perspectives": {
			"omniscient": _omniscient_frames.duplicate(true),
			"seat_0": (_seat_frames["seat_0"] as Array).duplicate(true),
			"seat_1": (_seat_frames["seat_1"] as Array).duplicate(true),
		},
		"public_event_count": _event_cursor,
		"terminal_tick": final_tick,
	}


func _validate_inputs(evidence: Dictionary, errors: PackedStringArray) -> void:
	for field: String in [
		"acknowledged_action_batches", "action_receipts", "checkpoints", "decision_mode",
		"final_state_sha256", "match_id", "match_init", "maximum_tick", "observations",
		"public_events", "replay_authority", "seed", "terminal",
	]:
		if not evidence.has(field):
			errors.append("official replay evidence is missing %s" % field)
	if str(evidence.get("decision_mode", "")) not in Session.MODES:
		errors.append("official replay decision mode is invalid")
	if typeof(evidence.get("seed")) != TYPE_INT or int(evidence.get("seed", -1)) < 0:
		errors.append("official replay seed is invalid")
	if typeof(evidence.get("maximum_tick")) != TYPE_INT \
		or int(evidence.get("maximum_tick", -1)) < 0 \
		or int(evidence.get("maximum_tick", -1)) > MAXIMUM_TICK_LIMIT:
		errors.append("official replay terminal tick is invalid")
	for field: String in [
		"acknowledged_action_batches", "action_receipts", "checkpoints", "public_events",
	]:
		if typeof(evidence.get(field)) != TYPE_ARRAY:
			errors.append("official replay %s must be an array" % field)
	for field: String in ["match_init", "observations", "replay_authority", "terminal"]:
		if typeof(evidence.get(field)) != TYPE_DICTIONARY:
			errors.append("official replay %s must be an object" % field)


func _observation_pairs_by_tick(observations: Dictionary, errors: PackedStringArray) -> Dictionary:
	var by_identity: Dictionary = {}
	for seat: int in [0, 1]:
		var perspective := "seat_%d" % seat
		for row_variant: Variant in observations.get(perspective, []):
			var row: Dictionary = row_variant
			var identity := "%d:%d" % [int(row["observation_seq"]), int(row["tick"])]
			if not by_identity.has(identity):
				by_identity[identity] = {
					"observations": {},
					"observation_seq": int(row["observation_seq"]),
					"skipped": {},
					"tick": int(row["tick"]),
				}
			var pair: Dictionary = by_identity[identity]
			if pair["observations"].has(seat):
				errors.append("replay observation pair duplicates a seat")
			pair["observations"][seat] = row["observation"].duplicate(true)
			pair["skipped"][seat] = bool(
				row["observation"].get("decision", {}).get("opportunity_skipped", false)
			)
	var result: Dictionary = {}
	for pair_variant: Variant in by_identity.values():
		var pair: Dictionary = pair_variant
		if pair["observations"].size() != 2:
			errors.append("replay observation pair does not contain both seats")
			continue
		var tick := int(pair["tick"])
		if result.has(tick):
			errors.append("replay contains multiple observation pairs at one tick")
		else:
			result[tick] = pair
	return result


func _receipts_by_checkpoint_tick(
	rows: Array, evidence: Dictionary, errors: PackedStringArray
) -> Dictionary:
	var result: Dictionary = {}
	var previous_application_tick := -1
	var previous_checkpoint_tick := -1
	for index: int in rows.size():
		var row_variant: Variant = rows[index]
		if typeof(row_variant) != TYPE_DICTIONARY:
			errors.append("action receipt frame must be an object")
			continue
		var row: Dictionary = row_variant
		_validate_exact_fields(row, RECEIPT_FRAME_FIELDS, "action receipt frame", errors)
		var tick := int(row.get("checkpoint_tick", -1))
		var application_tick := int(row.get("application_tick", -1))
		if typeof(row.get("application_seq")) != TYPE_INT \
			or int(row.get("application_seq", -1)) != index:
			errors.append("action receipt application sequence is not contiguous")
		if str(row.get("match_id", "")) != str(evidence["match_id"]) \
			or str(row.get("decision_mode", "")) != str(evidence["decision_mode"]):
			errors.append("action receipt identity differs from replay evidence")
		var expected_kind := (
			"fixed_pair"
			if str(evidence["decision_mode"]) == Session.FIXED_MODE
			else "continuous_gate"
		)
		if str(row.get("kind", "")) != expected_kind:
			errors.append("action receipt kind differs from replay decision mode")
		if typeof(row.get("checkpoint_tick")) != TYPE_INT \
			or typeof(row.get("application_tick")) != TYPE_INT \
			or tick < 0 or application_tick <= tick \
			or tick < previous_checkpoint_tick \
			or application_tick < previous_application_tick:
			errors.append("action receipt application/checkpoint ticks are invalid")
			continue
		previous_checkpoint_tick = tick
		previous_application_tick = application_tick
		if not _is_sha256(row.get("checkpoint_hash")):
			errors.append("action receipt checkpoint hash is invalid")
		var records: Variant = row.get("records")
		var expected_sizes := [2] if expected_kind == "fixed_pair" else [1, 2]
		if typeof(records) != TYPE_ARRAY or (records as Array).size() not in expected_sizes:
			errors.append("action receipt record count is invalid")
			continue
		var previous_seat := -1
		for record_variant: Variant in records:
			if typeof(record_variant) != TYPE_DICTIONARY:
				errors.append("action receipt record must be an object")
				continue
			var record: Dictionary = record_variant
			_validate_exact_fields(
				record, RECEIPT_RECORD_FIELDS, "action receipt record", errors
			)
			var seat := int(record.get("player_slot", -1))
			if typeof(record.get("player_slot")) != TYPE_INT \
				or seat not in [0, 1] or seat <= previous_seat:
				errors.append("action receipt seats are not in canonical unique order")
			previous_seat = seat
			if not _is_sha256(record.get("batch_digest")) \
				or not ActionContract.is_batch_id(record.get("batch_id")) \
				or typeof(record.get("compiled_intents")) != TYPE_ARRAY \
				or typeof(record.get("receipt")) != TYPE_DICTIONARY:
				errors.append("action receipt record body is invalid")
		var frames: Array = result.get(tick, [])
		frames.append(row)
		result[tick] = frames
	return result


func _acknowledged_by_sequence(
	rows: Array, evidence: Dictionary, errors: PackedStringArray
) -> Dictionary:
	var result: Dictionary = {}
	var observations: Dictionary = evidence["observations"]
	var previous_sequence := -1
	var previous_seat := -1
	for row_variant: Variant in rows:
		if typeof(row_variant) != TYPE_DICTIONARY:
			errors.append("acknowledged ActionBatch row must be an object")
			continue
		var row: Dictionary = row_variant
		_validate_exact_fields(row, ACK_FIELDS, "acknowledged ActionBatch row", errors)
		if str(row.get("schema_version", "")) != ACK_SCHEMA \
			or str(row.get("match_id", "")) != str(evidence["match_id"]) \
			or str(row.get("decision_mode", "")) != str(evidence["decision_mode"]):
			errors.append("acknowledged ActionBatch identity is invalid")
		var sequence := int(row.get("application_seq", -1))
		var seat := int(row.get("player_slot", -1))
		if typeof(row.get("application_seq")) != TYPE_INT \
			or typeof(row.get("application_tick")) != TYPE_INT \
			or typeof(row.get("observation_seq")) != TYPE_INT \
			or typeof(row.get("observation_tick")) != TYPE_INT \
			or typeof(row.get("player_slot")) != TYPE_INT \
			or sequence < 0 or int(row.get("application_tick", -1)) < 1 \
			or int(row.get("observation_seq", -1)) < 0 \
			or int(row.get("observation_tick", -1)) < 0 \
			or seat not in [0, 1] \
			or typeof(row.get("action_batch")) != TYPE_DICTIONARY:
			errors.append("acknowledged ActionBatch sequence/seat/body is invalid")
			continue
		if sequence < previous_sequence \
			or (sequence == previous_sequence and seat <= previous_seat):
			errors.append("acknowledged ActionBatch rows are not globally canonical")
		previous_sequence = sequence
		previous_seat = seat
		var batch: Dictionary = row["action_batch"]
		if Codec.sha256_canonical(batch) != str(row.get("batch_digest", "")) \
			or str(batch.get("client_batch_id", "")) != str(row.get("batch_id", "")):
			errors.append("acknowledged ActionBatch digest or ID mismatch")
		if not ActionContract.envelope_structural_code(batch).is_empty() \
			or str(batch.get("match_id", "")) != str(row.get("match_id", "")) \
			or int(batch.get("observation_seq", -1)) != int(row.get("observation_seq", -2)) \
			or str(batch.get("based_on_observation_hash", "")) \
			!= str(row.get("observation_hash", "")):
			errors.append("acknowledged ActionBatch body differs from its evidence identity")
		var perspective := "seat_%d" % seat
		var found := false
		for observation_variant: Variant in observations.get(perspective, []):
			var observation_row: Dictionary = observation_variant
			if int(observation_row["observation_seq"]) == int(row["observation_seq"]):
				found = int(observation_row["tick"]) == int(row["observation_tick"]) \
					and str(observation_row["observation"].get("observation_hash", "")) \
					== str(row.get("observation_hash", ""))
				break
		if not found:
			errors.append("acknowledged ActionBatch does not bind a protected observation")
		var group: Array = result.get(sequence, [])
		if not group.is_empty() and int(group[-1]["player_slot"]) >= seat:
			errors.append("acknowledged ActionBatch rows are not in canonical unique seat order")
		group.append(row)
		result[sequence] = group
	return result


func _validate_application_evidence_join(
	frames: Array,
	acknowledged_by_sequence: Dictionary,
	evidence: Dictionary,
	errors: PackedStringArray
) -> void:
	if acknowledged_by_sequence.size() != frames.size():
		errors.append("acknowledged ActionBatch applications do not match authority receipts")
	for frame_variant: Variant in frames:
		if typeof(frame_variant) != TYPE_DICTIONARY:
			continue
		var frame: Dictionary = frame_variant
		var sequence := int(frame.get("application_seq", -1))
		if not acknowledged_by_sequence.has(sequence):
			errors.append("authority receipt has no acknowledged ActionBatch group")
			continue
		var acknowledged: Array = acknowledged_by_sequence[sequence]
		var records: Array = frame.get("records", [])
		if acknowledged.size() != records.size():
			errors.append("acknowledged ActionBatch group has the wrong seat count")
			continue
		for index: int in records.size():
			var record: Dictionary = records[index]
			var row: Dictionary = acknowledged[index]
			if int(row.get("application_seq", -1)) != sequence \
				or int(row.get("application_tick", -1)) != int(frame.get("application_tick", -2)) \
				or int(row.get("player_slot", -1)) != int(record.get("player_slot", -2)) \
				or str(row.get("batch_id", "")) != str(record.get("batch_id", "_")) \
				or str(row.get("batch_digest", "")) != str(record.get("batch_digest", "_")):
				errors.append("acknowledged ActionBatch differs from its authority receipt")
		if str(evidence["decision_mode"]) == Session.FIXED_MODE \
			and [int(acknowledged[0]["player_slot"]), int(acknowledged[1]["player_slot"])] \
			!= [0, 1]:
			errors.append("fixed acknowledged ActionBatch group must contain both seats")


func _checkpoints_by_tick(rows: Array, errors: PackedStringArray) -> Dictionary:
	var result: Dictionary = {}
	for row_variant: Variant in rows:
		var row: Dictionary = row_variant
		var tick := int(row.get("tick", -1))
		if tick < 0 or result.has(tick):
			errors.append("replay checkpoints have an invalid or duplicate tick")
		else:
			result[tick] = str(row.get("state_sha256", ""))
	return result


func _apply_fixed(session: Variant, frame: Dictionary, acknowledged: Array) -> Dictionary:
	if acknowledged.size() != 2:
		return _local_failure("fixed application requires two acknowledged batches")
	var observation_seq := int(acknowledged[0]["observation_seq"])
	var boundary_tick := int(acknowledged[0]["observation_tick"])
	var opportunity_id := str(acknowledged[0]["opportunity_id"])
	var commits: Array = []
	var reveals: Array = []
	for row_variant: Variant in acknowledged:
		var row: Dictionary = row_variant
		if int(row["observation_seq"]) != observation_seq \
			or int(row["observation_tick"]) != boundary_tick \
			or str(row["opportunity_id"]) != opportunity_id:
			return _local_failure("fixed acknowledged batches do not share one opportunity")
		var seat := int(row["player_slot"])
		var salt_hex := _replay_salt(session.match_id, observation_seq, seat)
		var batch: Dictionary = row["action_batch"]
		var commit_hash := Session.action_batch_commit_hash(batch, salt_hex)
		if commit_hash.is_empty():
			return _local_failure("fixed acknowledged ActionBatch is not canonical")
		commits.append({"commit_hash": commit_hash, "player_slot": seat})
		reveals.append({"batch": batch.duplicate(true), "player_slot": seat, "salt_hex": salt_hex})
	var locked: Dictionary = session.lock_fixed_commits({
		"boundary_tick": boundary_tick,
		"commits": commits,
		"match_id": str(session.match_id),
		"observation_seq": observation_seq,
		"opportunity_id": opportunity_id,
	})
	if not bool(locked.get("ok", false)):
		return locked
	return session.reveal_fixed_pair({
		"activation_tick": int(frame["application_tick"]),
		"boundary_tick": boundary_tick,
		"disposition": "continue",
		"match_id": str(session.match_id),
		"observation_seq": observation_seq,
		"opportunity_id": opportunity_id,
		"reveals": reveals,
	})


func _apply_continuous(session: Variant, frame: Dictionary, acknowledged: Array) -> Dictionary:
	var applications: Array = []
	for row_variant: Variant in acknowledged:
		var row: Dictionary = row_variant
		applications.append({
			"batch": row["action_batch"].duplicate(true),
			"observation_seq": int(row["observation_seq"]),
			"observation_tick": int(row["observation_tick"]),
			"opportunity_id": str(row["opportunity_id"]),
			"player_slot": int(row["player_slot"]),
		})
	return session.apply_continuous_gate({
		"application_tick": int(frame["application_tick"]),
		"applications": applications,
		"match_id": str(session.match_id),
	})


func _apply_fixed_terminal(
	session: Variant, pair: Dictionary, disposition: String
) -> Dictionary:
	if pair.is_empty():
		return _local_failure("fixed terminal disposition has no recorded observation pair")
	var commits: Array = []
	var reveals: Array = []
	for seat: int in [0, 1]:
		var observation: Dictionary = pair["observations"][seat]
		var batch := {
			"based_on_observation_hash": str(observation["observation_hash"]),
			"client_batch_id": "replay_terminal_noop_%d_%d" % [
				int(pair["observation_seq"]), seat,
			],
			"commands": [],
			"match_id": str(session.match_id),
			"message_type": "action_batch",
			"observation_seq": int(pair["observation_seq"]),
			"protocol_version": ActionContract.PROTOCOL_VERSION,
			"valid_until_tick": int(observation["decision"]["valid_until_tick"]),
		}
		var salt_hex := _replay_salt(session.match_id, int(pair["observation_seq"]), seat)
		commits.append({
			"commit_hash": Session.action_batch_commit_hash(batch, salt_hex),
			"player_slot": seat,
		})
		reveals.append({"batch": batch, "player_slot": seat, "salt_hex": salt_hex})
	var locked: Dictionary = session.lock_fixed_commits({
		"boundary_tick": int(pair["tick"]),
		"commits": commits,
		"match_id": str(session.match_id),
		"observation_seq": int(pair["observation_seq"]),
		"opportunity_id": "opp_%08d" % int(pair["observation_seq"]),
	})
	if not bool(locked.get("ok", false)):
		return locked
	return session.reveal_fixed_pair({
		"activation_tick": int(pair["tick"]) + 1,
		"boundary_tick": int(pair["tick"]),
		"disposition": disposition,
		"match_id": str(session.match_id),
		"observation_seq": int(pair["observation_seq"]),
		"opportunity_id": "opp_%08d" % int(pair["observation_seq"]),
		"reveals": reveals,
	})


func _compare_observation_pair(
	emitted: Dictionary, expected: Dictionary, errors: PackedStringArray
) -> void:
	if int(emitted.get("observation_seq", -1)) != int(expected["observation_seq"]) \
		or int(emitted.get("boundary_tick", -1)) != int(expected["tick"]):
		errors.append("replayed observation identity differs from protected evidence")
	for seat: int in [0, 1]:
		if emitted.get("observations", {}).get(str(seat), {}) \
			!= expected["observations"].get(seat, {}):
			errors.append("replayed seat-%d legal observation differs byte-for-byte" % seat)


func _compare_application_record(
	session: Variant, frame: Dictionary, errors: PackedStringArray
) -> void:
	if int(frame["checkpoint_tick"]) != int(session.simulation.state.tick) \
		or str(frame["checkpoint_hash"]) != session.checkpoint_hash():
		errors.append("application receipt pre-tick checkpoint differs from replay authority")
	var record: Dictionary = session.latest_application_record()
	if int(record.get("application_tick", -1)) != int(frame["application_tick"]) \
		or str(record.get("kind", "")) != str(frame["kind"]):
		errors.append("application record identity differs from authority receipt")
		return
	var expected_records: Array = frame["records"]
	var actual_records: Array = record.get("batches", [])
	if actual_records.size() != expected_records.size():
		errors.append("application record has the wrong seat count")
		return
	for index: int in expected_records.size():
		var expected: Dictionary = expected_records[index]
		var actual: Dictionary = actual_records[index]
		if int(actual.get("player_seat", -1)) != int(expected.get("player_slot", -1)):
			errors.append("application record seat differs from authority receipt")
		for field: String in ["batch_digest", "batch_id", "compiled_intents", "receipt"]:
			if actual.get(field) != expected.get(field):
				errors.append("application record %s differs from authority receipt" % field)


func _verify_checkpoint_at_tick(
	session: Variant, checkpoints: Dictionary, tick: int, errors: PackedStringArray
) -> void:
	if not checkpoints.has(tick):
		return
	var actual: String = session.checkpoint_hash()
	if actual != str(checkpoints[tick]):
		errors.append(
			"checkpoint mismatch at tick %d: expected %s, reproduced %s" % [
				tick, str(checkpoints[tick]), actual,
			]
		)
	else:
		_capture_omniscient(session, tick)


func _capture_events(session: Variant, errors: PackedStringArray) -> void:
	var projected := _event_projector.project_from_cursor(session, _event_cursor)
	_append_result_errors(errors, projected, "public event projection")
	if not bool(projected.get("ok", false)):
		return
	for event_variant: Variant in projected["events"]:
		if _event_cursor >= _expected_events.size() \
			or event_variant != _expected_events[_event_cursor]:
			errors.append("public event stream differs at event index %d" % _event_cursor)
			return
		_event_cursor += 1


func _capture_seat_frames(pair: Dictionary) -> void:
	for seat: int in [0, 1]:
		(_seat_frames["seat_%d" % seat] as Array).append({
			"observation": pair["observations"][seat].duplicate(true),
			"observation_seq": int(pair["observation_seq"]),
			"tick": int(pair["tick"]),
		})


func _capture_omniscient(session: Variant, maximum_tick: int) -> void:
	var projection := _projection_builder.omniscient(session, maximum_tick)
	if projection.is_empty():
		return
	var tick := int(projection["tick"])
	if not _omniscient_frames.is_empty() and int(_omniscient_frames[-1]["tick"]) == tick:
		_omniscient_frames[-1] = {"projection": projection, "tick": tick}
	else:
		_omniscient_frames.append({"projection": projection, "tick": tick})


func _validate_terminal(
	actual: Dictionary, expected: Dictionary, errors: PackedStringArray
) -> void:
	var winner_player: Variant = expected.get("winner_player_id")
	var expected_winner := -1
	if winner_player == "player_a":
		expected_winner = 0
	elif winner_player == "player_b":
		expected_winner = 1
	if int(actual.get("winner_seat", -1)) != expected_winner \
		or str(actual.get("reason", "")) != str(expected.get("reason", "")):
		errors.append("reproduced terminal winner/reason differs from replay manifest")
	var result_map := {
		"draw": "draw",
		"infrastructure_void": "infrastructure_void",
		"normal": "normal",
		"technical_forfeit": "technical_forfeit",
	}
	if str(result_map.get(str(actual.get("result", "")), "")) \
		!= str(expected.get("result", "")):
		errors.append("reproduced terminal result differs from replay manifest")


static func _forced_disposition(terminal: Dictionary) -> String:
	var result := str(terminal.get("result", ""))
	var reason := str(terminal.get("reason", ""))
	if result == "infrastructure_void":
		return "void_infrastructure"
	if result == "technical_forfeit":
		return (
			"technical_forfeit_slot_1"
			if terminal.get("winner_player_id") == "player_a"
			else "technical_forfeit_slot_0"
		)
	if result == "draw" and reason == "double_technical_forfeit":
		return "draw_double_technical_forfeit"
	return ""


static func _authoritative_hashes(match_init: Dictionary, authority: Dictionary) -> Dictionary:
	return {
		"engine_build_hash": str(match_init["artifacts"]["engine_build"]["sha256"]),
		"faction_hash": str(match_init["faction"]["sha256"]),
		"helper_hash": str(match_init["artifacts"]["helper"]["sha256"]),
		"item_hash": str(match_init["artifacts"]["items"]["sha256"]),
		"map_hash": str(match_init["map"]["sha256"]),
		"neutral_hash": str(match_init["artifacts"]["neutrals"]["sha256"]),
		"prompt_hash": str(match_init["artifacts"]["prompt"]["sha256"]),
		"protocol_hash": str(match_init["artifacts"]["protocol"]["sha256"]),
		"ruleset_hash": str(match_init["ruleset"]["sha256"]),
		"tie_key_commitment": Codec.sha256_bytes(authority["tie_key"]),
	}


static func _replay_salt(match_id: String, observation_seq: int, seat: int) -> String:
	return Codec.sha256_text(
		"worldeval-rts/offline-replay-commit-salt/v1" + "\u0000" + match_id \
		+ "\u0000" + str(observation_seq) + "\u0000" + str(seat)
	)


func _reset() -> void:
	_event_cursor = 0
	_expected_events.clear()
	_omniscient_frames.clear()
	_requested_projection_ticks.clear()
	_seat_frames = {"seat_0": [], "seat_1": []}


static func _append_result_errors(
	errors: PackedStringArray, result: Dictionary, context: String
) -> void:
	for message_variant: Variant in result.get("errors", []):
		errors.append("%s: %s" % [context, str(message_variant)])


static func _validate_exact_fields(
	value: Dictionary,
	expected_fields: Array[String],
	context: String,
	errors: PackedStringArray
) -> void:
	if value.size() != expected_fields.size():
		errors.append("%s fields are not exact" % context)
		return
	for field: String in expected_fields:
		if not value.has(field):
			errors.append("%s is missing %s" % [context, field])


static func _is_sha256(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING or str(value).length() != 64:
		return false
	for code: int in str(value).to_ascii_buffer():
		if not (code >= 48 and code <= 57) and not (code >= 97 and code <= 102):
			return false
	return true


static func _local_failure(message: String) -> Dictionary:
	return {"errors": PackedStringArray([message]), "ok": false}


static func _failure(code: String, errors: PackedStringArray) -> Dictionary:
	return {"code": code, "errors": errors, "ok": false}
