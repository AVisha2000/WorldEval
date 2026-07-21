class_name DuelOfficialReplayVerifier
extends RefCounted

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const OfficialRunner := preload(
	"res://scripts/duel/replay/duel_official_replay_runner.gd"
)
const BundleLoader := preload(
	"res://scripts/duel/replay/duel_replay_bundle_loader.gd"
)

## Verifies the exact public/protected artifact evidence currently emitted by
## DuelLiveArtifactFinalizer.  Integrity verification and authoritative replay
## readiness are deliberately separate outcomes: a perfectly valid archive can
## still lack information required to recompute DuelMatchSession.checkpoint_hash().

const REPLAY_SCHEMA_VERSION := "worldeval-rts/replay-manifest/1.0.0"
const AUDIT_SCHEMA_VERSION := "worldeval-rts/protected-audit-manifest/1.0.0"
const INSUFFICIENCY_SCHEMA_VERSION := "worldeval-rts/replay-insufficiency/1.0.0"
const INSUFFICIENT_APPLICATION_EVIDENCE := (
	"insufficient_authoritative_application_evidence"
)
const REQUIRED_PUBLIC_ROLES: Array[String] = [
	"accepted_actions", "compiled_orders", "public_events", "state_checkpoints",
]
const REQUIRED_PROTECTED_ROLES: Array[String] = [
	"action_receipts", "match_init", "observations", "replay_authority",
]
const PERSPECTIVES: Array[String] = ["omniscient", "seat_0", "seat_1"]


