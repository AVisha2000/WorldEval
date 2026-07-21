extends SceneTree

const Session := preload("res://scripts/duel/match/duel_match_session.gd")
const ActionContract := preload("res://scripts/duel/actions/duel_action_contract.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const EventProjector := preload("res://scripts/duel/match/duel_public_event_projector.gd")
const OfficialRunner := preload(
	"res://scripts/duel/replay/duel_official_replay_runner.gd"
)
const OfficialVerifier := preload(
	"res://scripts/duel/replay/duel_official_replay_verifier.gd"
)
const BundleLoader := preload(
	"res://scripts/duel/replay/duel_replay_bundle_loader.gd"
)
const OfficialPlayer := preload(
	"res://scripts/duel/replay/duel_official_replay_player.gd"
)
const ReplayAdapter := preload(
	"res://scripts/duel/presentation/duel_replay_presentation_adapter.gd"
)
const Presentation := preload(
	"res://scripts/duel/presentation/duel_presentation.gd"
)

const FIXED_MODE := "fixed_simultaneous"
const CONTINUOUS_MODE := "continuous_realtime"
const TERMINAL_TICK := 1
const ACK_SCHEMA := "worldeval-rts/acknowledged-action-batch/1.0.0"
const EXPECTED_GOLDEN := "3f81e423c46b907521c75e26ae8665524e73c731f0536c2a883bcd3b243b15d8"

var _failures := PackedStringArray()


func _init() -> void:
	_test_canonical_decoder()
	var fixed := _build_evidence(FIXED_MODE, 74_101)
	var continuous := _build_evidence(CONTINUOUS_MODE, 74_102)
	_check(bool(fixed.get("ok", false)), "fixed replay fixture construction failed")
	_check(bool(continuous.get("ok", false)), "continuous replay fixture construction failed")
	if not bool(fixed.get("ok", false)) or not bool(continuous.get("ok", false)):
		_finish("")
		return

	var materialized := _materialized_package(fixed["evidence"])
	_check(bool(materialized.get("ok", false)), "materialized replay bundle did not load: %s" % _errors(materialized))
	var fixed_verification := (
		OfficialVerifier.new().verify_package(materialized["package"])
		if bool(materialized.get("ok", false))
		else materialized
	)
	var continuous_verification := OfficialVerifier.new().verify_package(
		_verification_package(continuous["evidence"], true)
	)
	_assert_verifier_result(fixed_verification, "fixed")
	_assert_verifier_result(continuous_verification, "continuous")
	var fixed_result := _runner_result_from_verification(fixed_verification)
	var continuous_result := _runner_result_from_verification(continuous_verification)
	_assert_verified_result(fixed_result, fixed["evidence"], "fixed")
	_assert_verified_result(continuous_result, continuous["evidence"], "continuous")
	_test_tamper_rejection(fixed["evidence"])
	_test_player_and_presenter(fixed_verification)
	_test_insufficient_verifier_and_player(fixed["evidence"])

	var summary := {
		"continuous": _summary(continuous["evidence"], continuous_result),
		"fixed": _summary(fixed["evidence"], fixed_result),
	}
	var golden := Codec.sha256_canonical(summary)
	if EXPECTED_GOLDEN.is_empty():
		print("DUEL_OFFICIAL_REPLAY_CANDIDATE_GOLDEN=%s" % golden)
	else:
		_check(golden == EXPECTED_GOLDEN, "official replay golden changed: %s" % golden)
	_finish(golden)


func _test_canonical_decoder() -> void:
	var valid_errors := PackedStringArray()
	var valid: Variant = BundleLoader.parse_canonical_value(
		'{"maximum":9007199254740991,"minimum":-9007199254740991}'.to_utf8_buffer(),
		"integer fixture",
		valid_errors
	)
	_check(
		valid_errors.is_empty() \
			and typeof(valid) == TYPE_DICTIONARY \
			and typeof(valid["maximum"]) == TYPE_INT,
		"canonical decoder did not preserve interoperable integer tokens"
	)
	for invalid_text: String in [
		'{"value":1.0}',
		'{"value":1e3}',
		'{"duplicate":1,"duplicate":2}',
		'{"unsafe":9007199254740992}',
		'{"z":0,"a":1}',
	]:
		var invalid_errors := PackedStringArray()
		BundleLoader.parse_canonical_value(
			invalid_text.to_utf8_buffer(), "invalid fixture", invalid_errors
		)
		_check(not invalid_errors.is_empty(), "invalid/noncanonical JSON passed replay decoding")


func _build_evidence(mode: String, seed: int) -> Dictionary:
	var match_id := "m_official-replay-%s" % (
		"fixed" if mode == FIXED_MODE else "continuous"
	)
	var protected := _protected(mode)
	var probe := Session.new()
	var probe_errors := probe.configure_official({
		"authoritative_hashes": {},
		"decision_mode": mode,
		"faction_id": "vanguard-v1",
		"match_id": match_id,
		"match_seed": seed,
		"scored": false,
	}, protected)
	if not probe_errors.is_empty():
		return _fixture_failure("unscored hash probe failed: %s" % "; ".join(probe_errors))
	var hashes := _scored_hashes(probe, protected["tie_key"])
	var session := Session.new()
	var errors := session.configure_official({
		"authoritative_hashes": hashes,
		"decision_mode": mode,
		"faction_id": "vanguard-v1",
		"match_id": match_id,
		"match_seed": seed,
		"scored": true,
	}, protected)
	if not errors.is_empty():
		return _fixture_failure("scored source session failed: %s" % "; ".join(errors))
	var emitted := session.emit_observation_pair()
	if not bool(emitted.get("ok", false)):
		return _fixture_failure("source observation failed: %s" % _errors(emitted))

	var batches := {
		0: _noop_batch(emitted["observations"]["0"], "replay.fixed-or-live.zero", "memory-zero"),
		1: _noop_batch(emitted["observations"]["1"], "replay.fixed-or-live.one", "memory-one"),
	}
	var applied: Dictionary
	if mode == FIXED_MODE:
		applied = _apply_source_fixed(session, emitted, batches)
	else:
		applied = session.apply_continuous_gate({
			"application_tick": TERMINAL_TICK,
			"applications": [
				_application_row(emitted, batches[0], 0),
				_application_row(emitted, batches[1], 1),
			],
			"match_id": match_id,
		})
	if not bool(applied.get("ok", false)):
		return _fixture_failure("source application failed: %s" % _errors(applied))
	var receipt_frame := _receipt_frame(session, 0)
	var acknowledged := _acknowledged_rows(mode, emitted, batches, receipt_frame)

	var advanced := session.advance_ticks(TERMINAL_TICK)
	if not bool(advanced.get("ok", false)) \
		or int(advanced.get("tick", -1)) != TERMINAL_TICK:
		return _fixture_failure("source session did not reach the terminal tick")
	var declared := session.declare_gateway_disposition("draw_double_technical_forfeit")
	if not bool(declared.get("ok", false)):
		return _fixture_failure("source terminal disposition failed: %s" % _errors(declared))
	var public_events_result := EventProjector.new().project_from_cursor(session, 0)
	if not bool(public_events_result.get("ok", false)):
		return _fixture_failure("source event projection failed: %s" % _errors(public_events_result))
	var terminal: Dictionary = session.simulation.terminal_result()
	var final_hash := session.checkpoint_hash()
	var evidence := {
		"accepted_actions": [],
		"acknowledged_action_batches": acknowledged,
		"action_receipts": [receipt_frame],
		"checkpoints": [{"state_sha256": final_hash, "tick": TERMINAL_TICK}],
		"compiled_orders": [],
		"decision_mode": mode,
		"final_state_sha256": final_hash,
		"match_id": match_id,
		"match_init": _match_init(session, hashes),
		"maximum_tick": TERMINAL_TICK,
		"observations": _protected_observations(emitted),
		"public_events": public_events_result["events"].duplicate(true),
		"replay_authority": {
			"alias_salt_seat_0": protected["alias_salt_seat_0"].duplicate(),
			"alias_salt_seat_1": protected["alias_salt_seat_1"].duplicate(),
			"tie_key": protected["tie_key"].duplicate(),
		},
		"seed": seed,
		"terminal": {
			"reason": str(terminal["reason"]),
			"result": str(terminal["result"]),
			"tick": TERMINAL_TICK,
			"winner_player_id": null,
		},
	}
	return {"evidence": evidence, "ok": true}


func _assert_verified_result(
	result: Dictionary, evidence: Dictionary, label: String
) -> void:
	_check(bool(result.get("ok", false)), "%s exact replay failed: %s" % [
		label, _errors(result),
	])
	if not bool(result.get("ok", false)):
		return
	_check(
		str(result.get("final_state_sha256", "")) == str(evidence["final_state_sha256"]),
		"%s exact replay returned the wrong final hash" % label
	)
	_check(
		int(result.get("terminal_tick", -1)) == TERMINAL_TICK,
		"%s exact replay returned the wrong terminal tick" % label
	)
	var perspectives: Dictionary = result.get("perspectives", {})
	_check(
		(perspectives.get("omniscient", []) as Array).size() >= 2,
		"%s replay did not expose verified omniscient frames" % label
	)
	for perspective: String in ["seat_0", "seat_1"]:
		_check(
			(perspectives.get(perspective, []) as Array).size() == 1,
			"%s replay did not retain exactly one legal %s observation" % [
				label, perspective,
			]
		)


func _assert_verifier_result(result: Dictionary, label: String) -> void:
	_check(bool(result.get("ok", false)), "%s package verification failed: %s" % [
		label, _errors(result),
	])
	_check(
		bool(result.get("integrity_verified", false)) \
			and bool(result.get("authority_replay_ready", false)) \
			and str(result.get("code", "")) == "verified",
		"%s package was not labelled authority-verified" % label
	)


func _test_tamper_rejection(evidence: Dictionary) -> void:
	var checkpoint_tamper := evidence.duplicate(true)
	checkpoint_tamper["checkpoints"][0]["state_sha256"] = "0".repeat(64)
	var checkpoint_result := OfficialRunner.new().verify(checkpoint_tamper)
	_check(not bool(checkpoint_result.get("ok", true)), "tampered checkpoint replay succeeded")
	_check(
		str(checkpoint_result.get("code", "")) in [
			"checkpoint_hash_mismatch", "official_replay_final_mismatch",
		],
		"tampered checkpoint did not fail at checkpoint verification"
	)

	var batch_tamper := evidence.duplicate(true)
	batch_tamper["acknowledged_action_batches"][0]["action_batch"]["working_memory"] = (
		"tampered-memory"
	)
	var batch_result := OfficialRunner.new().verify(batch_tamper)
	_check(not bool(batch_result.get("ok", true)), "tampered canonical ActionBatch replay succeeded")
	_check(
		str(batch_result.get("code", "")) == "official_replay_evidence_index_invalid",
		"tampered canonical ActionBatch did not fail before authority replay"
	)

	var observation_tamper := evidence.duplicate(true)
	observation_tamper["observations"]["seat_0"][0]["observation"]["working_memory"] = "bad"
	var observation_result := OfficialRunner.new().verify(observation_tamper)
	_check(not bool(observation_result.get("ok", true)), "tampered observation replay succeeded")


func _test_player_and_presenter(verification: Dictionary) -> void:
	if not bool(verification.get("ok", false)):
		return
	var player := OfficialPlayer.new()
	var loaded := player.load_verification(verification)
	_check(bool(loaded.get("ok", false)), "verified player did not load")
	_check(bool(player.replay_state()["verified"]), "verified replay HUD flag was not enabled")
	_check(
		bool(player.current_perspective_record().get("available", false)),
		"verified genesis omniscient perspective is unavailable"
	)
	_check(bool(player.seek_tick(TERMINAL_TICK).get("ok", false)), "verified seek failed")
	var terminal_record := player.current_perspective_record()
	_check(
		int(terminal_record.get("recorded_tick", -1)) == TERMINAL_TICK \
			and int(terminal_record.get("stale_ticks", -1)) == 0,
		"explicit seek did not resimulate the exact requested tick"
	)
	_check(bool(player.set_playback_speed(4.0).get("ok", false)), "4x speed was rejected")
	_check(not bool(player.set_playback_speed(3.0).get("ok", true)), "invalid speed was accepted")
	_check(bool(player.set_paused(false).get("ok", false)), "replay unpause failed")
	_check(bool(player.seek_tick(0).get("ok", false)), "verified rewind failed")
	_check(bool(player.advance_elapsed_ms(25).get("ok", false)), "elapsed playback failed")
	_check(int(player.replay_state()["tick"]) == 1, "4x playback used the wrong integer cadence")

	_check(bool(player.set_perspective("seat_0").get("ok", false)), "seat-0 view unavailable")
	var seat_zero := player.current_perspective_record()
	_check(
		str(seat_zero.get("kind", "")) == "recorded_legal_observation",
		"seat view was not sourced from its protected legal observation"
	)
	_check(bool(player.set_perspective("seat_1").get("ok", false)), "seat-1 view unavailable")
	var seat_one := player.current_perspective_record()
	_check(
		str(seat_zero.get("observation", {}).get("observation_hash", "")) \
			!= str(seat_one.get("observation", {}).get("observation_hash", "")),
		"seat perspectives collapsed into one shared knowledge state"
	)

	var presentation := Presentation.new()
	root.add_child(presentation)
	var adapter := ReplayAdapter.new()
	var bound := adapter.bind(presentation, player)
	_check(bool(bound.get("ok", false)), "replay presentation adapter did not bind")
	presentation.activate_perspective("seat_0", false)
	player.set_perspective("seat_0")
	_check(
		str(presentation.cached_projection_copy("seat_0").get("projection_kind", "")) \
			== "recorded_legal_observation",
		"presentation did not render the legal seat projection"
	)
	presentation.activate_perspective("omniscient", false)
	player.set_perspective("omniscient")
	_check(
		str(presentation.cached_projection_copy("omniscient").get("projection_kind", "")) \
			== "verified_omniscient_authority",
		"presentation did not render the verified omniscient projection"
	)
	adapter.unbind()
	presentation.free()


func _test_insufficient_verifier_and_player(evidence: Dictionary) -> void:
	var insufficient := OfficialVerifier.new().verify_package(
		_verification_package(evidence, false)
	)
	_check(not bool(insufficient.get("ok", true)), "insufficient package verified successfully")
	_check(bool(insufficient.get("integrity_verified", false)), "valid bundle integrity was lost")
	_check(
		str(insufficient.get("code", "")) \
			== "insufficient_authoritative_application_evidence" \
			and not bool(insufficient.get("authority_replay_ready", true)),
		"missing canonical batches did not return the stable insufficiency result"
	)
	_check(
		str(insufficient.get("error", {}).get("schema_version", "")) \
			== "worldeval-rts/replay-insufficiency/1.0.0",
		"insufficiency result schema is missing or unstable"
	)
	var player := OfficialPlayer.new()
	var loaded := player.load_verification(insufficient)
	_check(bool(loaded.get("ok", false)), "integrity-only replay timeline did not load")
	_check(not bool(player.replay_state()["verified"]), "insufficient replay was labelled verified")
	var omni := player.current_perspective_record()
	_check(
		not bool(omni.get("available", true)) \
			and str(omni.get("code", "")) == "omniscient_projection_evidence_unavailable",
		"insufficient replay fabricated an omniscient projection"
	)
	_check(
		bool(player.set_perspective("seat_0").get("ok", false)),
		"recorded protected seat observation was not safely available"
	)


func _materialized_package(evidence: Dictionary) -> Dictionary:
	var source := _verification_package(evidence, true)
	var nonce := "%d_%d" % [Time.get_ticks_usec(), randi()]
	var public_directory := ProjectSettings.globalize_path(
		"user://official_replay_%s_public" % nonce
	)
	var protected_directory := ProjectSettings.globalize_path(
		"user://official_replay_%s_protected" % nonce
	)
	var public_bundle := _write_materialized_layer(
		public_directory,
		"publishable",
		source["public"]["manifest"],
		source["public"]["artifacts"]
	)
	if not bool(public_bundle.get("ok", false)):
		return public_bundle
	var protected_manifest: Dictionary = source["protected"]["manifest"].duplicate(true)
	protected_manifest["publishable_bundle"] = {
		"content_sha256": str(public_bundle["content_sha256"]),
		"index_sha256": str(public_bundle["index"]["index_sha256"]),
		"manifest_sha256": str(public_bundle["index"]["manifest"]["sha256"]),
	}
	var protected_bundle := _write_materialized_layer(
		protected_directory,
		"protected_audit",
		protected_manifest,
		source["protected"]["artifacts"]
	)
	if not bool(protected_bundle.get("ok", false)):
		return protected_bundle
	var loaded := BundleLoader.new().load_materialized(
		public_directory,
		protected_directory,
		str(public_bundle["content_sha256"]),
		str(protected_bundle["content_sha256"])
	)
	if not bool(loaded.get("ok", false)):
		return loaded

	# Payload bytes are re-read and hashed on every load. Prove a changed
	# content-addressed object cannot reuse the already verified index.
	var first_descriptor: Dictionary = public_bundle["index"]["artifacts"][0]
	var payload_path := public_directory.path_join(str(first_descriptor["path"]))
	var original := _read_file_bytes(payload_path)
	var altered := original.duplicate()
	altered.append(10)
	if _write_file_bytes(payload_path, altered):
		var tampered := BundleLoader.new().load_materialized(
			public_directory, protected_directory
		)
		_check(
			not bool(tampered.get("ok", true)) \
				and str(tampered.get("code", "")) == "bundle_payload_mismatch",
			"materialized payload tamper was not rejected by its descriptor hash"
		)
	return loaded


func _write_materialized_layer(
	directory: String,
	layer_name: String,
	manifest_input: Dictionary,
	artifacts: Dictionary
) -> Dictionary:
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return _fixture_failure("could not create materialized replay directory")
	var roles: Array[String] = []
	for role_variant: Variant in artifacts.keys():
		roles.append(str(role_variant))
	roles.sort()
	var descriptors: Array = []
	var payloads: Dictionary = {}
	for role: String in roles:
		var artifact: Dictionary = artifacts[role]
		var bytes: PackedByteArray = artifact["bytes"]
		var digest := _bundle_sha256(bytes)
		var path := "objects/sha256/" + digest
		descriptors.append({
			"bytes": bytes.size(),
			"media_type": str(artifact["descriptor"]["media_type"]),
			"path": path,
			"role": role,
			"sha256": digest,
		})
		payloads[path] = bytes.duplicate()
	var manifest := manifest_input.duplicate(true)
	manifest["files"] = descriptors.duplicate(true)
	var manifest_path := (
		"replay-manifest.json"
		if layer_name == "publishable"
		else "protected-audit-manifest.json"
	)
	var manifest_bytes := Codec.canonical_bytes(manifest)
	var manifest_descriptor := {
		"bytes": manifest_bytes.size(),
		"media_type": "application/json",
		"path": manifest_path,
		"sha256": Codec.sha256_bytes(manifest_bytes),
	}
	payloads[manifest_path] = manifest_bytes
	var index_body := {
		"artifacts": descriptors,
		"layer": layer_name,
		"manifest": manifest_descriptor,
		"schema_version": "worldeval-rts/artifact-bundle/1.0.0",
	}
	var index := index_body.duplicate(true)
	index["index_sha256"] = Codec.sha256_canonical(index_body)
	var payload_rows: Array = []
	var payload_paths: Array[String] = []
	for path_variant: Variant in payloads.keys():
		payload_paths.append(str(path_variant))
	payload_paths.sort()
	for path: String in payload_paths:
		payload_rows.append({
			"data_base64": (
				"" if (payloads[path] as PackedByteArray).is_empty()
				else Marshalls.raw_to_base64(payloads[path])
			),
			"path": path,
		})
	var content_sha256 := Codec.sha256_canonical({
		"index": index,
		"payloads": payload_rows,
	})
	if not _write_file_bytes(directory.path_join("bundle-index.json"), Codec.canonical_bytes(index)):
		return _fixture_failure("could not write replay bundle index")
	for path: String in payload_paths:
		var absolute := directory.path_join(path)
		var base_directory := absolute.get_base_dir()
		if (
			not DirAccess.dir_exists_absolute(base_directory)
			and DirAccess.make_dir_recursive_absolute(base_directory) != OK
		) or not _write_file_bytes(absolute, payloads[path]):
			return _fixture_failure("could not write replay bundle payload")
	return {
		"content_sha256": content_sha256,
		"index": index,
		"ok": true,
	}


static func _write_file_bytes(path: String, bytes: PackedByteArray) -> bool:
	var stream := FileAccess.open(path, FileAccess.WRITE)
	if stream == null:
		return false
	stream.store_buffer(bytes)
	stream.close()
	return true


static func _read_file_bytes(path: String) -> PackedByteArray:
	var stream := FileAccess.open(path, FileAccess.READ)
	if stream == null:
		return PackedByteArray()
	var result := stream.get_buffer(stream.get_length())
	stream.close()
	return result


static func _bundle_sha256(bytes: PackedByteArray) -> String:
	return (
		"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
		if bytes.is_empty()
		else Codec.sha256_bytes(bytes)
	)


func _verification_package(evidence: Dictionary, include_acknowledged: bool) -> Dictionary:
	var checkpoints: Array = []
	for checkpoint_variant: Variant in evidence["checkpoints"]:
		var checkpoint: Dictionary = checkpoint_variant
		checkpoints.append({
			"actions_through_index": _latest_public_index(
				evidence["accepted_actions"], int(checkpoint["tick"]), "application_tick"
			),
			"events_through_index": _latest_public_index(
				evidence["public_events"], int(checkpoint["tick"]), "tick"
			),
			"state_sha256": str(checkpoint["state_sha256"]),
			"tick": int(checkpoint["tick"]),
		})
	var public_manifest := {
		"checkpoints": checkpoints,
		"decision": {"mode": str(evidence["decision_mode"])},
		"files": [],
		"final_state_sha256": str(evidence["final_state_sha256"]),
		"match_id": str(evidence["match_id"]),
		"schema_version": "worldeval-rts/replay-manifest/1.0.0",
		"seed": int(evidence["seed"]),
		"terminal": evidence["terminal"].duplicate(true),
	}
	var public_content_sha := "1".repeat(64)
	var public_index_sha := "2".repeat(64)
	var public_manifest_sha := Codec.sha256_canonical(public_manifest)
	var match_init: Dictionary = evidence["match_init"]
	var protected_manifest := {
		"audit_metadata": {
			"decision_mode": str(evidence["decision_mode"]),
			"match_init_sha256": Codec.sha256_canonical(match_init),
		},
		"files": [],
		"match_id": str(evidence["match_id"]),
		"publishable_bundle": {
			"content_sha256": public_content_sha,
			"index_sha256": public_index_sha,
			"manifest_sha256": public_manifest_sha,
		},
		"schema_version": "worldeval-rts/protected-audit-manifest/1.0.0",
	}
	var state_record := {
		"checkpoints": checkpoints,
		"final_state_sha256": str(evidence["final_state_sha256"]),
		"terminal_tick": int(evidence["maximum_tick"]),
	}
	var public_artifacts := {
		"accepted_actions": _artifact(
			_canonical_jsonl(evidence["accepted_actions"]), "application/x-ndjson"
		),
		"compiled_orders": _artifact(
			_canonical_jsonl(evidence["compiled_orders"]), "application/x-ndjson"
		),
		"public_events": _artifact(
			_canonical_jsonl(evidence["public_events"]), "application/x-ndjson"
		),
		"state_checkpoints": _artifact(
			Codec.canonical_bytes(state_record), "application/json"
		),
	}
	var protected_artifacts := {
		"action_receipts": _artifact(
			_canonical_jsonl(evidence["action_receipts"]), "application/x-ndjson"
		),
		"match_init": _artifact(Codec.canonical_bytes(match_init), "application/json"),
		"observations": _artifact(
			_canonical_jsonl(_observation_artifact_rows(evidence["observations"])),
			"application/x-ndjson"
		),
		"replay_authority": _artifact(
			Codec.canonical_bytes(_authority_artifact(evidence["replay_authority"])),
			"application/json"
		),
	}
	if include_acknowledged:
		protected_artifacts["acknowledged_action_batches"] = _artifact(
			_canonical_jsonl(evidence["acknowledged_action_batches"]),
			"application/x-ndjson"
		)
	return {
		"protected": {
			"artifacts": protected_artifacts,
			"content_sha256": "3".repeat(64),
			"index": {},
			"manifest": protected_manifest,
		},
		"public": {
			"artifacts": public_artifacts,
			"content_sha256": public_content_sha,
			"index": {
				"index_sha256": public_index_sha,
				"manifest": {"sha256": public_manifest_sha},
			},
			"manifest": public_manifest,
		},
	}


static func _runner_result_from_verification(verification: Dictionary) -> Dictionary:
	if not bool(verification.get("authority_replay_ready", false)):
		return {
			"code": str(verification.get("code", "verification_failed")),
			"errors": verification.get("errors", PackedStringArray()),
			"ok": false,
		}
	var evidence: Dictionary = verification["evidence"]
	return {
		"checkpoint_count": int(evidence.get("verified_checkpoint_count", -1)),
		"errors": PackedStringArray(),
		"final_state_sha256": str(evidence["final_state_sha256"]),
		"ok": true,
		"perspectives": evidence["perspectives"].duplicate(true),
		"public_event_count": int(evidence.get("verified_public_event_count", -1)),
		"terminal_tick": int(evidence["maximum_tick"]),
	}


static func _observation_artifact_rows(observations: Dictionary) -> Array:
	var result: Array = []
	for seat: int in [0, 1]:
		for row_variant: Variant in observations["seat_%d" % seat]:
			var row: Dictionary = row_variant
			var observation: Dictionary = row["observation"]
			result.append({
				"canonical_bytes_base64": Marshalls.raw_to_base64(
					Codec.canonical_bytes(observation)
				),
				"observation_hash": str(observation["observation_hash"]),
				"observation_seq": int(row["observation_seq"]),
				"player_slot": seat,
				"tick": int(row["tick"]),
			})
	result.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return [int(left["observation_seq"]), int(left["player_slot"])] \
			< [int(right["observation_seq"]), int(right["player_slot"])]
	)
	return result


