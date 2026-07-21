class_name DuelKeyedRandom
extends RefCounted

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

## Counter-based/keyed randomness. There is deliberately no mutable PRNG state.


static func stream_digest(
	ruleset_hash: String,
	match_seed: int,
	stream: String,
	tick: int,
	subject_id: int,
	contest_id: String
) -> String:
	var material := "%s|%d|%s|%d|%d|%s" % [
		ruleset_hash, match_seed, stream, tick, subject_id, contest_id,
	]
	return Codec.sha256_text(material)


static func hmac_sha256_hex(key: PackedByteArray, message: PackedByteArray) -> String:
	var context := HMACContext.new()
	var start_error := context.start(HashingContext.HASH_SHA256, key)
	if start_error != OK:
		push_error("Failed to initialize HMAC-SHA256 context: %d" % start_error)
		return ""
	var update_error := context.update(message)
	if update_error != OK:
		push_error("Failed to update HMAC-SHA256 context: %d" % update_error)
		return ""
	return context.finish().hex_encode()


static func contest_rank_digest(
	protected_tie_key: PackedByteArray,
	group_key: String,
	canonical_command_digest: String,
	internal_actor_id: int
) -> String:
	var material := "%s|%s|%d" % [
		group_key, canonical_command_digest, internal_actor_id,
	]
	return hmac_sha256_hex(protected_tie_key, material.to_utf8_buffer())


static func rank_claimants(
	protected_tie_key: PackedByteArray,
	group_key: String,
	claims: Array[Dictionary]
) -> Array[Dictionary]:
	var ranked: Array[Dictionary] = []
	for claim: Dictionary in claims:
		var actor_id := int(claim.get("internal_actor_id", 0))
		var command_digest := str(claim.get("canonical_command_digest", ""))
		var ranked_claim := claim.duplicate(true)
		ranked_claim["rank_digest"] = contest_rank_digest(
			protected_tie_key, group_key, command_digest, actor_id
		)
		ranked.append(ranked_claim)
	ranked.sort_custom(_claim_less)
	return ranked


static func _claim_less(left: Dictionary, right: Dictionary) -> bool:
	var left_digest := str(left["rank_digest"])
	var right_digest := str(right["rank_digest"])
	if left_digest != right_digest:
		return left_digest < right_digest
	return int(left.get("internal_actor_id", 0)) < int(right.get("internal_actor_id", 0))
