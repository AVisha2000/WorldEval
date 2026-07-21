extends SceneTree

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")

var _failures := PackedStringArray()


func _init() -> void:
	_test_integer_boundary()
	var first := CatalogLoader.load_official_catalogs()
	var reverse_order := CatalogLoader.official_catalog_keys()
	reverse_order.reverse()
	var second := CatalogLoader.load_official_catalogs(reverse_order)
	_check_load(first, "canonical-order load")
	_check_load(second, "reverse-order load")
	if bool(first.get("ok", false)) and bool(second.get("ok", false)):
		_test_repeatability(first, second)
		_test_public_bundles(first, second)

	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_CATALOG_FAILURE: %s" % failure)
		print("DUEL_CATALOGS_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("DUEL_CATALOGS_OK hash=%s" % str(first["aggregate_hash"]))
	quit(0)


func _test_integer_boundary() -> void:
	var valid := CatalogLoader.normalize_json_boundary({
		"nested": [42.0, -7.0, 9_007_199_254_740_990.0, 9_007_199_254_740_991],
	})
	_check(
		bool(valid["ok"]),
		"integral safe JSON floats were rejected: %s" % "; ".join(valid["errors"])
	)
	if bool(valid["ok"]):
		var normalized: Dictionary = valid["value"]
		var nested: Array = normalized["nested"]
		_check(typeof(nested[0]) == TYPE_INT, "integral JSON float was not converted to int")
		_check(int(nested[2]) == 9_007_199_254_740_990, "safe integral float changed")
		_check(int(nested[3]) == 9_007_199_254_740_991, "maximum safe integer changed")
	_check(
		not bool(CatalogLoader.normalize_json_boundary({"fraction": 1.25})["ok"]),
		"fractional authoritative number was accepted"
	)
	_check(
		not bool(CatalogLoader.normalize_json_boundary({"infinite": INF})["ok"]),
		"non-finite authoritative number was accepted"
	)
	_check(
		not bool(CatalogLoader.normalize_json_boundary({
			"unsafe": 9_007_199_254_740_992.0,
		})["ok"]),
		"unsafe authoritative number was accepted"
	)
	_check(
		not bool(CatalogLoader.normalize_json_boundary({"engine_type": Vector2i.ZERO})["ok"]),
		"unsupported engine Variant was accepted at the catalog boundary"
	)


func _check_load(result: Dictionary, label: String) -> void:
	if bool(result.get("ok", false)):
		return
	var details := PackedStringArray()
	var errors_variant: Variant = result.get("errors", [])
	if typeof(errors_variant) == TYPE_PACKED_STRING_ARRAY:
		details.append_array(errors_variant)
	elif typeof(errors_variant) == TYPE_ARRAY:
		for error_variant: Variant in errors_variant:
			details.append(str(error_variant))
	_failures.append("%s failed: %s" % [label, "; ".join(details)])


func _test_repeatability(first: Dictionary, second: Dictionary) -> void:
	_check(first["aggregate_hash"] != "", "aggregate catalog hash is empty")
	_check(
		first["aggregate_hash"] == second["aggregate_hash"],
		"validation order changed aggregate catalog hash"
	)
	_check(
		first["canonical_hashes"] == second["canonical_hashes"],
		"validation order changed individual catalog hashes"
	)
	var catalogs: Dictionary = first["catalogs"]
	var hashes: Dictionary = first["canonical_hashes"]
	_check(
		catalogs.size() == CatalogLoader.official_catalog_keys().size(),
		"not every official catalog was loaded"
	)
	for key: String in CatalogLoader.official_catalog_keys():
		_check(hashes.has(key), "canonical hash is missing for %s" % key)
		if hashes.has(key):
			_check(
				hashes[key] == Codec.sha256_canonical(catalogs[key]),
				"published canonical hash is wrong for %s" % key
			)
	var verified: Array = first["verified_hash_manifests"]
	_check(
		verified.has(CatalogLoader.GOLDEN_HASHES_PATH),
		"checked-in golden artifact hashes were not verified"
	)


func _test_public_bundles(first: Dictionary, second: Dictionary) -> void:
	for faction_id: String in CatalogLoader.official_faction_ids():
		var first_result := CatalogLoader.selected_faction_public_bundle(faction_id, first)
		var second_result := CatalogLoader.selected_faction_public_bundle(faction_id, second)
		_check(bool(first_result["ok"]), "public bundle failed for %s" % faction_id)
		_check(bool(second_result["ok"]), "reverse-order public bundle failed for %s" % faction_id)
		if not bool(first_result["ok"]) or not bool(second_result["ok"]):
			continue
		var first_bundle: Dictionary = first_result["bundle"]
		var second_bundle: Dictionary = second_result["bundle"]
		_check(
			first_bundle["bundle_hash"] == second_bundle["bundle_hash"],
			"validation order changed %s public bundle hash" % faction_id
		)
		_check(first_bundle["faction_id"] == faction_id, "bundle selected the wrong faction")
		var public_catalogs: Dictionary = first_bundle["catalogs"]
		_check(public_catalogs.size() == 6, "public faction bundle must contain six catalogs")
		_check(
			(public_catalogs["faction"] as Dictionary).get("faction_id", null) == faction_id,
			"public bundle leaked or substituted another faction"
		)
		var body := first_bundle.duplicate(true)
		body.erase("bundle_hash")
		_check(
			first_bundle["bundle_hash"] == Codec.sha256_canonical(body),
			"public bundle hash does not cover its complete body"
		)
	var invalid := CatalogLoader.selected_faction_public_bundle("not-official", first)
	_check(not bool(invalid["ok"]), "unknown faction public bundle was accepted")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