static func _authority_artifact(authority: Dictionary) -> Dictionary:
	return {
		"alias_salt_seat_0_base64": Marshalls.raw_to_base64(authority["alias_salt_seat_0"]),
		"alias_salt_seat_1_base64": Marshalls.raw_to_base64(authority["alias_salt_seat_1"]),
		"available": true,
		"tie_key_base64": Marshalls.raw_to_base64(authority["tie_key"]),
		"tie_key_sha256": Codec.sha256_bytes(authority["tie_key"]),
	}


static func _artifact(bytes: PackedByteArray, media_type: String) -> Dictionary:
	return {
		"bytes": bytes,
		"descriptor": {"media_type": media_type},
	}


static func _canonical_jsonl(rows: Array) -> PackedByteArray:
	if rows.is_empty():
		return PackedByteArray()
	var lines := PackedStringArray()
	for row_variant: Variant in rows:
		lines.append(Codec.canonical_json(row_variant))
	return ("\n".join(lines) + "\n").to_utf8_buffer()


static func _latest_public_index(rows: Array, tick: int, field: String) -> int:
	var result := -1
	for index: int in rows.size():
		if int(rows[index].get(field, -1)) <= tick:
			result = index
		else:
			break
	return result


func _apply_source_fixed(
	session: Variant, emitted: Dictionary, batches: Dictionary
) -> Dictionary:
	var salts := {0: "10".repeat(32), 1: "20".repeat(32)}
	var locked: Dictionary = session.lock_fixed_commits({
		"boundary_tick": int(emitted["boundary_tick"]),
		"commits": [
			{
				"commit_hash": Session.action_batch_commit_hash(batches[0], salts[0]),
				"player_slot": 0,
			},
			{
				"commit_hash": Session.action_batch_commit_hash(batches[1], salts[1]),
				"player_slot": 1,
			},
		],
		"match_id": str(session.match_id),
		"observation_seq": int(emitted["observation_seq"]),
		"opportunity_id": str(emitted["opportunity_id"]),
	})
	if not bool(locked.get("ok", false)):
		return locked
	return session.reveal_fixed_pair({
		"activation_tick": TERMINAL_TICK,
		"boundary_tick": int(emitted["boundary_tick"]),
		"disposition": "continue",
		"match_id": str(session.match_id),
		"observation_seq": int(emitted["observation_seq"]),
		"opportunity_id": str(emitted["opportunity_id"]),
		"reveals": [
			{"batch": batches[0], "player_slot": 0, "salt_hex": salts[0]},
			{"batch": batches[1], "player_slot": 1, "salt_hex": salts[1]},
		],
	})