func verify_package(package_input: Dictionary) -> Dictionary:
	var errors := PackedStringArray()
	if typeof(package_input.get("public")) != TYPE_DICTIONARY \
		or typeof(package_input.get("protected")) != TYPE_DICTIONARY:
		errors.append("replay package requires verified public and protected layers")
		return _corrupt("replay_package_invalid", errors)
	var public_layer: Dictionary = package_input["public"]
	var protected_layer: Dictionary = package_input["protected"]
	for layer_name: String in ["public", "protected"]:
		var layer: Dictionary = package_input[layer_name]
		for field: String in ["artifacts", "content_sha256", "index", "manifest"]:
			if not layer.has(field):
				errors.append("%s replay layer is missing %s" % [layer_name, field])
	if not errors.is_empty():
		return _corrupt("replay_package_invalid", errors)

	var public_manifest: Dictionary = public_layer["manifest"]
	var protected_manifest: Dictionary = protected_layer["manifest"]
	_validate_manifest_binding(
		public_layer, protected_layer, public_manifest, protected_manifest, errors
	)
	_require_roles(public_layer["artifacts"], REQUIRED_PUBLIC_ROLES, "public", errors)
	_require_roles(
		protected_layer["artifacts"], REQUIRED_PROTECTED_ROLES, "protected", errors
	)
	if not errors.is_empty():
		return _corrupt("replay_manifest_binding_invalid", errors)

	var match_id := str(public_manifest.get("match_id", ""))
	var decision: Variant = public_manifest.get("decision")
	if str(public_manifest.get("schema_version", "")) != REPLAY_SCHEMA_VERSION:
		errors.append("public replay schema_version is unsupported")
	if match_id.is_empty() or not match_id.begins_with("m_"):
		errors.append("public replay match_id is invalid")
	if typeof(decision) != TYPE_DICTIONARY \
		or str(decision.get("mode", "")) not in [
			"fixed_simultaneous", "continuous_realtime",
		]:
		errors.append("public replay decision mode is invalid")
	if not _is_sha256(public_manifest.get("final_state_sha256")):
		errors.append("public replay final_state_sha256 is invalid")
	if typeof(public_manifest.get("terminal")) != TYPE_DICTIONARY:
		errors.append("public replay terminal record is invalid")
	if not errors.is_empty():
		return _corrupt("replay_manifest_invalid", errors)

	var accepted := _decode_role_jsonl(
		public_layer, "accepted_actions", "application/x-ndjson", errors
	)
	var compiled := _decode_role_jsonl(
		public_layer, "compiled_orders", "application/x-ndjson", errors
	)
	var events := _decode_role_jsonl(
		public_layer, "public_events", "application/x-ndjson", errors
	)
	var state_record := _decode_role_object(
		public_layer, "state_checkpoints", "application/json", errors
	)
	var action_receipts := _decode_role_jsonl(
		protected_layer, "action_receipts", "application/x-ndjson", errors
	)
	var observation_rows := _decode_role_jsonl(
		protected_layer, "observations", "application/x-ndjson", errors
	)
	var match_init := _decode_role_object(
		protected_layer, "match_init", "application/json", errors
	)
	var replay_authority := _decode_role_object(
		protected_layer, "replay_authority", "application/json", errors
	)
	var acknowledged_action_batches: Array = []
	if protected_layer["artifacts"].has("acknowledged_action_batches"):
		acknowledged_action_batches = _decode_role_jsonl(
			protected_layer,
			"acknowledged_action_batches",
			"application/x-ndjson",
			errors
		)
	if not errors.is_empty():
		return _corrupt("replay_artifact_not_canonical", errors)

	_validate_public_timeline(
		accepted, compiled, events, state_record, public_manifest, match_id, errors
	)
	var authority := _validate_authority(replay_authority, errors)
	var observations := _validate_observations(observation_rows, match_id, errors)
	_validate_match_init(match_init, protected_manifest, public_manifest, match_id, errors)
	_validate_action_receipts(action_receipts, match_id, str(decision["mode"]), errors)
	_validate_public_against_receipts(accepted, compiled, action_receipts, errors)
	if not errors.is_empty():
		return _corrupt("replay_evidence_invalid", errors)

	var evidence := {
		"accepted_actions": accepted.duplicate(true),
		"acknowledged_action_batches": acknowledged_action_batches.duplicate(true),
		"action_receipts": action_receipts.duplicate(true),
		"checkpoints": (state_record.get("checkpoints", []) as Array).duplicate(true),
		"compiled_orders": compiled.duplicate(true),
		"decision_mode": str(decision["mode"]),
		"final_state_sha256": str(public_manifest["final_state_sha256"]),
		"match_id": match_id,
		"match_init": match_init.duplicate(true),
		"maximum_tick": int(public_manifest["terminal"].get("tick", 0)),
		"observations": observations,
		"public_events": events.duplicate(true),
		"public_manifest": public_manifest.duplicate(true),
		"replay_authority": authority,
		"seed": int(public_manifest.get("seed", 0)),
		"terminal": public_manifest["terminal"].duplicate(true),
	}

	# The current protected action-receipt wire carries the authoritative batch
	# digest and applied primitives, but intentionally does not retain the exact
	# canonical ActionBatch.  That omission is material: working_memory and
	# accepted no-op/rejected commands are included in the official checkpoint.
	var missing := _current_missing_evidence(public_layer, protected_layer)
	if not missing.is_empty():
		return {
			"authority_replay_ready": false,
			"code": INSUFFICIENT_APPLICATION_EVIDENCE,
			"error": {
				"blocking_claims": [
					"authoritative_checkpoint_recomputation",
					"verified_omniscient_arbitrary_tick_projection",
					"verified_player_arbitrary_tick_projection",
				],
				"code": INSUFFICIENT_APPLICATION_EVIDENCE,
				"missing_evidence": missing,
				"safe_capabilities": [
					"bundle_integrity_verification",
					"recorded_public_event_timeline",
					"recorded_application_timeline",
					"recorded_player_observations_at_decision_boundaries",
				],
				"schema_version": INSUFFICIENCY_SCHEMA_VERSION,
			},
			"errors": PackedStringArray([
				"current sealed artifacts are integrity-valid but insufficient for exact authority replay",
			]),
			"evidence": evidence,
			"integrity_verified": true,
			"ok": false,
		}

	var replayed := OfficialRunner.new().verify(evidence)
	if not bool(replayed.get("ok", false)):
		return {
			"authority_replay_ready": false,
			"code": str(replayed.get("code", "official_replay_failed")),
			"errors": replayed.get("errors", PackedStringArray()),
			"evidence": evidence,
			"integrity_verified": false,
			"ok": false,
		}
	evidence["perspectives"] = replayed["perspectives"].duplicate(true)
	evidence["verified_checkpoint_count"] = int(replayed["checkpoint_count"])
	evidence["verified_public_event_count"] = int(replayed["public_event_count"])
	return {
		"authority_replay_ready": true,
		"code": "verified",
		"errors": PackedStringArray(),
		"evidence": evidence,
		"integrity_verified": true,
		"ok": true,
	}


