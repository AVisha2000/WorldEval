class_name DuelGatewaySessionHost
extends RefCounted

const FrameCodec := preload("res://scripts/duel/protocol/duel_gateway_frame_codec.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const Session := preload("res://scripts/duel/match/duel_match_session.gd")
const ObservationContract := preload("res://scripts/duel/observations/duel_observation_contract.gd")

## Godot-side authority boundary for the Python LLM scheduler. Provider calls,
## deadlines, and raw model bytes remain in Python. This host verifies the
## authenticated scheduler decisions, strips protected timing metadata, and is
## the only bridge allowed to submit the resulting action batches to a Duel
## match session.

const ENGINE_VERSION := "4.5.stable.official.876b29033"
const CHECKPOINT_PERIOD_TICKS := 300
const MAX_EVIDENCE_BODY_BYTES := FrameCodec.MAX_FRAME_BYTES - 4_096

const PHASE_UNCONFIGURED := "unconfigured"
const PHASE_READY := "ready"
const PHASE_AWAITING_AUTH := "awaiting_auth"
const PHASE_AWAITING_CONFIG := "awaiting_config"
const PHASE_RUNNING := "running"
const PHASE_TERMINAL := "terminal"
const PHASE_COMPLETE := "complete"
const PHASE_FAILED := "failed"

const LAUNCH_FIELDS: Array[String] = [
	"alias_salt_seat_0",
	"alias_salt_seat_1",
	"authoritative_hashes",
	"scored",
	"tie_key",
]
const CONFIG_FIELDS: Array[String] = [
	"cadence_profile_id",
	"control_profile",
	"decision_mode",
	"decision_period_ticks",
	"faction_preset_id",
	"map_id",
	"maximum_match_ticks",
	"memory_policy",
	"mirror_faction",
	"observation_profile",
	"players",
	"protocol_version",
	"response_deadline_ms",
	"ruleset_id",
	"seed",
	"simulation_hz",
	"spectator",
]
const TIMING_FIELDS: Array[String] = [
	"application_gate_monotonic_ns",
	"application_tick",
	"completion_monotonic_ns",
	"deadline_monotonic_ns",
	"dispatch_monotonic_ns",
	"first_token_monotonic_ns",
	"parse_completed_monotonic_ns",
	"parse_started_monotonic_ns",
	"ready_monotonic_ns",
]
const PUBLIC_EVENT_PAYLOAD_KEYS: Array[String] = [
	"ability_id", "amount", "batch_id", "code", "command_id", "compiled_order_id",
	"damage", "day_phase", "details", "healing", "item_id", "level", "offer_id",
	"position_mt", "progress_bp", "queue_entry_id", "region_id", "resource", "site_id",
	"status_id", "terminal_reason", "tier", "type_id", "upgrade_id", "winner", "xp",
]
const PUBLIC_EVENT_ID_FIELDS: Array[String] = [
	"ability_id", "batch_id", "command_id", "compiled_order_id", "item_id", "offer_id",
	"queue_entry_id", "region_id", "site_id", "status_id", "type_id", "upgrade_id",
]
const PUBLIC_EVENT_KINDS: Array[String] = [
	"entity_created", "entity_entered_vision", "entity_left_vision", "entity_reacquired",
	"entity_transformed", "entity_destroyed", "attack_observed", "damage_observed",
	"healing_observed", "cast_observed", "status_started", "status_ended", "item_picked_up",
	"item_dropped", "resource_deposited", "resource_spent", "resource_refunded",
	"upkeep_changed", "order_started", "order_completed", "order_cancelled", "order_paused",
	"order_failed", "construction_progress", "construction_completed", "repair_progress",
	"production_progress", "production_completed", "research_progress", "research_completed",
	"tier_completed", "revival_progress", "revival_completed", "hero_xp_gained",
	"hero_level_gained", "hero_skill_learned", "creep_camp_cleared", "camp_item_revealed",
	"shop_restocked", "shop_purchase", "day_phase_changed", "resource_depleted",
	"terrain_changed", "pathing_changed", "batch_timeout", "batch_schema_failed",
	"command_applied", "command_rejected", "terminal_win", "terminal_loss", "terminal_draw",
	"terminal_forfeit", "terminal_infrastructure_void",
]
const PRIVATE_REPLAY_KEY_MARKERS: Array[String] = [
	"api_key", "authorization", "credential", "hidden_reasoning", "prompt", "raw_output",
	"raw_response", "scratchpad", "secret", "token", "validation_trace", "working_memory",
]

var session: Variant = null

var _codec := FrameCodec.new()
var _phase: String = PHASE_UNCONFIGURED
var _match_id: String = ""
var _connection_id: String = ""
var _decision_mode: String = ""
var _launch: Dictionary = {}
var _public_match_settings: Dictionary = {}
var _config_hash: String = ""
var _gateway_boundary_hash: String = ""
var _known_observation_hashes: Dictionary = {}
var _protected_timing_transcript: Array[Dictionary] = []
var _protected_thinking_transcript: Array[Dictionary] = []
var _checkpoint_transcript: Array[Dictionary] = []
var _terminal_emitted: bool = false
var _gateway_disposition_record: Dictionary = {}
var _continuous_clock_started: bool = false
var _latest_observation_seq: int = -1
var _latest_observation_tick: int = -1
var _next_application_seq: int = 0
var _next_replay_event_seq: int = 1
var _pending_application_checkpoint_ticks: Dictionary = {}
var _world_event_cursor: int = 0
var _issued_authority_boundaries: Dictionary = {}
var _issued_authority_boundary_order: Array[String] = []


func configure(
	match_id_input: String,
	token: PackedByteArray,
	connection_id_input: String,
	protected_launch: Dictionary
) -> PackedStringArray:
	var errors := PackedStringArray()
	if _phase != PHASE_UNCONFIGURED:
		errors.append("gateway session host is already configured")
		return errors
	if not ObservationContract.is_match_id(match_id_input):
		errors.append("gateway session match_id is invalid")
	if connection_id_input.is_empty() or connection_id_input.length() > 128:
		errors.append("gateway connection_id must contain 1 to 128 characters")
	_validate_exact_fields(protected_launch, LAUNCH_FIELDS, "protected launch", errors)
	if typeof(protected_launch.get("authoritative_hashes")) != TYPE_DICTIONARY:
		errors.append("protected launch authoritative_hashes must be an object")
	elif not Codec.validate_canonical_value(
		protected_launch["authoritative_hashes"], "$.authoritative_hashes"
	).is_empty():
		errors.append("protected launch authoritative_hashes are not canonical")
	if typeof(protected_launch.get("scored")) != TYPE_BOOL:
		errors.append("protected launch scored must be boolean")
	for key: String in ["alias_salt_seat_0", "alias_salt_seat_1"]:
		if typeof(protected_launch.get(key)) != TYPE_PACKED_BYTE_ARRAY \
			or (protected_launch.get(key) as PackedByteArray).size() < 16:
			errors.append("%s must contain at least 16 protected bytes" % key)
	if typeof(protected_launch.get("tie_key")) != TYPE_PACKED_BYTE_ARRAY \
		or (protected_launch.get("tie_key") as PackedByteArray).is_empty():
		errors.append("protected launch tie_key must be non-empty bytes")
	if typeof(protected_launch.get("alias_salt_seat_0")) == TYPE_PACKED_BYTE_ARRAY \
		and typeof(protected_launch.get("alias_salt_seat_1")) == TYPE_PACKED_BYTE_ARRAY \
		and protected_launch["alias_salt_seat_0"] == protected_launch["alias_salt_seat_1"]:
		errors.append("protected observer alias salts must be distinct")
	if not errors.is_empty():
		return errors
	var codec_errors := _codec.configure(match_id_input, token, "godot")
	for message: String in codec_errors:
		errors.append("frame codec: " + message)
	if not errors.is_empty():
		return errors
	_match_id = match_id_input
	_connection_id = connection_id_input
	_launch = protected_launch.duplicate(true)
	_next_application_seq = 0
	_next_replay_event_seq = 1
	_pending_application_checkpoint_ticks.clear()
	_world_event_cursor = 0
	_issued_authority_boundaries.clear()
	_issued_authority_boundary_order.clear()
	_phase = PHASE_READY
	return errors


func begin_handshake() -> Dictionary:
	if _phase != PHASE_READY:
		return _fail("bridge_phase_invalid", "gateway handshake can only begin once")
	var encoded := _codec.encode("hello", FrameCodec.SESSION_BOUNDARY_HASH, {
		"connection_id": _connection_id,
		"engine_version": ENGINE_VERSION,
		"headless": true,
	})
	if not bool(encoded.get("ok", false)):
		return _fail_from_result(encoded, "hello encoding failed")
	_phase = PHASE_AWAITING_AUTH
	return _outbound_success([encoded["payload"]], [{"kind": "hello_sent"}])


func receive(payload: PackedByteArray) -> Dictionary:
	if _phase in [PHASE_UNCONFIGURED, PHASE_READY, PHASE_FAILED, PHASE_COMPLETE]:
		return _fail("bridge_phase_invalid", "gateway frame is invalid in the current host phase")
	var decoded := _codec.decode(payload)
	if not bool(decoded.get("ok", false)):
		return _fail_from_result(decoded, "gateway frame decode failed")
	var frame: Dictionary = decoded["frame"]
	match str(frame["message_type"]):
		"auth":
			return _accept_auth(frame)
		"match_config":
			return _accept_match_config(frame)
		"thinking_status":
			return _accept_thinking_status(frame)
		"batch_commit_hashes":
			return _accept_fixed_commits(frame)
		"batch_reveal":
			return _accept_fixed_reveal(frame)
		"action":
			return _accept_continuous_action(frame)
		"continuous_start":
			return _accept_continuous_start(frame)
		"gateway_disposition":
			return _accept_gateway_disposition(frame)
		"artifact_ready":
			return _accept_artifact_ready(frame)
	return _fail("unexpected_message", "gateway message is invalid for the host state")


func emit_match_init(payload: Dictionary, protocol_hash: String) -> Dictionary:
	if _phase != PHASE_RUNNING:
		return _fail("bridge_phase_invalid", "MATCH_INIT requires a running host")
	var errors := PackedStringArray()
	if str(payload.get("message_type", "")) != "match_init":
		errors.append("MATCH_INIT message_type is invalid")
	if str(payload.get("protocol_version", "")) != FrameCodec.PROTOCOL_VERSION:
		errors.append("MATCH_INIT protocol_version is invalid")
	if str(payload.get("match_id", "")) != _match_id:
		errors.append("MATCH_INIT match_id is wrong")
	if not ObservationContract.is_sha256(protocol_hash):
		errors.append("MATCH_INIT protocol boundary hash is invalid")
	var canonical_errors := Codec.validate_canonical_value(payload, "$.match_init")
	if not canonical_errors.is_empty():
		var safe_details := PackedStringArray()
		for index: int in mini(canonical_errors.size(), 16):
			## Canonical validation emits only structural JSON paths and static type diagnostics.
			safe_details.append(str(canonical_errors[index]).left(256))
		if canonical_errors.size() > safe_details.size():
			safe_details.append("... %d additional canonical diagnostics" % (
				canonical_errors.size() - safe_details.size()
			))
		errors.append("MATCH_INIT payload is not canonical: " + "; ".join(safe_details))
	if not errors.is_empty():
		return _fail("match_init_invalid", "; ".join(errors))
	return _encode_host_event("match_init", protocol_hash, payload, "match_init_emitted")


func emit_observation_pair(opportunity_skipped: Dictionary = {}) -> Dictionary:
	if _phase != PHASE_RUNNING:
		return _fail("bridge_phase_invalid", "observation emission requires a running host")
	var emitted: Dictionary = session.emit_observation_pair(opportunity_skipped)
	if not bool(emitted.get("ok", false)):
		return _fail_from_result(emitted, "match session observation failed")
	var observations: Array = []
	_prune_known_observation_hashes(int(emitted["observation_seq"]))
	for seat: int in [0, 1]:
		var observation: Dictionary = emitted["observations"][str(seat)]
		var observation_hash := str(emitted["observation_hashes"][str(seat)])
		if ObservationContract.contains_forbidden_key(observation):
			return _fail("observation_leak", "provider observation contains protected authority fields")
		if ObservationContract.observation_hash(observation) != observation_hash:
			return _fail("observation_hash_mismatch", "provider observation hash is inconsistent")
		_known_observation_hashes[observation_hash] = {
			"observation_seq": int(emitted["observation_seq"]),
			"player_slot": seat,
		}
		observations.append({
			"observation": observation.duplicate(true),
			"observation_hash": observation_hash,
			"observation_seq": int(emitted["observation_seq"]),
			"player_slot": seat,
			"tick": int(emitted["boundary_tick"]),
		})
	var checkpoint_hash: String = session.checkpoint_hash()
	_remember_authority_boundary(checkpoint_hash)
	_gateway_boundary_hash = checkpoint_hash
	_latest_observation_seq = int(emitted["observation_seq"])
	_latest_observation_tick = int(emitted["boundary_tick"])
	var body := {
		"checkpoint_hash": checkpoint_hash,
		"observation_seq": int(emitted["observation_seq"]),
		"observations": observations,
		"tick": int(emitted["boundary_tick"]),
	}
	var result := _encode_host_event(
		"observation_pair", checkpoint_hash, body, "observation_pair_emitted"
	)
	if bool(result.get("ok", false)):
		result["observation_result"] = emitted
	return result


func advance_ticks(count: int) -> Dictionary:
	if _phase != PHASE_RUNNING:
		return _fail("bridge_phase_invalid", "tick advancement requires a running host")
	if count < 0:
		return _fail("advance_invalid", "tick advancement count must be non-negative")
	var outbound: Array = []
	var events: Array = []
	var remaining := count
	var last_advance: Dictionary = {
		"errors": PackedStringArray(), "ok": true,
		"terminal": session.simulation.terminal_result(),
		"tick": int(session.simulation.state.tick),
	}
	while remaining > 0 and not bool(session.simulation.state.terminal["ended"]):
		var tick := int(session.simulation.state.tick)
		var until_checkpoint := CHECKPOINT_PERIOD_TICKS - (tick % CHECKPOINT_PERIOD_TICKS)
		var chunk := mini(remaining, until_checkpoint)
		var until_application := _ticks_until_next_application_checkpoint(tick)
		if until_application > 0:
			chunk = mini(chunk, until_application)
		last_advance = session.advance_ticks(chunk)
		if not bool(last_advance.get("ok", false)):
			return _fail_from_result(last_advance, "match session advancement failed")
		remaining -= chunk
		var current_tick := int(session.simulation.state.tick)
		var tick_evidence := _take_tick_event_frames(session.checkpoint_hash())
		if not bool(tick_evidence.get("ok", false)):
			return tick_evidence
		outbound.append_array(tick_evidence["outbound"])
		events.append_array(tick_evidence["events"])
		var application_checkpoint_due := _pending_application_checkpoint_ticks.has(current_tick)
		var periodic_checkpoint_due := current_tick > 0 \
			and current_tick % CHECKPOINT_PERIOD_TICKS == 0
		if application_checkpoint_due or periodic_checkpoint_due:
			var checkpoint_reason := "application_periodic" if (
				application_checkpoint_due and periodic_checkpoint_due
			) else ("application" if application_checkpoint_due else "periodic")
			var checkpoint := _checkpoint_frame(checkpoint_reason)
			if not bool(checkpoint.get("ok", false)):
				return checkpoint
			outbound.append_array(checkpoint["outbound"])
			events.append_array(checkpoint["events"])
			if application_checkpoint_due:
				_pending_application_checkpoint_ticks.erase(current_tick)
	if bool(session.simulation.state.terminal["ended"]):
		var terminal := _terminal_frame()
		if not bool(terminal.get("ok", false)):
			return terminal
		outbound.append_array(terminal["outbound"])
		events.append_array(terminal["events"])
	return {
		"advance_result": last_advance,
		"errors": PackedStringArray(),
		"events": events,
		"ok": true,
		"outbound": outbound,
		"tick": int(session.simulation.state.tick),
	}


func emit_checkpoint(reason: String = "manual") -> Dictionary:
	if _phase != PHASE_RUNNING:
		return _fail("bridge_phase_invalid", "checkpoint emission requires a running host")
	return _checkpoint_frame(reason)


func emit_terminal_if_ended() -> Dictionary:
	if _phase not in [PHASE_RUNNING, PHASE_TERMINAL]:
		return _fail("bridge_phase_invalid", "terminal emission is invalid in the current phase")
	if not bool(session.simulation.state.terminal["ended"]):
		return _failure_without_transition("match_not_terminal", "match has not ended")
	return _terminal_frame()


func phase() -> String:
	return _phase


func protected_status() -> Dictionary:
	return {
		"checkpoint_count": _checkpoint_transcript.size(),
		"continuous_clock_started": _continuous_clock_started,
		"config_hash": _config_hash,
		"decision_mode": _decision_mode,
		"frame_inbound_sequence": _codec.inbound_sequence(),
		"frame_outbound_sequence": _codec.outbound_sequence(),
		"match_id": _match_id,
		"pending_application_checkpoints": _pending_application_checkpoint_ticks.size(),
		"phase": _phase,
		"session": session.protected_status() if session != null else null,
		"thinking_status_count": _protected_thinking_transcript.size(),
		"timing_record_count": _protected_timing_transcript.size(),
	}


func protected_timing_transcript() -> Array[Dictionary]:
	return _protected_timing_transcript.duplicate(true)


func protected_thinking_transcript() -> Array[Dictionary]:
	return _protected_thinking_transcript.duplicate(true)


func checkpoint_transcript() -> Array[Dictionary]:
	return _checkpoint_transcript.duplicate(true)


func _accept_auth(frame: Dictionary) -> Dictionary:
	if _phase != PHASE_AWAITING_AUTH:
		return _fail("bridge_phase_invalid", "auth arrived outside the handshake")
	var errors := PackedStringArray()
	_validate_exact_fields(frame["body"], ["accepted", "connection_id"], "auth", errors)
	var body: Dictionary = frame["body"]
	if body.get("accepted") != true:
		errors.append("gateway did not accept the Godot connection")
	if str(body.get("connection_id", "")) != _connection_id:
		errors.append("auth connection_id does not match the hello")
	if not errors.is_empty():
		return _fail("auth_invalid", "; ".join(errors))
	_phase = PHASE_AWAITING_CONFIG
	return _outbound_success([], [{"kind": "authenticated"}])


func _accept_match_config(frame: Dictionary) -> Dictionary:
	if _phase != PHASE_AWAITING_CONFIG:
		return _fail("bridge_phase_invalid", "match config arrived outside configuration")
	var errors := PackedStringArray()
	_validate_exact_fields(frame["body"], ["config", "config_hash"], "match config frame", errors)
	var body: Dictionary = frame["body"]
	if typeof(body.get("config")) != TYPE_DICTIONARY:
		errors.append("match config must be an object")
		return _fail("match_config_invalid", "; ".join(errors))
	var config: Dictionary = body["config"]
	var computed_hash := Codec.sha256_canonical(config)
	if str(body.get("config_hash", "")) != computed_hash \
		or str(frame["boundary_hash"]) != computed_hash:
		errors.append("match config hash does not match its canonical body")
	_validate_official_config(config, errors)
	if not errors.is_empty():
		return _fail("match_config_invalid", "; ".join(errors))
	session = Session.new()
	var session_errors: PackedStringArray = session.configure_official({
		"authoritative_hashes": _launch["authoritative_hashes"].duplicate(true),
		"decision_mode": str(config["decision_mode"]),
		"faction_id": str(config["faction_preset_id"]),
		"match_id": _match_id,
		"match_seed": int(config["seed"]),
		"scored": bool(_launch["scored"]),
	}, {
		"alias_salt_seat_0": (_launch["alias_salt_seat_0"] as PackedByteArray).duplicate(),
		"alias_salt_seat_1": (_launch["alias_salt_seat_1"] as PackedByteArray).duplicate(),
		"tie_key": (_launch["tie_key"] as PackedByteArray).duplicate(),
	})
	if not session_errors.is_empty():
		return _fail("session_configuration_failed", "; ".join(session_errors))
	_decision_mode = str(config["decision_mode"])
	_config_hash = computed_hash
	_public_match_settings = config.duplicate(true)
	_public_match_settings.erase("players")
	_phase = PHASE_RUNNING
	var encoded := _codec.encode("config_accepted", computed_hash, {
		"accepted": true,
		"config_hash": computed_hash,
	})
	if not bool(encoded.get("ok", false)):
		return _fail_from_result(encoded, "config acknowledgement encoding failed")
	return _outbound_success([encoded["payload"]], [{"kind": "config_accepted"}])


func _accept_thinking_status(frame: Dictionary) -> Dictionary:
	if _phase not in [PHASE_RUNNING, PHASE_TERMINAL]:
		return _fail(
			"bridge_phase_invalid",
			"thinking status requires a running or terminalizing host"
		)
	var errors := PackedStringArray()
	_validate_exact_fields(
		frame["body"], ["observation_seq", "player_slot", "status"],
		"thinking status", errors
	)
	var body: Dictionary = frame["body"]
	var observation_hash := str(frame["boundary_hash"])
	if not _known_observation_hashes.has(observation_hash):
		errors.append("thinking status references an unknown observation hash")
	else:
		var identity: Dictionary = _known_observation_hashes[observation_hash]
		if int(body.get("observation_seq", -1)) != int(identity["observation_seq"]) \
			or int(body.get("player_slot", -1)) != int(identity["player_slot"]):
			errors.append("thinking status identity does not match its observation hash")
	if str(body.get("status", "")) not in ["thinking", "locked", "timeout", "ready"]:
		errors.append("thinking status value is invalid")
	if not errors.is_empty():
		return _fail("thinking_status_invalid", "; ".join(errors))
	_protected_thinking_transcript.append({
		"observation_hash": observation_hash,
		"observation_seq": int(body["observation_seq"]),
		"player_slot": int(body["player_slot"]),
		"status": str(body["status"]),
		"tick": int(session.simulation.state.tick),
	})
	return _outbound_success([], [{
		"kind": (
			"thinking_status_recorded"
			if _phase == PHASE_RUNNING else "thinking_status_recorded_after_terminal"
		),
	}])


func _accept_fixed_commits(frame: Dictionary) -> Dictionary:
	if _phase != PHASE_RUNNING or _decision_mode != Session.FIXED_MODE:
		return _fail("bridge_phase_invalid", "fixed commits require a running fixed match")
	if str(frame["boundary_hash"]) != _gateway_boundary_hash:
		return _fail("checkpoint_hash_mismatch", "fixed commits use a stale decision boundary")
	var result: Dictionary = session.lock_fixed_commits(frame["body"])
	if not bool(result.get("ok", false)):
		return _fail_from_result(result, "fixed commit lock failed")
	var request: Dictionary = frame["body"]
	var encoded := _codec.encode("batch_commits_locked", str(frame["boundary_hash"]), {
		"boundary_tick": int(request["boundary_tick"]),
		"locked": true,
		"observation_seq": int(request["observation_seq"]),
		"opportunity_id": str(request["opportunity_id"]),
	})
	if not bool(encoded.get("ok", false)):
		return _fail_from_result(encoded, "fixed commit acknowledgement encoding failed")
	return _outbound_success([encoded["payload"]], [{"kind": "fixed_commits_locked"}])


func _accept_fixed_reveal(frame: Dictionary) -> Dictionary:
	if _phase != PHASE_RUNNING or _decision_mode != Session.FIXED_MODE:
		return _fail("bridge_phase_invalid", "fixed reveal requires a running fixed match")
	if str(frame["boundary_hash"]) != _gateway_boundary_hash:
		return _fail("checkpoint_hash_mismatch", "fixed reveal uses a stale decision boundary")
	var wire: Dictionary = frame["body"]
	var errors := PackedStringArray()
	_validate_exact_fields(
		wire,
		[
			"activation_tick", "boundary_tick", "disposition", "match_id", "mode",
			"observation_seq", "opportunity_id", "reveals",
		], "fixed reveal", errors
	)
	if str(wire.get("mode", "")) != Session.FIXED_MODE:
		errors.append("fixed reveal mode is invalid")
	if not errors.is_empty():
		return _fail("fixed_reveal_invalid", "; ".join(errors))
	var request := wire.duplicate(true)
	request.erase("mode")
	var result: Dictionary = session.reveal_fixed_pair(request)
	if not bool(result.get("ok", false)):
		return _fail_from_result(result, "fixed reveal application failed")
	var body := {
		"accepted": true,
		"actions": _receipt_rows(result.get("receipts", {})),
		"activation_tick": int(wire["activation_tick"]),
		"mode": Session.FIXED_MODE,
		"observation_seq": int(wire["observation_seq"]),
		"opportunity_id": str(wire["opportunity_id"]),
	}
	var evidence_outbound: Array = []
	var evidence_events: Array = []
	if str(wire["disposition"]) == "continue":
		var evidence := _application_evidence_frame("fixed_pair", result)
		if not bool(evidence.get("ok", false)):
			return evidence
		evidence_outbound.append_array(evidence["outbound"])
		evidence_events.append_array(evidence["events"])
	var encoded := _codec.encode("action_pair", str(frame["boundary_hash"]), body)
	if not bool(encoded.get("ok", false)):
		return _fail_from_result(encoded, "fixed action acknowledgement encoding failed")
	var outbound: Array = evidence_outbound
	outbound.append(encoded["payload"])
	var events: Array = evidence_events
	events.append({"kind": "fixed_action_pair_applied"})
	if bool(session.simulation.state.terminal["ended"]):
		var tick_evidence := _take_tick_event_frames(session.checkpoint_hash())
		if not bool(tick_evidence.get("ok", false)):
			return tick_evidence
		outbound.append_array(tick_evidence["outbound"])
		events.append_array(tick_evidence["events"])
		var terminal := _terminal_frame()
		if not bool(terminal.get("ok", false)):
			return terminal
		outbound.append_array(terminal["outbound"])
		events.append_array(terminal["events"])
	return _outbound_success(outbound, events)


func _accept_continuous_action(frame: Dictionary) -> Dictionary:
	if _phase != PHASE_RUNNING or _decision_mode != Session.CONTINUOUS_MODE:
		return _fail("bridge_phase_invalid", "continuous action requires a running continuous match")
	if not _continuous_clock_started:
		return _fail(
			"continuous_clock_not_started",
			"continuous action requires an acknowledged authority clock start"
		)
	if str(frame["boundary_hash"]) != _gateway_boundary_hash:
		return _fail("checkpoint_hash_mismatch", "continuous action uses a stale authority boundary")
	var wire: Dictionary = frame["body"]
	var errors := PackedStringArray()
	_validate_exact_fields(
		wire, ["actions", "application_tick", "match_id", "mode"],
		"continuous action", errors
	)
	if str(wire.get("mode", "")) != Session.CONTINUOUS_MODE:
		errors.append("continuous action mode is invalid")
	if str(wire.get("match_id", "")) != _match_id:
		errors.append("continuous action match_id is wrong")
	if typeof(wire.get("application_tick")) != TYPE_INT \
		or int(wire.get("application_tick", -1)) < 1:
		errors.append("continuous application_tick is invalid")
	if typeof(wire.get("actions")) != TYPE_ARRAY \
		or (wire.get("actions", []) as Array).is_empty() \
		or (wire.get("actions", []) as Array).size() > 2:
		errors.append("continuous action must contain one or two applications")
	var applications: Array = []
	var timing_rows: Array[Dictionary] = []
	var last_sort_key := ""
	if typeof(wire.get("actions")) == TYPE_ARRAY:
		for row_variant: Variant in (wire["actions"] as Array):
			if typeof(row_variant) != TYPE_DICTIONARY:
				errors.append("continuous application row must be an object")
				continue
			var row: Dictionary = row_variant
			_validate_exact_fields(
				row,
				[
					"batch", "observation_seq", "observation_tick", "opportunity_id",
					"player_slot", "timing",
				], "continuous application row", errors
			)
			_validate_timing(row.get("timing"), int(wire.get("application_tick", -1)), errors)
			var sort_key := "%d|%020d|%s" % [
				int(row.get("player_slot", -1)), int(row.get("observation_seq", -1)),
				str(row.get("opportunity_id", "")),
			]
			if not last_sort_key.is_empty() and sort_key < last_sort_key:
				errors.append("continuous applications are not in canonical seat/order order")
			last_sort_key = sort_key
			applications.append({
				"batch": _deep_copy(row.get("batch")),
				"observation_seq": row.get("observation_seq"),
				"observation_tick": row.get("observation_tick"),
				"opportunity_id": row.get("opportunity_id"),
				"player_slot": row.get("player_slot"),
			})
			timing_rows.append({
				"observation_seq": int(row.get("observation_seq", -1)),
				"opportunity_id": str(row.get("opportunity_id", "")),
				"player_slot": int(row.get("player_slot", -1)),
				"timing": _deep_copy(row.get("timing")),
			})
	if not errors.is_empty():
		return _fail("continuous_action_invalid", "; ".join(errors))
	var result: Dictionary = session.apply_continuous_gate({
		"application_tick": int(wire["application_tick"]),
		"applications": applications,
		"match_id": _match_id,
	})
	if not bool(result.get("ok", false)):
		return _fail_from_result(result, "continuous gate application failed")
	for timing_row: Dictionary in timing_rows:
		var protected_row := timing_row.duplicate(true)
		protected_row["recorded_at_simulation_tick"] = int(session.simulation.state.tick)
		_protected_timing_transcript.append(protected_row)
	var body := {
		"accepted": true,
		"actions": _receipt_rows(result.get("receipts", {})),
		"application_tick": int(wire["application_tick"]),
		"mode": Session.CONTINUOUS_MODE,
	}
	var evidence := _application_evidence_frame("continuous_gate", result)
	if not bool(evidence.get("ok", false)):
		return evidence
	var encoded := _codec.encode("action_pair", str(frame["boundary_hash"]), body)
	if not bool(encoded.get("ok", false)):
		return _fail_from_result(encoded, "continuous action acknowledgement encoding failed")
	var outbound: Array = evidence["outbound"]
	outbound.append(encoded["payload"])
	var events: Array = evidence["events"]
	events.append({"kind": "continuous_action_pair_applied"})
	return _outbound_success(outbound, events)


func _accept_continuous_start(frame: Dictionary) -> Dictionary:
	if _phase != PHASE_RUNNING or _decision_mode != Session.CONTINUOUS_MODE:
		return _fail(
			"bridge_phase_invalid", "continuous clock start requires a running continuous match"
		)
	if str(frame["boundary_hash"]) != _gateway_boundary_hash:
		return _fail(
			"checkpoint_hash_mismatch", "continuous clock start uses a stale authority boundary"
		)
	var body: Dictionary = frame["body"]
	var errors := PackedStringArray()
	_validate_exact_fields(
		body, ["match_id", "observation_seq", "start_id", "tick"],
		"continuous clock start", errors
	)
	if typeof(body.get("match_id")) != TYPE_STRING or str(body.get("match_id", "")) != _match_id:
		errors.append("continuous clock start match_id is wrong")
	if typeof(body.get("observation_seq")) != TYPE_INT \
		or int(body.get("observation_seq", -1)) != 0 \
		or int(body.get("observation_seq", -1)) != _latest_observation_seq:
		errors.append("continuous clock start requires observation sequence zero")
	if typeof(body.get("tick")) != TYPE_INT \
		or int(body.get("tick", -1)) != 0 \
		or int(body.get("tick", -1)) != _latest_observation_tick \
		or int(session.simulation.state.tick) != 0:
		errors.append("continuous clock start requires authoritative tick zero")
	var identity := {
		"match_id": body.get("match_id"),
		"observation_seq": body.get("observation_seq"),
		"tick": body.get("tick"),
	}
	if typeof(body.get("start_id")) != TYPE_STRING \
		or str(body.get("start_id", "")) != Codec.sha256_canonical(identity):
		errors.append("continuous clock start_id is inconsistent")
	if not errors.is_empty():
		return _fail("continuous_start_invalid", "; ".join(errors))
	if _continuous_clock_started:
		return _fail("continuous_clock_already_started", "continuous clock start is single-use")
	var encoded := _codec.encode("continuous_start_accepted", str(frame["boundary_hash"]), {
		"accepted": true,
		"match_id": str(body["match_id"]),
		"observation_seq": int(body["observation_seq"]),
		"start_id": str(body["start_id"]),
		"tick": int(body["tick"]),
	})
	if not bool(encoded.get("ok", false)):
		return _fail_from_result(encoded, "continuous clock start acknowledgement encoding failed")
	_continuous_clock_started = true
	return _outbound_success(
		[encoded["payload"]], [{"kind": "continuous_clock_started"}]
	)


func _accept_gateway_disposition(frame: Dictionary) -> Dictionary:
	if _phase not in [PHASE_RUNNING, PHASE_TERMINAL] \
		or _decision_mode != Session.CONTINUOUS_MODE:
		return _fail(
			"bridge_phase_invalid",
			"gateway disposition requires a running or idempotently terminal continuous match"
		)
	if not _issued_authority_boundaries.has(str(frame["boundary_hash"])):
		return _fail(
			"checkpoint_hash_mismatch",
			"gateway disposition does not reference an issued authority boundary"
		)
	var body: Dictionary = frame["body"]
	var errors := PackedStringArray()
	_validate_exact_fields(
		body, ["code", "disposition", "match_id", "reason", "request_id"],
		"gateway disposition", errors
	)
	var disposition := str(body.get("disposition", ""))
	var code := str(body.get("code", ""))
	if typeof(body.get("match_id")) != TYPE_STRING or str(body.get("match_id", "")) != _match_id:
		errors.append("gateway disposition match_id is wrong")
	if typeof(body.get("disposition")) != TYPE_STRING or disposition not in [
		"draw_double_technical_forfeit", "technical_forfeit_slot_0",
		"technical_forfeit_slot_1", "void_infrastructure",
	]:
		errors.append("gateway disposition value is invalid")
	if typeof(body.get("code")) != TYPE_STRING or not _is_identifier(code):
		errors.append("gateway disposition code is not a bounded public identifier")
	elif disposition != "void_infrastructure" and code != "model_failure_threshold":
		errors.append("technical dispositions require the frozen model failure threshold code")
	var expected_reason := _gateway_disposition_reason(disposition)
	if typeof(body.get("reason")) != TYPE_STRING or str(body.get("reason", "")) != expected_reason:
		errors.append("gateway disposition reason is not the frozen public reason")
	var identity := {
		"code": body.get("code"),
		"disposition": body.get("disposition"),
		"match_id": body.get("match_id"),
		"reason": body.get("reason"),
	}
	if typeof(body.get("request_id")) != TYPE_STRING \
		or str(body.get("request_id", "")) != Codec.sha256_canonical(identity):
		errors.append("gateway disposition request_id is inconsistent")
	if not errors.is_empty():
		return _fail("gateway_disposition_invalid", "; ".join(errors))

	if _phase == PHASE_TERMINAL:
		if body != _gateway_disposition_record:
			var terminal_source := "simulation" if _gateway_disposition_record.is_empty() \
				else "gateway"
			var terminal_result: Dictionary = session.simulation.terminal_result()
			return _fail(
				"gateway_disposition_conflict",
				"terminal host received a conflicting gateway disposition " \
					+ "(terminal_source=%s, result=%s, reason=%s, tick=%d)" % [
						terminal_source,
						str(terminal_result.get("result", "")),
						str(terminal_result.get("reason", "")),
						int(session.simulation.state.tick),
					]
			)
		var duplicate_ack := _gateway_disposition_ack(frame)
		if not bool(duplicate_ack.get("ok", false)):
			return _fail_from_result(
				duplicate_ack, "duplicate gateway disposition acknowledgement encoding failed"
			)
		return _outbound_success(
			[duplicate_ack["payload"]], [{"kind": "gateway_disposition_duplicate_acknowledged"}]
		)

	var declared: Dictionary = session.declare_gateway_disposition(disposition)
	if not bool(declared.get("ok", false)) \
		or not bool(declared.get("terminal", {}).get("ended", false)):
		return _fail_from_result(declared, "gateway disposition declaration failed")
	_gateway_disposition_record = body.duplicate(true)
	var acknowledgement := _gateway_disposition_ack(frame)
	if not bool(acknowledgement.get("ok", false)):
		return _fail_from_result(
			acknowledgement, "gateway disposition acknowledgement encoding failed"
		)
	var disposition_boundary := _gateway_boundary_hash
	var tick_evidence := _take_tick_event_frames(session.checkpoint_hash())
	if not bool(tick_evidence.get("ok", false)):
		return tick_evidence
	## Terminal idempotence is tied to the originally authenticated disposition
	## request.  Event evidence commits the final state without changing the
	## boundary accepted by an identical retry of that single request.
	_gateway_boundary_hash = disposition_boundary
	var terminal := _terminal_frame()
	if not bool(terminal.get("ok", false)):
		return terminal
	_gateway_boundary_hash = disposition_boundary
	var outbound: Array = [acknowledgement["payload"]]
	outbound.append_array(tick_evidence["outbound"])
	outbound.append_array(terminal["outbound"])
	var events: Array = [{"kind": "gateway_disposition_accepted"}]
	events.append_array(tick_evidence["events"])
	events.append_array(terminal["events"])
	return _outbound_success(outbound, events)


func _gateway_disposition_ack(frame: Dictionary) -> Dictionary:
	var body: Dictionary = frame["body"]
	return _codec.encode("gateway_disposition_accepted", str(frame["boundary_hash"]), {
		"accepted": true,
		"code": str(body["code"]),
		"disposition": str(body["disposition"]),
		"match_id": str(body["match_id"]),
		"reason": str(body["reason"]),
		"request_id": str(body["request_id"]),
	})


func _accept_artifact_ready(frame: Dictionary) -> Dictionary:
	if _phase != PHASE_TERMINAL:
		return _fail("bridge_phase_invalid", "artifact completion requires a terminal match")
	var errors := PackedStringArray()
	_validate_exact_fields(frame["body"], ["artifact_hash", "manifest"], "artifact ready", errors)
	var body: Dictionary = frame["body"]
	if str(body.get("artifact_hash", "")) != str(frame["boundary_hash"]):
		errors.append("artifact hash does not match its frame boundary")
	if typeof(body.get("manifest")) != TYPE_DICTIONARY:
		errors.append("artifact manifest must be an object")
	elif _contains_secret_key(body["manifest"]):
		errors.append("artifact manifest contains a secret-like key")
	if not errors.is_empty():
		return _fail("artifact_ready_invalid", "; ".join(errors))
	_phase = PHASE_COMPLETE
	_codec.close()
	return _outbound_success([], [{"kind": "artifact_ready"}])


func _application_evidence_frame(expected_kind: String, result: Dictionary) -> Dictionary:
	var record: Dictionary = session.latest_application_record()
	var errors := PackedStringArray()
	if record.is_empty():
		errors.append("authoritative application transcript is missing")
	if str(record.get("kind", "")) != expected_kind:
		errors.append("authoritative application kind is inconsistent")
	if typeof(record.get("application_tick")) != TYPE_INT \
		or int(record.get("application_tick", -1)) != int(result.get("application_tick", -2)) \
		or int(record.get("application_tick", -1)) < 0:
		errors.append("authoritative application tick is inconsistent")
	var records: Array = []
	var batches_variant: Variant = record.get("batches")
	if typeof(batches_variant) != TYPE_ARRAY or (batches_variant as Array).is_empty() \
		or (batches_variant as Array).size() > 2:
		errors.append("authoritative application batches are invalid")
	else:
		var previous_slot := -1
		for row_variant: Variant in (batches_variant as Array):
			if typeof(row_variant) != TYPE_DICTIONARY:
				errors.append("authoritative application row must be an object")
				continue
			var row: Dictionary = row_variant
			var slot := int(row.get("player_seat", -1))
			if typeof(row.get("player_seat")) != TYPE_INT or slot not in [0, 1] \
				or slot <= previous_slot:
				errors.append("authoritative application rows are not in canonical slot order")
			previous_slot = slot
			if not ObservationContract.is_sha256(row.get("batch_digest")):
				errors.append("authoritative application batch digest is invalid")
			if not ObservationContract.is_id(row.get("batch_id")):
				errors.append("authoritative application batch id is invalid")
			if typeof(row.get("compiled_intents")) != TYPE_ARRAY:
				errors.append("authoritative compiled intents must be an array")
			if typeof(row.get("receipt")) != TYPE_DICTIONARY:
				errors.append("authoritative action receipt must be an object")
			var public_row := {
				"batch_digest": str(row.get("batch_digest", "")),
				"batch_id": str(row.get("batch_id", "")),
				"compiled_intents": _deep_copy(row.get("compiled_intents", [])),
				"player_slot": slot,
				"receipt": _deep_copy(row.get("receipt", {})),
			}
			if _contains_private_replay_key(public_row):
				errors.append("authoritative application evidence contains protected model material")
			records.append(public_row)
	if not errors.is_empty():
		return _fail("action_receipts_invalid", "; ".join(errors))
	var checkpoint_hash: String = session.checkpoint_hash()
	var checkpoint_tick := int(session.simulation.state.tick)
	_remember_authority_boundary(checkpoint_hash)
	var body := {
		"application_seq": _next_application_seq,
		"application_tick": int(record["application_tick"]),
		"checkpoint_hash": checkpoint_hash,
		"checkpoint_tick": checkpoint_tick,
		"decision_mode": _decision_mode,
		"kind": expected_kind,
		"match_id": _match_id,
		"records": records,
	}
	var encoded := _codec.encode("action_receipts", checkpoint_hash, body)
	if not bool(encoded.get("ok", false)):
		return _fail_from_result(encoded, "action receipt evidence encoding failed")
	_gateway_boundary_hash = checkpoint_hash
	_pending_application_checkpoint_ticks[int(body["application_tick"])] = true
	_next_application_seq += 1
	return _outbound_success([encoded["payload"]], [{
		"application_seq": int(body["application_seq"]),
		"kind": "action_receipts_emitted",
	}])


func _take_tick_event_frames(checkpoint_hash: String) -> Dictionary:
	if not ObservationContract.is_sha256(checkpoint_hash):
		return _fail("tick_events_invalid", "tick event checkpoint hash is invalid")
	var state_events: Array = session.simulation.state.events
	if _world_event_cursor < 0 or _world_event_cursor > state_events.size():
		return _fail("tick_events_invalid", "tick event authority cursor is invalid")
	var projected: Array = []
	for index: int in range(_world_event_cursor, state_events.size()):
		var event: Variant = state_events[index]
		var expected_world_seq := index + 1
		if int(event.event_seq) != expected_world_seq \
			or expected_world_seq != _next_replay_event_seq + projected.size():
			return _fail("tick_event_sequence_invalid", "authority event sequence is not contiguous")
		var public_event := _project_omniscient_event(event, expected_world_seq)
		if not bool(public_event.get("ok", false)):
			return _fail_from_result(public_event, "omniscient event projection failed")
		projected.append(public_event["event"])
	if projected.is_empty():
		return _outbound_success([], [])

	var outbound: Array = []
	var chunk: Array = []
	for event_variant: Variant in projected:
		var candidate := chunk.duplicate(true)
		candidate.append(_deep_copy(event_variant))
		var candidate_body := _tick_event_body(checkpoint_hash, candidate)
		if Codec.canonical_bytes(candidate_body).size() > MAX_EVIDENCE_BODY_BYTES:
			if chunk.is_empty():
				return _fail("frame_too_large", "one tick event exceeds the authenticated frame limit")
			var chunk_result := _encode_tick_event_chunk(checkpoint_hash, chunk)
			if not bool(chunk_result.get("ok", false)):
				return chunk_result
			outbound.append_array(chunk_result["outbound"])
			chunk = [_deep_copy(event_variant)]
		else:
			chunk = candidate
	if not chunk.is_empty():
		var final_chunk := _encode_tick_event_chunk(checkpoint_hash, chunk)
		if not bool(final_chunk.get("ok", false)):
			return final_chunk
		outbound.append_array(final_chunk["outbound"])
	_gateway_boundary_hash = checkpoint_hash
	_world_event_cursor = state_events.size()
	_next_replay_event_seq += projected.size()
	return _outbound_success(outbound, [{
		"event_count": projected.size(),
		"kind": "tick_events_emitted",
	}])


func _encode_tick_event_chunk(checkpoint_hash: String, events: Array) -> Dictionary:
	_remember_authority_boundary(checkpoint_hash)
	var body := _tick_event_body(checkpoint_hash, events)
	var encoded := _codec.encode("tick_events", checkpoint_hash, body)
	if not bool(encoded.get("ok", false)):
		return _fail_from_result(encoded, "tick event evidence encoding failed")
	return _outbound_success([encoded["payload"]], [])


func _tick_event_body(checkpoint_hash: String, events: Array) -> Dictionary:
	var first: Dictionary = events[0] if not events.is_empty() else {}
	var last: Dictionary = events[-1] if not events.is_empty() else {}
	return {
		"checkpoint_hash": checkpoint_hash,
		"events": events.duplicate(true),
		"first_event_seq": int(first.get("event_seq", 0)),
		"last_event_seq": int(last.get("event_seq", 0)),
		"match_id": _match_id,
		"tick_from": int(first.get("tick", 0)),
		"tick_through": int(last.get("tick", 0)),
	}


func _project_omniscient_event(event: Variant, event_seq: int) -> Dictionary:
	var raw_kind := str(event.event_kind)
	var kind := _public_event_kind(raw_kind)
	var payload := _public_event_payload(
		raw_kind,
		event.payload if typeof(event.payload) == TYPE_DICTIONARY else {},
		int(event.source_internal_id),
		int(event.target_internal_id)
	)
	var projected := {
		"audience": "omniscient",
		"event_seq": event_seq,
		"kind": kind,
		"payload": payload,
		"tick": int(event.tick),
	}
	var errors := Codec.validate_canonical_value(projected, "$.tick_event")
	if not errors.is_empty() or int(event.tick) < 0 or kind not in PUBLIC_EVENT_KINDS:
		if errors.is_empty():
			errors.append("projected event identity is invalid")
		return {"errors": errors, "ok": false}
	return {"errors": PackedStringArray(), "event": projected, "ok": true}


func _public_event_kind(raw_kind: String) -> String:
	if raw_kind in PUBLIC_EVENT_KINDS:
		return raw_kind
	if raw_kind == "match_ended":
		var terminal: Dictionary = session.simulation.terminal_result()
		match str(terminal.get("result", "")):
			"draw":
				return "terminal_draw"
			"technical_forfeit":
				return "terminal_forfeit"
			"infrastructure_void":
				return "terminal_infrastructure_void"
		return "terminal_win"
	if raw_kind in ["economic_entity_destroyed", "construction_destroyed", "hero_died",
		"neutral_member_died", "summon_expired"]:
		return "entity_destroyed"
	if raw_kind == "hero_level_up":
		return "hero_level_gained"
	if raw_kind == "hero_ability_learned":
		return "hero_skill_learned"
	if raw_kind == "hero_xp_awarded":
		return "hero_xp_gained"
	if raw_kind == "hero_revival_started":
		return "revival_progress"
	if raw_kind == "hero_revived":
		return "revival_completed"
	if raw_kind == "neutral_camp_cleared":
		return "creep_camp_cleared"
	if raw_kind == "neutral_offer_purchased":
		return "shop_purchase"
	if raw_kind == "upgrade_completed":
		return "research_completed"
	if raw_kind in ["status_expired", "periodic_effect_interrupted"]:
		return "status_ended"
	if raw_kind == "item_spawned":
		return "item_dropped"
	if "heal" in raw_kind:
		return "healing_observed"
	if "impacted" in raw_kind or "damage" in raw_kind or raw_kind == "ground_attack_landed":
		return "damage_observed"
	if "attack" in raw_kind or "projectile" in raw_kind:
		return "attack_observed"
	if "ability" in raw_kind or "effect" in raw_kind:
		return "cast_observed"
	if raw_kind in ["arrived", "movement_arrived"]:
		return "order_completed"
	if raw_kind in ["movement_committed", "route_planned"]:
		return "order_started"
	if "route" in raw_kind or "movement" in raw_kind:
		return "pathing_changed"
	if "failed" in raw_kind or "invalid" in raw_kind or "cancelled" in raw_kind:
		return "command_rejected"
	return "command_applied"


func _public_event_payload(
	raw_kind: String, raw: Dictionary, source_internal_id: int, target_internal_id: int
) -> Dictionary:
	var payload: Dictionary = {}
	for field: String in PUBLIC_EVENT_PAYLOAD_KEYS:
		if not raw.has(field):
			continue
		var value: Variant = raw[field]
		if field in PUBLIC_EVENT_ID_FIELDS:
			if ObservationContract.is_id(value):
				payload[field] = value
		elif field == "code":
			if typeof(value) == TYPE_STRING and str(value).length() <= 64:
				payload[field] = value
		elif field == "terminal_reason":
			if typeof(value) == TYPE_STRING and str(value).length() <= 80:
				payload[field] = value
		elif field == "resource":
			if typeof(value) == TYPE_STRING and str(value) in ["gold", "lumber", "food", "mana", "hp"]:
				payload[field] = value
		elif field == "day_phase":
			if typeof(value) == TYPE_STRING and str(value) in ["day", "night", "forced_night"]:
				payload[field] = value
		elif field == "winner":
			if typeof(value) == TYPE_STRING and str(value) in ["self", "opponent", "none"]:
				payload[field] = value
		elif field == "position_mt":
			if typeof(value) == TYPE_ARRAY and (value as Array).size() == 2 \
				and typeof(value[0]) == TYPE_INT and typeof(value[1]) == TYPE_INT:
				payload[field] = (value as Array).duplicate()
		elif field == "details":
			if typeof(value) == TYPE_ARRAY:
				var details: Array[String] = []
				for detail: Variant in (value as Array):
					if ObservationContract.is_id(detail) and str(detail) not in details:
						details.append(str(detail))
				details.sort()
				if details.size() <= 24:
					payload[field] = details
		elif typeof(value) == TYPE_INT:
			if field in ["damage", "healing", "progress_bp", "level", "tier", "xp"] \
				and int(value) < 0:
				continue
			if field == "progress_bp" and int(value) > 10_000:
				continue
			if field == "level" and int(value) not in range(1, 11):
				continue
			if field == "tier" and int(value) not in range(1, 4):
				continue
			payload[field] = value
	if not payload.has("damage") and typeof(raw.get("hp_damage")) == TYPE_INT \
		and int(raw["hp_damage"]) >= 0:
		payload["damage"] = int(raw["hp_damage"])
	if not payload.has("amount"):
		for candidate: String in ["delivered", "harvested", "amount"]:
			if typeof(raw.get(candidate)) == TYPE_INT:
				payload["amount"] = int(raw[candidate])
				break
	var source_id := _entity_public_id(source_internal_id)
	var target_id := _entity_public_id(target_internal_id)
	if not source_id.is_empty():
		payload["source_entity_id"] = source_id
	if not target_id.is_empty():
		payload["target_entity_id"] = target_id
	if not target_id.is_empty() or not source_id.is_empty():
		payload["entity_id"] = target_id if not target_id.is_empty() else source_id
	var details: Array = payload.get("details", [])
	if ObservationContract.is_id(raw_kind) and raw_kind not in details:
		details.append(raw_kind)
	details.sort()
	if details.size() > 24:
		details.resize(24)
	if not details.is_empty():
		payload["details"] = details
	if raw_kind == "match_ended":
		var reason := str(raw.get("reason", "match_ended")).left(80)
		payload["terminal_reason"] = reason
	return payload


func _entity_public_id(internal_id: int) -> String:
	if internal_id <= 0 or not session.simulation.state.entities.has(internal_id):
		return ""
	var entity: Variant = session.simulation.state.entities[internal_id]
	return str(entity.public_id) if ObservationContract.is_id(entity.public_id) else ""


func _ticks_until_next_application_checkpoint(current_tick: int) -> int:
	var nearest := -1
	for tick_variant: Variant in _pending_application_checkpoint_ticks.keys():
		var pending_tick := int(tick_variant)
		if pending_tick <= current_tick:
			continue
		if nearest < 0 or pending_tick < nearest:
			nearest = pending_tick
	return -1 if nearest < 0 else nearest - current_tick


func _checkpoint_frame(reason: String) -> Dictionary:
	if reason.is_empty() or reason.length() > 96:
		return _fail("checkpoint_invalid", "checkpoint reason is invalid")
	var checkpoint_hash: String = session.checkpoint_hash()
	var tick := int(session.simulation.state.tick)
	_remember_authority_boundary(checkpoint_hash)
	_gateway_boundary_hash = checkpoint_hash
	if not _checkpoint_transcript.is_empty():
		var previous: Dictionary = _checkpoint_transcript[-1]
		if int(previous["tick"]) == tick \
			and str(previous["checkpoint_hash"]) == checkpoint_hash:
			return _outbound_success([], [{
				"checkpoint_hash": checkpoint_hash,
				"kind": "checkpoint_already_emitted",
				"tick": tick,
			}])
	_checkpoint_transcript.append({
		"checkpoint_hash": checkpoint_hash,
		"reason": reason,
		"tick": tick,
	})
	return _encode_host_event("checkpoint", checkpoint_hash, {
		"checkpoint_hash": checkpoint_hash,
		"reason": reason,
		"tick": tick,
	}, "checkpoint_emitted")


func _terminal_frame() -> Dictionary:
	if _terminal_emitted:
		return _outbound_success([], [{"kind": "terminal_already_emitted"}])
	var terminal: Dictionary = session.simulation.terminal_result()
	if not bool(terminal.get("ended", false)):
		return _failure_without_transition("match_not_terminal", "match has not ended")
	var final_checkpoint: String = session.checkpoint_hash()
	var checkpoint := _checkpoint_frame("terminal")
	if not bool(checkpoint.get("ok", false)):
		return checkpoint
	var result_material := {
		"final_checkpoint_hash": final_checkpoint,
		"match_id": _match_id,
		"terminal": terminal,
		"terminal_tick": int(session.simulation.state.tick),
	}
	if not _gateway_disposition_record.is_empty():
		result_material["gateway_disposition"] = _gateway_disposition_record.duplicate(true)
	var result_hash := Codec.sha256_canonical(result_material)
	var result := str(terminal.get("result", ""))
	var disposition := "victory"
	if result == "draw":
		disposition = "draw"
	elif result == "technical_forfeit":
		disposition = "technical_forfeit"
	elif result == "infrastructure_void":
		disposition = "infrastructure_void"
	elif result != "normal":
		return _fail("terminal_invalid", "match session produced an unsupported terminal result")
	var winner_seat := int(terminal.get("winner_seat", -1))
	var body := {
		"disposition": disposition,
		"reason": str(terminal.get("reason", "")),
		"result_hash": result_hash,
		"terminal_tick": int(session.simulation.state.tick),
		"winner_slot": winner_seat if winner_seat in [0, 1] else null,
	}
	if not _gateway_disposition_record.is_empty():
		body["reason"] = str(_gateway_disposition_record["reason"])
	if disposition == "technical_forfeit":
		body["failure"] = {
			"code": str(_gateway_disposition_record.get("code", "model_failure")),
			"hard_model_failure": true,
			"owner": "model",
		}
	elif disposition == "infrastructure_void":
		body["failure"] = {
			"code": str(_gateway_disposition_record.get(
				"code", terminal.get("reason", "infrastructure_void")
			)),
			"hard_model_failure": false,
			"owner": "organizer_infrastructure",
		}
	var encoded := _codec.encode("terminal", result_hash, body)
	if not bool(encoded.get("ok", false)):
		return _fail_from_result(encoded, "terminal frame encoding failed")
	_terminal_emitted = true
	_phase = PHASE_TERMINAL
	var outbound: Array = checkpoint["outbound"]
	outbound.append(encoded["payload"])
	var events: Array = checkpoint["events"]
	events.append({
		"final_checkpoint_hash": final_checkpoint,
		"kind": "terminal_emitted",
		"result_hash": result_hash,
	})
	return _outbound_success(outbound, events)


func _validate_official_config(config: Dictionary, errors: PackedStringArray) -> void:
	_validate_exact_fields(config, CONFIG_FIELDS, "match config", errors)
	var constants := {
		"control_profile": "hybrid-v1",
		"map_id": "crossroads-duel-v1",
		"maximum_match_ticks": 18_000,
		"mirror_faction": true,
		"observation_profile": "full-belief-v1",
		"protocol_version": FrameCodec.PROTOCOL_VERSION,
		"ruleset_id": "duel-rules-v1",
		"simulation_hz": 10,
	}
	for key: String in constants:
		if config.get(key) != constants[key]:
			errors.append("match config %s is not the frozen official value" % key)
	var mode := str(config.get("decision_mode", ""))
	if mode not in [Session.FIXED_MODE, Session.CONTINUOUS_MODE]:
		errors.append("match config decision_mode is invalid")
	elif mode == Session.FIXED_MODE:
		if int(config.get("decision_period_ticks", -1)) != 100 \
			or int(config.get("response_deadline_ms", -1)) != 45_000:
			errors.append("fixed scored host requires the official 100-tick/45000-ms profile")
	else:
		if int(config.get("decision_period_ticks", -1)) != 50 \
			or int(config.get("response_deadline_ms", -1)) != 8_000:
			errors.append("continuous scored host requires the official 50-tick/8000-ms profile")
	if str(config.get("faction_preset_id", "")) not in [
		"crypt-v1", "grove-v1", "vanguard-v1", "warhost-v1",
	]:
		errors.append("match config faction preset is invalid")
	if typeof(config.get("seed")) != TYPE_INT or int(config.get("seed", -1)) < 0:
		errors.append("match config seed is invalid")
	if str(config.get("memory_policy", "")) not in [
		"adaptive-series", "fresh-match-with-bounded-scratchpad",
	]:
		errors.append("match config memory policy is invalid")
	var cadence: Variant = config.get("cadence_profile_id")
	if cadence != null and not _is_identifier(cadence):
		errors.append("match config cadence_profile_id is invalid")
	_validate_spectator(config.get("spectator"), errors)
	_validate_players(config.get("players"), errors)


func _validate_spectator(value: Variant, errors: PackedStringArray) -> void:
	if value == null:
		return
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("match config spectator must be null or an object")
		return
	_validate_exact_fields(
		value, ["enabled", "initial_perspective", "record_replay"], "spectator", errors
	)
	var spectator: Dictionary = value
	if typeof(spectator.get("enabled")) != TYPE_BOOL \
		or typeof(spectator.get("record_replay")) != TYPE_BOOL:
		errors.append("spectator enabled/record_replay must be boolean")
	if str(spectator.get("initial_perspective", "")) not in [
		"omniscient", "slot_0", "slot_1",
	]:
		errors.append("spectator initial perspective is invalid")


func _validate_players(value: Variant, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != 2:
		errors.append("match config players must contain exactly two canonical slots")
		return
	for seat: int in [0, 1]:
		var row_variant: Variant = (value as Array)[seat]
		if typeof(row_variant) != TYPE_DICTIONARY:
			errors.append("player %d config must be an object" % seat)
			continue
		var row: Dictionary = row_variant
		_validate_exact_fields(
			row, ["model", "provider_adapter", "reasoning", "slot"],
			"player %d" % seat, errors
		)
		if typeof(row.get("slot")) != TYPE_INT or int(row.get("slot", -1)) != seat:
			errors.append("players must use canonical slots [0, 1]")
		if typeof(row.get("model")) != TYPE_STRING \
			or str(row.get("model", "")).is_empty() or str(row.get("model", "")).length() > 200:
			errors.append("player %d model identity is invalid" % seat)
		if typeof(row.get("reasoning")) != TYPE_STRING \
			or str(row.get("reasoning", "")).is_empty() \
			or str(row.get("reasoning", "")).length() > 80:
			errors.append("player %d reasoning identity is invalid" % seat)
		var adapter: Variant = row.get("provider_adapter")
		if adapter != null and not _is_identifier(adapter):
			errors.append("player %d provider adapter is invalid" % seat)


func _validate_timing(value: Variant, application_tick: int, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("continuous timing must be an object")
		return
	_validate_exact_fields(value, TIMING_FIELDS, "continuous timing", errors)
	var timing: Dictionary = value
	for key: String in TIMING_FIELDS:
		var field: Variant = timing.get(key)
		if key in ["deadline_monotonic_ns", "dispatch_monotonic_ns"]:
			if typeof(field) != TYPE_INT or int(field) < 0:
				errors.append("continuous timing %s must be a non-negative integer" % key)
		elif field != null and (typeof(field) != TYPE_INT or int(field) < 0):
			errors.append("continuous timing %s must be null or a non-negative integer" % key)
	if timing.get("application_tick") != application_tick:
		errors.append("continuous timing application_tick does not match the gate")
	if typeof(timing.get("dispatch_monotonic_ns")) == TYPE_INT \
		and typeof(timing.get("deadline_monotonic_ns")) == TYPE_INT \
		and int(timing["deadline_monotonic_ns"]) < int(timing["dispatch_monotonic_ns"]):
		errors.append("continuous timing deadline precedes dispatch")


func _encode_host_event(
	message_type: String, boundary_hash: String, body: Dictionary, event_kind: String
) -> Dictionary:
	var encoded := _codec.encode(message_type, boundary_hash, body)
	if not bool(encoded.get("ok", false)):
		return _fail_from_result(encoded, "%s encoding failed" % message_type)
	return _outbound_success([encoded["payload"]], [{"kind": event_kind}])


func _fail_from_result(result: Dictionary, prefix: String) -> Dictionary:
	var details := PackedStringArray()
	for message_variant: Variant in result.get("errors", []):
		details.append(str(message_variant))
	return _fail(
		str(result.get("code", "authority_failure")),
		prefix + (": " + "; ".join(details) if not details.is_empty() else "")
	)


func _fail(code: String, message: String) -> Dictionary:
	_phase = PHASE_FAILED
	return _failure_without_transition(code, message)


static func _failure_without_transition(code: String, message: String) -> Dictionary:
	return {
		"code": code,
		"errors": PackedStringArray([message]),
		"events": [],
		"ok": false,
		"outbound": [],
	}


static func _outbound_success(outbound: Array, events: Array) -> Dictionary:
	return {
		"errors": PackedStringArray(),
		"events": events,
		"ok": true,
		"outbound": outbound,
	}


static func _validate_exact_fields(
	value: Variant, fields: Array[String], label: String, errors: PackedStringArray
) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append(label + " must be an object")
		return
	var dictionary: Dictionary = value
	if dictionary.size() != fields.size():
		errors.append(label + " fields are not exact")
	for field: String in fields:
		if not dictionary.has(field):
			errors.append(label + " is missing " + field)
	for key_variant: Variant in dictionary.keys():
		if typeof(key_variant) != TYPE_STRING or str(key_variant) not in fields:
			errors.append(label + " has unknown field " + str(key_variant))


static func _receipt_rows(value: Variant) -> Array:
	var rows: Array = []
	if typeof(value) != TYPE_DICTIONARY:
		return rows
	var receipts: Dictionary = value
	for seat: int in [0, 1]:
		if receipts.has(str(seat)):
			rows.append({
				"player_slot": seat,
				"receipt": _deep_copy(receipts[str(seat)]),
			})
	return rows


func _prune_known_observation_hashes(current_sequence: int) -> void:
	## Continuous responses may legitimately finish after a later 50-tick grid
	## emitted a skipped opportunity. Retain the bounded 100-tick freshness
	## window instead of invalidating that still-authenticated observation.
	var minimum_sequence := maxi(0, current_sequence - 2)
	for hash_variant: Variant in _known_observation_hashes.keys():
		var identity: Dictionary = _known_observation_hashes[hash_variant]
		if int(identity.get("observation_seq", -1)) < minimum_sequence:
			_known_observation_hashes.erase(hash_variant)


func _remember_authority_boundary(boundary_hash: String) -> void:
	if not ObservationContract.is_sha256(boundary_hash) \
		or _issued_authority_boundaries.has(boundary_hash):
		return
	_issued_authority_boundaries[boundary_hash] = true
	_issued_authority_boundary_order.append(boundary_hash)
	## A full official match emits far fewer than this. The bound prevents a
	## malformed non-scored harness from growing retained hashes indefinitely.
	while _issued_authority_boundary_order.size() > 1_024:
		var expired: String = str(_issued_authority_boundary_order.pop_front())
		_issued_authority_boundaries.erase(expired)


static func _deep_copy(value: Variant) -> Variant:
	return value.duplicate(true) if typeof(value) in [TYPE_ARRAY, TYPE_DICTIONARY] else value


static func _is_identifier(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
	var regex := RegEx.new()
	if regex.compile("^[a-z0-9][a-z0-9_.:-]{0,95}$") != OK:
		return false
	return regex.search(str(value)) != null


static func _gateway_disposition_reason(disposition: String) -> String:
	match disposition:
		"technical_forfeit_slot_0", "technical_forfeit_slot_1":
			return "model_failure"
		"draw_double_technical_forfeit":
			return "double_technical_forfeit"
		"void_infrastructure":
			return "gateway_infrastructure_failure"
	return ""


static func _contains_secret_key(value: Variant) -> bool:
	if typeof(value) == TYPE_DICTIONARY:
		for key_variant: Variant in (value as Dictionary).keys():
			var key := str(key_variant).to_lower()
			for marker: String in ["api_key", "authorization", "secret", "token"]:
				if marker in key:
					return true
			if _contains_secret_key((value as Dictionary)[key_variant]):
				return true
	elif typeof(value) == TYPE_ARRAY:
		for element: Variant in (value as Array):
			if _contains_secret_key(element):
				return true
	return false


static func _contains_private_replay_key(value: Variant) -> bool:
	if typeof(value) == TYPE_DICTIONARY:
		for key_variant: Variant in (value as Dictionary).keys():
			var key := str(key_variant).to_lower()
			for marker: String in PRIVATE_REPLAY_KEY_MARKERS:
				if marker in key:
					return true
			if _contains_private_replay_key((value as Dictionary)[key_variant]):
				return true
	elif typeof(value) == TYPE_ARRAY:
		for element: Variant in (value as Array):
			if _contains_private_replay_key(element):
				return true
	return false
