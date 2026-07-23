class_name DuelOfficialReplayPlayer
extends RefCounted

const OfficialRunner := preload(
	"res://scripts/duel/replay/duel_official_replay_runner.gd"
)

## Deterministic, provider/network-free playback of integrity-verified replay
## evidence.  This player never receives DuelMatchSession, DuelSimulation, a
## socket, or a provider adapter.  Authority-ready controls remain false until
## the verifier has actually recomputed every checkpoint.

signal state_changed(state: Dictionary)
signal perspective_changed(perspective_id: String, record: Dictionary)

const SPEED_QUARTERS := {
	"0.25": 1,
	"0.5": 2,
	"1.0": 4,
	"2.0": 8,
	"4.0": 16,
}
const SIMULATION_HZ := 10
const WALLCLOCK_UNIT_THRESHOLD := 4_000
const PERSPECTIVES: Array[String] = ["omniscient", "seat_0", "seat_1"]

var _loaded := false
var _integrity_verified := false
var _authority_replay_ready := false
var _verification_code := "not_loaded"
var _evidence: Dictionary = {}
var _tick := 0
var _maximum_tick := 0
var _paused := true
var _speed_quarters := 4
var _elapsed_units := 0
var _perspective_id := "omniscient"


func load_verification(verification: Dictionary) -> Dictionary:
	_reset()
	if verification.get("integrity_verified") != true \
		or typeof(verification.get("evidence")) != TYPE_DICTIONARY:
		return _failure(
			str(verification.get("code", "replay_integrity_not_verified")),
			"player requires an integrity-verified replay result"
		)
	_evidence = (verification["evidence"] as Dictionary).duplicate(true)
	_integrity_verified = true
	_authority_replay_ready = bool(verification.get("authority_replay_ready", false))
	if _authority_replay_ready \
		and typeof(_evidence.get("perspectives")) != TYPE_DICTIONARY:
		_reset()
		return _failure(
			"verified_perspectives_missing",
			"authority-ready replay evidence has no verified perspective projections"
		)
	_verification_code = str(verification.get("code", "unknown"))
	_maximum_tick = maxi(0, int(_evidence.get("maximum_tick", 0)))
	_loaded = true
	_emit_state()
	return {
		"authority_replay_ready": _authority_replay_ready,
		"code": _verification_code,
		"errors": PackedStringArray(),
		"ok": true,
		"state": replay_state(),
	}


func is_loaded() -> bool:
	return _loaded


func set_paused(value: bool) -> Dictionary:
	if not _loaded:
		return _failure("replay_not_loaded", "no replay evidence is loaded")
	_paused = value
	_emit_state()
	return _success()


func set_playback_speed(value: float) -> Dictionary:
	if not _loaded:
		return _failure("replay_not_loaded", "no replay evidence is loaded")
	var key := _speed_key(value)
	if not SPEED_QUARTERS.has(key):
		return _failure("invalid_playback_speed", "playback speed is not an allowed preset")
	_speed_quarters = int(SPEED_QUARTERS[key])
	_elapsed_units = 0
	_emit_state()
	return _success()


func advance_elapsed_ms(elapsed_ms: int) -> Dictionary:
	if not _loaded:
		return _failure("replay_not_loaded", "no replay evidence is loaded")
	if elapsed_ms < 0:
		return _failure("invalid_elapsed_time", "elapsed milliseconds must be non-negative")
	if _paused or _tick >= _maximum_tick:
		return _success()
	_elapsed_units += elapsed_ms * SIMULATION_HZ * _speed_quarters
	var tick_count := int(_elapsed_units / WALLCLOCK_UNIT_THRESHOLD)
	_elapsed_units %= WALLCLOCK_UNIT_THRESHOLD
	if tick_count > 0:
		_seek_internal(_tick + tick_count)
	return _success()


func step_ticks(count: int = 1) -> Dictionary:
	if not _loaded:
		return _failure("replay_not_loaded", "no replay evidence is loaded")
	if count < 0:
		return _failure("invalid_step_count", "replay step count must be non-negative")
	return _seek_with_authority(_tick + count)