func _receipt_frame(session: Variant, application_seq: int) -> Dictionary:
	var record: Dictionary = session.latest_application_record()
	var rows: Array = []
	for batch_variant: Variant in record.get("batches", []):
		var batch: Dictionary = batch_variant
		rows.append({
			"batch_digest": str(batch["batch_digest"]),
			"batch_id": str(batch["batch_id"]),
			"compiled_intents": batch["compiled_intents"].duplicate(true),
			"player_slot": int(batch["player_seat"]),
			"receipt": batch["receipt"].duplicate(true),
		})
	return {
		"application_seq": application_seq,
		"application_tick": int(record["application_tick"]),
		"checkpoint_hash": session.checkpoint_hash(),
		"checkpoint_tick": int(session.simulation.state.tick),
		"decision_mode": str(session.decision_mode),
		"kind": str(record["kind"]),
		"match_id": str(session.match_id),
		"records": rows,
	}


func _acknowledged_rows(
	mode: String,
	emitted: Dictionary,
	batches: Dictionary,
	receipt_frame: Dictionary
) -> Array:
	var result: Array = []
	for record_variant: Variant in receipt_frame["records"]:
		var record: Dictionary = record_variant
		var seat := int(record["player_slot"])
		var observation: Dictionary = emitted["observations"][str(seat)]
		var batch: Dictionary = batches[seat]
		result.append({
			"action_batch": batch.duplicate(true),
			"application_seq": int(receipt_frame["application_seq"]),
			"application_tick": int(receipt_frame["application_tick"]),
			"batch_digest": Codec.sha256_canonical(batch),
			"batch_id": str(batch["client_batch_id"]),
			"decision_mode": mode,
			"match_id": str(batch["match_id"]),
			"observation_hash": str(observation["observation_hash"]),
			"observation_seq": int(observation["observation_seq"]),
			"observation_tick": int(observation["tick"]),
			"opportunity_id": str(emitted["opportunity_id"]),
			"player_slot": seat,
			"schema_version": ACK_SCHEMA,
		})
	return result


