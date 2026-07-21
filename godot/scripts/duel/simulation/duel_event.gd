class_name DuelEvent
extends RefCounted

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

var event_seq: int = 0
var tick: int = 0
var phase: int = 0
var event_kind: String = ""
var source_internal_id: int = 0
var target_internal_id: int = 0
var audience_mask: int = 7
var payload: Dictionary = {}


func _init(p_tick: int = 0, p_phase: int = 0, p_event_kind: String = "") -> void:
	tick = p_tick
	phase = p_phase
	event_kind = p_event_kind


func to_canonical_dict() -> Dictionary:
	return {
		"audience_mask": audience_mask,
		"event_kind": event_kind,
		"event_seq": event_seq,
		"payload": payload.duplicate(true),
		"phase": phase,
		"source_internal_id": source_internal_id,
		"target_internal_id": target_internal_id,
		"tick": tick,
	}


func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if event_seq < 0:
		errors.append("event_seq must be non-negative")
	if tick < 0:
		errors.append("event tick must be non-negative")
	if phase < 1 or phase > 14:
		errors.append("event phase must be in [1, 14]")
	if event_kind.is_empty():
		errors.append("event_kind must not be empty")
	if audience_mask < 0 or audience_mask > 7:
		errors.append("audience_mask must be in [0, 7]")
	for error: String in Codec.validate_canonical_value(payload, "$.payload"):
		errors.append(error)
	return errors
