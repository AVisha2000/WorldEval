extends SceneTree

const Bootstrap := preload("res://scripts/duel/match/duel_match_bootstrap.gd")
const MatchRuntime := preload("res://scripts/duel/match/duel_match_runtime.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const GOLDEN_AGGREGATE_HASH := "15ef8f81c4ad43c4cfb64132e9459046677e483c277b73232f6ce3f944a8213d"

var _failures := PackedStringArray()


func _init() -> void:
	var hashes: Dictionary = {}
	for faction_id: String in ["crypt-v1", "grove-v1", "vanguard-v1", "warhost-v1"]:
		var key := ("runtime-secret:%s" % faction_id).to_utf8_buffer()
		var first_bootstrap := Bootstrap.create_official({
			"faction_id": faction_id, "match_seed": 77,
		})
		var second_bootstrap := Bootstrap.create_official({
			"faction_id": faction_id, "match_seed": 77,
		})
		var first := MatchRuntime.attach_protected_authority(first_bootstrap, key)
		var second := MatchRuntime.attach_protected_authority(second_bootstrap, key)
		_check(bool(first["ok"]), "%s protected runtime failed: %s" % [
			faction_id, "; ".join(first["errors"]),
		])
		if not bool(first["ok"]):
			continue
		_check((first["registered_movement_entity_ids"] as Array).size() == 10,
			"%s did not register ten starting workers/special workers" % faction_id)
		_check(first["simulation"].state.movement.protected_tie_key_digest == Codec.sha256_bytes(key),
			"%s canonical movement commitment is wrong" % faction_id)
		_check(first["simulation"].checkpoint_hash() == second["simulation"].checkpoint_hash(),
			"%s protected runtime is not repeatable" % faction_id)
		_check(first["simulation"].validate().is_empty(),
			"%s protected runtime state failed validation" % faction_id)
		hashes[faction_id] = first["simulation"].checkpoint_hash()

	_test_scored_commitment()
	_test_rejections()
	var aggregate := Codec.sha256_canonical(hashes)
	if not GOLDEN_AGGREGATE_HASH.is_empty():
		_check(aggregate == GOLDEN_AGGREGATE_HASH,
			"protected runtime aggregate hash changed: %s" % aggregate)
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_MATCH_RUNTIME_FAILURE: %s" % failure)
		print("DUEL_MATCH_RUNTIME_FAILED count=%d hash=%s" % [_failures.size(), aggregate])
		quit(1)
		return
	print("DUEL_MATCH_RUNTIME_OK hash=%s factions=%s" % [aggregate, JSON.stringify(hashes)])
	quit(0)


func _test_scored_commitment() -> void:
	var key := "scored-protected-secret".to_utf8_buffer()
	var reference := Bootstrap.create_official({"faction_id": "vanguard-v1", "match_seed": 9})
	_check(bool(reference["ok"]), "scored runtime reference bootstrap failed")
	if not bool(reference["ok"]):
		return
	var state = reference["simulation"].state
	var hashes := {
		"engine_build_hash": "0".repeat(64),
		"faction_hash": state.faction_hash,
		"helper_hash": state.helper_hash,
		"item_hash": state.item_hash,
		"map_hash": state.map_hash,
		"neutral_hash": state.neutral_hash,
		"prompt_hash": state.prompt_hash,
		"protocol_hash": state.protocol_hash,
		"ruleset_hash": state.ruleset_hash,
		"tie_key_commitment": Codec.sha256_bytes(key),
	}
	var scored := Bootstrap.create_official({
		"authoritative_hashes": hashes,
		"faction_id": "vanguard-v1",
		"match_seed": 9,
		"scored": true,
	})
	_check(bool(MatchRuntime.attach_protected_authority(scored, key)["ok"]),
		"matching scored protected key was rejected")
	var wrong_key_result := MatchRuntime.attach_protected_authority(
		Bootstrap.create_official({
			"authoritative_hashes": hashes,
			"faction_id": "vanguard-v1",
			"match_seed": 9,
			"scored": true,
		}),
		"wrong-key".to_utf8_buffer()
	)
	_check(not bool(wrong_key_result["ok"]),
		"wrong scored protected key bypassed its commitment")


func _test_rejections() -> void:
	_check(not bool(MatchRuntime.attach_protected_authority({}, PackedByteArray([1]))["ok"]),
		"invalid bootstrap result was accepted")
	var bootstrap := Bootstrap.create_official({"faction_id": "vanguard-v1", "match_seed": 1})
	_check(not bool(MatchRuntime.attach_protected_authority(
		bootstrap, PackedByteArray()
	)["ok"]), "empty protected key was accepted")
	var attached := MatchRuntime.attach_protected_authority(
		bootstrap, "one-key".to_utf8_buffer()
	)
	_check(bool(attached["ok"]), "rejection fixture first attach failed")
	_check(not bool(MatchRuntime.attach_protected_authority(
		bootstrap, "second-key".to_utf8_buffer()
	)["ok"]), "protected authority attached twice")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
