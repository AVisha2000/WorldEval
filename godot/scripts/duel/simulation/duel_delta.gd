class_name DuelDelta
extends RefCounted

enum Kind {
	HP = 1,
	MANA = 2,
	INTEGER_ATTRIBUTE = 3,
}

var application_tick: int = 0
var entity_id: int = 0
var kind: int = Kind.HP
var attribute_key: String = ""
var amount: int = 0
var source_internal_id: int = 0
var local_seq: int = 0


func to_canonical_dict() -> Dictionary:
	return {
		"amount": amount,
		"application_tick": application_tick,
		"attribute_key": attribute_key,
		"entity_id": entity_id,
		"kind": kind,
		"local_seq": local_seq,
		"source_internal_id": source_internal_id,
	}


func stable_key() -> Array[int]:
	return [entity_id, kind, source_internal_id, local_seq]


func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if application_tick < 0:
		errors.append("delta application_tick must be non-negative")
	if entity_id <= 0:
		errors.append("delta entity_id must be positive")
	if kind < Kind.HP or kind > Kind.INTEGER_ATTRIBUTE:
		errors.append("delta kind is invalid")
	if kind == Kind.INTEGER_ATTRIBUTE and attribute_key.is_empty():
		errors.append("attribute delta requires attribute_key")
	if local_seq < 0:
		errors.append("delta local_seq must be non-negative")
	return errors
