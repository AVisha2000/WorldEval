class_name DuelMatchSession
extends RefCounted

const Bootstrap := preload("res://scripts/duel/match/duel_match_bootstrap.gd")
const MatchRuntime := preload("res://scripts/duel/match/duel_match_runtime.gd")
const SnapshotBuilder := preload("res://scripts/duel/perception/duel_phase_snapshot_builder.gd")
const PerceptionRuntime := preload("res://scripts/duel/perception/duel_perception_runtime.gd")
const LegalContextBuilder := preload("res://scripts/duel/controller/duel_legal_context_builder.gd")
const ActionValidator := preload("res://scripts/duel/actions/duel_action_validator.gd")
const ActionContract := preload("res://scripts/duel/actions/duel_action_contract.gd")
const IntentBridge := preload("res://scripts/duel/controller/duel_intent_execution_bridge.gd")
const ObservationContract := preload("res://scripts/duel/observations/duel_observation_contract.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

## Authoritative match-level coordinator for the two official LLM control modes.
##
## Python owns provider calls, raw-byte/schema validation, clocks, deadlines,
## failure classification, and fixed commit/reveal coordination. This class is
## the only joined Godot boundary that can turn revealed canonical action
## batches into authoritative simulation intents.

const FIXED_MODE := "fixed_simultaneous"
const CONTINUOUS_MODE := "continuous_realtime"
const MODES: Array[String] = [CONTINUOUS_MODE, FIXED_MODE]
const FIXED_DECISION_PERIOD_TICKS := 100
const CONTINUOUS_DECISION_PERIOD_TICKS := 50
const FIXED_DEADLINE_MS := 45_000
const CONTINUOUS_DEADLINE_MS := 8_000
const CONTINUOUS_VALIDITY_TICKS := 100
const TRANSPORT_RANGE_MT := 1_000
const NEUTRAL_BINDING_BASE := 1_500_000_000
const COMMIT_DOMAIN := "worldeval-rts/action-batch-commit/v1\u0000"

const CONFIG_FIELDS: Array[String] = [
	"authoritative_hashes", "decision_mode", "faction_id", "match_id", "match_seed", "scored",
]
const PROTECTED_FIELDS: Array[String] = [
	"alias_salt_seat_0", "alias_salt_seat_1", "tie_key",
]

var match_id: String = ""
var faction_id: String = ""
var decision_mode: String = ""
var simulation: Variant = null
var runtime_catalog: Dictionary = {}
var map_manifest: Dictionary = {}
var bootstrap_registry: Dictionary = {}

var perception := PerceptionRuntime.new()
var snapshot_builder := SnapshotBuilder.new()
var legal_context_builder := LegalContextBuilder.new()
var action_validator := ActionValidator.new()
var intent_bridge := IntentBridge.new()

var _protected_tie_key := PackedByteArray()
var _alias_salt_commitments: Dictionary = {}
var _neutral_building_bindings: Dictionary = {}
var _seat_runtime: Dictionary = {}
var _opportunities: Dictionary = {}
var _accepted_batch_ids: Dictionary = {0: {}, 1: {}}
var _fixed_window: Dictionary = {}
var _fixed_active_observation_seq: int = -1
var _next_observation_seq: int = 0
var _world_event_seq_after: int = 0
var _application_transcript: Array[Dictionary] = []
var _configured: bool = false


func configure_official(config_input: Dictionary, protected_input: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if _configured:
		errors.append("match session is already configured")
		return errors
	_validate_exact_fields(config_input, CONFIG_FIELDS, [], "config", errors)
	_validate_exact_fields(protected_input, PROTECTED_FIELDS, [], "protected", errors)
	if not errors.is_empty():
		return errors
	match_id = str(config_input.get("match_id", ""))
	faction_id = str(config_input.get("faction_id", ""))
	decision_mode = str(config_input.get("decision_mode", ""))
	if not ObservationContract.is_match_id(match_id):
		errors.append("match_id is invalid")
	if decision_mode not in MODES:
		errors.append("decision_mode is invalid")
	var tie_key: Variant = protected_input.get("tie_key")
	var salt_zero: Variant = protected_input.get("alias_salt_seat_0")
	var salt_one: Variant = protected_input.get("alias_salt_seat_1")
	if typeof(tie_key) != TYPE_PACKED_BYTE_ARRAY or (tie_key as PackedByteArray).is_empty():
		errors.append("protected tie key must be non-empty bytes")
	if typeof(salt_zero) != TYPE_PACKED_BYTE_ARRAY \
		or (salt_zero as PackedByteArray).size() < 16:
		errors.append("seat-0 alias salt must contain at least 16 bytes")
	if typeof(salt_one) != TYPE_PACKED_BYTE_ARRAY \
		or (salt_one as PackedByteArray).size() < 16:
		errors.append("seat-1 alias salt must contain at least 16 bytes")
	if typeof(salt_zero) == TYPE_PACKED_BYTE_ARRAY \
		and typeof(salt_one) == TYPE_PACKED_BYTE_ARRAY and salt_zero == salt_one:
		errors.append("observer alias salts must be distinct")
	if not errors.is_empty():
		return errors

	var bootstrap_options := {
		"authoritative_hashes": config_input.get("authoritative_hashes", {}).duplicate(true),
		"faction_id": faction_id,
		"match_seed": int(config_input.get("match_seed", 0)),
		"scored": bool(config_input.get("scored", false)),
	}
	var bootstrap := Bootstrap.create_official(bootstrap_options)
	_append_result_errors(errors, bootstrap, "bootstrap")
	if not bool(bootstrap.get("ok", false)):
		return errors
	var attached := MatchRuntime.attach_protected_authority(bootstrap, tie_key)
	_append_result_errors(errors, attached, "protected authority")
	if not bool(attached.get("ok", false)):
		return errors

	simulation = attached["simulation"]
	runtime_catalog = (bootstrap["runtime"] as Dictionary).duplicate(true)
	map_manifest = (bootstrap["map_manifest"] as Dictionary).duplicate(true)
	bootstrap_registry = (bootstrap["registry"] as Dictionary).duplicate(true)
	_protected_tie_key = (tie_key as PackedByteArray).duplicate()
	_alias_salt_commitments = {
		"0": Codec.sha256_bytes(salt_zero),
		"1": Codec.sha256_bytes(salt_one),
	}
	var perception_errors := perception.configure(match_id, map_manifest, salt_zero, salt_one)
	for message: String in perception_errors:
		errors.append("perception: " + message)
	if not errors.is_empty():
		return errors
	_initialize_neutral_bindings(errors)
	_initialize_seat_runtime()
	if not errors.is_empty():
		return errors
	for message: String in simulation.validate():
		errors.append("simulation: " + message)
	_configured = errors.is_empty()
	return errors


func is_configured() -> bool:
	return _configured


func emit_observation_pair(opportunity_skipped_input: Dictionary = {}) -> Dictionary:
	var errors := PackedStringArray()
	if not _configured:
		errors.append("match session is not configured")
		return _failure(errors)
	if bool(simulation.state.terminal["ended"]):
		errors.append("cannot emit a decision observation after terminal state")
		return _failure(errors)
	if decision_mode == FIXED_MODE and _fixed_active_observation_seq >= 0:
		errors.append("fixed decision opportunity is already outstanding")
		return _failure(errors)
	if decision_mode == CONTINUOUS_MODE \
		and int(simulation.state.tick) % CONTINUOUS_DECISION_PERIOD_TICKS != 0:
		errors.append("continuous observations must use the official 50-tick grid")
		return _failure(errors)
	for key_variant: Variant in opportunity_skipped_input.keys():
		if typeof(key_variant) != TYPE_INT or int(key_variant) not in [0, 1] \
			or typeof(opportunity_skipped_input[key_variant]) != TYPE_BOOL:
			errors.append("opportunity_skipped must map seat integers to booleans")
	if not errors.is_empty():
		return _failure(errors)

	var observation_seq := _next_observation_seq
	var tick := int(simulation.state.tick)
	var seat_rows: Array = []
	for seat: int in [0, 1]:
		seat_rows.append(_seat_snapshot_runtime(
			seat, observation_seq, tick, bool(opportunity_skipped_input.get(seat, false))
		))
	var phase: Dictionary = simulation.neutrals.day_phase(tick)
	var snapshot_context := {
		"controller_registry": _controller_registry(errors),
		"day_phase": "forced_night" if bool(phase["forced"]) else str(phase["phase"]),
		"neutral_registry": SnapshotBuilder.neutral_registry_from_authority(
			simulation, _neutral_building_bindings
		),
		"seat_runtime": seat_rows,
		"world_event_seq_after": _world_event_seq_after,
	}
	if not errors.is_empty():
		return _failure(errors)
	var snapshot := snapshot_builder.build(simulation, snapshot_context)
	_append_result_errors(errors, snapshot, "phase snapshot")
	if not bool(snapshot.get("ok", false)):
		return _failure(errors)
	var projected := perception.phase_12(snapshot["phase_snapshot"])
	_append_result_errors(errors, projected, "perception")
	if not bool(projected.get("ok", false)):
		return _failure(errors)

	var legal_results: Dictionary = {}
	for seat: int in [0, 1]:
		var boundary := {
			"accepted_batch_ids": _sorted_string_keys(_accepted_batch_ids[seat]),
			"neutral_building_bindings": _neutral_building_bindings.duplicate(),
			"received_tick": tick,
			"transport_range_mt": TRANSPORT_RANGE_MT,
		}
		if decision_mode == CONTINUOUS_MODE:
			## The provider sees commands_apply_tick=null. This minimum protected
			## gate exists only so legality can be frozen with the observation;
			## the actual gateway gate is rebound before compilation.
			boundary["application_tick"] = tick + 1
		var observation: Dictionary = projected["observations"][str(seat)]
		var legal := legal_context_builder.build(
			perception, seat, observation, simulation, map_manifest, runtime_catalog,
			boundary, _protected_tie_key
		)
		_append_result_errors(errors, legal, "seat-%d legal context" % seat)
		if bool(legal.get("ok", false)):
			legal_results[seat] = legal
	if not errors.is_empty() or legal_results.size() != 2:
		return _failure(errors)

	var opportunity_id := "opp_%08d" % observation_seq
	_opportunities[observation_seq] = {
		"boundary_tick": tick,
		"legal_results": legal_results,
		"observation_hashes": projected["observation_hashes"].duplicate(true),
		"observations": projected["observations"].duplicate(true),
		"opportunity_id": opportunity_id,
		"seat_status": {
			0: "skipped" if bool(opportunity_skipped_input.get(0, false)) else "open",
			1: "skipped" if bool(opportunity_skipped_input.get(1, false)) else "open",
		},
		"status": "open",
	}
	_next_observation_seq += 1
	_world_event_seq_after = maxi(0, int(simulation.state.next_event_seq) - 1)
	if decision_mode == FIXED_MODE:
		_fixed_active_observation_seq = observation_seq
	_prune_continuous_opportunities()
	return {
		"boundary_tick": tick,
		"byte_counts": projected["byte_counts"].duplicate(true),
		"canonical_json": projected["canonical_json"].duplicate(true),
		"errors": errors,
		"observation_hashes": projected["observation_hashes"].duplicate(true),
		"observation_seq": observation_seq,
		"observations": projected["observations"].duplicate(true),
		"ok": true,
		"opportunity_id": opportunity_id,
	}


func lock_fixed_commits(request_input: Dictionary) -> Dictionary:
	var errors := PackedStringArray()
	if not _configured or decision_mode != FIXED_MODE:
		errors.append("fixed commit lock requires a configured fixed-mode session")
		return _failure(errors)
	_validate_exact_fields(
		request_input,
		["boundary_tick", "commits", "match_id", "observation_seq", "opportunity_id"],
		[], "fixed commit request", errors
	)
	if not _fixed_window.is_empty():
		errors.append("fixed commit window is already locked")
	var opportunity := _opportunity_for_request(request_input, errors)
	var commits_by_seat: Dictionary = {}
	if typeof(request_input.get("commits")) != TYPE_ARRAY \
		or (request_input.get("commits", []) as Array).size() != 2:
		errors.append("fixed commit request must contain exactly two commits")
	else:
		for index: int in (request_input["commits"] as Array).size():
			var row_variant: Variant = request_input["commits"][index]
			if typeof(row_variant) != TYPE_DICTIONARY:
				errors.append("fixed commit row must be an object")
				continue
			var row: Dictionary = row_variant
			_validate_exact_fields(row, ["commit_hash", "player_slot"], [], "commit", errors)
			var seat := int(row.get("player_slot", -1))
			var commit_hash := str(row.get("commit_hash", ""))
			if seat not in [0, 1] or commits_by_seat.has(seat):
				errors.append("fixed commit seats must be unique 0 and 1")
			elif not ActionContract.is_sha256(commit_hash):
				errors.append("fixed commit hash is invalid")
			else:
				commits_by_seat[seat] = commit_hash
	if commits_by_seat.size() != 2:
		errors.append("fixed commits must cover both seats")
	if not errors.is_empty():
		return _failure(errors)
	_fixed_window = {
		"boundary_tick": int(opportunity["boundary_tick"]),
		"commits": commits_by_seat.duplicate(),
		"observation_seq": int(request_input["observation_seq"]),
		"opportunity_id": str(request_input["opportunity_id"]),
	}
	_opportunities[int(request_input["observation_seq"])]["status"] = "commits_locked"
	return {
		"commits": [
			{"commit_hash": str(commits_by_seat[0]), "player_slot": 0},
			{"commit_hash": str(commits_by_seat[1]), "player_slot": 1},
		],
		"errors": errors,
		"ok": true,
		"opportunity_id": str(request_input["opportunity_id"]),
	}


func reveal_fixed_pair(request_input: Dictionary) -> Dictionary:
	var errors := PackedStringArray()
	if not _configured or decision_mode != FIXED_MODE:
		errors.append("fixed reveal requires a configured fixed-mode session")
		return _failure(errors)
	_validate_exact_fields(
		request_input,
		[
			"activation_tick", "boundary_tick", "disposition", "match_id", "observation_seq",
			"opportunity_id", "reveals",
		], [], "fixed reveal request", errors
	)
	if _fixed_window.is_empty():
		errors.append("fixed commits have not been locked")
	var opportunity := _opportunity_for_request(request_input, errors)
	if not _fixed_window.is_empty():
		for field: String in ["boundary_tick", "observation_seq", "opportunity_id"]:
			if _fixed_window.get(field) != request_input.get(field):
				errors.append("fixed reveal does not match the locked %s" % field)
	if int(request_input.get("activation_tick", -1)) \
		!= int(request_input.get("boundary_tick", -2)) + 1:
		errors.append("fixed activation tick must equal boundary tick + 1")
	var reveals_by_seat := _validate_reveals(
		request_input.get("reveals"), _fixed_window.get("commits", {}), errors
	)
	var disposition := str(request_input.get("disposition", ""))
	if disposition not in [
		"continue", "draw_double_technical_forfeit", "technical_forfeit_slot_0",
		"technical_forfeit_slot_1", "void_infrastructure",
	]:
		errors.append("fixed reveal disposition is invalid")
	if not errors.is_empty():
		return _failure(errors)
	var terminal_outcome := _apply_disposition(disposition)
	if disposition != "continue":
		_close_fixed_opportunity(int(request_input["observation_seq"]), "terminal")
		return {
			"errors": errors,
			"ok": true,
			"receipts": [],
			"terminal": terminal_outcome,
		}

	var batches := {0: reveals_by_seat[0]["batch"], 1: reveals_by_seat[1]["batch"]}
	var applied := _apply_batch_group(
		batches, opportunity, int(request_input["activation_tick"]),
		int(request_input["boundary_tick"])
	)
	_append_result_errors(errors, applied, "fixed application")
	if not bool(applied.get("ok", false)):
		return _failure(errors)
	_close_fixed_opportunity(int(request_input["observation_seq"]), "applied")
	return applied


func apply_continuous_gate(request_input: Dictionary) -> Dictionary:
	var errors := PackedStringArray()
	if not _configured or decision_mode != CONTINUOUS_MODE:
		errors.append("continuous gate requires a configured continuous-mode session")
		return _failure(errors)
	_validate_exact_fields(
		request_input, ["application_tick", "applications", "match_id"], [],
		"continuous gate request", errors
	)
	if str(request_input.get("match_id", "")) != match_id:
		errors.append("continuous gate match_id is wrong")
	var application_tick := int(request_input.get("application_tick", -1))
	if application_tick < int(simulation.state.tick) + 1:
		errors.append("continuous application tick must be in the authoritative future")
	var applications_variant: Variant = request_input.get("applications")
	if typeof(applications_variant) != TYPE_ARRAY \
		or (applications_variant as Array).is_empty() \
		or (applications_variant as Array).size() > 2:
		errors.append("continuous gate must contain one or two applications")
	var batches: Dictionary = {}
	var opportunities_by_seat: Dictionary = {}
	if typeof(applications_variant) == TYPE_ARRAY:
		for row_variant: Variant in applications_variant:
			if typeof(row_variant) != TYPE_DICTIONARY:
				errors.append("continuous application row must be an object")
				continue
			var row: Dictionary = row_variant
			_validate_exact_fields(
				row,
				[
					"batch", "observation_seq", "observation_tick", "opportunity_id",
					"player_slot",
				], [], "continuous application", errors
			)
			var seat := int(row.get("player_slot", -1))
			if seat not in [0, 1] or batches.has(seat):
				errors.append("continuous applications must contain unique legal seats")
				continue
			var lookup := {
				"boundary_tick": row.get("observation_tick"),
				"match_id": request_input.get("match_id"),
				"observation_seq": row.get("observation_seq"),
				"opportunity_id": row.get("opportunity_id"),
			}
			var opportunity := _opportunity_for_request(lookup, errors)
			if not opportunity.is_empty():
				if str(opportunity["seat_status"].get(seat, "closed")) != "open":
					errors.append("continuous seat opportunity is already consumed or skipped")
					continue
				batches[seat] = row.get("batch")
				opportunities_by_seat[seat] = opportunity
	if not errors.is_empty():
		return _failure(errors)

	var compiled_by_seat: Dictionary = {}
	var all_intents: Array[Dictionary] = []
	var legal_results: Dictionary = {}
	for seat: int in _sorted_int_keys(batches):
		var opportunity: Dictionary = opportunities_by_seat[seat]
		var stored_legal: Dictionary = opportunity["legal_results"][seat]
		var legal_context := _rebound_legal_context(stored_legal["legal_context"], seat, application_tick)
		var compiled := action_validator.validate_and_compile(batches[seat], legal_context)
		compiled_by_seat[seat] = compiled
		if bool(compiled.get("ok", false)):
			all_intents.append_array(compiled.get("intents", []))
		legal_results[seat] = stored_legal
	var resolver_result := _resolution_context_for_group(legal_results, errors)
	if not errors.is_empty():
		return _failure(errors)
	var execution := intent_bridge.execute(
		simulation, all_intents, resolver_result["resolution_context"],
		{"abilities": simulation.abilities, "neutral_market": simulation.neutrals.market}
	)
	_append_result_errors(errors, execution, "continuous intent execution")
	if not bool(execution.get("ok", false)):
		return _failure(errors)
	var receipts := _finalize_receipts(compiled_by_seat, execution.get("receipts", []))
	_commit_accepted_batches_and_memory(batches, compiled_by_seat, receipts)
	_record_application(
		"continuous_gate", application_tick, batches, compiled_by_seat, execution, receipts
	)
	for seat: int in _sorted_int_keys(opportunities_by_seat):
		opportunities_by_seat[seat]["seat_status"][seat] = "applied"
		if str(opportunities_by_seat[seat]["seat_status"][0]) != "open" \
			and str(opportunities_by_seat[seat]["seat_status"][1]) != "open":
			opportunities_by_seat[seat]["status"] = "closed"
	return {
		"application_tick": application_tick,
		"errors": errors,
		"ok": true,
		"protected_contest_audit": execution["protected_contest_audit"].duplicate(true),
		"receipts": receipts,
	}


func advance_ticks(count: int) -> Dictionary:
	var errors := PackedStringArray()
	if not _configured:
		errors.append("match session is not configured")
	if count < 0:
		errors.append("advance count must be non-negative")
	if decision_mode == FIXED_MODE and _fixed_active_observation_seq >= 0:
		errors.append("fixed simulation cannot advance while a decision is outstanding")
	if not errors.is_empty():
		return _failure(errors)
	var completed: Array = []
	for _index: int in count:
		if bool(simulation.state.terminal["ended"]):
			break
		for message: String in intent_bridge.activate_pending_appends(simulation):
			errors.append("append activation: " + message)
		if not errors.is_empty():
			break
		completed.append(simulation.step_tick(false))
	if errors.is_empty():
		for message: String in simulation.validate():
			errors.append("simulation: " + message)
	_prune_continuous_opportunities()
	return {
		"completed": completed,
		"errors": errors,
		"ok": errors.is_empty(),
		"terminal": simulation.terminal_result(),
		"tick": int(simulation.state.tick),
	}


func advance_to_next_decision_boundary() -> Dictionary:
	if not _configured:
		return _failure(PackedStringArray(["match session is not configured"]))
	var period := (
		FIXED_DECISION_PERIOD_TICKS
		if decision_mode == FIXED_MODE else CONTINUOUS_DECISION_PERIOD_TICKS
	)
	var remainder := int(simulation.state.tick) % period
	var count := period if remainder == 0 else period - remainder
	return advance_ticks(count)


func declare_gateway_disposition(disposition: String) -> Dictionary:
	var allowed := [
		"draw_double_technical_forfeit", "technical_forfeit_slot_0",
		"technical_forfeit_slot_1", "void_infrastructure",
	]
	if not _configured or disposition not in allowed:
		return _failure(PackedStringArray(["gateway disposition is invalid for this session"]))
	return {"errors": PackedStringArray(), "ok": true, "terminal": _apply_disposition(disposition)}


func to_protected_canonical_dict() -> Dictionary:
	var seats: Array = []
	for seat: int in [0, 1]:
		var state: Dictionary = _seat_runtime.get(seat, {})
		seats.append({
			"accepted_batch_ids": _sorted_string_keys(_accepted_batch_ids.get(seat, {})),
			"last_action_receipt": _deep_copy(state.get("last_action_receipt")),
			"seat": seat,
			"working_memory": str(state.get("working_memory", "")),
		})
	var knowledge: Array = []
	if perception.is_configured():
		for seat: int in [0, 1]:
			var value: Variant = perception.knowledge_state_for_checkpoint(seat)
			knowledge.append(value.to_protected_canonical_dict())
	var fixed_lock: Variant = null
	if not _fixed_window.is_empty():
		fixed_lock = {
			"boundary_tick": int(_fixed_window["boundary_tick"]),
			"commits": {
				"0": str(_fixed_window["commits"][0]),
				"1": str(_fixed_window["commits"][1]),
			},
			"observation_seq": int(_fixed_window["observation_seq"]),
			"opportunity_id": str(_fixed_window["opportunity_id"]),
		}
	return {
		"alias_salt_commitments": _alias_salt_commitments.duplicate(true),
		"application_transcript": _application_transcript.duplicate(true),
		"controller": intent_bridge.to_canonical_dict(),
		"decision_mode": decision_mode,
		"faction_id": faction_id,
		"fixed_lock": fixed_lock,
		"knowledge": knowledge,
		"match_id": match_id,
		"neutral_building_bindings": _sorted_dictionary(_neutral_building_bindings),
		"next_observation_seq": _next_observation_seq,
		"seat_runtime": seats,
		"simulation": simulation.snapshot() if simulation != null else {},
		"tie_key_commitment": Codec.sha256_bytes(_protected_tie_key),
		"world_event_seq_after": _world_event_seq_after,
	}


func checkpoint_hash() -> String:
	return Codec.sha256_canonical(to_protected_canonical_dict())


func latest_application_record() -> Dictionary:
	## Authority-only accessor used by the authenticated Gateway host to publish the
	## replay-safe projection of the application that just committed.  The host
	## deliberately strips protected contest audit material before encoding it.
	if _application_transcript.is_empty():
		return {}
	return _application_transcript[-1].duplicate(true)


func protected_status() -> Dictionary:
	## Trusted runner/gateway diagnostics only. The omniscient checkpoint hash
	## must never be included in a provider observation or prompt.
	return {
		"checkpoint_hash": checkpoint_hash(),
		"decision_mode": decision_mode,
		"faction_id": faction_id,
		"match_id": match_id,
		"next_observation_seq": _next_observation_seq,
		"terminal": simulation.terminal_result() if simulation != null else {},
		"tick": int(simulation.state.tick) if simulation != null else 0,
	}


static func action_batch_commit_hash(batch: Dictionary, salt_hex: String) -> String:
	if salt_hex.length() != 64 or salt_hex.to_lower() != salt_hex:
		return ""
	var salt := salt_hex.hex_decode()
	if salt.size() != 32 or salt.hex_encode() != salt_hex:
		return ""
	if not Codec.validate_canonical_value(batch, "$.batch").is_empty():
		return ""
	var payload := COMMIT_DOMAIN.to_utf8_buffer()
	payload.append_array(Codec.canonical_bytes(batch))
	payload.append(0)
	payload.append_array(salt)
	return Codec.sha256_bytes(payload)


func _apply_batch_group(
	batches: Dictionary,
	opportunity: Dictionary,
	application_tick: int,
	received_tick: int
) -> Dictionary:
	var errors := PackedStringArray()
	var compiled_by_seat: Dictionary = {}
	var all_intents: Array[Dictionary] = []
	var legal_results: Dictionary = opportunity["legal_results"]
	for seat: int in [0, 1]:
		var legal_context := _rebound_legal_context(
			legal_results[seat]["legal_context"], seat, application_tick, received_tick
		)
		var compiled := action_validator.validate_and_compile(batches[seat], legal_context)
		compiled_by_seat[seat] = compiled
		if bool(compiled.get("ok", false)):
			all_intents.append_array(compiled.get("intents", []))
	var combined := legal_context_builder.build_combined_resolution_context(
		legal_results[0], legal_results[1], _protected_tie_key
	)
	_append_result_errors(errors, combined, "combined resolution context")
	if not bool(combined.get("ok", false)):
		return _failure(errors)
	var execution := intent_bridge.execute(
		simulation, all_intents, combined["resolution_context"],
		{"abilities": simulation.abilities, "neutral_market": simulation.neutrals.market}
	)
	_append_result_errors(errors, execution, "intent execution")
	if not bool(execution.get("ok", false)):
		return _failure(errors)
	var receipts := _finalize_receipts(compiled_by_seat, execution.get("receipts", []))
	_commit_accepted_batches_and_memory(batches, compiled_by_seat, receipts)
	_record_application(
		"fixed_pair", application_tick, batches, compiled_by_seat, execution, receipts
	)
	return {
		"application_tick": application_tick,
		"errors": errors,
		"ok": true,
		"protected_contest_audit": execution["protected_contest_audit"].duplicate(true),
		"receipts": receipts,
	}


func _resolution_context_for_group(
	legal_results_by_seat: Dictionary, errors: PackedStringArray
) -> Dictionary:
	var seats := _sorted_int_keys(legal_results_by_seat)
	if seats.size() == 1:
		return {
			"ok": true,
			"resolution_context": legal_results_by_seat[seats[0]]["resolution_context"],
		}
	if seats == [0, 1]:
		var combined := legal_context_builder.build_combined_resolution_context(
			legal_results_by_seat[0], legal_results_by_seat[1], _protected_tie_key
		)
		_append_result_errors(errors, combined, "combined resolution context")
		return combined
	errors.append("application group has an invalid seat set")
	return {}


func _rebound_legal_context(
	stored_input: Dictionary,
	seat: int,
	application_tick: int,
	received_tick: int = -1
) -> Dictionary:
	var value := stored_input.duplicate(true)
	value["accepted_batch_ids"] = _sorted_string_keys(_accepted_batch_ids[seat])
	value["application_tick"] = application_tick
	value["received_tick"] = (
		int(simulation.state.tick) if received_tick < 0 else received_tick
	)
	return value


func _finalize_receipts(compiled_by_seat: Dictionary, atomic_input: Array) -> Dictionary:
	var result: Dictionary = {}
	for seat: int in _sorted_int_keys(compiled_by_seat):
		var compiled: Dictionary = compiled_by_seat[seat]
		var receipt: Dictionary = (compiled["receipt"] as Dictionary).duplicate(true)
		if not bool(compiled.get("ok", false)):
			result[str(seat)] = receipt
			continue
		var batch: Dictionary = {}
		for command_variant: Variant in receipt["commands"]:
			var command: Dictionary = command_variant
			if str(command["status"]) == "rejected":
				continue
			var intent_refs: Dictionary = {}
			for intent_variant: Variant in compiled.get("intents", []):
				var intent: Dictionary = intent_variant
				if str(intent["source"]["command_id"]) == str(command["command_id"]):
					intent_refs[_compiled_intent_public_ref(intent)] = true
			var outcomes: Array = []
			for atomic_variant: Variant in atomic_input:
				var atomic: Dictionary = atomic_variant
				if intent_refs.has(str(atomic["intent_ref"])):
					outcomes.append(atomic)
			var applied_count := 0
			var first_code: Variant = null
			for outcome_variant: Variant in outcomes:
				var outcome: Dictionary = outcome_variant
				if str(outcome["status"]) == "applied":
					applied_count += 1
				elif first_code == null:
					first_code = outcome["code"]
			if not outcomes.is_empty():
				if applied_count == outcomes.size():
					command["status"] = "applied"
					command["code"] = null
				elif applied_count == 0:
					command["status"] = "rejected"
					command["code"] = first_code
				else:
					command["status"] = "partially_applied"
					command["code"] = first_code
				if command.has("requested_quantity"):
					command["accepted_quantity"] = applied_count
			batch[str(command["command_id"])] = command
		var ordered: Array = []
		for original_variant: Variant in receipt["commands"]:
			var original: Dictionary = original_variant
			ordered.append(batch.get(str(original["command_id"]), original))
		receipt["commands"] = ordered
		receipt["batch_status"] = _batch_status(ordered)
		result[str(seat)] = receipt
	return result


func _commit_accepted_batches_and_memory(
	batches: Dictionary, compiled_by_seat: Dictionary, receipts: Dictionary
) -> void:
	for seat: int in _sorted_int_keys(batches):
		var batch_variant: Variant = batches[seat]
		var compiled: Dictionary = compiled_by_seat[seat]
		if typeof(batch_variant) != TYPE_DICTIONARY or not bool(compiled.get("ok", false)):
			_seat_runtime[seat]["last_action_receipt"] = receipts[str(seat)].duplicate(true)
			continue
		var batch: Dictionary = batch_variant
		_accepted_batch_ids[seat][str(batch["client_batch_id"])] = true
		if batch.has("working_memory"):
			_seat_runtime[seat]["working_memory"] = str(batch["working_memory"])
		_seat_runtime[seat]["last_action_receipt"] = receipts[str(seat)].duplicate(true)


func _record_application(
	kind: String,
	application_tick: int,
	batches: Dictionary,
	compiled_by_seat: Dictionary,
	execution: Dictionary,
	receipts: Dictionary
) -> void:
	var batch_rows: Array = []
	for seat: int in _sorted_int_keys(batches):
		var batch_variant: Variant = batches[seat]
		batch_rows.append({
			"batch_digest": str(compiled_by_seat[seat].get("batch_digest", "")),
			"batch_id": (
				str((batch_variant as Dictionary).get("client_batch_id", "invalid"))
				if typeof(batch_variant) == TYPE_DICTIONARY else "invalid"
			),
			"compiled_intents": applied_compiled_intents_for_replay(
				compiled_by_seat[seat].get("intents", []), execution.get("receipts", [])
			),
			"player_seat": seat,
			"receipt": receipts[str(seat)].duplicate(true),
		})
	_application_transcript.append({
		"application_tick": application_tick,
		"batches": batch_rows,
		"kind": kind,
		"protected_contest_audit_hash": Codec.sha256_canonical(
			execution.get("protected_contest_audit", [])
		),
	})


static func applied_compiled_intents_for_replay(
	intents_input: Variant, execution_receipts_input: Variant
) -> Array:
	## Public replay contains only primitive orders that crossed the atomic
	## execution boundary.  Command-level partial status is insufficient because
	## one expanded intent may win while another loses; intent_ref is the exact
	## canonical join key shared by the compiler and execution bridge.
	if typeof(intents_input) != TYPE_ARRAY or typeof(execution_receipts_input) != TYPE_ARRAY:
		return []
	var applied_refs: Dictionary = {}
	for receipt_variant: Variant in (execution_receipts_input as Array):
		if typeof(receipt_variant) != TYPE_DICTIONARY:
			continue
		var receipt: Dictionary = receipt_variant
		if str(receipt.get("status", "")) == "applied" \
			and ObservationContract.is_public_id(receipt.get("intent_ref")):
			applied_refs[str(receipt["intent_ref"])] = true
	var result: Array = []
	for intent_variant: Variant in (intents_input as Array):
		if typeof(intent_variant) != TYPE_DICTIONARY:
			continue
		var intent: Dictionary = intent_variant
		if applied_refs.has(_compiled_intent_public_ref(intent)):
			result.append(intent.duplicate(true))
	return result


func _seat_snapshot_runtime(
	seat: int, observation_seq: int, tick: int, opportunity_skipped: bool
) -> Dictionary:
	var decision := {
		"commands_apply_tick": tick + 1 if decision_mode == FIXED_MODE else null,
		"mode": decision_mode,
		"observation_tick": tick,
		"response_deadline_ms": (
			FIXED_DEADLINE_MS if decision_mode == FIXED_MODE else CONTINUOUS_DEADLINE_MS
		),
		"valid_until_tick": (
			tick + 1 if decision_mode == FIXED_MODE else tick + CONTINUOUS_VALIDITY_TICKS
		),
	}
	if opportunity_skipped:
		decision["opportunity_skipped"] = true
	return {
		"decision": decision,
		"include_brief": true,
		"last_action_receipt": _deep_copy(_seat_runtime[seat]["last_action_receipt"]),
		"observation_seq": observation_seq,
		"seat": seat,
		"working_memory": str(_seat_runtime[seat]["working_memory"]),
	}


func _controller_registry(errors: PackedStringArray) -> Dictionary:
	var source: Dictionary = intent_bridge.to_canonical_dict()
	var alias_to_internal: Dictionary = {}
	var aliases_by_internal: Dictionary = {}
	for seat: int in [0, 1]:
		var knowledge: Variant = perception.knowledge_state_for_checkpoint(seat)
		if knowledge == null:
			continue
		var protected: Dictionary = knowledge.to_protected_canonical_dict()
		for row_variant: Variant in protected["aliases"]["entries"]:
			var row: Dictionary = row_variant
			var alias := str(row["alias"])
			var internal_id := int(row["internal_id"])
			alias_to_internal[alias] = internal_id
			if not aliases_by_internal.has(internal_id):
				aliases_by_internal[internal_id] = []
			(aliases_by_internal[internal_id] as Array).append(alias)
	var canonical_alias_by_internal: Dictionary = {}
	for internal_variant: Variant in aliases_by_internal.keys():
		var internal_id := int(internal_variant)
		var aliases: Array = aliases_by_internal[internal_id]
		aliases.sort()
		var chosen := str(aliases[0])
		if simulation.state.entities.has(internal_id):
			var owner := int(simulation.state.entities[internal_id].owner_seat)
			if owner in [0, 1]:
				var owner_knowledge: Variant = perception.knowledge_state_for_checkpoint(owner)
				var owner_alias := str(owner_knowledge.alias_if_known(internal_id))
				if not owner_alias.is_empty():
					chosen = owner_alias
		canonical_alias_by_internal[internal_id] = chosen
	var remap: Dictionary = {}
	for alias_variant: Variant in alias_to_internal.keys():
		remap[str(alias_variant)] = str(canonical_alias_by_internal[alias_to_internal[alias_variant]])
	var state := _remap_controller_state(source, remap)
	var bindings: Dictionary = {}
	var referenced := _controller_referenced_aliases(state)
	for alias_variant: Variant in referenced.keys():
		var alias := str(alias_variant)
		if not alias_to_internal.has(alias):
			## The remapped alias may be the selected value rather than a source key.
			var found := 0
			for internal_variant: Variant in canonical_alias_by_internal.keys():
				if str(canonical_alias_by_internal[internal_variant]) == alias:
					found = int(internal_variant)
					break
			if found <= 0:
				errors.append("controller state references an unknown observer alias")
				continue
			bindings[alias] = found
		else:
			bindings[alias] = int(alias_to_internal[alias])
	return {"entity_bindings": bindings, "state": state}


func _remap_controller_state(source: Dictionary, remap: Dictionary) -> Dictionary:
	var result: Dictionary = SnapshotBuilder.empty_controller_registry()["state"]
	for field: String in [
		"autocast_by_actor", "rally_by_producer", "tactics_by_actor", "transport_manifests",
	]:
		for alias_variant: Variant in (source.get(field, {}) as Dictionary).keys():
			var alias := str(remap.get(str(alias_variant), str(alias_variant)))
			result[field][alias] = _remap_entity_aliases(source[field][alias_variant], remap)
	for squad_variant: Variant in (source.get("squads", {}) as Dictionary).keys():
		var squad: Dictionary = source["squads"][squad_variant]
		var members: Array = []
		for member_variant: Variant in squad["member_ids"]:
			members.append(str(remap.get(str(member_variant), str(member_variant))))
		members.sort()
		result["squads"][str(squad_variant)] = {
			"member_ids": members,
			"owner_seat": int(squad["owner_seat"]),
			"tactics": _remap_entity_aliases(squad.get("tactics", {}), remap),
		}
	for row_variant: Variant in source.get("pending_append_order_ids", []):
		var row: Dictionary = row_variant
		result["pending_append_order_ids"].append({
			"pending_count": int(row["pending_count"]),
			"public_id": str(remap.get(str(row["public_id"]), str(row["public_id"]))),
		})
	return result


func _remap_entity_aliases(value: Variant, remap: Dictionary, parent_key: String = "") -> Variant:
	if typeof(value) == TYPE_DICTIONARY:
		var result: Dictionary = {}
		var keys: Array = (value as Dictionary).keys()
		keys.sort()
		for key_variant: Variant in keys:
			var key := str(key_variant)
			var next_key := str(remap.get(key, key)) if parent_key == "entity_key_map" else key
			result[next_key] = _remap_entity_aliases(value[key_variant], remap, key)
		return result
	if typeof(value) == TYPE_ARRAY:
		var result: Array = []
		for child: Variant in value:
			result.append(_remap_entity_aliases(child, remap, parent_key))
		return result
	if typeof(value) == TYPE_STRING and (
		parent_key in [
			"entity_id", "producer_id", "public_id", "subject", "transport_id",
		]
		or remap.has(str(value))
	):
		return str(remap.get(str(value), str(value)))
	return value


func _controller_referenced_aliases(state: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for field: String in [
		"autocast_by_actor", "rally_by_producer", "tactics_by_actor", "transport_manifests",
	]:
		for alias_variant: Variant in state[field].keys():
			result[str(alias_variant)] = true
		_collect_entity_alias_values(state[field], result)
	for squad_variant: Variant in state["squads"].values():
		var squad: Dictionary = squad_variant
		for alias_variant: Variant in squad["member_ids"]:
			result[str(alias_variant)] = true
		_collect_entity_alias_values(squad["tactics"], result)
	for row_variant: Variant in state["pending_append_order_ids"]:
		result[str(row_variant["public_id"])] = true
	return result


func _collect_entity_alias_values(value: Variant, result: Dictionary) -> void:
	if typeof(value) == TYPE_DICTIONARY:
		for key_variant: Variant in (value as Dictionary).keys():
			_collect_entity_alias_values(value[key_variant], result)
	elif typeof(value) == TYPE_ARRAY:
		for child: Variant in value:
			_collect_entity_alias_values(child, result)
	elif typeof(value) == TYPE_STRING and ActionContract.is_entity_id(value):
		result[str(value)] = true


func _validate_reveals(
	reveals_variant: Variant, commits_variant: Variant, errors: PackedStringArray
) -> Dictionary:
	var result: Dictionary = {}
	if typeof(reveals_variant) != TYPE_ARRAY or (reveals_variant as Array).size() != 2:
		errors.append("fixed reveal must contain exactly two rows")
		return result
	var commits: Dictionary = commits_variant if typeof(commits_variant) == TYPE_DICTIONARY else {}
	for row_variant: Variant in reveals_variant:
		if typeof(row_variant) != TYPE_DICTIONARY:
			errors.append("fixed reveal row must be an object")
			continue
		var row: Dictionary = row_variant
		_validate_exact_fields(row, ["batch", "player_slot", "salt_hex"], [], "reveal", errors)
		var seat := int(row.get("player_slot", -1))
		if seat not in [0, 1] or result.has(seat):
			errors.append("fixed reveals must contain unique seats 0 and 1")
			continue
		if typeof(row.get("batch")) != TYPE_DICTIONARY:
			errors.append("fixed reveal batch must be an object")
			continue
		var actual := action_batch_commit_hash(row["batch"], str(row.get("salt_hex", "")))
		if actual.is_empty() or actual != str(commits.get(seat, "")):
			errors.append("fixed reveal does not match its locked commit")
			continue
		result[seat] = row.duplicate(true)
	if result.size() != 2:
		errors.append("fixed reveals must cover both seats")
	return result


func _opportunity_for_request(request: Dictionary, errors: PackedStringArray) -> Dictionary:
	if str(request.get("match_id", "")) != match_id:
		errors.append("request match_id is wrong")
	var seq := int(request.get("observation_seq", -1))
	if not _opportunities.has(seq):
		errors.append("request observation opportunity is unknown or expired")
		return {}
	var opportunity: Dictionary = _opportunities[seq]
	if str(request.get("opportunity_id", "")) != str(opportunity["opportunity_id"]):
		errors.append("request opportunity_id is wrong")
	if int(request.get("boundary_tick", -1)) != int(opportunity["boundary_tick"]):
		errors.append("request boundary_tick is wrong")
	return opportunity


func _apply_disposition(disposition: String) -> Dictionary:
	var losing_seats: Array[int] = []
	match disposition:
		"technical_forfeit_slot_0":
			losing_seats = [0]
		"technical_forfeit_slot_1":
			losing_seats = [1]
		"draw_double_technical_forfeit":
			losing_seats = [0, 1]
		"void_infrastructure":
			simulation.declare_infrastructure_void("gateway_infrastructure_failure")
	if not losing_seats.is_empty():
		simulation.declare_technical_forfeit(losing_seats)
	return simulation.terminal_result()


func _close_fixed_opportunity(observation_seq: int, status: String) -> void:
	if _opportunities.has(observation_seq):
		_opportunities[observation_seq]["status"] = status
		_opportunities[observation_seq]["seat_status"] = {0: status, 1: status}
	_fixed_window.clear()
	_fixed_active_observation_seq = -1


func _initialize_neutral_bindings(errors: PackedStringArray) -> void:
	_neutral_building_bindings.clear()
	var next_virtual_id := NEUTRAL_BINDING_BASE
	for building_id: String in simulation.state.neutrals.sorted_building_ids():
		if next_virtual_id > Codec.MAX_SAFE_INTEGER:
			errors.append("neutral virtual ID range exhausted")
			return
		_neutral_building_bindings[building_id] = next_virtual_id
		next_virtual_id += 1


func _initialize_seat_runtime() -> void:
	_seat_runtime = {
		0: {"last_action_receipt": null, "working_memory": ""},
		1: {"last_action_receipt": null, "working_memory": ""},
	}
	_accepted_batch_ids = {0: {}, 1: {}}


func _prune_continuous_opportunities() -> void:
	if decision_mode != CONTINUOUS_MODE:
		return
	var current_tick := int(simulation.state.tick)
	var seqs: Array = _opportunities.keys()
	seqs.sort()
	for seq_variant: Variant in seqs:
		var opportunity: Dictionary = _opportunities[seq_variant]
		if int(opportunity["boundary_tick"]) + CONTINUOUS_VALIDITY_TICKS < current_tick:
			_opportunities.erase(seq_variant)


static func _compiled_intent_public_ref(intent: Dictionary) -> String:
	var source: Dictionary = intent["source"]
	var seed := {
		"batch_id": str(source["batch_id"]),
		"command_id": str(source["command_id"]),
		"expansion_index": int(source["expansion_index"]),
		"operation": str(intent["operation"]),
	}
	return "intent.%s" % Codec.sha256_canonical(seed).substr(0, 20)


static func _batch_status(commands: Array) -> String:
	if commands.is_empty():
		return "no_op"
	var applied := 0
	var rejected := 0
	for command_variant: Variant in commands:
		match str(command_variant["status"]):
			"applied":
				applied += 1
			"partially_applied":
				applied += 1
				rejected += 1
			_:
				rejected += 1
	if applied > 0 and rejected > 0:
		return "partially_applied"
	return "applied" if applied > 0 else "rejected"


static func _validate_exact_fields(
	value: Variant,
	required: Array[String],
	optional: Array[String],
	label: String,
	errors: PackedStringArray
) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append(label + " must be an object")
		return
	var allowed: Dictionary = {}
	for field: String in required:
		allowed[field] = true
		if not (value as Dictionary).has(field):
			errors.append(label + " is missing " + field)
	for field: String in optional:
		allowed[field] = true
	for key_variant: Variant in (value as Dictionary).keys():
		if typeof(key_variant) != TYPE_STRING or not allowed.has(str(key_variant)):
			errors.append(label + " has unknown field " + str(key_variant))


static func _append_result_errors(
	errors: PackedStringArray, result: Dictionary, label: String
) -> void:
	for message_variant: Variant in result.get("errors", []):
		errors.append("%s: %s" % [label, str(message_variant)])


static func _sorted_string_keys(value: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for key_variant: Variant in value.keys():
		result.append(str(key_variant))
	result.sort()
	return result


static func _sorted_int_keys(value: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for key_variant: Variant in value.keys():
		result.append(int(key_variant))
	result.sort()
	return result


static func _sorted_dictionary(value: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var keys: Array = value.keys()
	keys.sort()
	for key_variant: Variant in keys:
		result[str(key_variant)] = value[key_variant]
	return result


static func _deep_copy(value: Variant) -> Variant:
	return value.duplicate(true) if typeof(value) in [TYPE_ARRAY, TYPE_DICTIONARY] else value


static func _failure(errors: PackedStringArray) -> Dictionary:
	return {"errors": errors, "ok": false}