static func _application_row(
	emitted: Dictionary, batch: Dictionary, seat: int
) -> Dictionary:
	return {
		"batch": batch,
		"observation_seq": int(emitted["observation_seq"]),
		"observation_tick": int(emitted["boundary_tick"]),
		"opportunity_id": str(emitted["opportunity_id"]),
		"player_slot": seat,
	}


static func _protected_observations(emitted: Dictionary) -> Dictionary:
	var result := {"seat_0": [], "seat_1": []}
	for seat: int in [0, 1]:
		result["seat_%d" % seat].append({
			"observation": emitted["observations"][str(seat)].duplicate(true),
			"observation_seq": int(emitted["observation_seq"]),
			"tick": int(emitted["boundary_tick"]),
		})
	return result


static func _noop_batch(
	observation: Dictionary, batch_id: String, working_memory: String
) -> Dictionary:
	return {
		"based_on_observation_hash": str(observation["observation_hash"]),
		"client_batch_id": batch_id,
		"commands": [],
		"match_id": str(observation["match_id"]),
		"message_type": "action_batch",
		"observation_seq": int(observation["observation_seq"]),
		"protocol_version": ActionContract.PROTOCOL_VERSION,
		"valid_until_tick": int(observation["decision"]["valid_until_tick"]),
		"working_memory": working_memory,
	}


