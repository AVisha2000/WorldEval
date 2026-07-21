class_name DuelMatchController
extends Node

const Host := preload("res://scripts/duel/match/duel_gateway_session_host.gd")
const Client := preload("res://scripts/duel/protocol/duel_gateway_client.gd")
const Session := preload("res://scripts/duel/match/duel_match_session.gd")
const ObservationContract := preload("res://scripts/duel/observations/duel_observation_contract.gd")

## Production lifecycle coordinator. It owns neither model inference nor game
## mechanics: Python schedules providers, DuelGatewaySessionHost authenticates
## the boundary, and DuelMatchSession resolves authority. This Node supplies
## the fixed pause/advance loop and the continuous exact-1x tick clock.

signal authority_ready(mode: String, faction_id: String)
signal observation_emitted(observation_seq: int, tick: int)
signal authority_event(kind: String, payload: Dictionary)
signal match_terminal(result: Dictionary)
signal match_failed(code: String, message: String)
signal match_closed

const TICK_PERIOD_USEC := 100_000
const MAX_CONTINUOUS_LATE_USEC := 250_000
const SUSTAINED_CONTINUOUS_LATE_DEADLINES := 2
const FIXED_PERIOD_TICKS := 100
const CONTINUOUS_PERIOD_TICKS := 50
const GATEWAY_PROCESS_PRIORITY := -100

const LAUNCH_FIELDS: Array[String] = [
	"authority",
	"connection_id",
	"gateway_url",
	"match_id",
	"match_init",
	"protocol_hash",
	"token",
]

var host := Host.new()
var client := Client.new()

var _launch: Dictionary = {}
var _configured: bool = false
var _started: bool = false
var _continuous_clock_active: bool = false
var _next_tick_deadline_usec: int = 0
var _consecutive_continuous_late_deadlines: int = 0
var _terminal_announced: bool = false


func _ready() -> void:
	set_process(false)


