extends SceneTree

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const CoordinateFrame := preload("res://scripts/duel/knowledge/duel_coordinate_frame.gd")
const AliasBook := preload("res://scripts/duel/knowledge/duel_alias_book.gd")
const Visibility := preload("res://scripts/duel/knowledge/duel_visibility.gd")
const KnowledgeState := preload("res://scripts/duel/knowledge/duel_agent_knowledge_state.gd")
const Projector := preload("res://scripts/duel/knowledge/duel_knowledge_projector.gd")

const GOLDEN_KNOWLEDGE_HASH := "5615dcd1bab7066a88f1c89328ab43377e39ecb0628e9ddfdc717f0ec9363c9d"

var _failures := PackedStringArray()
var _manifest: Dictionary = {}


func _init() -> void:
	_manifest = _load_official_manifest()
	_check(not _manifest.is_empty(), "official map manifest could not be loaded")
	if not _manifest.is_empty():
		_test_coordinate_frame_and_aliases()
		_test_supercover_all_octants()
		_test_los_elevation_forest_building_and_air()
		_test_day_night_high_ground_and_detection()
		_test_exploration_memory_unlocated_and_destroyed()
		_test_locked_visibility_conformance()
		_test_audience_events_and_insertion_order()
		_test_mirror_equivalence()
	var golden_hash := _test_fresh_process_golden()
	if not GOLDEN_KNOWLEDGE_HASH.is_empty():
		_check(golden_hash == GOLDEN_KNOWLEDGE_HASH, "knowledge golden hash changed")
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_VISIBILITY_FAILURE: %s" % failure)
		print("DUEL_VISIBILITY_FAILED count=%d hash=%s" % [_failures.size(), golden_hash])
		quit(1)
		return
	print("DUEL_VISIBILITY_OK hash=%s" % golden_hash)
	quit(0)


func _test_coordinate_frame_and_aliases() -> void:
	var frame_zero := CoordinateFrame.new()
	var frame_one := CoordinateFrame.new()
	_check(frame_zero.configure(0, _manifest).is_empty(), "seat-0 frame rejected official manifest")
	_check(frame_one.configure(1, _manifest).is_empty(), "seat-1 frame rejected official manifest")
	var world_point := [12_345, 67_890]
	var rotated_point := [191_999 - 12_345, 127_999 - 67_890]
	_check(frame_zero.world_point_to_self(world_point) == world_point, "seat 0 changed world point")
	_check(frame_one.world_point_to_self(rotated_point) == world_point, "seat 1 point was not self-canonical")
	_check(
		frame_one.self_point_to_world(frame_one.world_point_to_self(world_point)) == world_point,
		"world/self point transform did not round-trip"
	)
	var world_cell := [17, 93]
	_check(
		frame_one.self_cell_to_world(frame_one.world_cell_to_self(world_cell)) == world_cell,
		"world/self cell transform did not round-trip"
	)
	_check(frame_one.world_facing_to_self(270_000) == 90_000, "seat-1 facing did not rotate 180 degrees")
	_check(frame_one.self_facing_to_world(90_000) == 270_000, "seat-1 facing did not round-trip")
	_check(
		frame_one.world_public_id_to_self("r_opponent_home") == "r_self_home",
		"seat-1 region ID did not rotate to self"
	)
	_check(frame_one.world_point_to_self([-1, 0]).is_empty(), "out-of-bounds coordinate was accepted")

	var salt := "visibility-alias-salt".to_utf8_buffer()
	var aliases_zero := AliasBook.new()
	var aliases_one := AliasBook.new()
	_check(aliases_zero.configure(0, salt).is_empty(), "seat-0 alias book failed")
	_check(aliases_one.configure(1, salt).is_empty(), "seat-1 alias book failed")
	var alias_zero := aliases_zero.ensure_alias(42)
	var alias_one := aliases_one.ensure_alias(42)
	_check(alias_zero == aliases_zero.ensure_alias(42), "alias was unstable on repeated lookup")
	_check(alias_zero != alias_one, "two observers received the same entity alias")
	_check(alias_zero.begins_with("e_") and alias_zero.length() == 66, "alias is not full opaque HMAC")
	_check(aliases_zero.tombstone(42), "known alias could not be tombstoned")
	_check(aliases_zero.is_tombstoned(42), "tombstone was not retained")
	_check(alias_zero == aliases_zero.ensure_alias(42), "tombstoned alias was reused or changed")