static func _protected(mode: String) -> Dictionary:
	return {
		"alias_salt_seat_0": ("replay-%s-observer-zero-salt" % mode).to_utf8_buffer(),
		"alias_salt_seat_1": ("replay-%s-observer-one-salt" % mode).to_utf8_buffer(),
		"tie_key": ("replay-%s-protected-tie-key" % mode).to_utf8_buffer(),
	}


static func _scored_hashes(probe: Variant, tie_key: PackedByteArray) -> Dictionary:
	var state: Variant = probe.simulation.state
	return {
		"engine_build_hash": "a".repeat(64),
		"faction_hash": str(state.faction_hash),
		"helper_hash": str(state.helper_hash),
		"item_hash": str(state.item_hash),
		"map_hash": str(state.map_hash),
		"neutral_hash": str(state.neutral_hash),
		"prompt_hash": str(state.prompt_hash),
		"protocol_hash": str(state.protocol_hash),
		"ruleset_hash": str(state.ruleset_hash),
		"tie_key_commitment": Codec.sha256_bytes(tie_key),
	}


static func _match_init(session: Variant, hashes: Dictionary) -> Dictionary:
	return {
		"artifacts": {
			"engine_build": {"sha256": str(hashes["engine_build_hash"])},
			"helper": {"sha256": str(hashes["helper_hash"])},
			"items": {"sha256": str(hashes["item_hash"])},
			"neutrals": {"sha256": str(hashes["neutral_hash"])},
			"prompt": {"sha256": str(hashes["prompt_hash"])},
			"protocol": {"sha256": str(hashes["protocol_hash"])},
		},
		"faction": {"id": "vanguard-v1", "sha256": str(hashes["faction_hash"])},
		"map": {"sha256": str(hashes["map_hash"])},
		"map_manifest": session.map_manifest.duplicate(true),
		"match_id": str(session.match_id),
		"message_type": "match_init",
		"ruleset": {"sha256": str(hashes["ruleset_hash"])},
	}