func configure_launch(launch: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if _configured or _started:
		errors.append("Duel match controller is already configured")
		return errors
	_validate_exact_fields(launch, LAUNCH_FIELDS, "launch", errors)
	if typeof(launch.get("gateway_url")) != TYPE_STRING \
		or not Client.is_loopback_websocket_url(str(launch.get("gateway_url", ""))):
		errors.append("launch gateway_url must be an explicit loopback WebSocket")
	if not ObservationContract.is_match_id(launch.get("match_id")):
		errors.append("launch match_id is invalid")
	if typeof(launch.get("connection_id")) != TYPE_STRING \
		or str(launch.get("connection_id", "")).is_empty() \
		or str(launch.get("connection_id", "")).length() > 128:
		errors.append("launch connection_id is invalid")
	if typeof(launch.get("token")) != TYPE_PACKED_BYTE_ARRAY \
		or (launch.get("token", PackedByteArray()) as PackedByteArray).size() < 32:
		errors.append("launch token must contain at least 32 protected bytes")
	if typeof(launch.get("authority")) != TYPE_DICTIONARY:
		errors.append("launch authority configuration must be an object")
	if typeof(launch.get("match_init")) != TYPE_DICTIONARY:
		errors.append("launch MATCH_INIT must be a prevalidated object")
	if not ObservationContract.is_sha256(launch.get("protocol_hash")):
		errors.append("launch protocol hash is invalid")
	if not errors.is_empty():
		return errors
	var match_init: Dictionary = launch["match_init"]
	if str(match_init.get("message_type", "")) != "match_init" \
		or str(match_init.get("match_id", "")) != str(launch["match_id"]):
		errors.append("launch MATCH_INIT identity is inconsistent")
	if not errors.is_empty():
		return errors
	var host_errors := host.configure(
		str(launch["match_id"]),
		(launch["token"] as PackedByteArray).duplicate(),
		str(launch["connection_id"]),
		(launch["authority"] as Dictionary).duplicate(true)
	)
	for message: String in host_errors:
		errors.append("authority host: " + message)
	if not errors.is_empty():
		return errors
	var client_errors := client.configure(str(launch["gateway_url"]), host)
	for message: String in client_errors:
		errors.append("gateway client: " + message)
	if not errors.is_empty():
		return errors
	## Once the host has derived its authenticated transport keys and copied its
	## authority material, this coordinator only needs the public MATCH_INIT and
	## protocol hash. Do not retain another session token, gateway capability,
	## tie key, or observer-salt copy for the lifetime of the match.
	_launch = {
		"match_init": (launch["match_init"] as Dictionary).duplicate(true),
		"protocol_hash": str(launch["protocol_hash"]),
	}
	_configured = true
	return errors


func start_match() -> PackedStringArray:
	var errors := PackedStringArray()
	if not _configured or _started:
		errors.append("Duel match controller may start exactly once after configuration")
		return errors
	_started = true
	## Command gates are immediately before tick phase 1.  Poll and drain the
	## authenticated loopback socket before this controller advances the clock,
	## including on a frame that is already late.  Node process order must not
	## decide whether an organizer disposition or the next simulation tick wins.
	client.process_priority = GATEWAY_PROCESS_PRIORITY
	add_child(client)
	client.host_events.connect(_on_host_events)
	client.transport_failed.connect(_on_transport_failed)
	client.transport_closed.connect(_on_transport_closed)
	var connect_errors := client.connect_once()
	for message: String in connect_errors:
		errors.append(message)
	if not errors.is_empty():
		_fail("transport_connect_failed", "; ".join(errors))
	return errors


func _process(_delta: float) -> void:
	if not _continuous_clock_active or host.phase() != Host.PHASE_RUNNING:
		return
	var now := Time.get_ticks_usec()
	if now < _next_tick_deadline_usec:
		return
	var lateness := now - _next_tick_deadline_usec
	if lateness > MAX_CONTINUOUS_LATE_USEC:
		_consecutive_continuous_late_deadlines += 1
		if _consecutive_continuous_late_deadlines >= SUSTAINED_CONTINUOUS_LATE_DEADLINES:
			_void_continuous_clock("continuous_host_rate_breach")
			return
	else:
		_consecutive_continuous_late_deadlines = 0
	var advanced: Dictionary = host.advance_ticks(1)
	if not client.send_host_result(advanced):
		return
	_next_tick_deadline_usec += TICK_PERIOD_USEC
	if host.phase() != Host.PHASE_RUNNING:
		_announce_terminal_if_needed()
		return
	var tick := int(host.session.simulation.state.tick)
	if tick % CONTINUOUS_PERIOD_TICKS == 0:
		_emit_decision_observation(_continuous_skipped_seats())


func _on_host_events(events: Array) -> void:
	for event_variant: Variant in events:
		if typeof(event_variant) != TYPE_DICTIONARY:
			continue
		var event: Dictionary = event_variant
		var kind := str(event.get("kind", ""))
		authority_event.emit(kind, event.duplicate(true))
		match kind:
			"config_accepted":
				_start_configured_authority.call_deferred()
			"fixed_action_pair_applied":
				_advance_fixed_window.call_deferred()
			"continuous_clock_started":
				_activate_continuous_clock()
			"terminal_emitted":
				_announce_terminal_if_needed()
			"artifact_ready":
				_continuous_clock_active = false
				set_process(false)
				client.close()


func _start_configured_authority() -> void:
	if host.phase() != Host.PHASE_RUNNING:
		return
	if not client.send_host_result(host.emit_match_init(
		(_launch["match_init"] as Dictionary).duplicate(true), str(_launch["protocol_hash"])
	)):
		return
	authority_ready.emit(host.session.decision_mode, host.session.faction_id)
	if not _emit_decision_observation({}):
		return


func continuous_clock_active() -> bool:
	return _continuous_clock_active


func next_tick_deadline_usec() -> int:
	return _next_tick_deadline_usec


func _activate_continuous_clock() -> void:
	if _continuous_clock_active:
		_fail("continuous_clock_ambiguous", "continuous clock start event was duplicated")
		return
	if host.phase() != Host.PHASE_RUNNING \
		or host.session == null \
		or host.session.decision_mode != Session.CONTINUOUS_MODE:
		_fail(
			"continuous_clock_start_invalid",
			"continuous clock start event arrived outside a running continuous match"
		)
		return
	_next_tick_deadline_usec = Time.get_ticks_usec() + TICK_PERIOD_USEC
	_consecutive_continuous_late_deadlines = 0
	_continuous_clock_active = true
	set_process(true)


func _advance_fixed_window() -> void:
	if host.phase() != Host.PHASE_RUNNING \
		or host.session.decision_mode != Session.FIXED_MODE:
		_announce_terminal_if_needed()
		return
	var tick := int(host.session.simulation.state.tick)
	var remainder := tick % FIXED_PERIOD_TICKS
	var count := FIXED_PERIOD_TICKS if remainder == 0 else FIXED_PERIOD_TICKS - remainder
	var advanced: Dictionary = host.advance_ticks(count)
	if not client.send_host_result(advanced):
		return
	if host.phase() == Host.PHASE_RUNNING:
		_emit_decision_observation({})
	else:
		_announce_terminal_if_needed()


func _emit_decision_observation(skipped: Dictionary) -> bool:
	var emitted: Dictionary = host.emit_observation_pair(skipped)
	if not client.send_host_result(emitted):
		return false
	if bool(emitted.get("ok", false)):
		var source: Dictionary = emitted.get("observation_result", {})
		observation_emitted.emit(
			int(source.get("observation_seq", -1)), int(source.get("boundary_tick", -1))
		)
	return true


func _continuous_skipped_seats() -> Dictionary:
	var latest := {0: "", 1: ""}
	for row: Dictionary in host.protected_thinking_transcript():
		var seat := int(row.get("player_slot", -1))
		if seat in [0, 1]:
			latest[seat] = str(row.get("status", ""))
	return {
		0: str(latest[0]) == "thinking",
		1: str(latest[1]) == "thinking",
	}


func _void_continuous_clock(reason: String) -> void:
	_continuous_clock_active = false
	set_process(false)
	var disposition: Dictionary = host.session.declare_gateway_disposition("void_infrastructure")
	if not bool(disposition.get("ok", false)):
		_fail("continuous_clock_void_failed", reason)
		return
	if not client.send_host_result(host.emit_terminal_if_ended()):
		return
	_announce_terminal_if_needed()


func _announce_terminal_if_needed() -> void:
	if _terminal_announced or host.session == null \
		or not bool(host.session.simulation.state.terminal["ended"]):
		return
	_terminal_announced = true
	_continuous_clock_active = false
	set_process(false)
	match_terminal.emit(host.session.simulation.terminal_result())


func _on_transport_failed(code: String, message: String) -> void:
	_fail(code, message)


func _on_transport_closed() -> void:
	_continuous_clock_active = false
	set_process(false)
	match_closed.emit()


func _fail(code: String, message: String) -> void:
	_continuous_clock_active = false
	set_process(false)
	match_failed.emit(code, message)


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