func _validate_manifest_binding(
	public_layer: Dictionary,
	protected_layer: Dictionary,
	public_manifest: Dictionary,
	protected_manifest: Dictionary,
	errors: PackedStringArray
) -> void:
	if str(protected_manifest.get("schema_version", "")) != AUDIT_SCHEMA_VERSION:
		errors.append("protected audit schema_version is unsupported")
	if protected_manifest.get("match_id") != public_manifest.get("match_id"):
		errors.append("public and protected replay match IDs differ")
	var binding: Variant = protected_manifest.get("publishable_bundle")
	if typeof(binding) != TYPE_DICTIONARY:
		errors.append("protected audit publishable binding is invalid")
		return
	if str(binding.get("content_sha256", "")) != str(public_layer["content_sha256"]):
		errors.append("protected audit binds a different public content hash")
	var public_index: Dictionary = public_layer["index"]
	if str(binding.get("index_sha256", "")) != str(public_index.get("index_sha256", "")):
		errors.append("protected audit binds a different public index hash")
	var manifest_descriptor: Variant = public_index.get("manifest")
	if typeof(manifest_descriptor) != TYPE_DICTIONARY \
		or str(binding.get("manifest_sha256", "")) \
		!= str(manifest_descriptor.get("sha256", "")):
		errors.append("protected audit binds a different public manifest hash")
	if not _is_sha256(protected_layer.get("content_sha256")):
		errors.append("protected audit content hash is invalid")


func _validate_public_timeline(
	accepted: Array,
	compiled: Array,
	events: Array,
	state_record: Dictionary,
	manifest: Dictionary,
	match_id: String,
	errors: PackedStringArray
) -> void:
	var previous_tick := -1
	for index: int in accepted.size():
		var row_variant: Variant = accepted[index]
		if typeof(row_variant) != TYPE_DICTIONARY:
			errors.append("accepted action row must be an object")
			continue
		var row: Dictionary = row_variant
		var tick := _non_negative_int(row.get("application_tick"), "accepted action tick", errors)
		if tick < previous_tick:
			errors.append("accepted action ticks move backwards")
		previous_tick = tick
		if row.get("transcript_index") != index:
			errors.append("accepted action transcript_index is not contiguous")
		if int(row.get("player_slot", -1)) not in [0, 1]:
			errors.append("accepted action player_slot is invalid")
		if not _is_sha256(row.get("batch_digest")):
			errors.append("accepted action batch_digest is invalid")

	previous_tick = -1
	for index: int in compiled.size():
		var row_variant: Variant = compiled[index]
		if typeof(row_variant) != TYPE_DICTIONARY:
			errors.append("compiled order row must be an object")
			continue
		var row: Dictionary = row_variant
		var tick := _non_negative_int(row.get("application_tick"), "compiled order tick", errors)
		if tick < previous_tick:
			errors.append("compiled order ticks move backwards")
		previous_tick = tick
		if row.get("transcript_index") != index:
			errors.append("compiled order transcript_index is not contiguous")
		if row.get("apply_tick") != tick:
			errors.append("compiled order apply_tick differs from application_tick")
		var source_index := int(row.get("source_action_index", -1))
		if source_index < 0 or source_index >= accepted.size():
			errors.append("compiled order source_action_index is invalid")
		elif int(accepted[source_index].get("application_tick", -1)) != tick:
			errors.append("compiled order references an accepted action at another tick")
		var source: Variant = row.get("source")
		if typeof(source) != TYPE_DICTIONARY \
			or str(source.get("match_id", "")) != match_id:
			errors.append("compiled order source has the wrong match ID")

	previous_tick = -1
	for index: int in events.size():
		var event_variant: Variant = events[index]
		if typeof(event_variant) != TYPE_DICTIONARY:
			errors.append("public event row must be an object")
			continue
		var event: Dictionary = event_variant
		var tick := _non_negative_int(event.get("tick"), "public event tick", errors)
		if tick < previous_tick:
			errors.append("public event ticks move backwards")
		previous_tick = tick
		if event.get("event_seq") != index + 1:
			errors.append("public event sequence is not contiguous")

	var checkpoints: Variant = state_record.get("checkpoints")
	if typeof(checkpoints) != TYPE_ARRAY or (checkpoints as Array).is_empty():
		errors.append("state checkpoint artifact has no checkpoints")
		return
	if checkpoints != manifest.get("checkpoints"):
		errors.append("state checkpoint artifact differs from replay manifest")
	if state_record.get("final_state_sha256") != manifest.get("final_state_sha256"):
		errors.append("state checkpoint final hash differs from replay manifest")
	if state_record.get("terminal_tick") != manifest["terminal"].get("tick"):
		errors.append("state checkpoint terminal tick differs from replay manifest")
	previous_tick = -1
	for checkpoint_variant: Variant in checkpoints:
		if typeof(checkpoint_variant) != TYPE_DICTIONARY:
			errors.append("state checkpoint must be an object")
			continue
		var checkpoint: Dictionary = checkpoint_variant
		var tick := _non_negative_int(checkpoint.get("tick"), "checkpoint tick", errors)
		if tick <= previous_tick:
			errors.append("checkpoint ticks are not strictly ascending")
		previous_tick = tick
		if not _is_sha256(checkpoint.get("state_sha256")):
			errors.append("checkpoint state hash is invalid")
		var action_cursor := int(checkpoint.get("actions_through_index", -2))
		var event_cursor := int(checkpoint.get("events_through_index", -2))
		if action_cursor != _latest_index_at_tick(accepted, tick, "application_tick"):
			errors.append("checkpoint accepted-action cursor is invalid")
		if event_cursor != _latest_index_at_tick(events, tick, "tick"):
			errors.append("checkpoint public-event cursor is invalid")
	var last_checkpoint: Dictionary = checkpoints[-1]
	if last_checkpoint.get("tick") != state_record.get("terminal_tick") \
		or last_checkpoint.get("state_sha256") != state_record.get("final_state_sha256"):
		errors.append("final checkpoint does not bind the terminal state")