func _test_supercover_all_octants() -> void:
	var tied := Visibility.supercover_cells([0, 0], [2, 2])
	_check(
		tied == [[1, 0], [0, 1], [1, 1], [2, 1], [1, 2], [2, 2]],
		"tied-corner supercover did not use (y,x) order: %s" % str(tied)
	)
	var source := [4, 4]
	for delta: Array in [
		[3, 2], [2, 3], [-3, 2], [-2, 3], [-3, -2], [-2, -3], [3, -2], [2, -3],
	]:
		var target := [int(source[0]) + int(delta[0]), int(source[1]) + int(delta[1])]
		var forward := Visibility.supercover_cells(source, target)
		var reverse := Visibility.supercover_cells(target, source)
		_check(not forward.has(source), "supercover included its source in octant %s" % str(delta))
		_check(forward.back() == target, "supercover omitted its target in octant %s" % str(delta))
		var forward_set := _cell_set(forward)
		forward_set[_cell_key(source)] = true
		var reverse_set := _cell_set(reverse)
		reverse_set[_cell_key(target)] = true
		_check(forward_set == reverse_set, "supercover cell set changed on reverse ray %s" % str(delta))


func _test_los_elevation_forest_building_and_air() -> void:
	var grid := _empty_grid(7, 7, "r_self_home")
	var source := _entity(1, 0, 1, 3, 7, {
		"sight_day_mt": 3_000,
		"sight_night_mt": 3_000,
	})
	var target := _entity(2, 1, 5, 3, 7)
	var building_grid := grid.duplicate(true)
	building_grid["los_block_heights"][3 * 7 + 3] = 1
	building_grid["terrain_ids"][3 * 7 + 3] = "ordinary_building"
	_check(
		not _is_visible(building_grid, [source, target], 2),
		"height-1 building did not block elevation-0 sight"
	)
	building_grid["elevations"][3 * 7 + 1] = 1
	_check(
		_is_visible(building_grid, [source, target], 2),
		"height-1 building incorrectly blocked equal-elevation sight"
	)

	var forest_grid := grid.duplicate(true)
	forest_grid["los_block_heights"][3 * 7 + 3] = 2
	forest_grid["terrain_ids"][3 * 7 + 3] = "forest"
	_check(not _is_visible(forest_grid, [source, target], 2), "forest did not block ground sight")
	var air_source := source.duplicate(true)
	var air_target := target.duplicate(true)
	air_source["tags"] = ["air", "scout"]
	air_target["tags"] = ["air"]
	_check(
		_is_visible(forest_grid, [air_source, air_target], 2),
		"forest incorrectly blocked an air-to-air ray"
	)
	var cliff_grid := forest_grid.duplicate(true)
	cliff_grid["terrain_ids"][3 * 7 + 3] = "cliff"
	cliff_grid["los_block_kinds"][3 * 7 + 3] = "cliff"
	_check(
		not _is_visible(cliff_grid, [air_source, air_target], 2),
		"height-2 cliff did not block an air-to-air ray"
	)
	var direct_ray := Visibility.has_line_of_sight(grid, [1, 3], [5, 3], 0, false, false)
	_check(direct_ray, "unobstructed integer LOS was rejected")


