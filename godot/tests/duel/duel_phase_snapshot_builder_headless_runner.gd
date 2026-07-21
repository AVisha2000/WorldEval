extends SceneTree

const Bootstrap := preload("res://scripts/duel/match/duel_match_bootstrap.gd")
const MatchRuntime := preload("res://scripts/duel/match/duel_match_runtime.gd")
const SnapshotBuilder := preload("res://scripts/duel/perception/duel_phase_snapshot_builder.gd")
const PerceptionRuntime := preload("res://scripts/duel/perception/duel_perception_runtime.gd")
const PerceptionContract := preload("res://scripts/duel/perception/duel_perception_contract.gd")
const ObservationContract := preload("res://scripts/duel/observations/duel_observation_contract.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const GOLDEN_AGGREGATE_HASH := "4dd515fecf8aaa51ed761ad02c583f9c2fe0c5844457e7107d8fa64c46448131"

var _failures := PackedStringArray()
var _hashes: Dictionary = {}


func _init() -> void:
	for faction_id: String in ["crypt-v1", "grove-v1", "vanguard-v1", "warhost-v1"]:
		_test_official_faction(faction_id)
	_test_post_tick_neutral_projection()
	_test_authoritative_queue_projection()
	_test_terminal_mapping()
	_test_fail_closed_tamper_rejection()
	var aggregate := Codec.sha256_canonical(_hashes)
	if not GOLDEN_AGGREGATE_HASH.is_empty():
		_check(aggregate == GOLDEN_AGGREGATE_HASH, "snapshot aggregate golden changed: %s" % aggregate)
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_PHASE_SNAPSHOT_FAILURE: %s" % failure)
		print("DUEL_PHASE_SNAPSHOT_FAILED count=%d hash=%s" % [_failures.size(), aggregate])
		quit(1)
		return
	print("DUEL_PHASE_SNAPSHOT_OK hash=%s factions=%s" % [aggregate, JSON.stringify(_hashes)])
	quit(0)


func _test_official_faction(faction_id: String) -> void:
	var setup := _official(faction_id, 314)
	_check(bool(setup["ok"]), "%s official protected setup failed: %s" % [
		faction_id, _errors(setup),
	])
	if not bool(setup["ok"]):
		return
	var simulation: Variant = setup["simulation"]
	_spawn_probe_item(simulation, faction_id)
	var context := _context(simulation, setup["registry"], faction_id)
	var builder := SnapshotBuilder.new()
	var first := builder.build(simulation, context)
	_check(bool(first["ok"]), "%s snapshot build failed: %s" % [faction_id, _errors(first)])
	if not bool(first["ok"]):
		return
	_check(
		PerceptionContract.validate_phase_snapshot(first["phase_snapshot"]).is_empty(),
		"%s adapter output failed the locked phase contract" % faction_id
	)
	var protected_json := str(first["protected_canonical_json"])
	for forbidden: String in [
		"tie_key", "commitment", "provider_identity", "model_identity", "world_hash",
		"state_hash", "checkpoint",
	]:
		_check(not protected_json.contains(forbidden), "%s snapshot leaked %s" % [faction_id, forbidden])

	var runtime := PerceptionRuntime.new()
	var configure_errors := runtime.configure(
		"m_snapshot-%s" % faction_id,
		setup["map_manifest"],
		("snapshot-alias-zero:%s" % faction_id).to_utf8_buffer(),
		("snapshot-alias-one:%s" % faction_id).to_utf8_buffer()
	)
	_check(configure_errors.is_empty(), "%s perception configure failed" % faction_id)
	var projected := runtime.phase_12(first["phase_snapshot"])
	_check(bool(projected["ok"]), "%s perception rejected adapter snapshot: %s" % [
		faction_id, _errors(projected),
	])
	if bool(projected["ok"]):
		var zero: Dictionary = projected["observations"]["0"]
		var one: Dictionary = projected["observations"]["1"]
		_check(
			ObservationContract.validate_observation(zero).is_empty()
			and ObservationContract.validate_observation(one).is_empty(),
			"%s produced an invalid model observation" % faction_id
		)
		_check(str(zero["working_memory"]) == "zero:%s" % faction_id, "%s seat-0 memory crossed" % faction_id)
		_check(str(one["working_memory"]) == "one:%s" % faction_id, "%s seat-1 memory crossed" % faction_id)
		_check((zero["squads"] as Array).size() == 1, "%s seat 0 squad was not joined" % faction_id)
		_check((one["squads"] as Array).is_empty(), "%s seat 0 squad leaked to seat 1" % faction_id)
		_check((zero["visible_items"] as Array).size() == 1, "%s nearby authoritative item was not visible" % faction_id)
		_check((one["visible_items"] as Array).is_empty(), "%s hidden neutral item leaked to seat 1" % faction_id)
		_check(
			str((zero["owned_entities"] as Array)[0]["entity_id"])
			!= str((one["owned_entities"] as Array)[0]["entity_id"]),
			"%s observer aliases collided across seats" % faction_id
			)
	_check_neutral_authority_snapshot(setup, first["phase_snapshot"], faction_id)
	for seat_snapshot_variant: Variant in first["phase_snapshot"]["seat_snapshots"]:
		_check(
			(seat_snapshot_variant["visible_shop_candidates"] as Array).size() == 5,
			"%s did not project all five authoritative neutral shops" % faction_id
		)

	var permuted := context.duplicate(true)
	(permuted["seat_runtime"] as Array).reverse()
	(permuted["neutral_registry"]["buildings"] as Array).reverse()
	(permuted["neutral_registry"]["ground_items"] as Array).reverse()
	var repeated := SnapshotBuilder.new().build(simulation, permuted)
	_check(bool(repeated["ok"]), "%s permuted snapshot build failed" % faction_id)
	if bool(repeated["ok"]):
		_check(
			str(repeated["protected_snapshot_hash"]) == str(first["protected_snapshot_hash"]),
			"%s input insertion order changed protected snapshot bytes" % faction_id
		)
	if faction_id == "vanguard-v1":
		var continuous := context.duplicate(true)
		for row_variant: Variant in continuous["seat_runtime"]:
			var row: Dictionary = row_variant
			row["decision"] = {
				"commands_apply_tick": 1,
				"mode": "continuous_realtime",
				"observation_tick": 0,
				"response_deadline_ms": 8_000,
				"valid_until_tick": 100,
			}
		_check(
			bool(SnapshotBuilder.new().build(simulation, continuous)["ok"]),
			"continuous-realtime pregame mode was not accepted"
		)
	_hashes[faction_id] = str(first["protected_snapshot_hash"])


func _test_authoritative_queue_projection() -> void:
	var setup := _official("vanguard-v1", 515)
	if not bool(setup["ok"]):
		_check(false, "queue projection setup failed")
		return
	var simulation: Variant = setup["simulation"]
	var stronghold_id := 0
	for entity_id: int in simulation.state.economy.sorted_entity_record_ids():
		var record: Dictionary = simulation.state.economy.entity_records[entity_id]
		if int(record["owner_seat"]) == 0 and str(record["semantic_role"]) == "stronghold":
			stronghold_id = entity_id
			break
	_check(stronghold_id > 0, "queue projection could not locate the seat-0 stronghold")
	if stronghold_id <= 0:
		return
	simulation.state.economy.players[0]["gold"] = 2_000
	simulation.state.economy.players[0]["lumber"] = 1_000
	var receipt: Dictionary = simulation.economy.queue_tier_upgrade(
		simulation.state, 0, stronghold_id, 2
	)
	_check(bool(receipt["accepted"]), "authoritative tier queue setup was rejected")
	var context := _context(simulation, setup["registry"], "vanguard-v1")
	var built := SnapshotBuilder.new().build(simulation, context)
	_check(bool(built["ok"]), "authoritative queue snapshot failed: %s" % _errors(built))
	if not bool(built["ok"]):
		return
	var seat_zero: Dictionary = built["phase_snapshot"]["seat_snapshots"][0]
	_check(
		(seat_zero["own_technology"]["researching"] as Array).size() == 1,
		"tier queue was omitted from own technology"
	)
	var found_structure_queue := false
	for entity_variant: Variant in built["phase_snapshot"]["entity_snapshots"]:
		var entity: Dictionary = entity_variant
		if int(entity["internal_id"]) == stronghold_id:
			found_structure_queue = (entity["owned_observation"]["producer_queue"] as Array).size() == 1
	_check(found_structure_queue, "tier queue was omitted from the owned stronghold")


func _test_post_tick_neutral_projection() -> void:
	var setup := _official("vanguard-v1", 616)
	if not bool(setup["ok"]):
		_check(false, "post-tick neutral setup failed")
		return
	var simulation: Variant = setup["simulation"]
	var tick_result: Dictionary = simulation.step_tick()
	_check(tick_result["phase_ids"] == range(1, 15), "post-tick neutral setup skipped a phase")
	var built := SnapshotBuilder.new().build(
		simulation, _context(simulation, setup["registry"], "vanguard-v1")
	)
	_check(bool(built["ok"]), "post-tick neutral snapshot failed: %s" % _errors(built))
	if bool(built["ok"]):
		_check_neutral_authority_snapshot(setup, built["phase_snapshot"], "post-tick")


func _test_terminal_mapping() -> void:
	var setup := _official("vanguard-v1", 911)
	if not bool(setup["ok"]):
		_check(false, "terminal setup failed")
		return
	var simulation: Variant = setup["simulation"]
	var losing_seats: Array[int] = [1]
	_check(bool(simulation.declare_technical_forfeit(losing_seats)["accepted"]), "technical forfeit setup failed")
	var built := SnapshotBuilder.new().build(
		simulation, _context(simulation, setup["registry"], "vanguard-v1")
	)
	_check(bool(built["ok"]), "terminal snapshot failed: %s" % _errors(built))
	if not bool(built["ok"]):
		return
	var terminal: Dictionary = built["phase_snapshot"]["terminal"]
	_check(
		str(terminal["kind"]) == "forfeit" and int(terminal["winner_seat"]) == 0
		and int(terminal["terminal_tick"]) == 0,
		"technical forfeit was mapped incorrectly"
	)
	_check(int(built["phase_snapshot"]["remaining_match_ticks"]) == 0, "terminal remaining time is not zero")
	var runtime := PerceptionRuntime.new()
	_check(runtime.configure(
		"m_snapshot-terminal", setup["map_manifest"],
		"snapshot-terminal-zero".to_utf8_buffer(), "snapshot-terminal-one".to_utf8_buffer()
	).is_empty(), "terminal perception configure failed")
	var projected := runtime.phase_12(built["phase_snapshot"])
	_check(bool(projected["ok"]), "terminal adapter snapshot was rejected by perception")
	if bool(projected["ok"]):
		_check(
			str(projected["observations"]["0"]["match_state"]["terminal"]["result"]) == "win"
			and str(projected["observations"]["1"]["match_state"]["terminal"]["result"]) == "forfeit",
			"terminal result was not player-relative"
		)


func _test_fail_closed_tamper_rejection() -> void:
	var setup := _official("vanguard-v1", 72)
	if not bool(setup["ok"]):
		_check(false, "tamper setup failed")
		return
	var simulation: Variant = setup["simulation"]
	var base := _context(simulation, setup["registry"], "vanguard-v1")
	var unknown := base.duplicate(true)
	unknown["world_checkpoint_hash"] = "f".repeat(64)
	_check(not bool(SnapshotBuilder.new().build(simulation, unknown)["ok"]), "unknown context field was accepted")
	var provider := base.duplicate(true)
	provider["controller_registry"]["state"]["provider_identity"] = "secret-model"
	_check(not bool(SnapshotBuilder.new().build(simulation, provider)["ok"]), "provider identity was accepted")
	var bad_binding := base.duplicate(true)
	var aliases: Array = bad_binding["controller_registry"]["entity_bindings"].keys()
	bad_binding["controller_registry"]["entity_bindings"][aliases[0]] = 999_999
	_check(not bool(SnapshotBuilder.new().build(simulation, bad_binding)["ok"]), "invalid entity binding was accepted")
	var duplicate_neutral := base.duplicate(true)
	duplicate_neutral["neutral_registry"]["buildings"][1]["entity_internal_id"] = int(
		duplicate_neutral["neutral_registry"]["buildings"][0]["entity_internal_id"]
	)
	_check(not bool(SnapshotBuilder.new().build(simulation, duplicate_neutral)["ok"]), "neutral ID collision was accepted")
	var tampered_neutral_state := base.duplicate(true)
	var first_camp_id: String = simulation.state.neutrals.sorted_camp_ids()[0]
	var first_member_ids: Array = simulation.state.neutrals.camps[first_camp_id]["members"].keys()
	first_member_ids.sort()
	var first_member: Dictionary = simulation.state.neutrals.camps[first_camp_id]["members"][first_member_ids[0]]
	first_member["spawn_position_mt"][0] = int(first_member["spawn_position_mt"][0]) + 500
	_check(
		not bool(SnapshotBuilder.new().build(simulation, tampered_neutral_state)["ok"]),
		"neutral spawn/entity authority disagreement was accepted"
	)


func _official(faction_id: String, seed: int) -> Dictionary:
	var bootstrap := Bootstrap.create_official({"faction_id": faction_id, "match_seed": seed})
	if not bool(bootstrap["ok"]):
		return bootstrap
	var attached := MatchRuntime.attach_protected_authority(
		bootstrap, ("snapshot-protected:%s:%d" % [faction_id, seed]).to_utf8_buffer()
	)
	if not bool(attached["ok"]):
		return attached
	return {
		"errors": PackedStringArray(),
		"map_manifest": bootstrap["map_manifest"],
		"ok": true,
		"registered_neutral_entity_ids": attached["registered_neutral_entity_ids"],
		"registry": bootstrap["registry"],
		"simulation": attached["simulation"],
	}


func _context(simulation: Variant, _bootstrap_registry: Dictionary, faction_id: String) -> Dictionary:
	var controller := SnapshotBuilder.empty_controller_registry()
	var first_worker_id := 0
	var owned_zero: Array[int] = []
	for entity_id: int in simulation.state.sorted_entity_ids():
		var entity: Variant = simulation.state.entities[entity_id]
		if int(entity.owner_seat) not in [0, 1]:
			continue
		controller["entity_bindings"][str(entity.public_id)] = entity_id
		if int(entity.owner_seat) == 0 and str(entity.entity_kind) == "unit":
			owned_zero.append(entity_id)
	owned_zero.sort()
	first_worker_id = owned_zero[0]
	var first_worker: Variant = simulation.state.entities[first_worker_id]
	var worker_alias := str(first_worker.public_id)
	controller["state"]["squads"]["squad.alpha"] = {
		"member_ids": [worker_alias],
		"owner_seat": 0,
		"tactics": {"formation": "line", "retreat_hp_threshold_bp": 2500, "stance": "aggressive"},
	}
	controller["state"]["tactics_by_actor"][worker_alias] = {
		"formation": "line", "retreat_hp_threshold_bp": 2500, "stance": "aggressive",
	}
	var building_bindings: Dictionary = {}
	var virtual_id := 1_500_000_000
	for building_id: String in simulation.state.neutrals.sorted_building_ids():
		building_bindings[building_id] = virtual_id
		virtual_id += 1
	var neutral := SnapshotBuilder.neutral_registry_from_authority(
		simulation, building_bindings
	)
	var phase: Dictionary = simulation.neutrals.day_phase(int(simulation.state.tick))
	return {
		"controller_registry": controller,
		"day_phase": "forced_night" if bool(phase["forced"]) else str(phase["phase"]),
		"neutral_registry": neutral,
		"seat_runtime": [
			_seat_runtime(0, faction_id, int(simulation.state.tick)),
			_seat_runtime(1, faction_id, int(simulation.state.tick)),
		],
		"world_event_seq_after": 0,
	}


func _spawn_probe_item(simulation: Variant, faction_id: String) -> void:
	var worker_id := 0
	for entity_id: int in simulation.state.sorted_entity_ids():
		var entity: Variant = simulation.state.entities[entity_id]
		if int(entity.owner_seat) == 0 and str(entity.entity_kind) == "unit":
			worker_id = entity_id
			break
	_check(worker_id > 0, "%s probe item has no seat-0 anchor" % faction_id)
	if worker_id <= 0:
		return
	var worker: Variant = simulation.state.entities[worker_id]
	var receipt: Dictionary = simulation.heroes.spawn_ground_item(
		simulation.state,
		"lesser_vitality_draught",
		[int(worker.position_x_mt), int(worker.position_y_mt)],
		int(simulation.state.tick),
		int(simulation.state.tick) + 600,
		"phase_snapshot_probe",
	)
	_check(bool(receipt.get("accepted", false)), "%s authoritative probe item spawn failed" % faction_id)


func _check_neutral_authority_snapshot(
	setup: Dictionary, phase_snapshot: Dictionary, faction_id: String
) -> void:
	var simulation: Variant = setup["simulation"]
	var registered: Array = setup["registered_neutral_entity_ids"]
	_check(registered.size() == 34, "%s official neutral entity count changed" % faction_id)
	var snapshot_by_id: Dictionary = {}
	for row_variant: Variant in phase_snapshot["entity_snapshots"]:
		var row: Dictionary = row_variant
		snapshot_by_id[int(row["internal_id"])] = row
	var relocated_count := 0
	var authored_camps: Dictionary = {}
	for camp_variant: Variant in simulation.neutrals.map_manifest["creep_camps"]:
		authored_camps[str(camp_variant["id"])] = camp_variant
	for camp_id: String in simulation.state.neutrals.sorted_camp_ids():
		var camp: Dictionary = simulation.state.neutrals.camps[camp_id]
		var authored: Dictionary = authored_camps[camp_id]
		var authored_anchor: Array = authored["anchor_cell"]
		var authored_members: Dictionary = {}
		for source_variant: Variant in authored["member_spawns"]:
			authored_members[str(source_variant["id"])] = source_variant
		var member_ids: Array = camp["members"].keys()
		member_ids.sort()
		for member_id_variant: Variant in member_ids:
			var member_id := str(member_id_variant)
			var member: Dictionary = camp["members"][member_id]
			var entity_id := int(member["internal_id"])
			_check(snapshot_by_id.has(entity_id), "%s neutral snapshot omitted %s" % [faction_id, member_id])
			if snapshot_by_id.has(entity_id):
				var snapshot: Dictionary = snapshot_by_id[entity_id]
				_check(
					snapshot["position_mt"] == member["spawn_position_mt"]
					and str(snapshot["type_id"]) == str(member["neutral_id"])
					and int(snapshot["sight_day_mt"]) > 0,
					"%s neutral snapshot disagrees with %s" % [faction_id, member_id]
				)
			var source: Dictionary = authored_members[member_id]
			var cell: Array = source["cell"]
			var requested := [
				int(authored["position_mt"][0]) + (int(cell[0]) - int(authored_anchor[0])) * 500,
				int(authored["position_mt"][1]) + (int(cell[1]) - int(authored_anchor[1])) * 500,
			]
			if requested != member["spawn_position_mt"]:
				relocated_count += 1
	_check(relocated_count > 0, "%s official overlapping neutral spawns were not relocated" % faction_id)


func _seat_runtime(seat: int, faction_id: String, observation_tick: int) -> Dictionary:
	return {
		"decision": {
			"commands_apply_tick": observation_tick + 1,
			"mode": "fixed_simultaneous",
			"observation_tick": observation_tick,
			"response_deadline_ms": 45_000,
			"valid_until_tick": observation_tick + 1,
		},
		"include_brief": true,
		"last_action_receipt": {
			"apply_tick": 1,
			"batch_id": "previous_zero",
			"batch_status": "applied",
			"commands": [{
				"atomic_cost": 1,
				"code": null,
				"command_id": "previous_command",
				"compiled_order_ids": ["order.previous"],
				"status": "applied",
			}],
			"observation_seq": 0,
			"received_tick": 0,
		} if seat == 0 else null,
		"observation_seq": 1,
		"seat": seat,
		"working_memory": ("zero:" if seat == 0 else "one:") + faction_id,
	}


func _errors(result: Dictionary) -> String:
	var parts := PackedStringArray()
	for error: Variant in result.get("errors", []):
		parts.append(str(error))
	return "; ".join(parts)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
