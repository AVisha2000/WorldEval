extends SceneTree

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const OrderRecord := preload("res://scripts/duel/simulation/duel_order.gd")
const DeltaRecord := preload("res://scripts/duel/simulation/duel_delta.gd")
const Replay := preload("res://scripts/duel/simulation/duel_replay.gd")

## Frozen after the first reviewed run. Running this script in two fresh Godot
## processes must print the same document/final hashes.
const GOLDEN_DOCUMENT_HASH := "e9623667f3f578b2de970513dbc8885c4c731567a843109cc8be49e7600d23f7"

var _failures := PackedStringArray()


func _init() -> void:
	var setup := _fixture_setup(false)
	var shuffled_setup := _fixture_setup(true)
	var transcript := _fixture_transcript()
	var decisions: Array = [0, 2, 300, 304]

	var recorder := Replay.new()
	var recorded := recorder.record(setup, transcript, decisions, 305)
	_check(bool(recorded.get("ok", false)), "canonical replay recording failed: %s" % str(recorded.get("errors", [])))
	if not bool(recorded.get("ok", false)):
		_finish("record_failed", "")
		return
	var document: Dictionary = recorded["document"]
	var document_hash := str(recorded["document_hash"])
	print("DUEL_REPLAY_CANDIDATE_GOLDEN=%s" % document_hash)

	var shuffled_recorded := Replay.new().record(shuffled_setup, transcript, decisions, 305)
	_check(bool(shuffled_recorded.get("ok", false)), "shuffled setup recording failed")
	if bool(shuffled_recorded.get("ok", false)):
		_check(
			str(shuffled_recorded["document_hash"]) == document_hash,
			"shuffled setup construction changed the canonical replay document"
		)

	var canonical_bytes := Replay.canonical_document_bytes(document)
	var first_replay := Replay.new().replay(document, canonical_bytes)
	var second_replay := Replay.new().replay(document, canonical_bytes)
	_check(bool(first_replay.get("ok", false)), "first offline replay failed: %s" % str(first_replay.get("errors", [])))
	_check(bool(second_replay.get("ok", false)), "second offline replay failed: %s" % str(second_replay.get("errors", [])))
	if bool(first_replay.get("ok", false)) and bool(second_replay.get("ok", false)):
		_check(
			str(first_replay["final_state_hash"]) == str(second_replay["final_state_hash"]),
			"two in-process replays produced different final hashes"
		)
		_check(int(first_replay["external_calls"]) == 0, "replay attempted an external call")
		_check(int(second_replay["external_calls"]) == 0, "second replay attempted an external call")
	_check(not Replay.EXTERNAL_CALL_CAPABILITY, "replay unexpectedly exposes external-call capability")
	_check(recorder.external_call_count == 0, "recording attempted an external call")

	var found_periodic := false
	for checkpoint_variant: Variant in document["checkpoints"]:
		var checkpoint: Dictionary = checkpoint_variant
		if str(checkpoint["kind"]) == "periodic" and int(checkpoint["state_tick"]) == 300:
			found_periodic = true
	_check(found_periodic, "the required 300-tick periodic checkpoint was not recorded")
	_check(
		str(document["checkpoints"][0]["kind"]) == "initial"
			and int(document["checkpoints"][0]["state_tick"]) == 0,
		"tick-0 checkpoint is missing"
	)
	_check(
		str(document["checkpoints"][-1]["kind"]) == "final"
			and int(document["checkpoints"][-1]["state_tick"]) == 305,
		"final checkpoint is missing or has the wrong tick"
	)

	_test_action_tamper(document)
	_test_event_tamper(document)
	_test_checkpoint_tamper(document)
	_test_final_hash_tamper(document)
	_test_noncanonical_bytes(document)
	_test_rejected_inputs(setup, transcript, decisions)

	_check(
		document_hash == GOLDEN_DOCUMENT_HASH,
		"fresh-process replay golden changed: %s" % document_hash
	)
	_finish(document_hash, str(document["final_state_hash"]), document)