func _test_day_night_high_ground_and_detection() -> void:
	var grid := _empty_grid(8, 5, "r_self_home")
	var source := _entity(1, 0, 1, 2, 8, {
		"sight_day_mt": 1_500,
		"sight_night_mt": 500,
	})
	var target := _entity(2, 1, 3, 2, 8)
	_check(_is_visible(grid, [source, target], 2, "day"), "day sight radius was not used")
	_check(not _is_visible(grid, [source, target], 2, "night"), "night sight radius was not used")
	_check(not _is_visible(grid, [source, target], 2, "forced_night"), "forced night used day sight")

	var high_source := source.duplicate(true)
	high_source["sight_day_mt"] = 950
	grid["elevations"][2 * 8 + 1] = 1
	_check(
		_is_visible(grid, [high_source, target], 2, "day"),
		"integer 110% high-to-low sight bonus was not applied"
	)
	grid["elevations"][2 * 8 + 1] = 0
	_check(
		not _is_visible(grid, [high_source, target], 2, "day"),
		"base sight radius unexpectedly reached beyond its circle"
	)

	var invisible_target := target.duplicate(true)
	invisible_target["invisible"] = true
	source["sight_day_mt"] = 2_000
	_check(
		not _is_visible(grid, [source, invisible_target], 2),
		"invisible entity was exposed without detection"
	)
	var detector := source.duplicate(true)
	detector["detection_radius_mt"] = 1_000
	_check(
		_is_visible(grid, [detector, invisible_target], 2),
		"invisible entity inside legal detection was not exposed"
	)
	detector["detection_radius_mt"] = 999
	_check(
		not _is_visible(grid, [detector, invisible_target], 2),
		"detection circle accepted a target beyond exact squared radius"
	)