func _validate_authority(value: Dictionary, errors: PackedStringArray) -> Dictionary:
	if value.get("available") != true:
		errors.append("protected replay authority material is unavailable")
		return {}
	var tie_key := _decode_base64(value.get("tie_key_base64"), "tie key", errors)
	var salt_zero := _decode_base64(
		value.get("alias_salt_seat_0_base64"), "seat-0 alias salt", errors
	)
	var salt_one := _decode_base64(
		value.get("alias_salt_seat_1_base64"), "seat-1 alias salt", errors
	)
	if tie_key.is_empty():
		errors.append("protected tie key is empty")
	if salt_zero.size() < 16 or salt_one.size() < 16 or salt_zero == salt_one:
		errors.append("protected observer alias salts are invalid")
	if Codec.sha256_bytes(tie_key) != str(value.get("tie_key_sha256", "")):
		errors.append("protected tie-key commitment mismatch")
	return {
		"alias_salt_seat_0": salt_zero,
		"alias_salt_seat_1": salt_one,
		"tie_key": tie_key,
	}


func _validate_observations(
	rows: Array, match_id: String, errors: PackedStringArray
) -> Dictionary:
	var result := {"seat_0": [], "seat_1": []}
	var seen: Dictionary = {}
	for index: int in rows.size():
		var row_variant: Variant = rows[index]
		if typeof(row_variant) != TYPE_DICTIONARY:
			errors.append("protected observation row must be an object")
			continue
		var row: Dictionary = row_variant
		var seat := int(row.get("player_slot", -1))
		var seq := int(row.get("observation_seq", -1))
		var tick := int(row.get("tick", -1))
		if seat not in [0, 1] or seq < 0 or tick < 0:
			errors.append("protected observation identity is invalid")
			continue
		var identity := "%d:%d" % [seq, seat]
		if seen.has(identity):
			errors.append("protected observation identity is duplicated")
			continue
		seen[identity] = true
		var bytes := _decode_base64(
			row.get("canonical_bytes_base64"), "protected observation", errors
		)
		var observation := _canonical_object(bytes, "protected observation", errors)
		if observation.get("match_id") != match_id \
			or observation.get("observation_seq") != seq \
			or observation.get("tick") != tick:
			errors.append("protected observation metadata differs from its canonical bytes")
		if observation.get("observation_hash") != row.get("observation_hash"):
			errors.append("protected observation hash metadata differs from its canonical bytes")
		(result["seat_%d" % seat] as Array).append({
			"observation": observation,
			"observation_seq": seq,
			"tick": tick,
		})
	for seat: int in [0, 1]:
		var timeline: Array = result["seat_%d" % seat]
		timeline.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return [int(a["tick"]), int(a["observation_seq"])] \
				< [int(b["tick"]), int(b["observation_seq"])]
		)
	return result