func _test_action_tamper(document: Dictionary) -> void:
	var altered := document.duplicate(true)
	altered["transcript"][0]["primitive_orders"][0]["target"] = {"tampered": true}
	_refresh_integrity(altered)
	var result := Replay.new().replay(altered)
	_check(not bool(result.get("ok", true)), "altered primitive action replayed successfully")
	_check(bool(result.get("corruption", false)), "altered primitive action was not reported as corruption")
	_check(str(result.get("stage", "")) == "checkpoint", "altered action did not stop at a checkpoint")


func _test_event_tamper(document: Dictionary) -> void:
	var altered := document.duplicate(true)
	altered["events"][0]["payload"]["internal_order_id"] = 999
	_refresh_integrity(altered)
	var result := Replay.new().replay(altered)
	_check(not bool(result.get("ok", true)), "altered event replayed successfully")
	_check(bool(result.get("corruption", false)), "altered event was not reported as corruption")
	_check(str(result.get("stage", "")) == "event", "altered event did not stop at event verification")


func _test_checkpoint_tamper(document: Dictionary) -> void:
	var altered := document.duplicate(true)
	altered["checkpoints"][0]["state_hash"] = "0".repeat(64)
	_refresh_integrity(altered)
	var result := Replay.new().replay(altered)
	_check(not bool(result.get("ok", true)), "altered checkpoint replayed successfully")
	_check(bool(result.get("corruption", false)), "altered checkpoint was not reported as corruption")
	_check(str(result.get("stage", "")) == "checkpoint", "checkpoint corruption stage was not visible")


func _test_final_hash_tamper(document: Dictionary) -> void:
	var altered := document.duplicate(true)
	altered["final_state_hash"] = "f".repeat(64)
	_refresh_integrity(altered)
	var result := Replay.new().replay(altered)
	_check(not bool(result.get("ok", true)), "altered final hash replayed successfully")
	_check(bool(result.get("corruption", false)), "altered final hash was not reported as corruption")
	_check(str(result.get("stage", "")) == "final_hash", "final-hash corruption stage was not visible")


func _test_noncanonical_bytes(document: Dictionary) -> void:
	var bytes := Replay.canonical_document_bytes(document)
	bytes.append(10)
	var result := Replay.new().replay(document, bytes)
	_check(not bool(result.get("ok", true)), "non-canonical replay bytes were accepted")
	_check(str(result.get("stage", "")) == "canonical_bytes", "non-canonical byte failure was not visible")


func _test_rejected_inputs(setup: Dictionary, transcript: Array, decisions: Array) -> void:
	var float_setup := setup.duplicate(true)
	float_setup["config"]["match_seed"] = 1.5
	_check(
		not bool(Replay.new().record(float_setup, transcript, decisions, 305).get("ok", true)),
		"authoritative float was accepted into replay setup"
	)

	var unsafe_setup := setup.duplicate(true)
	unsafe_setup["entities"][0]["integer_attributes"]["unsafe"] = 9_007_199_254_740_992
	_check(
		not bool(Replay.new().record(unsafe_setup, transcript, decisions, 305).get("ok", true)),
		"unsafe JCS integer was accepted into replay setup"
	)

	var unsorted_transcript := transcript.duplicate(true)
	unsorted_transcript.reverse()
	_check(
		not bool(Replay.new().record(setup, unsorted_transcript, decisions, 305).get("ok", true)),
		"unsorted transcript ticks/IDs were accepted"
	)

	var duplicate_id_transcript := transcript.duplicate(true)
	duplicate_id_transcript[1]["transcript_id"] = duplicate_id_transcript[0]["transcript_id"]
	_check(
		not bool(Replay.new().record(setup, duplicate_id_transcript, decisions, 305).get("ok", true)),
		"duplicate transcript ID was accepted"
	)

	var duplicate_order_transcript := transcript.duplicate(true)
	duplicate_order_transcript[1]["primitive_orders"][0]["internal_order_id"] = 21
	_check(
		not bool(Replay.new().record(setup, duplicate_order_transcript, decisions, 305).get("ok", true)),
		"duplicate primitive order ID was accepted"
	)

	var economy_setup := setup.duplicate(true)
	economy_setup["economy_enabled"] = true
	var economy_result := Replay.new().record(economy_setup, transcript, decisions, 305)
	_check(not bool(economy_result.get("ok", true)), "economy-enabled tick-0 replay was silently accepted")
	_check(
		_contains_error(economy_result.get("errors", []), "economy-enabled replay restoration is unsupported"),
		"economy replay limitation was not explicit"
	)