func _test_exploration_memory_unlocated_and_destroyed() -> void:
	var grid := _empty_grid(10, 6, "r_self_home")
	var source := _entity(1, 0, 1, 2, 10, {
		"hp": 100,
		"max_hp": 100,
		"sight_day_mt": 1_500,
		"sight_night_mt": 1_500,
	})
	var enemy := _entity(2, 1, 3, 2, 10, {
		"catalog_id": "footguard",
		"hp": 80,
		"mana": 25,
		"max_hp": 100,
		"observable_activity": "moving",
		"production_queue": [{"secret": "never-copy"}],
		"visible_statuses": [{"status_id": "slow"}],
	})
	var state := _new_state(0, "memory-salt")
	_check(state.alias_if_known(2).is_empty(), "enemy alias existed before first legal sight")
	var first := Projector.project_phase_12(state, 1, "day", grid, [source, enemy])
	_check(bool(first["ok"]), "first-sight projection failed: %s" % _errors(first))
	var first_alias := state.alias_if_known(2)
	_check(not first_alias.is_empty(), "enemy alias was not created on first legal sight")
	_check(
		(first["projection"]["events_since_previous"] as Array)[0]["event_seq"] == 1,
		"first audience event did not begin at sequence 1"
	)
	var explored_after_first: Array = state.to_protected_canonical_dict()["explored_cell_ids"]

	var blind_source := source.duplicate(true)
	blind_source["sight_day_mt"] = 0
	blind_source["sight_night_mt"] = 0
	var hidden_enemy := enemy.duplicate(true)
	hidden_enemy["position_mt"] = [4_250, 2_250]
	hidden_enemy["hp"] = 1
	hidden_enemy["mana"] = 0
	hidden_enemy["visible_statuses"] = []
	var remembered := Projector.project_phase_12(state, 2, "day", grid, [blind_source, hidden_enemy])
	_check(bool(remembered["ok"]), "remembered projection failed: %s" % _errors(remembered))
	var remembered_contact: Dictionary = remembered["projection"]["remembered_contacts"][0]
	_check(remembered_contact["last_observed"]["hp"] == 80, "hidden HP updated remembered state")
	_check(remembered_contact["last_observed"]["visible_mana"] == 25, "hidden mana updated remembered state")
	_check(
		remembered_contact["last_observed"]["position_mt"] == [1_750, 1_250],
		"hidden position updated remembered state"
	)
	_check(
		not Codec.canonical_json(remembered_contact).contains("never-copy"),
		"hidden production queue crossed the remembered boundary"
	)
	var remembered_hash := Codec.sha256_canonical(remembered_contact)
	hidden_enemy["visible_statuses"].append({"status_id": "mutated_after_projection"})
	_check(
		Codec.sha256_canonical(state.public_projection()["remembered_contacts"][0]) == remembered_hash,
		"remembered record retained a live hidden snapshot reference"
	)
	_check(state.alias_if_known(2) == first_alias, "hidden transition changed stable alias")
	_check(
		(state.to_protected_canonical_dict()["explored_cell_ids"] as Array).size() \
			>= explored_after_first.size(),
		"exploration did not persist"
	)

	var revisit_state := _new_state(0, "revisit-salt")
	_check(bool(Projector.project_phase_12(
		revisit_state, 1, "day", grid, [source, enemy]
	)["ok"]), "revisit setup failed")
	var revisit_alias := revisit_state.alias_if_known(2)
	var blind_at_two := Projector.project_phase_12(
		revisit_state, 2, "day", grid, [blind_source, hidden_enemy]
	)
	var far_enemy := hidden_enemy.duplicate(true)
	far_enemy["position_mt"] = [4_750, 2_250]
	far_enemy["occupied_cell_ids"] = [2 * 10 + 9]
	var revisit := Projector.project_phase_12(
		revisit_state, 3, "day", grid, [source, far_enemy]
	)
	_check(bool(revisit["ok"]), "revisit projection failed: %s" % _errors(revisit))
	var before_record: Dictionary = blind_at_two["projection"]["remembered_contacts"][0]
	var unlocated_record: Dictionary = revisit["projection"]["remembered_contacts"][0]
	_check(unlocated_record["last_location_status"] == "unlocated", "revisited empty location was not unlocated")
	var before_without_status := before_record.duplicate(true)
	var after_without_status := unlocated_record.duplicate(true)
	before_without_status.erase("last_location_status")
	after_without_status.erase("last_location_status")
	before_without_status["memory_age_ticks"] = after_without_status["memory_age_ticks"]
	_check(
		before_without_status == after_without_status,
		"unlocated transition changed a frozen last-observed field"
	)

	var reacquired_enemy := enemy.duplicate(true)
	reacquired_enemy["position_mt"] = [2_250, 1_250]
	var reacquired := Projector.project_phase_12(
		revisit_state, 4, "day", grid, [source, reacquired_enemy]
	)
	_check(bool(reacquired["ok"]), "reacquisition failed: %s" % _errors(reacquired))
	_check(state.alias_if_known(2) == first_alias, "control alias changed unexpectedly")
	_check(revisit_state.alias_if_known(2) == revisit_alias, "reacquisition changed stable alias")
	_check(
		(reacquired["projection"]["events_since_previous"] as Array)[0]["kind"] == "entity_reacquired",
		"reacquisition event was not emitted"
	)

	var dead_enemy := reacquired_enemy.duplicate(true)
	dead_enemy["alive"] = false
	var destroyed := Projector.project_phase_12(
		revisit_state, 5, "day", grid, [source, dead_enemy]
	)
	_check(bool(destroyed["ok"]), "visible destruction projection failed: %s" % _errors(destroyed))
	_check((destroyed["projection"]["destroyed_contacts"] as Array).size() == 1, "destroyed state was not retained")
	_check(revisit_state.alias_book.is_tombstoned(2), "destroyed alias was not tombstoned")