func _validate_match_init(
	match_init: Dictionary,
	protected_manifest: Dictionary,
	public_manifest: Dictionary,
	match_id: String,
	errors: PackedStringArray
) -> void:
	if match_init.get("match_id") != match_id:
		errors.append("protected MATCH_INIT has the wrong match ID")
	if match_init.get("message_type") != "match_init":
		errors.append("protected MATCH_INIT message_type is invalid")
	var audit: Variant = protected_manifest.get("audit_metadata")
	if typeof(audit) != TYPE_DICTIONARY:
		errors.append("protected audit metadata is invalid")
		return
	if str(audit.get("match_init_sha256", "")) != Codec.sha256_canonical(match_init):
		errors.append("protected MATCH_INIT hash differs from audit metadata")
	if str(audit.get("decision_mode", "")) \
		!= str(public_manifest["decision"].get("mode", "")):
		errors.append("protected audit decision mode differs from public replay")


func _validate_action_receipts(
	rows: Array, match_id: String, decision_mode: String, errors: PackedStringArray
) -> void:
	var previous_tick := -1
	for index: int in rows.size():
		var row_variant: Variant = rows[index]
		if typeof(row_variant) != TYPE_DICTIONARY:
			errors.append("protected action receipt frame must be an object")
			continue
		var row: Dictionary = row_variant
		if row.get("application_seq") != index:
			errors.append("protected application sequence is not contiguous")
		if row.get("match_id") != match_id or row.get("decision_mode") != decision_mode:
			errors.append("protected action receipt identity is invalid")
		var tick := int(row.get("application_tick", -1))
		if tick < 0 or tick < previous_tick:
			errors.append("protected application ticks move backwards")
		previous_tick = tick
		if typeof(row.get("records")) != TYPE_ARRAY:
			errors.append("protected action receipt records are invalid")


func _validate_public_against_receipts(
	accepted: Array, compiled: Array, frames: Array, errors: PackedStringArray
) -> void:
	var expected_accepted: Array = []
	var expected_compiled: Array = []
	for frame_variant: Variant in frames:
		var frame: Dictionary = frame_variant
		var application_tick := int(frame.get("application_tick", -1))
		for record_variant: Variant in frame.get("records", []):
			if typeof(record_variant) != TYPE_DICTIONARY:
				continue
			var record: Dictionary = record_variant
			var source_indexes: Dictionary = {}
			var receipt: Dictionary = record.get("receipt", {})
			for command_variant: Variant in receipt.get("commands", []):
				if typeof(command_variant) != TYPE_DICTIONARY:
					continue
				var command: Dictionary = command_variant
				if str(command.get("status", "")) not in ["applied", "partially_applied"]:
					continue
				var row := {
					"application_tick": application_tick,
					"batch_digest": str(record.get("batch_digest", "")),
					"batch_id": str(record.get("batch_id", "")),
					"code": command.get("code"),
					"command_id": str(command.get("command_id", "")),
					"observation_seq": int(receipt.get("observation_seq", -1)),
					"player_slot": int(record.get("player_slot", -1)),
					"status": str(command.get("status", "")),
					"transcript_index": expected_accepted.size(),
				}
				for optional: String in [
					"accepted_quantity", "atomic_cost", "compiled_order_ids",
					"requested_quantity",
				]:
					if command.has(optional):
						row[optional] = command[optional]
				source_indexes[str(command.get("command_id", ""))] = expected_accepted.size()
				expected_accepted.append(row)
			for intent_variant: Variant in record.get("compiled_intents", []):
				if typeof(intent_variant) != TYPE_DICTIONARY:
					continue
				var intent: Dictionary = intent_variant.duplicate(true)
				var command_id := str(intent.get("source", {}).get("command_id", ""))
				if not source_indexes.has(command_id):
					errors.append("authority compiled intent has no applied command source")
					continue
				intent["application_tick"] = application_tick
				intent["source_action_index"] = int(source_indexes[command_id])
				intent["transcript_index"] = expected_compiled.size()
				expected_compiled.append(intent)
	if expected_accepted != accepted:
		errors.append("public accepted-action transcript differs from authority receipts")
	if expected_compiled != compiled:
		errors.append("public compiled-order transcript differs from authority receipts")


