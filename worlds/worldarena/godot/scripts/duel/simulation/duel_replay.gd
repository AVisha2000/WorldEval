class_name DuelReplay
extends RefCounted

const Rules := preload("res://scripts/duel/simulation/duel_rules.gd")
const Simulation := preload("res://scripts/duel/simulation/duel_simulation.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const OrderRecord := preload("res://scripts/duel/simulation/duel_order.gd")
const DeltaRecord := preload("res://scripts/duel/simulation/duel_delta.gd")
const EventRecord := preload("res://scripts/duel/simulation/duel_event.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

## Phase-2, render-free replay authority. This foundation deliberately restores
## only a deterministic tick-0 core setup. Economy-enabled state is rejected
## until the economy subsystem exposes a complete snapshot restoration API.
##
## The class has no provider, transport, filesystem, scene-tree, or clock
## dependency. Playback can only construct DuelSimulation and call step_tick().

const FORMAT_VERSION := "worldarena-duel-core-replay-v1"
const SCOPE := "tick0_core_no_economy"
const CHECKPOINT_INTERVAL_TICKS := 300
const INTEGRITY_ALGORITHM := "sha256-jcs"
const EXTERNAL_CALL_CAPABILITY := false

const SETUP_KEYS: Array[String] = [
	"config", "economy_enabled", "entities", "pending_deltas", "prequeued_orders",
]
const TRANSCRIPT_ENTRY_KEYS: Array[String] = [
	"application_tick", "primitive_orders", "transcript_id",
]
const ENTITY_KEYS: Array[String] = [
	"active_order_id", "alive", "catalog_id", "entity_kind", "facing_mdeg", "hp",
	"integer_attributes", "internal_id", "mana", "max_hp", "max_mana",
	"movement_remainder_mt", "next_replan_tick", "owner_seat", "position_mt",
	"public_id", "radius_mt", "route", "route_index", "segment_denominator",
	"segment_numerator", "tags",
]
const ORDER_KEYS: Array[String] = [
	"activation_tick", "actor_id", "command_digest", "command_index",
	"internal_order_id", "issued_tick", "order_kind", "owner_seat", "status", "target",
]
const DELTA_KEYS: Array[String] = [
	"amount", "application_tick", "attribute_key", "entity_id", "kind", "local_seq",
	"source_internal_id",
]
const EVENT_KEYS: Array[String] = [
	"audience_mask", "event_kind", "event_seq", "payload", "phase", "source_internal_id",
	"target_internal_id", "tick",
]
const CHECKPOINT_KEYS: Array[String] = [
	"checkpoint_index", "kind", "state_hash", "state_tick", "transcript_id",
]
const DOCUMENT_KEYS: Array[String] = [
	"checkpoints", "decision_ticks", "events", "final_state_hash", "final_tick",
	"format_version", "integrity", "scope", "setup", "terminal_result", "transcript",
]

var last_errors := PackedStringArray()
var external_call_count: int = 0


## Records a canonical replay document by executing the supplied tick-0 setup.
## Setup entity/order/delta arrays are normalized, so shuffled construction
## order cannot change the document. Transcript order is evidence and therefore
## must already be strictly canonical.
func record(
	setup_input: Dictionary,
	transcript_input: Array,
	decision_ticks_input: Array,
	requested_final_tick: int
) -> Dictionary:
	last_errors.clear()
	external_call_count = 0
	var setup_result := _normalize_setup(setup_input)
	if not bool(setup_result["ok"]):
		return _failure(setup_result["errors"], false, "setup_validation", 0)
	var transcript_result := _normalize_transcript(
		transcript_input, setup_result["value"], requested_final_tick
	)
	if not bool(transcript_result["ok"]):
		return _failure(transcript_result["errors"], false, "transcript_validation", 0)
	var decisions_result := _normalize_decision_ticks(decision_ticks_input, requested_final_tick)
	if not bool(decisions_result["ok"]):
		return _failure(decisions_result["errors"], false, "decision_validation", 0)
	if requested_final_tick <= 0:
		return _failure(["final_tick must be positive"], false, "document_validation", 0)

	var execution := _execute(
		setup_result["value"],
		transcript_result["value"],
		decisions_result["value"],
		requested_final_tick,
		[],
		[],
		false
	)
	if not bool(execution["ok"]):
		return _failure(
			execution["errors"], false, str(execution["stage"]), int(execution["stopped_tick"])
		)

	var document := {
		"checkpoints": execution["checkpoints"],
		"decision_ticks": decisions_result["value"],
		"events": execution["events"],
		"final_state_hash": execution["final_state_hash"],
		"final_tick": int(execution["final_tick"]),
		"format_version": FORMAT_VERSION,
		"integrity": {},
		"scope": SCOPE,
		"setup": setup_result["value"],
		"terminal_result": execution["terminal_result"],
		"transcript": transcript_result["value"],
	}
	document["integrity"] = {
		"algorithm": INTEGRITY_ALGORITHM,
		"content_hash": compute_content_hash(document),
	}
	return {
		"document": document,
		"document_hash": Codec.sha256_canonical(document),
		"errors": [],
		"external_calls": external_call_count,
		"ok": true,
	}


## Replays a stored document offline. If exact_bytes is supplied, it must be
## byte-for-byte JCS for document; whitespace, alternate key ordering, or other
## non-canonical transport bytes fail before the simulation is constructed.
func replay(document: Dictionary, exact_bytes: PackedByteArray = PackedByteArray()) -> Dictionary:
	last_errors.clear()
	external_call_count = 0
	var canonical_errors := Codec.validate_canonical_value(document, "$")
	if not canonical_errors.is_empty():
		return _failure(canonical_errors, true, "canonical_validation", 0)
	if not exact_bytes.is_empty() and exact_bytes != Codec.canonical_bytes(document):
		return _failure(
			["DUEL_REPLAY_CORRUPTION: supplied bytes are not the exact canonical document bytes"],
			true,
			"canonical_bytes",
			0
		)

	var document_errors := _validate_document_shape(document)
	if not document_errors.is_empty():
		return _failure(document_errors, true, "document_validation", 0)
	var expected_content_hash := compute_content_hash(document)
	if str(document["integrity"]["content_hash"]) != expected_content_hash:
		return _failure(
			["DUEL_REPLAY_CORRUPTION: replay content hash mismatch"], true, "integrity", 0
		)

	var final_tick := int(document["final_tick"])
	var setup_result := _normalize_setup(document["setup"])
	if not bool(setup_result["ok"]):
		return _failure(setup_result["errors"], true, "setup_validation", 0)
	if Codec.canonical_json(setup_result["value"]) != Codec.canonical_json(document["setup"]):
		return _failure(
			["DUEL_REPLAY_CORRUPTION: stored setup arrays are not in canonical order"],
			true,
			"setup_validation",
			0
		)
	var transcript_result := _normalize_transcript(document["transcript"], document["setup"], final_tick)
	if not bool(transcript_result["ok"]):
		return _failure(transcript_result["errors"], true, "transcript_validation", 0)
	var decisions_result := _normalize_decision_ticks(document["decision_ticks"], final_tick)
	if not bool(decisions_result["ok"]):
		return _failure(decisions_result["errors"], true, "decision_validation", 0)
	var event_errors := _validate_recorded_events(document["events"])
	if not event_errors.is_empty():
		return _failure(event_errors, true, "event_validation", 0)
	var checkpoint_errors := _validate_recorded_checkpoints(document["checkpoints"])
	if not checkpoint_errors.is_empty():
		return _failure(checkpoint_errors, true, "checkpoint_validation", 0)
	if not _is_lower_hex_hash(str(document["final_state_hash"])):
		return _failure(
			["DUEL_REPLAY_CORRUPTION: final_state_hash must be lowercase SHA-256"],
			true,
			"final_hash_validation",
			0
		)

	var execution := _execute(
		document["setup"],
		document["transcript"],
		document["decision_ticks"],
		final_tick,
		document["events"],
		document["checkpoints"],
		true
	)
	if not bool(execution["ok"]):
		return _failure(
			execution["errors"], true, str(execution["stage"]), int(execution["stopped_tick"])
		)
	if str(execution["final_state_hash"]) != str(document["final_state_hash"]):
		return _failure(
			["DUEL_REPLAY_CORRUPTION: final state hash mismatch at tick %d" % final_tick],
			true,
			"final_hash",
			final_tick
		)
	if Codec.canonical_json(execution["terminal_result"]) != Codec.canonical_json(document["terminal_result"]):
		return _failure(
			["DUEL_REPLAY_CORRUPTION: terminal result mismatch at tick %d" % final_tick],
			true,
			"terminal_result",
			final_tick
		)
	return {
		"document_hash": Codec.sha256_canonical(document),
		"errors": [],
		"events_verified": execution["events"].size(),
		"external_calls": external_call_count,
		"final_state_hash": execution["final_state_hash"],
		"final_tick": final_tick,
		"ok": true,
		"checkpoints_verified": execution["checkpoints"].size(),
	}


static func canonical_document_bytes(document: Dictionary) -> PackedByteArray:
	return Codec.canonical_bytes(document)


## Public so artifact tooling can validate or refresh an unsigned content
## digest. Replay correctness still comes from re-executing every event and
## checkpoint, not from trusting this digest as a signature.
static func compute_content_hash(document: Dictionary) -> String:
	var content := document.duplicate(true)
	content.erase("integrity")
	return Codec.sha256_canonical(content)


func _execute(
	setup: Dictionary,
	transcript: Array,
	decision_ticks: Array,
	final_tick: int,
	expected_events: Array,
	expected_checkpoints: Array,
	verify: bool
) -> Dictionary:
	var build_result := _build_simulation(setup)
	if not bool(build_result["ok"]):
		return _execution_failure(build_result["errors"], "setup_restore", 0)
	var simulation: Simulation = build_result["simulation"]
	var actual_events: Array = []
	var actual_checkpoints: Array = []
	var event_cursor := 0
	var checkpoint_cursor := 0
	var transcript_cursor := 0
	var decision_cursor := 0

	var checkpoint_result := _process_checkpoint(
		simulation,
		"initial",
		"",
		actual_checkpoints,
		expected_checkpoints,
		checkpoint_cursor,
		verify
	)
	if not bool(checkpoint_result["ok"]):
		return checkpoint_result
	checkpoint_cursor = int(checkpoint_result["cursor"])

	while simulation.state.tick < final_tick:
		var tick := simulation.state.tick
		if bool(simulation.state.terminal["ended"]):
			return _execution_failure(
				["simulation became terminal before recorded final_tick %d" % final_tick],
				"terminal_tick",
				tick
			)

		if decision_cursor < decision_ticks.size() and int(decision_ticks[decision_cursor]) == tick:
			checkpoint_result = _process_checkpoint(
				simulation,
				"decision",
				"",
				actual_checkpoints,
				expected_checkpoints,
				checkpoint_cursor,
				verify
			)
			if not bool(checkpoint_result["ok"]):
				return checkpoint_result
			checkpoint_cursor = int(checkpoint_result["cursor"])
			decision_cursor += 1

		if transcript_cursor < transcript.size() \
			and int(transcript[transcript_cursor]["application_tick"]) == tick:
			var entry: Dictionary = transcript[transcript_cursor]
			for order_data_variant: Variant in entry["primitive_orders"]:
				var order_result := _order_from_dict(order_data_variant, "$.transcript.order")
				if not bool(order_result["ok"]):
					return _execution_failure(order_result["errors"], "action_restore", tick)
				var queued_id := simulation.queue_order(order_result["value"])
				if queued_id == 0:
					return _execution_failure(
						[
							"primitive order %d was rejected at application tick %d"
							% [int(order_data_variant["internal_order_id"]), tick]
						],
						"action_application",
						tick
					)
			checkpoint_result = _process_checkpoint(
				simulation,
				"application",
				str(entry["transcript_id"]),
				actual_checkpoints,
				expected_checkpoints,
				checkpoint_cursor,
				verify
			)
			if not bool(checkpoint_result["ok"]):
				return checkpoint_result
			checkpoint_cursor = int(checkpoint_result["cursor"])
			transcript_cursor += 1

		var event_start := simulation.state.events.size()
		simulation.step_tick()
		for event_index: int in range(event_start, simulation.state.events.size()):
			var event: EventRecord = simulation.state.events[event_index]
			var event_data := event.to_canonical_dict()
			actual_events.append(event_data)
			if verify:
				if event_cursor >= expected_events.size():
					return _execution_failure(
						["DUEL_REPLAY_CORRUPTION: unexpected event_seq %d" % event.event_seq],
						"event",
						tick
					)
				if Codec.canonical_json(event_data) != Codec.canonical_json(expected_events[event_cursor]):
					return _execution_failure(
						["DUEL_REPLAY_CORRUPTION: event mismatch at event_seq %d" % event.event_seq],
						"event",
						tick
					)
				event_cursor += 1

		if simulation.state.tick % CHECKPOINT_INTERVAL_TICKS == 0:
			checkpoint_result = _process_checkpoint(
				simulation,
				"periodic",
				"",
				actual_checkpoints,
				expected_checkpoints,
				checkpoint_cursor,
				verify
			)
			if not bool(checkpoint_result["ok"]):
				return checkpoint_result
			checkpoint_cursor = int(checkpoint_result["cursor"])

	checkpoint_result = _process_checkpoint(
		simulation,
		"final",
		"",
		actual_checkpoints,
		expected_checkpoints,
		checkpoint_cursor,
		verify
	)
	if not bool(checkpoint_result["ok"]):
		return checkpoint_result
	checkpoint_cursor = int(checkpoint_result["cursor"])
	if verify and event_cursor != expected_events.size():
		return _execution_failure(
			[
				"DUEL_REPLAY_CORRUPTION: replay ended with %d unconsumed recorded events"
				% (expected_events.size() - event_cursor)
			],
			"event",
			final_tick
		)
	if verify and checkpoint_cursor != expected_checkpoints.size():
		return _execution_failure(
			[
				"DUEL_REPLAY_CORRUPTION: replay ended with %d unconsumed checkpoints"
				% (expected_checkpoints.size() - checkpoint_cursor)
			],
			"checkpoint",
			final_tick
		)
	return {
		"checkpoints": actual_checkpoints,
		"errors": [],
		"events": actual_events,
		"final_state_hash": simulation.checkpoint_hash(),
		"final_tick": simulation.state.tick,
		"ok": true,
		"stage": "complete",
		"stopped_tick": simulation.state.tick,
		"terminal_result": simulation.terminal_result(),
	}


func _process_checkpoint(
	simulation: Simulation,
	kind: String,
	transcript_id: String,
	actual: Array,
	expected: Array,
	cursor: int,
	verify: bool
) -> Dictionary:
	var record := {
		"checkpoint_index": actual.size(),
		"kind": kind,
		"state_hash": simulation.checkpoint_hash(),
		"state_tick": simulation.state.tick,
		"transcript_id": transcript_id,
	}
	actual.append(record)
	if verify:
		if cursor >= expected.size():
			return _execution_failure(
				[
					"DUEL_REPLAY_CORRUPTION: unexpected %s checkpoint at tick %d"
					% [kind, simulation.state.tick]
				],
				"checkpoint",
				simulation.state.tick
			)
		if Codec.canonical_json(record) != Codec.canonical_json(expected[cursor]):
			return _execution_failure(
				[
					"DUEL_REPLAY_CORRUPTION: %s checkpoint mismatch at tick %d"
					% [kind, simulation.state.tick]
				],
				"checkpoint",
				simulation.state.tick
			)
	return {"cursor": cursor + 1, "ok": true}


func _build_simulation(setup: Dictionary) -> Dictionary:
	if bool(setup["economy_enabled"]):
		return {
			"errors": [
				"economy-enabled replay restoration is unsupported by the Phase-2 tick-0 core foundation"
			],
			"ok": false,
		}
	var simulation := Simulation.new(setup["config"])
	if not simulation.last_errors.is_empty():
		return {"errors": _packed_to_array(simulation.last_errors), "ok": false}
	for entity_data_variant: Variant in setup["entities"]:
		var entity_result := _entity_from_dict(entity_data_variant, "$.setup.entities")
		if not bool(entity_result["ok"]):
			return entity_result
		var entity: EntityRecord = entity_result["value"]
		if simulation.add_entity(entity, entity.alive) == 0:
			return {
				"errors": ["failed to restore entity %d or its occupancy" % entity.internal_id],
				"ok": false,
			}
	for order_data_variant: Variant in setup["prequeued_orders"]:
		var order_result := _order_from_dict(order_data_variant, "$.setup.prequeued_orders")
		if not bool(order_result["ok"]):
			return order_result
		if simulation.queue_order(order_result["value"]) == 0:
			return {
				"errors": [
					"failed to restore prequeued order %d"
					% int(order_data_variant["internal_order_id"])
				],
				"ok": false,
			}
	for delta_data_variant: Variant in setup["pending_deltas"]:
		var delta_result := _delta_from_dict(delta_data_variant, "$.setup.pending_deltas")
		if not bool(delta_result["ok"]):
			return delta_result
		var errors := simulation.queue_delta(delta_result["value"])
		if not errors.is_empty():
			return {"errors": _packed_to_array(errors), "ok": false}
	return {"errors": [], "ok": true, "simulation": simulation}


func _normalize_setup(input: Dictionary) -> Dictionary:
	var errors := PackedStringArray()
	errors.append_array(Codec.validate_canonical_value(input, "$.setup"))
	_validate_exact_keys(input, SETUP_KEYS, "$.setup", errors)
	if not errors.is_empty():
		return {"errors": _packed_to_array(errors), "ok": false}
	if typeof(input["config"]) != TYPE_DICTIONARY:
		errors.append("$.setup.config must be an object")
	if typeof(input["economy_enabled"]) != TYPE_BOOL:
		errors.append("$.setup.economy_enabled must be a boolean")
	elif bool(input["economy_enabled"]):
		errors.append(
			"economy-enabled replay restoration is unsupported by the Phase-2 tick-0 core foundation"
		)
	for key: String in ["entities", "pending_deltas", "prequeued_orders"]:
		if typeof(input[key]) != TYPE_ARRAY:
			errors.append("$.setup.%s must be an array" % key)
	if not errors.is_empty():
		return {"errors": _packed_to_array(errors), "ok": false}

	var config := Rules.merge_with_defaults(input["config"])
	errors.append_array(Rules.validate_config(config))
	errors.append_array(Codec.validate_canonical_value(config, "$.setup.config"))
	var entities: Array = []
	var entity_ids: Dictionary = {}
	for index: int in input["entities"].size():
		var result := _entity_from_dict(input["entities"][index], "$.setup.entities[%d]" % index)
		if not bool(result["ok"]):
			_append_errors(errors, result["errors"])
			continue
		var value: Dictionary = result["canonical"]
		var entity_id := int(value["internal_id"])
		if entity_ids.has(entity_id):
			errors.append("$.setup.entities has duplicate internal_id %d" % entity_id)
		else:
			entity_ids[entity_id] = true
		entities.append(value)
	entities.sort_custom(_entity_dict_less)

	var orders: Array = []
	var order_ids: Dictionary = {}
	for index: int in input["prequeued_orders"].size():
		var result := _order_from_dict(
			input["prequeued_orders"][index], "$.setup.prequeued_orders[%d]" % index
		)
		if not bool(result["ok"]):
			_append_errors(errors, result["errors"])
			continue
		var value: Dictionary = result["canonical"]
		var order_id := int(value["internal_order_id"])
		if order_ids.has(order_id):
			errors.append("$.setup.prequeued_orders has duplicate internal_order_id %d" % order_id)
		else:
			order_ids[order_id] = true
		if int(value["status"]) != OrderRecord.Status.QUEUED:
			errors.append("tick-0 prequeued order %d must have QUEUED status" % order_id)
		orders.append(value)
	orders.sort_custom(_order_dict_less)

	var deltas: Array = []
	var delta_keys: Dictionary = {}
	for index: int in input["pending_deltas"].size():
		var result := _delta_from_dict(
			input["pending_deltas"][index], "$.setup.pending_deltas[%d]" % index
		)
		if not bool(result["ok"]):
			_append_errors(errors, result["errors"])
			continue
		var value: Dictionary = result["canonical"]
		var key := Codec.canonical_json(value)
		if delta_keys.has(key):
			errors.append("$.setup.pending_deltas contains an exact duplicate")
		else:
			delta_keys[key] = true
		deltas.append(value)
	deltas.sort_custom(_delta_dict_less)
	if not errors.is_empty():
		return {"errors": _packed_to_array(errors), "ok": false}
	return {
		"errors": [],
		"ok": true,
		"value": {
			"config": config,
			"economy_enabled": false,
			"entities": entities,
			"pending_deltas": deltas,
			"prequeued_orders": orders,
		},
	}


func _normalize_transcript(input: Array, setup: Dictionary, final_tick: int) -> Dictionary:
	var errors := PackedStringArray()
	errors.append_array(Codec.validate_canonical_value(input, "$.transcript"))
	var result: Array = []
	var previous_tick := -1
	var previous_transcript_id := ""
	var transcript_ids: Dictionary = {}
	var order_ids: Dictionary = {}
	for setup_order_variant: Variant in setup.get("prequeued_orders", []):
		order_ids[int(setup_order_variant["internal_order_id"])] = true
	for index: int in input.size():
		if typeof(input[index]) != TYPE_DICTIONARY:
			errors.append("$.transcript[%d] must be an object" % index)
			continue
		var entry: Dictionary = input[index]
		_validate_exact_keys(entry, TRANSCRIPT_ENTRY_KEYS, "$.transcript[%d]" % index, errors)
		if not _has_exact_type(entry, "application_tick", TYPE_INT):
			errors.append("$.transcript[%d].application_tick must be an integer" % index)
		if not _has_exact_type(entry, "transcript_id", TYPE_STRING):
			errors.append("$.transcript[%d].transcript_id must be a string" % index)
		if not _has_exact_type(entry, "primitive_orders", TYPE_ARRAY):
			errors.append("$.transcript[%d].primitive_orders must be an array" % index)
		if not entry.has("application_tick") or not entry.has("transcript_id") \
			or not entry.has("primitive_orders"):
			continue
		if typeof(entry["application_tick"]) != TYPE_INT \
			or typeof(entry["transcript_id"]) != TYPE_STRING \
			or typeof(entry["primitive_orders"]) != TYPE_ARRAY:
			continue
		var tick := int(entry["application_tick"])
		var transcript_id := str(entry["transcript_id"])
		if tick < 0 or tick >= final_tick:
			errors.append(
				"$.transcript[%d].application_tick must be in [0, final_tick)" % index
			)
		if tick <= previous_tick:
			errors.append("transcript application ticks must be strictly increasing and unique")
		if transcript_id.is_empty():
			errors.append("$.transcript[%d].transcript_id must not be empty" % index)
		if transcript_ids.has(transcript_id):
			errors.append("transcript_id %s is duplicated" % transcript_id)
		elif index > 0 and transcript_id <= previous_transcript_id:
			errors.append("transcript IDs must be strictly ascending and unique")
		transcript_ids[transcript_id] = true
		previous_tick = tick
		previous_transcript_id = transcript_id

		var primitive_orders: Array = []
		var previous_order_id := 0
		for order_index: int in entry["primitive_orders"].size():
			var order_result := _order_from_dict(
				entry["primitive_orders"][order_index],
				"$.transcript[%d].primitive_orders[%d]" % [index, order_index]
			)
			if not bool(order_result["ok"]):
				_append_errors(errors, order_result["errors"])
				continue
			var order: Dictionary = order_result["canonical"]
			var order_id := int(order["internal_order_id"])
			if order_id <= previous_order_id:
				errors.append(
					"primitive order IDs must be strictly ascending within transcript entry %s"
					% transcript_id
				)
			if order_ids.has(order_id):
				errors.append("internal_order_id %d is duplicated across setup/transcript" % order_id)
			order_ids[order_id] = true
			previous_order_id = order_id
			if int(order["activation_tick"]) != tick:
				errors.append(
					"primitive order %d activation_tick must equal application_tick %d"
					% [order_id, tick]
				)
			if int(order["status"]) != OrderRecord.Status.QUEUED:
				errors.append("primitive order %d must have QUEUED status" % order_id)
			primitive_orders.append(order)
		result.append({
			"application_tick": tick,
			"primitive_orders": primitive_orders,
			"transcript_id": transcript_id,
		})
	if not errors.is_empty():
		return {"errors": _packed_to_array(errors), "ok": false}
	return {"errors": [], "ok": true, "value": result}


func _normalize_decision_ticks(input: Array, final_tick: int) -> Dictionary:
	var errors := PackedStringArray()
	errors.append_array(Codec.validate_canonical_value(input, "$.decision_ticks"))
	var result: Array = []
	var previous := -1
	for index: int in input.size():
		if typeof(input[index]) != TYPE_INT:
			errors.append("$.decision_ticks[%d] must be an integer" % index)
			continue
		var tick := int(input[index])
		if tick < 0 or tick >= final_tick:
			errors.append("decision ticks must be in [0, final_tick)")
		if tick <= previous:
			errors.append("decision ticks must be strictly increasing and unique")
		previous = tick
		result.append(tick)
	if not errors.is_empty():
		return {"errors": _packed_to_array(errors), "ok": false}
	return {"errors": [], "ok": true, "value": result}


func _entity_from_dict(data_variant: Variant, path: String) -> Dictionary:
	var errors := PackedStringArray()
	if typeof(data_variant) != TYPE_DICTIONARY:
		return {"errors": ["%s must be an object" % path], "ok": false}
	var data: Dictionary = data_variant
	_validate_exact_keys(data, ENTITY_KEYS, path, errors)
	var int_fields: Array[String] = [
		"active_order_id", "facing_mdeg", "hp", "internal_id", "mana", "max_hp", "max_mana",
		"movement_remainder_mt", "next_replan_tick", "owner_seat", "radius_mt", "route_index",
		"segment_denominator", "segment_numerator",
	]
	for field: String in int_fields:
		if not _has_exact_type(data, field, TYPE_INT):
			errors.append("%s.%s must be an integer" % [path, field])
	for field: String in ["catalog_id", "entity_kind", "public_id"]:
		if not _has_exact_type(data, field, TYPE_STRING):
			errors.append("%s.%s must be a string" % [path, field])
	if not _has_exact_type(data, "alive", TYPE_BOOL):
		errors.append("%s.alive must be a boolean" % path)
	if not _has_exact_type(data, "position_mt", TYPE_DICTIONARY):
		errors.append("%s.position_mt must be an object" % path)
	if not _has_exact_type(data, "route", TYPE_ARRAY):
		errors.append("%s.route must be an array" % path)
	if not _has_exact_type(data, "tags", TYPE_ARRAY):
		errors.append("%s.tags must be an array" % path)
	if not _has_exact_type(data, "integer_attributes", TYPE_DICTIONARY):
		errors.append("%s.integer_attributes must be an object" % path)
	if not errors.is_empty():
		return {"errors": _packed_to_array(errors), "ok": false}
	_validate_exact_keys(data["position_mt"], ["x", "y"], "%s.position_mt" % path, errors)
	if not _has_exact_type(data["position_mt"], "x", TYPE_INT) \
		or not _has_exact_type(data["position_mt"], "y", TYPE_INT):
		errors.append("%s.position_mt x/y must be integers" % path)
	var route: Array[Dictionary] = []
	for index: int in data["route"].size():
		if typeof(data["route"][index]) != TYPE_DICTIONARY:
			errors.append("%s.route[%d] must be an object" % [path, index])
			continue
		var point: Dictionary = data["route"][index]
		_validate_exact_keys(point, ["x", "y"], "%s.route[%d]" % [path, index], errors)
		if not _has_exact_type(point, "x", TYPE_INT) or not _has_exact_type(point, "y", TYPE_INT):
			errors.append("%s.route[%d] x/y must be integers" % [path, index])
			continue
		route.append({"x": int(point["x"]), "y": int(point["y"])})
	var tags: Array[String] = []
	var previous_tag := ""
	for index: int in data["tags"].size():
		if typeof(data["tags"][index]) != TYPE_STRING:
			errors.append("%s.tags[%d] must be a string" % [path, index])
			continue
		var tag := str(data["tags"][index])
		if index > 0 and tag <= previous_tag:
			errors.append("%s.tags must be strictly ascending and unique" % path)
		previous_tag = tag
		tags.append(tag)
	for key_variant: Variant in data["integer_attributes"].keys():
		if typeof(key_variant) != TYPE_STRING:
			errors.append("%s.integer_attributes keys must be strings" % path)
		elif typeof(data["integer_attributes"][key_variant]) != TYPE_INT:
			errors.append("%s.integer_attributes.%s must be an integer" % [path, str(key_variant)])
	if not errors.is_empty():
		return {"errors": _packed_to_array(errors), "ok": false}

	var entity := EntityRecord.new(int(data["internal_id"]), int(data["owner_seat"]), str(data["entity_kind"]))
	entity.active_order_id = int(data["active_order_id"])
	entity.alive = bool(data["alive"])
	entity.catalog_id = str(data["catalog_id"])
	entity.facing_mdeg = int(data["facing_mdeg"])
	entity.hp = int(data["hp"])
	entity.internal_id = int(data["internal_id"])
	entity.mana = int(data["mana"])
	entity.max_hp = int(data["max_hp"])
	entity.max_mana = int(data["max_mana"])
	entity.movement_remainder_mt = int(data["movement_remainder_mt"])
	entity.next_replan_tick = int(data["next_replan_tick"])
	entity.public_id = str(data["public_id"])
	entity.radius_mt = int(data["radius_mt"])
	entity.route = route
	entity.route_index = int(data["route_index"])
	entity.segment_denominator = int(data["segment_denominator"])
	entity.segment_numerator = int(data["segment_numerator"])
	entity.tags = tags
	entity.integer_attributes = data["integer_attributes"].duplicate(true)
	entity.set_position_mt(int(data["position_mt"]["x"]), int(data["position_mt"]["y"]))
	errors.append_array(entity.validate())
	if entity.public_id.is_empty():
		errors.append("%s.public_id must be explicit in a replay setup" % path)
	if entity.active_order_id != 0:
		errors.append("%s.active_order_id must be zero in a tick-0 setup" % path)
	if not errors.is_empty():
		return {"errors": _packed_to_array(errors), "ok": false}
	return {"canonical": entity.to_canonical_dict(), "errors": [], "ok": true, "value": entity}


func _order_from_dict(data_variant: Variant, path: String) -> Dictionary:
	var errors := PackedStringArray()
	if typeof(data_variant) != TYPE_DICTIONARY:
		return {"errors": ["%s must be an object" % path], "ok": false}
	var data: Dictionary = data_variant
	_validate_exact_keys(data, ORDER_KEYS, path, errors)
	for field: String in [
		"activation_tick", "actor_id", "command_index", "internal_order_id", "issued_tick",
		"owner_seat", "status",
	]:
		if not _has_exact_type(data, field, TYPE_INT):
			errors.append("%s.%s must be an integer" % [path, field])
	for field: String in ["command_digest", "order_kind"]:
		if not _has_exact_type(data, field, TYPE_STRING):
			errors.append("%s.%s must be a string" % [path, field])
	if not _has_exact_type(data, "target", TYPE_DICTIONARY):
		errors.append("%s.target must be an object" % path)
	if not errors.is_empty():
		return {"errors": _packed_to_array(errors), "ok": false}
	var order := OrderRecord.new(
		int(data["internal_order_id"]),
		int(data["owner_seat"]),
		int(data["actor_id"]),
		str(data["order_kind"])
	)
	order.activation_tick = int(data["activation_tick"])
	order.command_digest = str(data["command_digest"])
	order.command_index = int(data["command_index"])
	order.issued_tick = int(data["issued_tick"])
	order.status = int(data["status"])
	order.target = data["target"].duplicate(true)
	errors.append_array(order.validate())
	if not errors.is_empty():
		return {"errors": _packed_to_array(errors), "ok": false}
	return {"canonical": order.to_canonical_dict(), "errors": [], "ok": true, "value": order}


func _delta_from_dict(data_variant: Variant, path: String) -> Dictionary:
	var errors := PackedStringArray()
	if typeof(data_variant) != TYPE_DICTIONARY:
		return {"errors": ["%s must be an object" % path], "ok": false}
	var data: Dictionary = data_variant
	_validate_exact_keys(data, DELTA_KEYS, path, errors)
	for field: String in [
		"amount", "application_tick", "entity_id", "kind", "local_seq", "source_internal_id",
	]:
		if not _has_exact_type(data, field, TYPE_INT):
			errors.append("%s.%s must be an integer" % [path, field])
	if not _has_exact_type(data, "attribute_key", TYPE_STRING):
		errors.append("%s.attribute_key must be a string" % path)
	if not errors.is_empty():
		return {"errors": _packed_to_array(errors), "ok": false}
	var delta := DeltaRecord.new()
	delta.amount = int(data["amount"])
	delta.application_tick = int(data["application_tick"])
	delta.attribute_key = str(data["attribute_key"])
	delta.entity_id = int(data["entity_id"])
	delta.kind = int(data["kind"])
	delta.local_seq = int(data["local_seq"])
	delta.source_internal_id = int(data["source_internal_id"])
	errors.append_array(delta.validate())
	if not errors.is_empty():
		return {"errors": _packed_to_array(errors), "ok": false}
	return {"canonical": delta.to_canonical_dict(), "errors": [], "ok": true, "value": delta}


func _validate_document_shape(document: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	_validate_exact_keys(document, DOCUMENT_KEYS, "$", errors)
	if not _has_exact_type(document, "format_version", TYPE_STRING) \
		or str(document.get("format_version", "")) != FORMAT_VERSION:
		errors.append("format_version must equal %s" % FORMAT_VERSION)
	if not _has_exact_type(document, "scope", TYPE_STRING) \
		or str(document.get("scope", "")) != SCOPE:
		errors.append("scope must equal %s" % SCOPE)
	for field: String in ["setup", "terminal_result", "integrity"]:
		if not _has_exact_type(document, field, TYPE_DICTIONARY):
			errors.append("$.%s must be an object" % field)
	for field: String in ["transcript", "decision_ticks", "events", "checkpoints"]:
		if not _has_exact_type(document, field, TYPE_ARRAY):
			errors.append("$.%s must be an array" % field)
	if not _has_exact_type(document, "final_tick", TYPE_INT) or int(document.get("final_tick", 0)) <= 0:
		errors.append("$.final_tick must be a positive integer")
	if not _has_exact_type(document, "final_state_hash", TYPE_STRING):
		errors.append("$.final_state_hash must be a string")
	if document.has("integrity") and typeof(document["integrity"]) == TYPE_DICTIONARY:
		_validate_exact_keys(document["integrity"], ["algorithm", "content_hash"], "$.integrity", errors)
		if str(document["integrity"].get("algorithm", "")) != INTEGRITY_ALGORITHM:
			errors.append("$.integrity.algorithm must equal %s" % INTEGRITY_ALGORITHM)
		if not _is_lower_hex_hash(str(document["integrity"].get("content_hash", ""))):
			errors.append("$.integrity.content_hash must be lowercase SHA-256")
	if document.has("terminal_result") and typeof(document["terminal_result"]) == TYPE_DICTIONARY:
		_validate_exact_keys(
			document["terminal_result"],
			["ended", "reason", "result", "winner_seat"],
			"$.terminal_result",
			errors
		)
		if not _has_exact_type(document["terminal_result"], "ended", TYPE_BOOL):
			errors.append("$.terminal_result.ended must be a boolean")
		for field: String in ["reason", "result"]:
			if not _has_exact_type(document["terminal_result"], field, TYPE_STRING):
				errors.append("$.terminal_result.%s must be a string" % field)
		if not _has_exact_type(document["terminal_result"], "winner_seat", TYPE_INT):
			errors.append("$.terminal_result.winner_seat must be an integer")
	return errors


func _validate_recorded_events(events: Array) -> PackedStringArray:
	var errors := PackedStringArray()
	for index: int in events.size():
		if typeof(events[index]) != TYPE_DICTIONARY:
			errors.append("$.events[%d] must be an object" % index)
			continue
		var data: Dictionary = events[index]
		_validate_exact_keys(data, EVENT_KEYS, "$.events[%d]" % index, errors)
		for field: String in [
			"audience_mask", "event_seq", "phase", "source_internal_id", "target_internal_id", "tick",
		]:
			if not _has_exact_type(data, field, TYPE_INT):
				errors.append("$.events[%d].%s must be an integer" % [index, field])
		if not _has_exact_type(data, "event_kind", TYPE_STRING):
			errors.append("$.events[%d].event_kind must be a string" % index)
		if not _has_exact_type(data, "payload", TYPE_DICTIONARY):
			errors.append("$.events[%d].payload must be an object" % index)
		if not errors.is_empty():
			continue
		var event := EventRecord.new(int(data["tick"]), int(data["phase"]), str(data["event_kind"]))
		event.audience_mask = int(data["audience_mask"])
		event.event_seq = int(data["event_seq"])
		event.payload = data["payload"].duplicate(true)
		event.source_internal_id = int(data["source_internal_id"])
		event.target_internal_id = int(data["target_internal_id"])
		errors.append_array(event.validate())
		if event.event_seq != index + 1:
			errors.append("recorded event_seq must be contiguous from 1")
	return errors


func _validate_recorded_checkpoints(checkpoints: Array) -> PackedStringArray:
	var errors := PackedStringArray()
	for index: int in checkpoints.size():
		if typeof(checkpoints[index]) != TYPE_DICTIONARY:
			errors.append("$.checkpoints[%d] must be an object" % index)
			continue
		var data: Dictionary = checkpoints[index]
		_validate_exact_keys(data, CHECKPOINT_KEYS, "$.checkpoints[%d]" % index, errors)
		for field: String in ["checkpoint_index", "state_tick"]:
			if not _has_exact_type(data, field, TYPE_INT):
				errors.append("$.checkpoints[%d].%s must be an integer" % [index, field])
		for field: String in ["kind", "state_hash", "transcript_id"]:
			if not _has_exact_type(data, field, TYPE_STRING):
				errors.append("$.checkpoints[%d].%s must be a string" % [index, field])
		if not errors.is_empty():
			continue
		if int(data["checkpoint_index"]) != index:
			errors.append("checkpoint_index must be contiguous from 0")
		if int(data["state_tick"]) < 0:
			errors.append("checkpoint state_tick must be non-negative")
		if not str(data["kind"]) in ["initial", "decision", "application", "periodic", "final"]:
			errors.append("checkpoint kind is invalid")
		if not _is_lower_hex_hash(str(data["state_hash"])):
			errors.append("checkpoint state_hash must be lowercase SHA-256")
	return errors


static func _validate_exact_keys(
	data: Dictionary,
	expected: Array,
	path: String,
	errors: PackedStringArray
) -> void:
	var expected_set: Dictionary = {}
	for key_variant: Variant in expected:
		expected_set[str(key_variant)] = true
	for key_variant: Variant in data.keys():
		if typeof(key_variant) != TYPE_STRING or not expected_set.has(str(key_variant)):
			errors.append("%s has unknown field %s" % [path, str(key_variant)])
	for key_variant: Variant in expected:
		var key := str(key_variant)
		if not data.has(key):
			errors.append("%s is missing required field %s" % [path, key])


static func _has_exact_type(data: Dictionary, key: String, expected_type: int) -> bool:
	return data.has(key) and typeof(data[key]) == expected_type


static func _entity_dict_less(left: Dictionary, right: Dictionary) -> bool:
	return int(left["internal_id"]) < int(right["internal_id"])


static func _order_dict_less(left: Dictionary, right: Dictionary) -> bool:
	for field: String in ["activation_tick", "issued_tick", "command_index", "internal_order_id"]:
		var left_value := int(left[field])
		var right_value := int(right[field])
		if left_value != right_value:
			return left_value < right_value
	return false


static func _delta_dict_less(left: Dictionary, right: Dictionary) -> bool:
	for field: String in ["application_tick", "entity_id", "kind", "source_internal_id", "local_seq"]:
		var left_value := int(left[field])
		var right_value := int(right[field])
		if left_value != right_value:
			return left_value < right_value
	if str(left["attribute_key"]) != str(right["attribute_key"]):
		return str(left["attribute_key"]) < str(right["attribute_key"])
	return false


static func _is_lower_hex_hash(value: String) -> bool:
	if value.length() != 64:
		return false
	for index: int in value.length():
		var code := value.unicode_at(index)
		if not (code >= 48 and code <= 57) and not (code >= 97 and code <= 102):
			return false
	return true


static func _append_errors(destination: PackedStringArray, source: Array) -> void:
	for error_variant: Variant in source:
		destination.append(str(error_variant))


static func _packed_to_array(source: PackedStringArray) -> Array:
	var result: Array = []
	for value: String in source:
		result.append(value)
	return result


func _failure(
	errors: Array,
	corruption: bool,
	stage: String,
	stopped_tick: int
) -> Dictionary:
	last_errors.clear()
	for error_variant: Variant in errors:
		last_errors.append(str(error_variant))
	return {
		"corruption": corruption,
		"errors": _packed_to_array(last_errors),
		"external_calls": external_call_count,
		"ok": false,
		"stage": stage,
		"stopped_tick": stopped_tick,
	}


static func _execution_failure(errors: Array, stage: String, stopped_tick: int) -> Dictionary:
	return {
		"errors": errors,
		"ok": false,
		"stage": stage,
		"stopped_tick": stopped_tick,
	}