func _test_locked_visibility_conformance() -> void:
	var path := "res://../game/duel_protocol/conformance/visibility-cases.json"
	var file := FileAccess.open(path, FileAccess.READ)
	_check(file != null, "locked visibility conformance artifact is missing")
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	_check(typeof(parsed) == TYPE_DICTIONARY, "visibility conformance artifact is invalid JSON")
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var cases: Array = parsed["cases"]
	_check(cases.size() == 17, "locked visibility conformance case count changed")
	var case_ids: Array[String] = []
	for case_variant: Variant in cases:
		case_ids.append(str((case_variant as Dictionary)["case_id"]))
	for required: String in [
		"hidden_enemy_position", "hidden_enemy_hp", "hidden_enemy_mana",
		"hidden_enemy_inventory", "hidden_enemy_queue", "hidden_enemy_upgrade",
		"hidden_enemy_status", "hidden_enemy_order", "hidden_enemy_death",
		"hidden_blocker", "hidden_corpse", "hidden_item_drop", "hidden_shop_purchase",
		"owned_state_changes", "visible_enemy_changes", "remembered_state_frozen",
		"revisit_empty_last_location",
	]:
		_check(case_ids.has(required), "locked visibility case was not exercised: %s" % required)

	var grid := _empty_grid(12, 6, "r_self_home")
	var source := _entity(1, 0, 1, 2, 12, {"sight_day_mt": 1_500, "sight_night_mt": 1_500})
	var enemy := _entity(2, 1, 3, 2, 12, {
		"hp": 75, "mana": 20, "max_hp": 100, "visible_statuses": [{"status_id": "slow"}],
	})
	var hidden_source := source.duplicate(true)
	hidden_source["sight_day_mt"] = 0
	hidden_source["sight_night_mt"] = 0
	var baseline_hidden := enemy.duplicate(true)
	baseline_hidden["position_mt"] = [5_250, 2_250]
	var mutation_fields := [
		["position_mt", [5_750, 2_250]],
		["hp", 1],
		["mana", 0],
		["inventory", [{"item_id": "secret"}]],
		["production_queue", [{"type_id": "secret"}]],
		["completed_upgrades", ["secret_upgrade"]],
		["visible_statuses", [{"status_id": "secret_status"}]],
		["current_order", {"kind": "secret"}],
		["alive", false],
		["corpse_exists", true],
		["drop_item_id", "secret_item"],
		["shop_stock", 0],
	]
	var baseline_hash := _remembered_hash_after_hidden(grid, source, enemy, hidden_source, baseline_hidden)
	for mutation: Array in mutation_fields:
		var changed := baseline_hidden.duplicate(true)
		changed[mutation[0]] = mutation[1]
		var changed_hash := _remembered_hash_after_hidden(grid, source, enemy, hidden_source, changed)
		_check(changed_hash == baseline_hash, "hidden mutation leaked through field %s" % str(mutation[0]))
	var hidden_block_grid := grid.duplicate(true)
	hidden_block_grid["los_block_heights"][0] = 2
	hidden_block_grid["terrain_ids"][0] = "forest"
	_check(
		_remembered_hash_after_hidden(hidden_block_grid, source, enemy, hidden_source, baseline_hidden) \
			== baseline_hash,
		"hidden blocker changed remembered observation bytes"
	)

	var visible_low := _single_projection_hash(grid, source, enemy)
	var visible_changed_enemy := enemy.duplicate(true)
	visible_changed_enemy["hp"] = 74
	_check(
		_single_projection_hash(grid, source, visible_changed_enemy) != visible_low,
		"visible enemy change did not change legal projection hash"
	)
	var owned_changed := source.duplicate(true)
	owned_changed["hp"] = 99
	owned_changed["max_hp"] = 100
	_check(
		_single_projection_hash(grid, owned_changed, enemy) != visible_low,
		"owned state change did not change legal projection hash"
	)
	var invariants: Array = parsed["mandatory_invariants"]
	_check(
		invariants.has("observation_builder_accepts_agent_knowledge_state_not_world_state"),
		"locked type-boundary invariant is missing"
	)
	_check(
		invariants.has("omniscient_state_hash_never_enters_model_message"),
		"locked no-world-hash invariant is missing"
	)