func _current_missing_evidence(_public_layer: Dictionary, protected_layer: Dictionary) -> Array:
	var missing: Array = []
	var protected_artifacts: Dictionary = protected_layer["artifacts"]
	if not protected_artifacts.has("acknowledged_action_batches"):
		missing.append({
			"evidence": "canonical_applied_action_batches",
			"reason": (
				"action_receipts retain digests and receipts but not exact command bodies or working_memory"
			),
			"required_layer": "protected_audit",
		})
	return missing


func _decode_role_jsonl(
	layer: Dictionary, role: String, expected_media: String, errors: PackedStringArray
) -> Array:
	var artifact: Dictionary = layer["artifacts"].get(role, {})
	if artifact.is_empty():
		return []
	if str(artifact["descriptor"].get("media_type", "")) != expected_media:
		errors.append("replay role %s has the wrong media type" % role)
		return []
	return _canonical_jsonl(artifact["bytes"], role, errors)


func _decode_role_object(
	layer: Dictionary, role: String, expected_media: String, errors: PackedStringArray
) -> Dictionary:
	var artifact: Dictionary = layer["artifacts"].get(role, {})
	if artifact.is_empty():
		return {}
	if str(artifact["descriptor"].get("media_type", "")) != expected_media:
		errors.append("replay role %s has the wrong media type" % role)
		return {}
	return _canonical_object(artifact["bytes"], role, errors)


func _canonical_jsonl(
	bytes: PackedByteArray, context: String, errors: PackedStringArray
) -> Array:
	if bytes.is_empty():
		return []
	var text := bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != bytes or "\r" in text or not text.ends_with("\n"):
		errors.append("%s is not canonical LF-terminated UTF-8 JSONL" % context)
		return []
	var result: Array = []
	var lines := text.trim_suffix("\n").split("\n", true)
	for index: int in lines.size():
		var line := str(lines[index])
		if line.is_empty():
			errors.append("%s contains an empty JSONL row" % context)
			continue
		var before := errors.size()
		var value: Variant = BundleLoader.parse_canonical_value(
			line.to_utf8_buffer(), "%s JSONL row %d" % [context, index], errors
		)
		if typeof(value) != TYPE_DICTIONARY:
			if errors.size() == before:
				errors.append("%s JSONL row %d is not an object" % [context, index])
			continue
		result.append(value)
	return result


func _canonical_object(
	bytes: PackedByteArray, context: String, errors: PackedStringArray
) -> Dictionary:
	var text := bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != bytes:
		errors.append("%s is not exact UTF-8" % context)
		return {}
	var before := errors.size()
	var value: Variant = BundleLoader.parse_canonical_value(bytes, context, errors)
	if typeof(value) != TYPE_DICTIONARY:
		if errors.size() == before:
			errors.append("%s is not a JSON object" % context)
		return {}
	return value


func _decode_base64(
	value: Variant, context: String, errors: PackedStringArray
) -> PackedByteArray:
	if typeof(value) != TYPE_STRING:
		errors.append("%s base64 value is invalid" % context)
		return PackedByteArray()
	var bytes := Marshalls.base64_to_raw(str(value))
	if Marshalls.raw_to_base64(bytes) != str(value):
		errors.append("%s base64 value is non-canonical" % context)
	return bytes


static func _require_roles(
	artifacts: Dictionary, roles: Array[String], layer: String, errors: PackedStringArray
) -> void:
	for role: String in roles:
		if not artifacts.has(role):
			errors.append("%s replay layer is missing role %s" % [layer, role])


static func _latest_index_at_tick(rows: Array, tick: int, tick_field: String) -> int:
	var result := -1
	for index: int in rows.size():
		if int(rows[index].get(tick_field, -1)) <= tick:
			result = index
		else:
			break
	return result


static func _non_negative_int(
	value: Variant, context: String, errors: PackedStringArray
) -> int:
	if typeof(value) != TYPE_INT or int(value) < 0:
		errors.append("%s is not a non-negative integer" % context)
		return -1
	return int(value)


static func _is_sha256(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING or str(value).length() != 64:
		return false
	var text := str(value)
	return text == text.to_lower() and text.hex_decode().size() == 32 \
		and text.hex_decode().hex_encode() == text


static func _corrupt(code: String, errors: PackedStringArray) -> Dictionary:
	return {
		"authority_replay_ready": false,
		"code": code,
		"errors": errors,
		"integrity_verified": false,
		"ok": false,
	}
