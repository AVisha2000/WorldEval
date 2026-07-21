extends SceneTree

const Contract := preload("res://scripts/duel/actions/duel_action_contract.gd")
const Validator := preload("res://scripts/duel/actions/duel_action_validator.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")

const EXPECTED_GOLDEN := "e82ca46037a78d7958a1dcbb6fe78e1582cb33e0db12ccf972c4e9e1e168506f"

var _failures := PackedStringArray()


func _init() -> void:
	_test_catalog_and_schema_parity()
	_test_all_operations()
	_test_fixture_parity()
	_test_atomic_expansion_and_budget()
	_test_partial_legality_and_alias_safety()
	_test_duplicate_and_stale_rejections()
	_test_queue_semantics()
	_test_squads_and_tactics()
	_test_self_relative_transform()
	_test_application_tick_availability()
	_test_shuffled_context_determinism()
	_test_intent_ids_and_digests()
	_test_no_reflective_dispatch()
	var golden := _test_fresh_process_golden()

	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_ACTIONS_FAILURE: %s" % failure)
		print("DUEL_ACTIONS_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("DUEL_ACTIONS_OK hash=%s operations=%d" % [golden, Contract.OPERATIONS.size()])
	quit(0)


func _test_catalog_and_schema_parity() -> void:
	var loaded := CatalogLoader.load_official_catalogs()
	_check(bool(loaded.get("ok", false)), "official catalogs failed to load")
	if not bool(loaded.get("ok", false)):
		return
	var operations: Dictionary = loaded["catalogs"]["actions"]["operations"]
	var keys: Array = operations.keys()
	keys.sort()
	_check(keys == Contract.OPERATIONS, "action contract operation list drifted from locked catalog")
	_check(Contract.OPERATIONS.size() == 37, "hybrid-v1 must expose exactly 37 operations")
	for command: Dictionary in _all_commands():
		var operation := str(command["op"])
		_check(
			Contract.command_structural_code(command).is_empty(),
			"schema-parity command rejected for %s" % operation
		)
		var locked_spec: Dictionary = operations[operation]
		_check(
			locked_spec["required"] == Contract.REQUIRED_FIELDS[operation],
			"required-field allowlist drifted for %s" % operation
		)
		_check(
			locked_spec["optional"] == Contract.OPTIONAL_FIELDS.get(operation, []),
			"optional-field allowlist drifted for %s" % operation
		)


func _test_all_operations() -> void:
	var seen: Dictionary = {}
	for command: Dictionary in _all_commands():
		seen[str(command["op"])] = true
		var result := Validator.new().validate_and_compile(_batch([command]), _base_context())
		_check(bool(result["ok"]), "%s envelope failed: %s" % [command["op"], result["code"]])
		if not bool(result["ok"]):
			continue
		var receipt: Dictionary = result["receipt"]
		var command_receipts: Array = receipt["commands"]
		_check(command_receipts.size() == 1, "%s did not emit one receipt" % command["op"])
		if command_receipts.size() == 1:
			_check(
				str(command_receipts[0]["status"]) == "applied",
				"%s was individually rejected: %s" % [command["op"], command_receipts[0]["code"]]
			)
	_check(seen.size() == Contract.OPERATIONS.size(), "operation test matrix contains duplicates")
	for operation: String in Contract.OPERATIONS:
		_check(seen.has(operation), "operation is untested: %s" % operation)


func _test_fixture_parity() -> void:
	var fixture: Variant = _read_normalized_json(
		"res://../game/duel_protocol/fixtures/action-batch.valid.json"
	)
	var fixture_context := _base_context()
	fixture_context["application_tick"] = 1801
	fixture_context["controller_valid_until_tick"] = 1801
	fixture_context["received_tick"] = 1800
	var valid_result := Validator.new().validate_and_compile(fixture, fixture_context)
	_check(bool(valid_result["ok"]), "locked valid action fixture was rejected")
	if bool(valid_result["ok"]):
		_check(valid_result["intents"].size() == 5, "valid fixture must compile 5 atomic intents")

	var invalid_paths: Array[String] = [
		"duplicate-command-id.semantic-invalid.json",
		"extra-target-property.invalid.json",
		"missing-observation-hash.invalid.json",
		"too-many-commands.invalid.json",
		"unknown-envelope-field.invalid.json",
		"unknown-operation.invalid.json",
	]
	for filename: String in invalid_paths:
		var path := "res://../game/duel_protocol/fixtures/action-batches.invalid/%s" % filename
		var invalid: Variant = _read_normalized_json(path)
		var result := Validator.new().validate_and_compile(invalid, _base_context())
		_check(not bool(result["ok"]), "locked invalid fixture was accepted: %s" % filename)


func _test_atomic_expansion_and_budget() -> void:
	var group := {
		"actor_ids": ["e_u1", "e_u2", "e_u3"],
		"command_id": "group",
		"op": "move",
		"queue": "replace",
		"target": _point(1000, 2000),
	}
	var group_result := Validator.new().validate_and_compile(_batch([group]), _base_context())
	_check(group_result["intents"].size() == 3, "three-actor move did not expand to three intents")

	var produce := {
		"command_id": "five",
		"op": "produce",
		"producer_id": "e_producer",
		"quantity": 5,
		"unit_type_id": "longbow",
	}
	var produce_result := Validator.new().validate_and_compile(_batch([produce]), _base_context())
	_check(produce_result["intents"].size() == 5, "quantity five did not expand to five intents")
	var purchase := {
		"buyer_id": "e_hero", "command_id": "purchase_three", "offer_id": "potion_offer",
		"op": "purchase_offer", "quantity": 3, "shop_id": "e_shop",
	}
	var purchase_result := Validator.new().validate_and_compile(_batch([purchase]), _base_context())
	_check(purchase_result["atomic_cost"] == 3, "purchase quantity did not match Python atomic pricing")
	_check(purchase_result["intents"].size() == 3, "purchase quantity did not expand atomically")

	var context := _base_context()
	var entities: Dictionary = context["entities"]
	var commands: Array[Dictionary] = []
	for group_index: int in 3:
		var ids: Array[String] = []
		for actor_index: int in 24:
			var entity_id := "e_budget_%d_%d" % [group_index, actor_index]
			ids.append(entity_id)
			entities[entity_id] = _entity(1000 + group_index * 24 + actor_index, 0, ["ground"])
		commands.append({
			"actor_ids": ids,
			"command_id": "budget_%d" % group_index,
			"op": "move",
			"queue": "replace",
			"target": _point(5000, 5000),
		})
	var over := Validator.new().validate_and_compile(_batch(commands), context)
	_check(not bool(over["ok"]), "72-atomic batch was accepted")
	_check(over["code"] == "atomic_budget_exceeded", "over-budget code drifted")
	_check(over["intents"].is_empty(), "over-budget envelope compiled intents")


func _test_partial_legality_and_alias_safety() -> void:
	var context := _base_context()
	context["entities"]["e_hidden"] = _entity(900, 1, ["ground"], false)
	var commands: Array[Dictionary] = [
		{
			"actor_ids": ["e_u1"], "command_id": "legal_a", "op": "move",
			"queue": "replace", "target": _point(1000, 1000),
		},
		{
			"actor_ids": ["e_u2"], "command_id": "hidden", "op": "attack_entity",
			"queue": "replace", "target": {"kind": "entity", "entity_id": "e_hidden"},
		},
		{
			"actor_ids": ["e_missing"], "command_id": "unknown", "op": "stop",
		},
		{
			"actor_ids": ["e_u3"], "command_id": "legal_b", "op": "stop",
		},
	]
	var result := Validator.new().validate_and_compile(_batch(commands), context)
	_check(bool(result["ok"]), "individual illegality invalidated the envelope")
	var receipts: Array = result["receipt"]["commands"]
	_check(receipts.size() == 4, "partial batch receipt count is wrong")
	if receipts.size() == 4:
		_check(receipts[0]["status"] == "applied", "first legal sibling was rejected")
		_check(receipts[1]["code"] == "target_unavailable", "hidden alias leaked a distinct code")
		_check(receipts[2]["code"] == "unknown_entity", "unknown actor code drifted")
		_check(receipts[3]["status"] == "applied", "later legal sibling was rejected")
	_check(result["intents"].size() == 2, "partial batch compiled an illegal command")
	_check(result["receipt"]["batch_status"] == "partially_applied", "partial status drifted")


func _test_duplicate_and_stale_rejections() -> void:
	var duplicate_ids: Array[Dictionary] = [
		{"actor_ids": ["e_u1"], "command_id": "same", "op": "stop"},
		{"actor_ids": ["e_u2"], "command_id": "same", "op": "stop"},
	]
	var duplicate_result := Validator.new().validate_and_compile(
		_batch(duplicate_ids), _base_context()
	)
	_check(duplicate_result["code"] == "duplicate_command_id", "duplicate command IDs were not fail-closed")
	_check(duplicate_result["intents"].is_empty(), "duplicate command IDs compiled intents")

	var duplicate_actors := {
		"actor_ids": ["e_u1", "e_u1"],
		"command_id": "duplicate_actor",
		"op": "move",
		"queue": "replace",
		"target": _point(100, 100),
	}
	var duplicate_actor_result := Validator.new().validate_and_compile(
		_batch([duplicate_actors]), _base_context()
	)
	_check(duplicate_actor_result["code"] == "schema_mismatch", "duplicate actor array was accepted")

	var stale_batch := _batch([])
	stale_batch["valid_until_tick"] = 100
	var stale := Validator.new().validate_and_compile(stale_batch, _base_context())
	_check(stale["code"] == "expired_batch", "stale batch code drifted")
	_check(stale["receipt"]["batch_status"] == "expired", "stale receipt status drifted")

	var extended := _batch([])
	extended["valid_until_tick"] = 102
	var extended_result := Validator.new().validate_and_compile(extended, _base_context())
	_check(extended_result["code"] == "schema_mismatch", "model extended validity window")


func _test_queue_semantics() -> void:
	var context := _base_context()
	context["entities"]["e_u1"]["order_queue_size"] = 8
	var commands: Array[Dictionary] = [
		{
			"actor_ids": ["e_u1"], "command_id": "full", "op": "move",
			"queue": "append", "target": _point(1, 1),
		},
		{
			"actor_ids": ["e_u2"], "command_id": "front_move", "op": "move",
			"queue": "front", "target": _point(2, 2),
		},
		{
			"actor_ids": ["e_u3"], "command_id": "replace_one", "op": "move",
			"queue": "replace", "target": _point(3, 3),
		},
		{
			"actor_ids": ["e_u3"], "command_id": "replace_two", "op": "move",
			"queue": "replace", "target": _point(4, 4),
		},
		{
			"ability_id": "marshal_shield_strike", "actor_id": "e_hero", "command_id": "cast_front",
			"op": "cast", "queue": "front",
		},
	]
	var result := Validator.new().validate_and_compile(_batch(commands), context)
	var receipts: Array = result["receipt"]["commands"]
	_check(receipts[0]["code"] == "queue_full", "append did not enforce queue limit")
	_check(receipts[1]["code"] == "conflicting_order", "front move was accepted")
	_check(receipts[2]["status"] == "applied", "first replace was rejected")
	_check(receipts[3]["code"] == "conflicting_order", "duplicate replace was accepted")
	_check(receipts[4]["status"] == "applied", "manual cast front was rejected")


func _test_squads_and_tactics() -> void:
	var define := {
		"command_id": "define", "member_ids": ["e_u1", "e_u2"],
		"op": "define_squad", "squad_id": "squad.new",
	}
	var define_result := Validator.new().validate_and_compile(_batch([define]), _base_context())
	_check(define_result["squads"].has("squad.new"), "define_squad did not project persistent state")

	var update_then_order: Array[Dictionary] = [
		{
			"command_id": "update", "member_ids": ["e_u3"],
			"op": "update_squad", "squad_id": "squad.main",
		},
		{
			"command_id": "order", "engagement": "avoid", "formation": "line",
			"objective": "move_to", "op": "order_squad", "queue": "replace",
			"squad_id": "squad.main", "target": _point(20, 30),
		},
	]
	var result := Validator.new().validate_and_compile(_batch(update_then_order), _base_context())
	var receipts: Array = result["receipt"]["commands"]
	_check(receipts[0]["status"] == "applied", "squad update was rejected")
	_check(receipts[1]["code"] == "conflicting_order", "update/order budget evasion was allowed")
	_check(result["squads"]["squad.main"]["member_ids"] == ["e_u3"], "squad update state is wrong")

	var tactics := {
		"command_id": "tactics",
		"focus_tag": "healer",
		"formation": "spread",
		"op": "set_tactics",
		"retreat_hp_threshold_bp": 2500,
		"retreat_target": {"kind": "entity", "entity_id": "e_deposit"},
		"stance": "defensive",
		"subject": {"kind": "squad", "squad_id": "squad.main"},
	}
	var tactics_result := Validator.new().validate_and_compile(_batch([tactics]), _base_context())
	_check(tactics_result["intents"].size() == 2, "squad tactics did not expand to current members")
	_check(
		tactics_result["squads"]["squad.main"]["tactics"]["focus_tag"] == "healer",
		"squad tactics were not projected persistently"
	)


func _test_self_relative_transform() -> void:
	var context := _base_context()
	context["player_seat"] = 1
	context["self_rotates_to_world"] = true
	context["entities"]["e_enemy"]["owner_seat"] = 0
	context["entities"]["e_u1"]["owner_seat"] = 1
	context["self_to_world_public_ids"] = {
		"r_center": "r_center_world",
		"high_ground": "high_ground_world",
		"site_home": "site_world_north",
	}
	context["known_regions"]["r_center"].erase("world_region_id")
	var move := {
		"actor_ids": ["e_u1"], "command_id": "rotate", "op": "move",
		"queue": "replace", "target": _point(42000, 45000),
	}
	var result := Validator.new().validate_and_compile(_batch([move]), context)
	_check(bool(result["ok"]), "rotated seat command failed")
	if not result["intents"].is_empty():
		_check(
			result["intents"][0]["target"]["xy_mt"] == [149999, 82999],
			"self-relative point did not use exact inverse 180-degree transform"
		)

	var rally := {
		"command_id": "region_rotate", "op": "set_rally", "producer_id": "e_producer",
		"target": {"kind": "region_slot", "region_id": "r_center", "slot_id": "high_ground"},
	}
	context["entities"]["e_producer"]["owner_seat"] = 1
	var region_result := Validator.new().validate_and_compile(_batch([rally]), context)
	if not region_result["intents"].is_empty():
		var target: Dictionary = region_result["intents"][0]["target"]
		_check(target["region_id"] == "r_center_world", "region ID did not transform")
		_check(target["slot_id"] == "high_ground_world", "slot ID did not transform")
	var site_rally := {
		"command_id": "site_rotate", "op": "set_rally", "producer_id": "e_producer",
		"target": {"kind": "site", "site_id": "site_home"},
	}
	var site_result := Validator.new().validate_and_compile(_batch([site_rally]), context)
	if not site_result["intents"].is_empty():
		_check(
			site_result["intents"][0]["target"]["site_id"] == "site_world_north",
			"site ID did not transform"
		)


func _test_application_tick_availability() -> void:
	var context := _base_context()
	context["entities"]["e_u1"]["unavailable_at_tick"] = 101
	var stop := {"actor_ids": ["e_u1"], "command_id": "late", "op": "stop"}
	var result := Validator.new().validate_and_compile(_batch([stop]), context)
	_check(bool(result["ok"]), "unavailable actor invalidated envelope")
	_check(result["receipt"]["commands"][0]["code"] == "actor_unavailable", "application tick was ignored")
	var enemy_stop := {"actor_ids": ["e_enemy"], "command_id": "enemy", "op": "stop"}
	var ownership := Validator.new().validate_and_compile(_batch([enemy_stop]), _base_context())
	_check(ownership["receipt"]["commands"][0]["code"] == "not_owner", "ownership check was skipped")


func _test_shuffled_context_determinism() -> void:
	var command := {
		"actor_ids": ["e_u2", "e_u1"],
		"command_id": "ordered",
		"op": "attack_move",
		"queue": "replace",
		"target": {"kind": "region_slot", "region_id": "r_center", "slot_id": "high_ground"},
	}
	var first_context := _base_context()
	var second_context := first_context.duplicate(true)
	var reversed_entities: Dictionary = {}
	var keys: Array = (second_context["entities"] as Dictionary).keys()
	keys.sort()
	keys.reverse()
	for key: Variant in keys:
		reversed_entities[key] = second_context["entities"][key]
	second_context["entities"] = reversed_entities
	var first := Validator.new().validate_and_compile(_batch([command]), first_context)
	var second := Validator.new().validate_and_compile(_batch([command]), second_context)
	_check(first["intents"][0]["subject"]["public_id"] == "e_u2", "model actor order was sorted")
	_check(first["intents"][1]["subject"]["public_id"] == "e_u1", "model actor order was changed")
	_check(
		Codec.canonical_json(first) == Codec.canonical_json(second),
		"Dictionary insertion order changed compiled action output"
	)
	_check(first_context == _base_context(), "validator mutated its legal context")


func _test_intent_ids_and_digests() -> void:
	var command := {
		"actor_ids": ["e_u2", "e_u1"],
		"command_id": "digest_group",
		"op": "move",
		"queue": "replace",
		"target": _point(1234, 5678),
	}
	var batch := _batch([command])
	var context := _base_context()
	var batch_before := Codec.canonical_json(batch)
	var context_before := Codec.canonical_json(context)
	var result := Validator.new().validate_and_compile(batch, context)
	for intent: Dictionary in result["intents"]:
		var body := intent.duplicate(true)
		var digest := str(body["intent_digest"])
		body.erase("intent_digest")
		body.erase("intent_id")
		_check(Codec.sha256_canonical(body) == digest, "intent digest does not cover its canonical body")
		_check(intent["intent_id"] == "ci_" + digest, "intent ID is not its full digest")
		_check(
			intent["source"]["command_digest"] == Codec.sha256_canonical(command),
			"source command digest is wrong"
		)
	var published_ids: Array = result["receipt"]["commands"][0]["compiled_order_ids"]
	var sorted_ids := published_ids.duplicate()
	sorted_ids.sort()
	_check(published_ids == sorted_ids, "receipt compiled IDs are not canonically sorted")
	_check(Codec.canonical_json(batch) == batch_before, "validator mutated the action batch")
	_check(Codec.canonical_json(context) == context_before, "validator mutated the legal context")


func _test_no_reflective_dispatch() -> void:
	var paths: Array[String] = [
		"res://scripts/duel/actions/duel_action_validator.gd",
		"res://scripts/duel/actions/duel_order_compiler.gd",
	]
	var forbidden: Array[String] = [".call(", "callv(", "Callable(", "get_method("]
	for path: String in paths:
		var text := FileAccess.get_file_as_string(path)
		for token: String in forbidden:
			_check(text.find(token) == -1, "%s contains reflective dispatch token %s" % [path, token])


func _test_fresh_process_golden() -> String:
	var commands: Array[Dictionary] = [
		_all_commands()[15], # move
		_all_commands()[19], # produce
		_all_commands()[16], # order_squad
		_all_commands()[6],  # cast
		_all_commands()[30], # set_tactics
	]
	var result := Validator.new().validate_and_compile(_batch(commands), _base_context())
	_check(bool(result["ok"]), "golden action transcript failed validation")
	var digest := Codec.sha256_canonical(result)
	if not EXPECTED_GOLDEN.is_empty():
		_check(digest == EXPECTED_GOLDEN, "action compiler golden changed: %s" % digest)
	else:
		print("DUEL_ACTIONS_CANDIDATE_GOLDEN=%s" % digest)
	return digest


func _all_commands() -> Array[Dictionary]:
	return [
		{"actor_ids": ["e_u1"], "command_id": "attack_entity", "op": "attack_entity", "queue": "replace", "target": {"kind": "entity", "entity_id": "e_enemy"}},
		{"actor_ids": ["e_u1"], "command_id": "attack_ground", "op": "attack_ground", "queue": "replace", "target": _point(1000, 2000)},
		{"actor_ids": ["e_u1"], "command_id": "attack_move", "op": "attack_move", "queue": "replace", "target": _point(2000, 3000)},
		{"builder_ids": ["e_worker", "e_worker2"], "building_type_id": "barracks", "build_site_id": "site_home", "command_id": "build", "op": "build"},
		{"building_id": "e_building", "command_id": "cancel_construction", "op": "cancel_construction"},
		{"command_id": "cancel_queue", "op": "cancel_queue", "producer_id": "e_producer", "queue_entry_id": "q_one"},
		{"ability_id": "marshal_shield_strike", "actor_id": "e_hero", "command_id": "cast", "op": "cast", "queue": "front", "target": {"kind": "entity", "entity_id": "e_enemy"}},
		{"command_id": "define_squad", "member_ids": ["e_u1", "e_u2"], "op": "define_squad", "squad_id": "squad.new"},
		{"command_id": "disband_squad", "op": "disband_squad", "squad_id": "squad.main"},
		{"command_id": "drop_item", "hero_id": "e_hero", "item_instance_id": "item_one", "op": "drop_item", "target": _point(3000, 4000)},
		{"actor_ids": ["e_u1"], "command_id": "follow", "distance_mt": 2000, "op": "follow", "queue": "append", "target": {"kind": "entity", "entity_id": "e_u2"}},
		{"command_id": "gather", "op": "gather", "queue": "replace", "resource_target": {"kind": "site", "site_id": "site_resource"}, "worker_ids": ["e_worker"]},
		{"actor_ids": ["e_u1"], "command_id": "hold_position", "op": "hold_position"},
		{"ability_id": "hero_heal", "command_id": "learn_ability", "hero_id": "e_hero", "op": "learn_ability"},
		{"command_id": "load_transport", "op": "load_transport", "passenger_ids": ["e_u1", "e_u2"], "queue": "append", "transport_id": "e_transport"},
		{"actor_ids": ["e_u1"], "command_id": "move", "op": "move", "queue": "replace", "target": _point(42000, 45000)},
		{"command_id": "order_squad", "engagement": "engage_visible", "formation": "spread", "objective": "attack_move_to", "op": "order_squad", "queue": "replace", "squad_id": "squad.main", "target": {"kind": "region_slot", "region_id": "r_center", "slot_id": "high_ground"}},
		{"actor_ids": ["e_u1"], "command_id": "patrol", "op": "patrol", "queue": "append", "targets": [_point(1000, 1000), _point(2000, 2000)]},
		{"command_id": "pick_up_item", "hero_id": "e_hero", "item_entity_id": "e_item", "op": "pick_up_item", "queue": "replace"},
		{"command_id": "produce", "op": "produce", "producer_id": "e_producer", "quantity": 2, "unit_type_id": "longbow"},
		{"buyer_id": "e_hero", "command_id": "purchase_offer", "offer_id": "potion_offer", "op": "purchase_offer", "quantity": 2, "shop_id": "e_shop"},
		{"command_id": "repair", "op": "repair", "queue": "replace", "target": {"kind": "entity", "entity_id": "e_building"}, "worker_ids": ["e_worker"]},
		{"command_id": "research", "op": "research", "producer_id": "e_producer", "upgrade_id": "ranged_attack_1"},
		{"actor_ids": ["e_u1"], "command_id": "retreat", "op": "retreat", "queue": "front", "target": {"kind": "entity", "entity_id": "e_deposit"}},
		{"command_id": "return_cargo", "deposit_target": {"kind": "entity", "entity_id": "e_deposit"}, "op": "return_cargo", "queue": "append", "worker_ids": ["e_worker"]},
		{"command_id": "revive_hero", "hero_id": "e_deadhero", "op": "revive_hero", "revival_method": "altar", "reviver_id": "e_reviver"},
		{"command_id": "sell_item", "hero_id": "e_hero", "item_instance_id": "item_one", "op": "sell_item", "shop_id": "e_shop"},
		{"ability_id": "marshal_shield_strike", "actor_ids": ["e_hero"], "command_id": "set_autocast", "enabled": true, "op": "set_autocast"},
		{"command_id": "set_rally", "op": "set_rally", "producer_id": "e_producer", "target": _point(6000, 7000)},
		{"actor_ids": ["e_u1", "e_u2"], "command_id": "set_stance", "op": "set_stance", "stance": "defensive"},
		{"command_id": "set_tactics", "focus_tag": "healer", "formation": "line", "op": "set_tactics", "retreat_hp_threshold_bp": 2500, "retreat_target": {"kind": "entity", "entity_id": "e_deposit"}, "stance": "defensive", "subject": {"kind": "actors", "actor_ids": ["e_u1", "e_u2"]}},
		{"actor_ids": ["e_u1"], "command_id": "stop", "op": "stop"},
		{"command_id": "transfer_item", "from_hero_id": "e_hero", "item_instance_id": "item_one", "op": "transfer_item", "to_hero_id": "e_hero2"},
		{"command_id": "unload_transport", "op": "unload_transport", "passengers": "all", "target": _point(8000, 9000), "transport_id": "e_transport"},
		{"command_id": "update_squad", "member_ids": ["e_u2", "e_u3"], "op": "update_squad", "squad_id": "squad.main"},
		{"command_id": "upgrade_tier", "op": "upgrade_tier", "stronghold_id": "e_stronghold", "target_tier": 2},
		{"command_id": "use_item", "hero_id": "e_hero", "item_instance_id": "item_one", "op": "use_item", "queue": "front", "target": {"kind": "entity", "entity_id": "e_u1"}},
	]


func _base_context() -> Dictionary:
	var entities := {
		"e_barr1": _producer(120),
		"e_building": _entity(20, 0, ["structure"]),
		"e_deadhero": _entity(31, 0, ["hero"]),
		"e_deposit": _entity(21, 0, ["deposit", "hall"]),
		"e_enemy": _entity(100, 1, ["ground"], true),
		"e_enemy7": _entity(107, 1, ["ground"], true),
		"e_hero": _hero(30),
		"e_hero1": _hero(130),
		"e_hero2": _hero(32),
		"e_item": _entity(40, -1, ["item"], true),
		"e_producer": _producer(22),
		"e_resource": _entity(50, -1, ["resource"], true),
		"e_reviver": _entity(23, 0, ["altar"]),
		"e_shop": _entity(41, -1, ["shop"], true),
		"e_stronghold": _producer(24),
		"e_transport": _entity(25, 0, ["transport"]),
		"e_u1": _entity(1, 0, ["ground"]),
		"e_u2": _entity(2, 0, ["ground"]),
		"e_u3": _entity(3, 0, ["ground"]),
		"e_worker": _entity(10, 0, ["worker"]),
		"e_worker2": _entity(11, 0, ["worker"]),
	}
	entities["e_building"]["construction_complete"] = false
	entities["e_building"]["repairable"] = true
	entities["e_deadhero"]["alive"] = false
	entities["e_deadhero"]["available"] = false
	entities["e_shop"]["visible_offer_ids"] = ["potion_offer"]
	entities["e_stronghold"]["tags"] = ["deposit", "hall", "producer", "stronghold"]
	entities["e_stronghold"]["tier"] = 1
	entities["e_transport"]["passenger_ids"] = ["e_u1", "e_u2"]
	return {
		"accepted_batch_ids": [],
		"all_points_explored": true,
		"application_tick": 101,
		"catalog_ids": {
			"ability_ids": ["hero_heal", "marshal_shield_strike"],
			"building_type_ids": ["barracks"],
			"unit_type_ids": ["longbow"],
			"upgrade_ids": ["ranged_attack_1"],
		},
		"controller_valid_until_tick": 101,
		"entities": entities,
		"known_regions": {
			"r_center": {
				"slots": {"high_ground": {"xy_mt": [96000, 64000]}},
				"world_region_id": "r_center",
			},
		},
		"known_sites": {
			"site_home": {"buildable": true, "explored": true, "owner_seat": 0, "xy_mt": [90000, 110000]},
			"site_resource": {"explored": true, "tags": ["resource"], "xy_mt": [80000, 100000]},
		},
		"match_id": "m_0042",
		"observation_hash": "a".repeat(64),
		"observation_seq": 18,
		"player_seat": 0,
		"received_tick": 100,
		"self_rotates_to_world": false,
		"squad_sizes": {"squad.main": 2},
		"squads": {
			"squad.main": {"member_ids": ["e_u1", "e_u2"], "tactics": {}},
		},
		"transport_passenger_counts": {"e_transport": 2},
		"world_max_inclusive_mt": [191999, 127999],
	}


func _entity(internal_id: int, owner_seat: int, tags: Array, visible: bool = true) -> Dictionary:
	return {
		"alive": true,
		"available": true,
		"current_order_interruptible": true,
		"internal_id": internal_id,
		"known": true,
		"order_queue_size": 0,
		"owner_seat": owner_seat,
		"tags": tags.duplicate(),
		"visible": visible,
	}


func _hero(internal_id: int) -> Dictionary:
	var value := _entity(internal_id, 0, ["hero"])
	value["ability_ids"] = ["marshal_shield_strike"]
	value["defensive_item_instance_ids"] = ["item_one"]
	value["item_instance_ids"] = ["item_one"]
	value["learnable_ability_ids"] = ["hero_heal"]
	return value


func _producer(internal_id: int) -> Dictionary:
	var value := _entity(internal_id, 0, ["producer"])
	value["producible_unit_ids"] = ["longbow"]
	value["production_queue_limit"] = 5
	value["production_queue_size"] = 0
	value["queue_entry_ids"] = ["q_one"]
	value["researchable_upgrade_ids"] = ["ranged_attack_1"]
	return value


func _batch(commands: Array) -> Dictionary:
	return {
		"based_on_observation_hash": "a".repeat(64),
		"client_batch_id": "batch_actions",
		"commands": commands,
		"match_id": "m_0042",
		"message_type": "action_batch",
		"observation_seq": 18,
		"protocol_version": "worldeval-rts/1.0.0",
		"valid_until_tick": 101,
	}


func _point(x: int, y: int) -> Dictionary:
	return {"kind": "point", "xy_mt": [x, y]}


func _read_normalized_json(path: String) -> Variant:
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	var normalized := CatalogLoader.normalize_json_boundary(parsed)
	_check(bool(normalized["ok"]), "could not normalize JSON fixture: %s" % path)
	return normalized["value"]


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