static func _summary(evidence: Dictionary, replayed: Dictionary) -> Dictionary:
	return {
		"acknowledged_batches": (evidence["acknowledged_action_batches"] as Array).size(),
		"checkpoint_count": int(replayed.get("checkpoint_count", -1)),
		"event_count": int(replayed.get("public_event_count", -1)),
		"final_state_sha256": str(replayed.get("final_state_sha256", "")),
		"mode": str(evidence["decision_mode"]),
		"observation_hashes": [
			str(evidence["observations"]["seat_0"][0]["observation"]["observation_hash"]),
			str(evidence["observations"]["seat_1"][0]["observation"]["observation_hash"]),
		],
		"ok": bool(replayed.get("ok", false)),
		"terminal_tick": int(replayed.get("terminal_tick", -1)),
	}


static func _fixture_failure(message: String) -> Dictionary:
	return {"errors": PackedStringArray([message]), "ok": false}


static func _errors(result: Dictionary) -> String:
	var messages := PackedStringArray()
	for value: Variant in result.get("errors", []):
		messages.append(str(value))
	return "; ".join(messages)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish(golden: String) -> void:
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_OFFICIAL_REPLAY_FAILURE: %s" % failure)
		print("DUEL_OFFICIAL_REPLAY_FAILED count=%d hash=%s" % [_failures.size(), golden])
		quit(1)
		return
	print(
		"DUEL_OFFICIAL_REPLAY_OK hash=%s modes=2 exact_checkpoints=2 external_calls=0" % golden
	)
	quit(0)