func _test_audience_events_and_insertion_order() -> void:
	var grid := _empty_grid(8, 5, "r_self_home")
	var source := _entity(1, 0, 1, 2, 8, {"sight_day_mt": 2_000, "sight_night_mt": 2_000})
	var enemy := _entity(2, 1, 3, 2, 8)
	var self_event := {
		"audience_seats": [0],
		"kind": "resource_deposited",
		"owner_seat": 0,
		"phase": 12,
		"public_payload": {"amount": 10, "resource": "gold"},
		"tick": 2,
		"visibility_rule": "owner",
		"world_event_seq": 20,
	}
	var second_self_event := {
		"audience_seats": [0],
		"kind": "day_phase_changed",
		"phase": 12,
		"public_payload": {"day_phase": "night"},
		"tick": 2,
		"visibility_rule": "explicit",
		"world_event_seq": 10,
	}
	var opponent_only := {
		"audience_seats": [1],
		"kind": "resource_spent",
		"owner_seat": 1,
		"phase": 12,
		"public_payload": {"amount": 999, "resource": "gold"},
		"tick": 2,
		"visibility_rule": "owner",
		"world_event_seq": 1,
	}
	var first_state := _new_state(0, "event-salt")
	var second_state := _new_state(0, "event-salt")
	_check(bool(Projector.project_phase_12(first_state, 1, "day", grid, [source, enemy])["ok"]), "event setup A failed")
	_check(bool(Projector.project_phase_12(second_state, 1, "day", grid, [enemy, source])["ok"]), "event setup B failed")
	var first := Projector.project_phase_12(
		first_state, 2, "night", grid, [source, enemy], [self_event, second_self_event]
	)
	var second := Projector.project_phase_12(
		second_state, 2, "night", grid, [enemy, source], [opponent_only, second_self_event, self_event]
	)
	_check(bool(first["ok"]), "audience event projection A failed: %s" % _errors(first))
	_check(bool(second["ok"]), "audience event projection B failed: %s" % _errors(second))
	var first_events: Array = first["projection"]["events_since_previous"]
	var second_events: Array = second["projection"]["events_since_previous"]
	_check(first_events == second_events, "hidden/opponent event changed player event bytes or sequence")
	_check(first_events.size() == 2, "audience event filter emitted wrong event count")
	_check(first_events[0]["kind"] == "day_phase_changed", "events ignored stable replay sequence order")
	_check(
		first_events[0]["event_seq"] == 2 and first_events[1]["event_seq"] == 3,
		"per-audience event sequence was not contiguous"
	)
	_check(
		not Codec.canonical_json(first["projection"]).contains("999"),
		"opponent-only payload leaked into player projection"
	)


func _test_mirror_equivalence() -> void:
	var grid := _empty_grid(384, 256, "r_self_home")
	for y: int in 128:
		for x: int in 384:
			grid["region_ids"][y * 384 + x] = "r_opponent_home"
	var source_zero := _entity(1, 0, 40, 200, 384, {
		"catalog_id": "rotor_scout", "sight_day_mt": 2_000, "sight_night_mt": 2_000,
	})
	var target_zero := _entity(2, 1, 42, 200, 384, {"catalog_id": "bat_scout", "hp": 73, "max_hp": 100})
	var source_one := _entity(2, 1, 343, 55, 384, {
		"catalog_id": "rotor_scout", "sight_day_mt": 2_000, "sight_night_mt": 2_000,
	})
	var target_one := _entity(1, 0, 341, 55, 384, {"catalog_id": "bat_scout", "hp": 73, "max_hp": 100})
	source_one["position_mt"] = [191_999 - 20_250, 127_999 - 100_250]
	target_one["position_mt"] = [191_999 - 21_250, 127_999 - 100_250]
	var state_zero := _new_state(0, "mirror-salt")
	var state_one := _new_state(1, "mirror-salt")
	var result_zero := Projector.project_phase_12(state_zero, 10, "day", grid, [source_zero, target_zero])
	var result_one := Projector.project_phase_12(state_one, 10, "day", grid, [target_one, source_one])
	_check(bool(result_zero["ok"]), "seat-0 mirror projection failed: %s" % _errors(result_zero))
	_check(bool(result_one["ok"]), "seat-1 mirror projection failed: %s" % _errors(result_one))
	if not bool(result_zero["ok"]) or not bool(result_one["ok"]):
		return
	var own_zero: Dictionary = result_zero["projection"]["owned_entities"][0]
	var own_one: Dictionary = result_one["projection"]["owned_entities"][0]
	var visible_zero: Dictionary = result_zero["projection"]["visible_contacts"][0]
	var visible_one: Dictionary = result_one["projection"]["visible_contacts"][0]
	_check(own_zero["position_mt"] == own_one["position_mt"], "mirrored owned coordinates were unequal")
	_check(own_zero["region_id"] == own_one["region_id"], "mirrored owned regions were unequal")
	_check(visible_zero["position_mt"] == visible_one["position_mt"], "mirrored enemy coordinates were unequal")
	_check(visible_zero["region_id"] == visible_one["region_id"], "mirrored enemy regions were unequal")
	_check(visible_zero["hp"] == visible_one["hp"], "mirrored visible contact fields diverged")
	_check(
		visible_zero["entity_id"] != visible_one["entity_id"],
		"mirror equivalence incorrectly reused aliases across observers"
	)
	_check(
		result_zero["projection"]["map_state"] == result_one["projection"]["map_state"],
		"mirrored visibility/exploration region projection diverged"
	)