func _fixture_setup(reverse: bool) -> Dictionary:
	var entity_10 := EntityRecord.new(10, 0, "unit")
	entity_10.public_id = "entity-00000010"
	entity_10.catalog_id = "placeholder-worker"
	entity_10.radius_mt = 0
	entity_10.max_hp = 100
	entity_10.hp = 100
	entity_10.set_position_mt(750, 750)
	entity_10.tags = ["ground", "worker"]
	var entity_20 := EntityRecord.new(20, 1, "unit")
	entity_20.public_id = "entity-00000020"
	entity_20.catalog_id = "placeholder-worker"
	entity_20.radius_mt = 0
	entity_20.max_hp = 100
	entity_20.hp = 100
	entity_20.max_mana = 20
	entity_20.mana = 10
	entity_20.set_position_mt(2_750, 2_750)
	entity_20.tags = ["ground", "worker"]

	var order_10 := _order_data(7, 0, 10, 0, 1, "setup-order-10")
	var order_20 := _order_data(8, 1, 20, 0, 0, "setup-order-20")
	var delta_10 := _delta_data(0, 10, DeltaRecord.Kind.HP, -9, 20, 1)
	var delta_20 := _delta_data(0, 20, DeltaRecord.Kind.MANA, -2, 10, 2)
	var entities: Array = [entity_10.to_canonical_dict(), entity_20.to_canonical_dict()]
	var orders: Array = [order_10, order_20]
	var deltas: Array = [delta_10, delta_20]
	if reverse:
		entities.reverse()
		orders.reverse()
		deltas.reverse()
	return {
		"config": {
			"grid_height": 6,
			"grid_width": 6,
			"match_seed": 91_337,
		},
		"economy_enabled": false,
		"entities": entities,
		"pending_deltas": deltas,
		"prequeued_orders": orders,
	}


func _fixture_transcript() -> Array:
	return [
		{
			"application_tick": 2,
			"primitive_orders": [_order_data(21, 1, 20, 2, 0, "transcript-order-21")],
			"transcript_id": "batch-000002",
		},
		{
			"application_tick": 300,
			"primitive_orders": [_order_data(22, 0, 10, 300, 0, "transcript-order-22")],
			"transcript_id": "batch-000300",
		},
	]


func _order_data(
	order_id: int,
	owner_seat: int,
	actor_id: int,
	application_tick: int,
	command_index: int,
	digest_source: String
) -> Dictionary:
	var order := OrderRecord.new(order_id, owner_seat, actor_id, "hold")
	order.issued_tick = application_tick
	order.activation_tick = application_tick
	order.command_index = command_index
	order.command_digest = Codec.sha256_text(digest_source)
	order.target = {"anchor": actor_id}
	return order.to_canonical_dict()


func _delta_data(
	application_tick: int,
	entity_id: int,
	kind: int,
	amount: int,
	source_id: int,
	local_seq: int
) -> Dictionary:
	var delta := DeltaRecord.new()
	delta.application_tick = application_tick
	delta.entity_id = entity_id
	delta.kind = kind
	delta.amount = amount
	delta.source_internal_id = source_id
	delta.local_seq = local_seq
	return delta.to_canonical_dict()


func _refresh_integrity(document: Dictionary) -> void:
	document["integrity"] = {
		"algorithm": Replay.INTEGRITY_ALGORITHM,
		"content_hash": Replay.compute_content_hash(document),
	}


func _contains_error(errors: Array, needle: String) -> bool:
	for error_variant: Variant in errors:
		if needle in str(error_variant):
			return true
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish(document_hash: String, final_hash: String, document: Dictionary = {}) -> void:
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_REPLAY_FAILURE: %s" % failure)
		print("DUEL_REPLAY_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print(
		"DUEL_REPLAY_OK document_hash=%s final_hash=%s checkpoints=%d events=%d external_calls=0"
		% [
			document_hash,
			final_hash,
			document.get("checkpoints", []).size(),
			document.get("events", []).size(),
		]
	)
	quit(0)