func seek_tick(target_tick: int) -> Dictionary:
	if not _loaded:
		return _failure("replay_not_loaded", "no replay evidence is loaded")
	if target_tick < 0:
		return _failure("invalid_seek_tick", "replay seek tick must be non-negative")
	return _seek_with_authority(target_tick)


func set_perspective(perspective_id: String) -> Dictionary:
	if not _loaded:
		return _failure("replay_not_loaded", "no replay evidence is loaded")
	if perspective_id not in PERSPECTIVES:
		return _failure("invalid_replay_perspective", "replay perspective is invalid")
	if perspective_id == "omniscient" and _authority_replay_ready:
		var projected := _ensure_omniscient_projection(_tick)
		if not bool(projected.get("ok", false)):
			return projected
	_perspective_id = perspective_id
	var record := current_perspective_record()
	perspective_changed.emit(_perspective_id, record.duplicate(true))
	_emit_state()
	if not bool(record.get("available", false)):
		return {
			"code": str(record.get("code", "perspective_evidence_unavailable")),
			"errors": PackedStringArray([str(record.get("reason", "perspective unavailable"))]),
			"ok": false,
			"record": record,
		}
	return {"code": "ok", "errors": PackedStringArray(), "ok": true, "record": record}


func replay_state() -> Dictionary:
	return {
		"authority_replay_ready": _authority_replay_ready,
		"checkpoint_status": "matched" if _authority_replay_ready else _verification_code,
		"integrity_verified": _integrity_verified,
		"maximum_tick": _maximum_tick,
		"paused": _paused,
		"perspective_id": _perspective_id,
		"replay": _loaded,
		"speed": float(_speed_quarters) / 4.0,
		"tick": _tick,
		# The HUD's verified affordances mean authority hashes were reproduced,
		# never merely that the archive bytes were internally consistent.
		"verified": _authority_replay_ready,
		"verification_code": _verification_code,
	}


func visible_public_events() -> Array:
	var result: Array = []
	for event_variant: Variant in _evidence.get("public_events", []):
		if typeof(event_variant) != TYPE_DICTIONARY:
			continue
		var event: Dictionary = event_variant
		if int(event.get("tick", 0)) > _tick:
			break
		result.append(event.duplicate(true))
	return result


func visible_accepted_actions() -> Array:
	var result: Array = []
	for row_variant: Variant in _evidence.get("accepted_actions", []):
		if typeof(row_variant) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = row_variant
		if int(row.get("application_tick", 0)) > _tick:
			break
		result.append(row.duplicate(true))
	return result


func visible_compiled_orders() -> Array:
	var result: Array = []
	for row_variant: Variant in _evidence.get("compiled_orders", []):
		if typeof(row_variant) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = row_variant
		if int(row.get("application_tick", 0)) > _tick:
			break
		result.append(row.duplicate(true))
	return result


func current_perspective_record() -> Dictionary:
	if not _loaded:
		return _unavailable("replay_not_loaded", "no replay evidence is loaded")
	if _perspective_id == "omniscient":
		var perspectives: Variant = _evidence.get("perspectives")
		if typeof(perspectives) != TYPE_DICTIONARY:
			return _unavailable(
				"omniscient_projection_evidence_unavailable",
				"the current replay has no authority-verified omniscient snapshots"
			)
		var selected_frame: Dictionary = {}
		for frame_variant: Variant in perspectives.get("omniscient", []):
			if typeof(frame_variant) != TYPE_DICTIONARY:
				continue
			var frame: Dictionary = frame_variant
			if int(frame.get("tick", 0)) > _tick:
				break
			selected_frame = frame
		if selected_frame.is_empty() \
			or typeof(selected_frame.get("projection")) != TYPE_DICTIONARY:
			return _unavailable(
				"omniscient_projection_not_recorded_at_tick",
				"no authority-verified omniscient projection exists at or before this tick"
			)
		return {
			"available": true,
			"kind": "verified_omniscient_authority",
			"perspective_id": "omniscient",
			"projection": selected_frame["projection"].duplicate(true),
			"recorded_tick": int(selected_frame["tick"]),
			"requested_tick": _tick,
			"stale_ticks": _tick - int(selected_frame["tick"]),
		}
	var observations: Variant = _evidence.get("observations")
	if typeof(observations) != TYPE_DICTIONARY:
		return _unavailable(
			"player_projection_evidence_unavailable",
			"the protected replay has no player observation evidence"
		)
	var timeline: Array = observations.get(_perspective_id, [])
	var selected: Dictionary = {}
	for row_variant: Variant in timeline:
		if typeof(row_variant) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = row_variant
		if int(row.get("tick", 0)) > _tick:
			break
		selected = row
	if selected.is_empty():
		return _unavailable(
			"player_projection_not_recorded_at_tick",
			"no legal player observation has been recorded at or before this tick"
		)
	return {
		"available": true,
		"kind": "recorded_legal_observation",
		"observation": selected["observation"].duplicate(true),
		"observation_seq": int(selected["observation_seq"]),
		"perspective_id": _perspective_id,
		"recorded_tick": int(selected["tick"]),
		"requested_tick": _tick,
		"stale_ticks": _tick - int(selected["tick"]),
	}


