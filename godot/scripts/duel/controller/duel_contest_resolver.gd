class_name DuelContestResolver
extends RefCounted

const KeyedRandom := preload("res://scripts/duel/simulation/duel_keyed_random.gd")

## One deterministic resolver for finite same-tick exclusive claims.
##
## Callers collect only individually legal atomic claims from a frozen state.
## Capacity is consumed one charge at a time, re-ranking the remaining claims
## with the protected HMAC tie key for each canonical charge-index group.


func resolve(
	tick: int,
	claims_input: Array[Dictionary],
	capacities_input: Dictionary,
	protected_tie_key: PackedByteArray
) -> Dictionary:
	var errors := PackedStringArray()
	if tick < 0:
		errors.append("contest tick must be non-negative")
	if protected_tie_key.is_empty():
		errors.append("contest resolver requires a protected tie key")
	var claims: Array[Dictionary] = []
	var seen_claim_ids: Dictionary = {}
	for claim_input: Dictionary in claims_input:
		var claim := claim_input.duplicate(true)
		var code := _claim_code(claim)
		if not code.is_empty():
			errors.append(code)
			continue
		var claim_id := str(claim["claim_id"])
		if seen_claim_ids.has(claim_id):
			errors.append("duplicate contest claim ID")
			continue
		seen_claim_ids[claim_id] = true
		claims.append(claim)
	for group_variant: Variant in capacities_input.keys():
		if typeof(group_variant) != TYPE_STRING \
			or typeof(capacities_input[group_variant]) != TYPE_INT \
			or int(capacities_input[group_variant]) < 0:
			errors.append("contest capacity map is invalid")
	if not errors.is_empty():
		return {
			"accepted_claim_ids": [], "audit": [], "errors": errors,
			"rejected_claim_ids": [],
		}

	var groups: Dictionary = {}
	for claim: Dictionary in claims:
		var group_id := _group_id(str(claim["claim_kind"]), str(claim["object_id"]))
		if not groups.has(group_id):
			groups[group_id] = []
		(groups[group_id] as Array).append(claim)

	var accepted: Array[String] = []
	var rejected: Array[String] = []
	var audit: Array[Dictionary] = []
	var group_ids: Array = groups.keys()
	group_ids.sort()
	for group_variant: Variant in group_ids:
		var group_id := str(group_variant)
		var group: Array = groups[group_id]
		var capacity := int(capacities_input.get(group_id, 0))
		var resolution := _resolve_group(tick, group, capacity, protected_tie_key)
		accepted.append_array(resolution["accepted_claim_ids"])
		rejected.append_array(resolution["rejected_claim_ids"])
		audit.append_array(resolution["audit"])
	accepted.sort()
	rejected.sort()
	return {
		"accepted_claim_ids": accepted,
		"audit": audit,
		"errors": errors,
		"rejected_claim_ids": rejected,
	}


static func group_id(claim_kind: String, object_id: String) -> String:
	return _group_id(claim_kind, object_id)


func _resolve_group(
	tick: int,
	group_input: Array,
	capacity: int,
	protected_tie_key: PackedByteArray
) -> Dictionary:
	var remaining: Array[Dictionary] = []
	for claim_variant: Variant in group_input:
		remaining.append((claim_variant as Dictionary).duplicate(true))
	remaining.sort_custom(_claim_id_less)
	var accepted: Array[String] = []
	var audit: Array[Dictionary] = []
	var claim_kind := str(remaining[0]["claim_kind"]) if not remaining.is_empty() else ""
	var object_id := str(remaining[0]["object_id"]) if not remaining.is_empty() else ""
	for charge_index: int in mini(capacity, remaining.size()):
		var group_key := "%d|%s|%s|%d" % [tick, claim_kind, object_id, charge_index]
		var ranked := KeyedRandom.rank_claimants(protected_tie_key, group_key, remaining)
		var winner: Dictionary = ranked[0]
		var winner_id := str(winner["claim_id"])
		accepted.append(winner_id)
		var ranking: Array[Dictionary] = []
		for ranked_claim: Dictionary in ranked:
			ranking.append({
				"claim_id": str(ranked_claim["claim_id"]),
				"internal_actor_id": int(ranked_claim["internal_actor_id"]),
				"rank_digest": str(ranked_claim["rank_digest"]),
			})
		audit.append({
			"charge_index": charge_index,
			"claim_kind": claim_kind,
			"group_key": group_key,
			"object_id": object_id,
			"ranking": ranking,
			"tick": tick,
			"winner_claim_id": winner_id,
		})
		var next_remaining: Array[Dictionary] = []
		for candidate: Dictionary in remaining:
			if str(candidate["claim_id"]) != winner_id:
				next_remaining.append(candidate)
		remaining = next_remaining
	var rejected: Array[String] = []
	for claim: Dictionary in remaining:
		rejected.append(str(claim["claim_id"]))
	accepted.sort()
	rejected.sort()
	return {
		"accepted_claim_ids": accepted,
		"rejected_claim_ids": rejected,
		"audit": audit,
	}


static func _claim_code(claim: Dictionary) -> String:
	for field: String in ["canonical_command_digest", "claim_id", "claim_kind", "object_id"]:
		if typeof(claim.get(field, null)) != TYPE_STRING or str(claim[field]).is_empty():
			return "contest claim %s is invalid" % field
	if str(claim["canonical_command_digest"]).length() != 64:
		return "contest claim command digest is invalid"
	if typeof(claim.get("internal_actor_id", null)) != TYPE_INT \
		or int(claim["internal_actor_id"]) <= 0:
		return "contest claim actor is invalid"
	return ""


static func _group_id(claim_kind: String, object_id: String) -> String:
	return "%s|%s" % [claim_kind, object_id]


static func _claim_id_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left["claim_id"]) < str(right["claim_id"])
