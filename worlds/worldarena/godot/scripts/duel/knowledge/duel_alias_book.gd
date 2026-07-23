class_name DuelAliasBook
extends RefCounted

const KeyedRandom := preload("res://scripts/duel/simulation/duel_keyed_random.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

## Protected, per-observer alias table.  The salt and reverse mapping must never
## be included in a model observation or public replay bundle.

var observer_seat: int = -1
var _alias_salt := PackedByteArray()
var _internal_to_alias: Dictionary = {}
var _alias_to_internal: Dictionary = {}
var _tombstoned_internal_ids: Dictionary = {}
var _configured: bool = false


func configure(p_observer_seat: int, alias_salt: PackedByteArray) -> PackedStringArray:
	var errors := PackedStringArray()
	if p_observer_seat < 0 or p_observer_seat > 1:
		errors.append("observer_seat must be 0 or 1")
	if alias_salt.is_empty():
		errors.append("match alias salt must not be empty")
	if not errors.is_empty():
		return errors
	observer_seat = p_observer_seat
	_alias_salt = alias_salt.duplicate()
	_internal_to_alias.clear()
	_alias_to_internal.clear()
	_tombstoned_internal_ids.clear()
	_configured = true
	return errors


func is_configured() -> bool:
	return _configured


func ensure_alias(internal_id: int) -> String:
	if not _configured or internal_id <= 0:
		return ""
	if _internal_to_alias.has(internal_id):
		return str(_internal_to_alias[internal_id])
	## The message is canonical and frozen as [internal ID, observing seat].
	## A full 256-bit digest avoids collision handling that could depend on
	## entity insertion order.
	var material := Codec.canonical_bytes([internal_id, observer_seat])
	var alias := "e_" + KeyedRandom.hmac_sha256_hex(_alias_salt, material)
	if _alias_to_internal.has(alias):
		push_error("HMAC alias collision")
		return ""
	_internal_to_alias[internal_id] = alias
	_alias_to_internal[alias] = internal_id
	return alias


func alias_if_known(internal_id: int) -> String:
	return str(_internal_to_alias.get(internal_id, ""))


func has_alias(internal_id: int) -> bool:
	return _internal_to_alias.has(internal_id)


func tombstone(internal_id: int) -> bool:
	if not _internal_to_alias.has(internal_id):
		return false
	_tombstoned_internal_ids[internal_id] = true
	return true


func is_tombstoned(internal_id: int) -> bool:
	return _tombstoned_internal_ids.has(internal_id)


func to_protected_canonical_dict() -> Dictionary:
	var ids: Array[int] = []
	for id_variant: Variant in _internal_to_alias.keys():
		ids.append(int(id_variant))
	ids.sort()
	var entries: Array = []
	for internal_id: int in ids:
		entries.append({
			"alias": str(_internal_to_alias[internal_id]),
			"internal_id": internal_id,
			"tombstoned": _tombstoned_internal_ids.has(internal_id),
		})
	return {
		"entries": entries,
		"observer_seat": observer_seat,
	}