func _test_fresh_process_golden() -> String:
	if _manifest.is_empty():
		return ""
	var grid := _empty_grid(9, 7, "r_self_natural")
	grid["los_block_heights"][3 * 9 + 4] = 2
	grid["terrain_ids"][3 * 9 + 4] = "forest"
	var source := _entity(10, 0, 2, 3, 9, {
		"catalog_id": "owl_rider",
		"detection_radius_mt": 2_000,
		"facing_mdeg": 90_000,
		"hp": 350,
		"max_hp": 350,
		"sight_day_mt": 2_000,
		"sight_night_mt": 1_500,
		"tags": ["scout", "air", "detector"],
	})
	var visible_enemy := _entity(20, 1, 3, 3, 9, {
		"catalog_id": "veil_adept",
		"hp": 211,
		"mana": 144,
		"max_hp": 360,
		"observable_activity": "casting",
		"visible_statuses": [{"status_id": "marked"}],
	})
	var hidden_invisible := _entity(30, 1, 5, 3, 9, {
		"catalog_id": "scout_ward",
		"hp": 100,
		"invisible": true,
		"max_hp": 100,
		"tags": ["ground", "ward"],
	})
	var state := _new_state(0, "fresh-process-golden-salt")
	var result := Projector.project_phase_12(
		state,
		77,
		"night",
		grid,
		[hidden_invisible, visible_enemy, source],
		[{
			"audience_seats": [0],
			"kind": "day_phase_changed",
			"phase": 12,
			"public_payload": {"day_phase": "night"},
			"tick": 77,
			"visibility_rule": "explicit",
			"world_event_seq": 4,
		}]
	)
	_check(bool(result["ok"]), "golden knowledge projection failed: %s" % _errors(result))
	if not bool(result["ok"]):
		return ""
	var hash := Codec.sha256_canonical(result["projection"])
	_check(hash == result["knowledge_hash"], "reported knowledge hash did not cover public projection")
	_check(
		not Codec.canonical_json(result["projection"]).contains("internal_id"),
		"public golden projection leaked an internal ID key"
	)
	return hash


func _remembered_hash_after_hidden(
	grid: Dictionary,
	visible_source: Dictionary,
	visible_enemy: Dictionary,
	hidden_source: Dictionary,
	hidden_enemy: Dictionary
) -> String:
	var state := _new_state(0, "conformance-salt")
	var first := Projector.project_phase_12(state, 1, "day", grid, [visible_source, visible_enemy])
	if not bool(first["ok"]):
		_failures.append("conformance first sight failed: %s" % _errors(first))
		return ""
	var second := Projector.project_phase_12(state, 2, "day", grid, [hidden_source, hidden_enemy])
	if not bool(second["ok"]):
		_failures.append("conformance hidden projection failed: %s" % _errors(second))
		return ""
	return Codec.sha256_canonical(second["projection"])


