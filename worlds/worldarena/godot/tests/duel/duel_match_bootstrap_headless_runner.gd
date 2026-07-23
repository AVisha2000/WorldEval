extends SceneTree

const Bootstrap := preload("res://scripts/duel/match/duel_match_bootstrap.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const EXPECTED_AGGREGATE_HASH := "192c85011d2943ab1bedf077cbee432fd0fcf160ea764d3f907d172da819fe3b"

var _failures := PackedStringArray()


func _init() -> void:
	var summaries: Dictionary = {}
	for faction_id: String in ["crypt-v1", "grove-v1", "vanguard-v1", "warhost-v1"]:
		var first := Bootstrap.create_official({"faction_id": faction_id, "match_seed": 90210})
		var second := Bootstrap.create_official({"faction_id": faction_id, "match_seed": 90210})
		_check(bool(first["ok"]), "%s bootstrap failed: %s" % [
			faction_id, "; ".join(first["errors"]),
		])
		if not bool(first["ok"]):
			continue
		var sim = first["simulation"]
		var second_sim = second["simulation"]
		_check(sim.checkpoint_hash() == second_sim.checkpoint_hash(),
			"%s fresh bootstraps diverged" % faction_id)
		_check(sim.state.entities.size() == 22, "%s must start with 14 spawns and 8 resources" % faction_id)
		_check(sim.state.economy.players.size() == 2, "%s did not configure both economies" % faction_id)
		for seat: int in [0, 1]:
			var player: Dictionary = sim.state.economy.players[seat]
			_check(int(player["gold"]) == 500 and int(player["lumber"]) == 200,
				"%s seat %d starting resources are wrong" % [faction_id, seat])
			_check(int(player["food_capacity"]) == 20 and int(player["food_used"]) == 5,
				"%s seat %d starting food is wrong" % [faction_id, seat])
			_check((first["registry"]["spawn_ids_by_seat"][seat] as Array).size() == 7,
				"%s seat %d starting entity registry is incomplete" % [faction_id, seat])
		_check(sim.state.economy.resource_nodes.size() == 8,
			"%s did not register all eight resource sites" % faction_id)
		_check(sim.validate().is_empty(), "%s bootstrapped state failed validation" % faction_id)
		if faction_id == "crypt-v1":
			_check(_count_catalog(sim, 0, "acolyte") == 3 and _count_catalog(sim, 0, "ghast") == 2,
				"Crypt starting 3 Acolyte / 2 Ghast split is wrong")
		summaries[faction_id] = {
			"checkpoint_hash": sim.checkpoint_hash(),
			"entities": sim.state.entities.size(),
			"runtime_hash": first["runtime"]["runtime_hash"],
		}

	var aggregate_hash := Codec.sha256_canonical(summaries)
	if not EXPECTED_AGGREGATE_HASH.is_empty():
		_check(aggregate_hash == EXPECTED_AGGREGATE_HASH,
			"match bootstrap aggregate hash changed: %s" % aggregate_hash)
	_test_fail_closed()
	_test_scored_boundary()
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_MATCH_BOOTSTRAP_FAILURE: %s" % failure)
		print("DUEL_MATCH_BOOTSTRAP_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("DUEL_MATCH_BOOTSTRAP_OK hash=%s summaries=%s" % [
		aggregate_hash, JSON.stringify(summaries),
	])
	quit(0)


func _test_fail_closed() -> void:
	_check(not bool(Bootstrap.create_official({"faction_id": "unknown-v1"})["ok"]),
		"unknown faction bootstrap succeeded")
	_check(not bool(Bootstrap.create_official({"match_seed": -1})["ok"]),
		"negative seed bootstrap succeeded")
	_check(not bool(Bootstrap.create_official({"unexpected": true})["ok"]),
		"unknown bootstrap option succeeded")
	_check(not bool(Bootstrap.create_official({
		"scored": true,
		"authoritative_hashes": {},
	})["ok"]), "scored bootstrap accepted missing hash commitments")


func _test_scored_boundary() -> void:
	var reference := Bootstrap.create_official({"faction_id": "vanguard-v1", "match_seed": 44})
	_check(bool(reference["ok"]), "unscored scored-boundary reference failed")
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
		"tie_key_commitment": "1".repeat(64),
	}
	var scored := Bootstrap.create_official({
		"authoritative_hashes": hashes,
		"faction_id": "vanguard-v1",
		"match_seed": 44,
		"scored": true,
	})
	_check(bool(scored["ok"]), "valid scored bootstrap failed: %s" % "; ".join(scored["errors"]))
	var tampered := hashes.duplicate(true)
	tampered["map_hash"] = "f".repeat(64)
	_check(not bool(Bootstrap.create_official({
		"authoritative_hashes": tampered,
		"faction_id": "vanguard-v1",
		"match_seed": 44,
		"scored": true,
	})["ok"]), "scored bootstrap accepted the wrong map hash")


func _count_catalog(sim: Variant, seat: int, catalog_id: String) -> int:
	var count := 0
	for entity_id: int in sim.state.sorted_entity_ids():
		var entity = sim.state.entities[entity_id]
		if entity.owner_seat == seat and entity.catalog_id == catalog_id:
			count += 1
	return count


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
