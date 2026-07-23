extends SceneTree

const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const RuntimeCatalog := preload("res://scripts/duel/protocol/duel_runtime_catalog.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const EXPECTED_AGGREGATE_HASH := "de9b8d52f4cbd75280890b612c1b008d9638c8b08502b1f926711fcbccc17a42"

var _failures := PackedStringArray()


func _init() -> void:
	var loaded := CatalogLoader.load_official_catalogs()
	_check(bool(loaded["ok"]), "official catalogs failed to load")
	var hashes: Dictionary = {}
	for faction_id: String in CatalogLoader.official_faction_ids():
		var first := RuntimeCatalog.compile_selected_faction(faction_id, loaded)
		var second := RuntimeCatalog.compile_selected_faction(faction_id, loaded)
		_check(bool(first["ok"]), "%s runtime compile failed: %s" % [
			faction_id, "; ".join(first["errors"]),
		])
		if not bool(first["ok"]):
			continue
		var runtime: Dictionary = first["runtime"]
		var economy: Dictionary = runtime["economy"]
		_check(runtime == second["runtime"], "%s runtime compile is not repeatable" % faction_id)
		_check(economy["structures"].size() == 11, "%s must compile 11 structures" % faction_id)
		_check(economy["units"].size() == 9, "%s must compile 9 regular units" % faction_id)
		var expected_upgrade_count := 6 + int(
			loaded["catalogs"]["faction:%s" % faction_id]["upgrades"]["faction_specific"].size()
		)
		_check(economy["upgrades"].size() == expected_upgrade_count,
			"%s compiled the wrong number of upgrade lines" % faction_id)
		_check(runtime["heroes"].size() == 3, "%s must expose 3 Heroes" % faction_id)
		_check(runtime["structure_type_by_role"].size() == 11, "%s role map is incomplete" % faction_id)
		var starting_worker := str(runtime["starting_state"]["worker_type_id"])
		_check(economy["units"].has(starting_worker), "%s starting worker is absent" % faction_id)
		var stronghold_type := str(runtime["structure_type_by_role"]["stronghold"])
		_check(economy["structures"].has(stronghold_type), "%s Stronghold type is absent" % faction_id)
		_check(str(runtime["structure_role_by_type_id"][stronghold_type]) == "stronghold",
			"%s Stronghold reverse map is wrong" % faction_id)
		_check(str(runtime["runtime_hash"]) == str(second["runtime"]["runtime_hash"]),
			"%s runtime hash changed between identical compiles" % faction_id)
		hashes[faction_id] = runtime["runtime_hash"]
		if faction_id == "crypt-v1":
			_check(economy["units"]["acolyte"]["gather_profiles"].has("gold"),
				"Crypt Acolyte cannot gather gold")
			_check(not economy["units"]["acolyte"]["gather_profiles"].has("lumber"),
				"Crypt Acolyte incorrectly gathers lumber")
			_check(economy["units"]["ghast"]["gather_profiles"].has("lumber"),
				"Crypt Ghast cannot gather lumber")
		if faction_id == "grove-v1":
			_check(int(economy["units"]["wisp"]["gather_profiles"]["lumber"]["cargo"]) == 8,
				"Grove Wisp lumber cargo override is missing")

	var aggregate_hash := Codec.sha256_canonical(hashes)
	if not EXPECTED_AGGREGATE_HASH.is_empty():
		_check(aggregate_hash == EXPECTED_AGGREGATE_HASH,
			"runtime catalog aggregate hash changed: %s" % aggregate_hash)
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_RUNTIME_CATALOG_FAILURE: %s" % failure)
		print("DUEL_RUNTIME_CATALOG_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("DUEL_RUNTIME_CATALOG_OK hash=%s factions=%s" % [aggregate_hash, JSON.stringify(hashes)])
	quit(0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