func _single_projection_hash(grid: Dictionary, source: Dictionary, enemy: Dictionary) -> String:
	var state := _new_state(0, "visible-change-salt")
	var result := Projector.project_phase_12(state, 1, "day", grid, [source, enemy])
	if not bool(result["ok"]):
		_failures.append("single projection failed: %s" % _errors(result))
		return ""
	return str(result["knowledge_hash"])


func _new_state(seat: int, salt_text: String) -> KnowledgeState:
	var state := KnowledgeState.new()
	var errors := state.configure(seat, salt_text.to_utf8_buffer(), _manifest)
	_check(errors.is_empty(), "knowledge state configure failed: %s" % "; ".join(errors))
	return state


func _is_visible(
	grid: Dictionary,
	entities: Array,
	internal_id: int,
	day_phase: String = "day"
) -> bool:
	var result := Visibility.compute(grid, entities, 0, day_phase)
	_check(bool(result["ok"]), "visibility compute failed: %s" % _errors(result))
	return bool(result["ok"]) and (result["visible_entity_ids"] as Array).has(internal_id)


func _empty_grid(width: int, height: int, region_id: String) -> Dictionary:
	var count := width * height
	var elevations: Array = []
	var blockers: Array = []
	var blocker_kinds: Array = []
	var terrain_ids: Array = []
	var region_ids: Array = []
	for _id: int in count:
		elevations.append(0)
		blockers.append(0)
		blocker_kinds.append("")
		terrain_ids.append("grass")
		region_ids.append(region_id)
	return {
		"cell_size_mt": 500,
		"elevations": elevations,
		"height": height,
		"los_block_heights": blockers,
		"los_block_kinds": blocker_kinds,
		"region_ids": region_ids,
		"terrain_ids": terrain_ids,
		"width": width,
	}


func _entity(
	internal_id: int,
	owner_seat: int,
	cell_x: int,
	cell_y: int,
	grid_width: int,
	overrides: Dictionary = {}
) -> Dictionary:
	var entity := {
		"alive": true,
		"catalog_id": "unit",
		"hp": 50,
		"internal_id": internal_id,
		"mana": 0,
		"max_hp": 50,
		"observable_activity": "idle",
		"occupied_cell_ids": [cell_y * grid_width + cell_x],
		"owner_seat": owner_seat,
		"position_mt": [cell_x * 500 + 250, cell_y * 500 + 250],
		"region_id": "r_self_home" if cell_y >= 128 else "r_opponent_home",
		"sight_day_mt": 0,
		"sight_night_mt": 0,
		"tags": ["ground"],
		"visible_statuses": [],
	}
	for key_variant: Variant in overrides.keys():
		entity[key_variant] = overrides[key_variant]
	return entity


func _load_official_manifest() -> Dictionary:
	var path := "res://../game/duel_protocol/maps/crossroads-duel-v1.json"
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var normalized := CatalogLoader.normalize_json_boundary(parsed)
	if not bool(normalized["ok"]):
		return {}
	return normalized["value"]


func _cell_set(cells: Array) -> Dictionary:
	var result: Dictionary = {}
	for cell_variant: Variant in cells:
		result[_cell_key(cell_variant)] = true
	return result


func _cell_key(cell: Array) -> String:
	return "%d,%d" % [int(cell[0]), int(cell[1])]


func _errors(result: Dictionary) -> String:
	var errors: Variant = result.get("errors", [])
	if typeof(errors) == TYPE_PACKED_STRING_ARRAY:
		return "; ".join(errors)
	var parts := PackedStringArray()
	if typeof(errors) == TYPE_ARRAY:
		for error: Variant in errors:
			parts.append(str(error))
	return "; ".join(parts)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