func evidence_copy() -> Dictionary:
	return _evidence.duplicate(true)


func _seek_internal(target_tick: int) -> void:
	_tick = clampi(target_tick, 0, _maximum_tick)
	_elapsed_units = 0
	var record := current_perspective_record()
	perspective_changed.emit(_perspective_id, record.duplicate(true))
	_emit_state()


func _seek_with_authority(target_tick: int) -> Dictionary:
	var bounded := clampi(target_tick, 0, _maximum_tick)
	if _authority_replay_ready:
		var projected := _ensure_omniscient_projection(bounded)
		if not bool(projected.get("ok", false)):
			return projected
	_seek_internal(bounded)
	return _success()


func _ensure_omniscient_projection(target_tick: int) -> Dictionary:
	var perspectives: Variant = _evidence.get("perspectives")
	if typeof(perspectives) == TYPE_DICTIONARY:
		for frame_variant: Variant in perspectives.get("omniscient", []):
			if typeof(frame_variant) == TYPE_DICTIONARY \
				and int(frame_variant.get("tick", -1)) == target_tick \
				and typeof(frame_variant.get("projection")) == TYPE_DICTIONARY:
				return {"code": "ok", "errors": PackedStringArray(), "ok": true}
	return _resimulate_projection(target_tick)


func _resimulate_projection(target_tick: int) -> Dictionary:
	var replayed: Dictionary = OfficialRunner.new().verify(_evidence, [target_tick])
	if not bool(replayed.get("ok", false)):
		return {
			"code": str(replayed.get("code", "replay_seek_verification_failed")),
			"errors": replayed.get("errors", PackedStringArray([
				"authority replay failed while reconstructing the requested tick",
			])),
			"ok": false,
		}
	_evidence["perspectives"] = replayed["perspectives"].duplicate(true)
	return {"code": "ok", "errors": PackedStringArray(), "ok": true}


func _emit_state() -> void:
	state_changed.emit(replay_state().duplicate(true))


func _reset() -> void:
	_loaded = false
	_integrity_verified = false
	_authority_replay_ready = false
	_verification_code = "not_loaded"
	_evidence.clear()
	_tick = 0
	_maximum_tick = 0
	_paused = true
	_speed_quarters = 4
	_elapsed_units = 0
	_perspective_id = "omniscient"


func _success() -> Dictionary:
	return {
		"code": "ok",
		"errors": PackedStringArray(),
		"ok": true,
		"state": replay_state(),
	}


static func _failure(code: String, message: String) -> Dictionary:
	return {"code": code, "errors": PackedStringArray([message]), "ok": false}


static func _unavailable(code: String, reason: String) -> Dictionary:
	return {"available": false, "code": code, "reason": reason}


static func _speed_key(value: float) -> String:
	if is_equal_approx(value, 0.25):
		return "0.25"
	if is_equal_approx(value, 0.5):
		return "0.5"
	if is_equal_approx(value, 1.0):
		return "1.0"
	if is_equal_approx(value, 2.0):
		return "2.0"
	if is_equal_approx(value, 4.0):
		return "4.0"
	return ""
