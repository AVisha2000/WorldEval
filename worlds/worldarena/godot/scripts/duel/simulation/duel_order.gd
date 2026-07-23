class_name DuelOrder
extends RefCounted

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

enum Status {
	QUEUED = 0,
	ACTIVE = 1,
	COMPLETED = 2,
	CANCELLED = 3,
}

var internal_order_id: int = 0
var owner_seat: int = -1
var actor_id: int = 0
var order_kind: String = "noop"
var issued_tick: int = 0
var activation_tick: int = 0
var command_index: int = 0
var command_digest: String = ""
var status: int = Status.QUEUED
var target: Dictionary = {}


func _init(
	p_internal_order_id: int = 0,
	p_owner_seat: int = -1,
	p_actor_id: int = 0,
	p_order_kind: String = "noop"
) -> void:
	internal_order_id = p_internal_order_id
	owner_seat = p_owner_seat
	actor_id = p_actor_id
	order_kind = p_order_kind


func to_canonical_dict() -> Dictionary:
	return {
		"activation_tick": activation_tick,
		"actor_id": actor_id,
		"command_digest": command_digest,
		"command_index": command_index,
		"internal_order_id": internal_order_id,
		"issued_tick": issued_tick,
		"order_kind": order_kind,
		"owner_seat": owner_seat,
		"status": status,
		"target": target.duplicate(true),
	}


func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if internal_order_id <= 0:
		errors.append("order internal_order_id must be positive")
	if owner_seat < -1 or owner_seat > 1:
		errors.append("order owner_seat must be -1, 0, or 1")
	if actor_id <= 0:
		errors.append("order actor_id must be positive")
	if order_kind.is_empty():
		errors.append("order_kind must not be empty")
	if issued_tick < 0 or activation_tick < issued_tick:
		errors.append("activation_tick must not precede issued_tick")
	if status < Status.QUEUED or status > Status.CANCELLED:
		errors.append("order status is invalid")
	for error: String in Codec.validate_canonical_value(target, "$.target"):
		errors.append(error)
	return errors
