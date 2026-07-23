class_name DuelEconomy
extends RefCounted

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const StateRecord := preload("res://scripts/duel/simulation/duel_state.gd")
const OccupancyGrid := preload("res://scripts/duel/simulation/duel_occupancy_grid.gd")
const EconomyState := preload("res://scripts/duel/economy/duel_economy_state.gd")

## Deterministic economy authority. All content values come from a merged
## runtime catalog; this class contains only the rules for applying those
## values. Commands return stable, non-leaking receipts and never partially
## reserve a rejected entry.

const MAX_FOOD := 100
const QUEUE_CAPACITY := 5
const MAX_REPAIR_WORKERS := 5

var catalog: Dictionary = {}
var _pending_worker_ids: Array[int] = []
var _pending_construction_ids: Array[int] = []
var _pending_repair_ids: Array[int] = []
var _pending_producer_ids: Array[int] = []
var _pending_tier_seats: Array[int] = []
var _events: Array[Dictionary] = []
var _progress_this_tick: bool = false


func configure(economy: EconomyState, merged_catalog: Dictionary) -> PackedStringArray:
	var errors := validate_catalog(merged_catalog)
	if not errors.is_empty():
		return errors
	catalog = merged_catalog.duplicate(true)
	economy.reset()
	economy.enabled = true
	economy.catalog_hash = Codec.sha256_canonical(catalog)
	return errors


func is_configured(economy: EconomyState) -> bool:
	return economy.enabled and not catalog.is_empty()


func validate_catalog(value: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	for section: String in [
		"construction", "food_and_upkeep", "structures", "technology", "units", "upgrades",
	]:
		if not value.has(section) or typeof(value[section]) != TYPE_DICTIONARY:
			errors.append("economy catalog.%s must be an object" % section)
	if not errors.is_empty():
		return errors

	var construction: Dictionary = value["construction"]
	for field: String in [
		"work_bp_per_worker_tick", "minimum_incomplete_hp_bp", "repair_hp_per_worker_tick",
		"full_repair_cost_bp_of_original",
	]:
		_require_non_negative_int(construction, field, "construction", errors)
	if typeof(construction.get("cooperative_speed_bp", null)) != TYPE_ARRAY:
		errors.append("economy catalog.construction.cooperative_speed_bp must be an array")
	else:
		var speeds: Array = construction["cooperative_speed_bp"]
		if speeds.size() != MAX_REPAIR_WORKERS:
			errors.append("cooperative_speed_bp must contain worker counts 1 through 5")
		for index: int in speeds.size():
			if typeof(speeds[index]) != TYPE_INT or int(speeds[index]) <= 0:
				errors.append("cooperative_speed_bp[%d] must be a positive integer" % index)

	var food: Dictionary = value["food_and_upkeep"]
	if typeof(food.get("maximum_food", null)) != TYPE_INT \
		or int(food.get("maximum_food", 0)) != MAX_FOOD:
		errors.append("food_and_upkeep.maximum_food must equal 100")
	if typeof(food.get("upkeep", null)) != TYPE_ARRAY \
		or (food.get("upkeep", []) as Array).size() != 3:
		errors.append("food_and_upkeep.upkeep must contain exactly three tiers")

	var structures: Dictionary = value["structures"]
	var structure_ids: Array = structures.keys()
	structure_ids.sort()
	for id_variant: Variant in structure_ids:
		var catalog_id := str(id_variant)
		if typeof(structures[id_variant]) != TYPE_DICTIONARY:
			errors.append("structure %s must be an object" % catalog_id)
			continue
		var definition: Dictionary = structures[id_variant]
		_validate_common_definition(catalog_id, definition, "structure", errors)
		for field: String in ["build_ticks", "food_provided", "required_tier", "radius_mt"]:
			_require_non_negative_int(definition, field, "structure.%s" % catalog_id, errors)
		if str(definition.get("semantic_role", "")).is_empty():
			errors.append("structure.%s.semantic_role must not be empty" % catalog_id)

	var units: Dictionary = value["units"]
	var unit_ids: Array = units.keys()
	unit_ids.sort()
	for id_variant: Variant in unit_ids:
		var catalog_id := str(id_variant)
		if typeof(units[id_variant]) != TYPE_DICTIONARY:
			errors.append("unit %s must be an object" % catalog_id)
			continue
		var definition: Dictionary = units[id_variant]
		_validate_common_definition(catalog_id, definition, "unit", errors)
		for field: String in ["food_cost", "train_ticks", "required_tier", "radius_mt"]:
			_require_non_negative_int(definition, field, "unit.%s" % catalog_id, errors)
		if typeof(definition.get("producer_roles", null)) != TYPE_ARRAY:
			errors.append("unit.%s.producer_roles must be an array" % catalog_id)

	var technology: Dictionary = value["technology"]
	for key: String in ["tier_2", "tier_3"]:
		if typeof(technology.get(key, null)) != TYPE_DICTIONARY:
			errors.append("technology.%s must be an object" % key)
			continue
		var tier: Dictionary = technology[key]
		for field: String in ["cost_gold", "cost_lumber", "duration_ticks", "hero_slots"]:
			_require_non_negative_int(tier, field, "technology.%s" % key, errors)

	for error: String in Codec.validate_canonical_value(value, "$.economy_catalog"):
		errors.append(error)
	return errors


func configure_player(
	state: StateRecord,
	seat: int,
	starting_gold: int = 500,
	starting_lumber: int = 200,
	technology_tier: int = 1
) -> Dictionary:
	if not _ready(state) or seat < 0 or seat > 1:
		return _receipt(state, seat, "configure_player", false, "invalid_request", {})
	if state.economy.players.has(seat):
		return _receipt(state, seat, "configure_player", false, "already_exists", {})
	if starting_gold < 0 or starting_lumber < 0 \
		or technology_tier < 1 or technology_tier > 3:
		return _receipt(state, seat, "configure_player", false, "invalid_request", {})
	var hero_slots := int(catalog["technology"]["tier_%d" % technology_tier].get(
		"hero_slots", technology_tier
	)) if technology_tier > 1 else 1
	state.economy.players[seat] = {
		"completed_upgrades": {},
		"food_capacity": 0,
		"food_used": 0,
		"gold": starting_gold,
		"gold_delivery_bp": 10_000,
		"hero_slots": hero_slots,
		"lumber": starting_lumber,
		"reserved_food": 0,
		"technology_tier": technology_tier,
		"upkeep_tier": "none",
	}
	_update_upkeep(state.economy.players[seat])
	return _receipt(state, seat, "configure_player", true, "accepted", {
		"gold": starting_gold,
		"lumber": starting_lumber,
		"technology_tier": technology_tier,
	})


func apply_external_resource_delta(
	state: StateRecord,
	seat: int,
	gold_delta: int,
	lumber_delta: int,
	source_kind: String,
	source_id: String = ""
) -> Dictionary:
	## Neutral rewards and market charges use a narrow atomic boundary instead
	## of writing player dictionaries from another subsystem.
	if not _ready(state) or not state.economy.players.has(seat) \
		or source_kind.is_empty():
		return _receipt(state, seat, "external_resource_delta", false, "invalid_request", {})
	var player: Dictionary = state.economy.players[seat]
	var next_gold := int(player["gold"]) + gold_delta
	var next_lumber := int(player["lumber"]) + lumber_delta
	if next_gold < 0 or next_lumber < 0:
		return _receipt(
			state, seat, "external_resource_delta", false, "insufficient_resources", {}
		)
	player["gold"] = next_gold
	player["lumber"] = next_lumber
	_queue_event(state.tick, "external_resources_applied", 0, 0, {
		"gold_delta": gold_delta,
		"lumber_delta": lumber_delta,
		"seat": seat,
		"source_id": source_id,
		"source_kind": source_kind,
	})
	_progress_this_tick = gold_delta != 0 or lumber_delta != 0
	return _receipt(state, seat, "external_resource_delta", true, "accepted", {
		"gold": next_gold,
		"gold_delta": gold_delta,
		"lumber": next_lumber,
		"lumber_delta": lumber_delta,
		"source_id": source_id,
		"source_kind": source_kind,
	})


func register_completed_entity(state: StateRecord, entity_id: int) -> PackedStringArray:
	var errors := PackedStringArray()
	if not _ready(state):
		errors.append("economy is not configured")
		return errors
	if not state.entities.has(entity_id):
		errors.append("entity does not exist")
		return errors
	if state.economy.entity_records.has(entity_id):
		errors.append("entity is already registered with economy")
		return errors
	var entity: EntityRecord = state.entities[entity_id]
	if not state.economy.players.has(entity.owner_seat):
		errors.append("entity owner has no economy")
		return errors
	var definition := _definition(entity.catalog_id)
	if definition.is_empty():
		errors.append("entity catalog definition is not economic")
		return errors
	var kind := "structure" if catalog["structures"].has(entity.catalog_id) else "unit"
	var food_cost := int(definition.get("food_cost", 0))
	var food_provided := int(definition.get("food_provided", 0))
	var player: Dictionary = state.economy.players[entity.owner_seat]
	if player["food_used"] + food_cost > MAX_FOOD:
		errors.append("entity registration would exceed maximum food")
		return errors
	state.economy.entity_records[entity_id] = {
		"catalog_id": entity.catalog_id,
		"entity_id": entity_id,
		"food_cost": food_cost,
		"food_provided": food_provided,
		"kind": kind,
		"owner_seat": entity.owner_seat,
		"semantic_role": str(definition.get("semantic_role", "unit")),
	}
	player["food_used"] += food_cost
	player["food_capacity"] = mini(MAX_FOOD, player["food_capacity"] + food_provided)
	_update_upkeep(player)
	entity.integer_attributes["construction_complete"] = 1
	entity.integer_attributes["construction_progress_bp"] = 10_000
	return errors


func register_external_unit(
	state: StateRecord,
	entity_id: int,
	definition: Dictionary,
	source_kind: String
) -> PackedStringArray:
	## Narrow handoff for protocol-locked hired units. External units never enter
	## the faction production catalog, so every economic fact needed after the
	## purchase is copied into canonical entity/record state here.
	var errors := PackedStringArray()
	if not _ready(state):
		errors.append("economy is not configured")
		return errors
	if not state.entities.has(entity_id):
		errors.append("external unit entity does not exist")
		return errors
	if state.economy.entity_records.has(entity_id):
		errors.append("external unit is already registered with economy")
		return errors
	if source_kind not in ["hire", "summon"]:
		errors.append("external economic unit source is invalid")
	for field: String in ["food", "radius_mt", "speed_mt_per_tick", "tags"]:
		if not definition.has(field):
			errors.append("external unit definition is missing %s" % field)
	if typeof(definition.get("food", null)) != TYPE_INT or int(definition.get("food", -1)) < 0:
		errors.append("external unit food must be a non-negative integer")
	if typeof(definition.get("tags", null)) != TYPE_ARRAY:
		errors.append("external unit tags must be an array")
	if not errors.is_empty():
		return errors
	var entity: EntityRecord = state.entities[entity_id]
	if entity.owner_seat not in [0, 1] or not state.economy.players.has(entity.owner_seat):
		errors.append("external unit owner has no economy")
		return errors
	var food_cost := int(definition["food"])
	var player: Dictionary = state.economy.players[entity.owner_seat]
	if int(player["food_used"]) + int(player["reserved_food"]) + food_cost \
		> int(player["food_capacity"]):
		errors.append("external unit registration is food-cap blocked")
		return errors
	var tags := _string_array(definition["tags"])
	var is_worker := "worker" in tags
	state.economy.entity_records[entity_id] = {
		"catalog_id": entity.catalog_id,
		"entity_id": entity_id,
		"food_cost": food_cost,
		"food_provided": 0,
		"kind": "unit",
		"owner_seat": entity.owner_seat,
		"semantic_role": "worker" if is_worker else source_kind,
		"source_kind": source_kind,
	}
	player["food_used"] += food_cost
	_update_upkeep(player)
	entity.integer_attributes["construction_complete"] = 1
	entity.integer_attributes["construction_progress_bp"] = 10_000
	entity.integer_attributes["external_worker"] = 1 if is_worker else 0
	if is_worker and definition.has("lumber_cargo") and definition.has("lumber_work_ticks"):
		entity.integer_attributes["gather_lumber_cargo"] = int(definition["lumber_cargo"])
		entity.integer_attributes["gather_lumber_work_ticks"] = int(definition["lumber_work_ticks"])
	return errors


func register_resource_node(
	state: StateRecord,
	entity_id: int,
	resource_type: String,
	stock: int,
	slots: int,
	cargo_amount: int,
	work_ticks: int
) -> PackedStringArray:
	var errors := PackedStringArray()
	if not _ready(state):
		errors.append("economy is not configured")
	if not state.entities.has(entity_id):
		errors.append("resource entity does not exist")
	if resource_type not in ["gold", "lumber"]:
		errors.append("resource_type must be gold or lumber")
	if stock < 0 or slots <= 0 or cargo_amount <= 0 or work_ticks <= 0:
		errors.append("resource node values are invalid")
	if state.economy.resource_nodes.has(entity_id):
		errors.append("resource node is already registered")
	if not errors.is_empty():
		return errors
	var entity: EntityRecord = state.entities[entity_id]
	state.economy.resource_nodes[entity_id] = {
		"assigned_worker_ids": [],
		"cargo_amount": cargo_amount,
		"catalog_id": entity.catalog_id,
		"entity_id": entity_id,
		"maximum_stock": stock,
		"resource_type": resource_type,
		"slots": slots,
		"stock": stock,
		"work_ticks": work_ticks,
	}
	entity.integer_attributes["resource_stock"] = stock
	return errors


func assign_gather(
	state: StateRecord,
	seat: int,
	worker_ids: Array[int],
	resource_entity_id: int,
	deposit_entity_id: int,
	travel_to_ticks: int,
	travel_return_ticks: int
) -> Dictionary:
	if not _ready(state) or not state.economy.players.has(seat):
		return _receipt(state, seat, "gather", false, "invalid_request", {})
	if not state.economy.resource_nodes.has(resource_entity_id) \
		or not _is_owned_deposit(state, seat, deposit_entity_id):
		return _receipt(state, seat, "gather", false, "target_unavailable", {})
	if worker_ids.is_empty() or travel_to_ticks < 0 or travel_return_ticks < 0:
		return _receipt(state, seat, "gather", false, "invalid_request", {})
	var canonical_workers := _unique_sorted(worker_ids)
	if canonical_workers.size() != worker_ids.size():
		return _receipt(state, seat, "gather", false, "invalid_request", {})
	var node: Dictionary = state.economy.resource_nodes[resource_entity_id]
	var resource_type := str(node["resource_type"])
	for worker_id: int in canonical_workers:
		if not _is_owned_worker(state, seat, worker_id):
			return _receipt(state, seat, "gather", false, "not_owned", {})
		var worker: EntityRecord = state.entities[worker_id]
		var profiles := _worker_gather_profiles(worker)
		if not profiles.is_empty() and not profiles.has(resource_type):
			return _receipt(state, seat, "gather", false, "invalid_actor", {})
	for worker_id: int in canonical_workers:
		var worker: EntityRecord = state.entities[worker_id]
		var profiles := _worker_gather_profiles(worker)
		var profile: Dictionary = profiles.get(resource_type, {})
		_clear_worker_assignment(state, worker_id)
		state.economy.worker_tasks[worker_id] = {
			"cargo": 0,
			"cargo_amount": int(profile.get("cargo", node["cargo_amount"])),
			"cycle_index": 0,
			"deposit_entity_id": deposit_entity_id,
			"node_entity_id": resource_entity_id,
			"phase": "to_resource",
			"remaining_travel_ticks": travel_to_ticks,
			"resource_type": resource_type,
			"travel_return_ticks": travel_return_ticks,
			"travel_to_ticks": travel_to_ticks,
			"work_progress_ticks": 0,
			"work_ticks": int(profile.get("work_ticks", node["work_ticks"])),
			"worker_id": worker_id,
		}
	return _receipt(state, seat, "gather", true, "accepted", {
		"resource_entity_id": resource_entity_id,
		"worker_ids": canonical_workers,
	})


func return_cargo(
	state: StateRecord,
	seat: int,
	worker_ids: Array[int],
	deposit_entity_id: int
) -> Dictionary:
	if not _is_owned_deposit(state, seat, deposit_entity_id):
		return _receipt(state, seat, "return_cargo", false, "target_unavailable", {})
	var canonical_workers := _unique_sorted(worker_ids)
	for worker_id: int in canonical_workers:
		if not _is_owned_worker(state, seat, worker_id):
			return _receipt(state, seat, "return_cargo", false, "not_owned", {})
		if not state.economy.worker_tasks.has(worker_id) \
			or int(state.economy.worker_tasks[worker_id].get("cargo", 0)) <= 0:
			return _receipt(state, seat, "return_cargo", false, "invalid_state", {})
	for worker_id: int in canonical_workers:
		var task: Dictionary = state.economy.worker_tasks[worker_id]
		task["deposit_entity_id"] = deposit_entity_id
		task["phase"] = "to_deposit"
		task["remaining_travel_ticks"] = int(task["travel_return_ticks"])
	return _receipt(state, seat, "return_cargo", true, "accepted", {
		"deposit_entity_id": deposit_entity_id,
		"worker_ids": canonical_workers,
	})


func begin_construction(
	state: StateRecord,
	grid: OccupancyGrid,
	seat: int,
	structure_catalog_id: String,
	site_id: String,
	position_x_mt: int,
	position_y_mt: int,
	worker_ids: Array[int]
) -> Dictionary:
	if not _ready(state) or not state.economy.players.has(seat):
		return _receipt(state, seat, "build", false, "invalid_request", {})
	if not catalog["structures"].has(structure_catalog_id):
		return _receipt(state, seat, "build", false, "unknown_catalog_id", {})
	if site_id.is_empty() or state.economy.claimed_site_ids.has(site_id):
		return _receipt(state, seat, "build", false, "target_unavailable", {})
	var definition: Dictionary = catalog["structures"][structure_catalog_id]
	var player: Dictionary = state.economy.players[seat]
	if int(definition["required_tier"]) > int(player["technology_tier"]):
		return _receipt(state, seat, "build", false, "prerequisite_missing", {})
	var canonical_workers := _unique_sorted(worker_ids)
	if canonical_workers.is_empty() or canonical_workers.size() != worker_ids.size():
		return _receipt(state, seat, "build", false, "invalid_request", {})
	for worker_id: int in canonical_workers:
		if not _is_owned_worker(state, seat, worker_id):
			return _receipt(state, seat, "build", false, "not_owned", {})
	var cost_gold := int(definition["cost_gold"])
	var cost_lumber := int(definition["cost_lumber"])
	if not _can_reserve(player, cost_gold, cost_lumber):
		return _receipt(state, seat, "build", false, "insufficient_resources", {})
	var radius_mt := int(definition["radius_mt"])
	if grid == null or not grid.fits_ground_footprint_at_position(
		position_x_mt, position_y_mt, radius_mt
	):
		return _receipt(state, seat, "build", false, "target_unavailable", {})

	var building_id := state.next_entity_id
	if not grid.reserve_ground_actor(building_id, position_x_mt, position_y_mt, radius_mt):
		return _receipt(state, seat, "build", false, "target_unavailable", {})
	var building := EntityRecord.new(building_id, seat, "structure")
	building.catalog_id = structure_catalog_id
	building.radius_mt = radius_mt
	building.max_hp = int(definition["max_hp"])
	var minimum_hp_bp := int(catalog["construction"]["minimum_incomplete_hp_bp"])
	@warning_ignore("integer_division")
	building.hp = maxi(1, (building.max_hp * minimum_hp_bp) / 10_000)
	building.set_position_mt(position_x_mt, position_y_mt)
	building.tags.assign(_string_array(definition.get("tags", [])))
	building.integer_attributes["construction_complete"] = 0
	building.integer_attributes["construction_progress_bp"] = 0
	if state.add_entity(building) == 0:
		grid.release_ground_actor(building_id)
		return _receipt(state, seat, "build", false, "execution_failed", {})

	_reserve(player, cost_gold, cost_lumber)
	for worker_id: int in canonical_workers:
		_clear_worker_assignment(state, worker_id)
	var build_ticks := int(definition["build_ticks"])
	var work_per_tick := int(catalog["construction"]["work_bp_per_worker_tick"])
	state.economy.construction_sites[building_id] = {
		"building_id": building_id,
		"catalog_id": structure_catalog_id,
		"cost_gold": cost_gold,
		"cost_lumber": cost_lumber,
		"food_provided": int(definition["food_provided"]),
		"granted_hp": building.hp,
		"owner_seat": seat,
		"refund_applied": false,
		"site_id": site_id,
		"work_done_bp": 0,
		"work_required_bp": build_ticks * work_per_tick,
		"worker_ids": canonical_workers,
		"worker_range_mt": int(definition["worker_range_mt"]),
	}
	state.economy.claimed_site_ids[site_id] = building_id
	return _receipt(state, seat, "build", true, "accepted", {
		"building_id": building_id,
		"reserved_gold": cost_gold,
		"reserved_lumber": cost_lumber,
		"site_id": site_id,
	})


func assign_construction_workers(
	state: StateRecord,
	seat: int,
	building_id: int,
	worker_ids: Array[int]
) -> Dictionary:
	if not state.economy.construction_sites.has(building_id):
		return _receipt(state, seat, "assign_construction", false, "target_unavailable", {})
	var site: Dictionary = state.economy.construction_sites[building_id]
	if int(site["owner_seat"]) != seat:
		return _receipt(state, seat, "assign_construction", false, "not_owned", {})
	var canonical_workers := _unique_sorted(worker_ids)
	if canonical_workers.is_empty() or canonical_workers.size() != worker_ids.size():
		return _receipt(state, seat, "assign_construction", false, "invalid_request", {})
	for worker_id: int in canonical_workers:
		if not _is_owned_worker(state, seat, worker_id):
			return _receipt(state, seat, "assign_construction", false, "not_owned", {})
	for worker_id: int in canonical_workers:
		_clear_worker_assignment(state, worker_id)
	var combined := _unique_sorted((site["worker_ids"] as Array) + canonical_workers)
	site["worker_ids"] = combined
	return _receipt(state, seat, "assign_construction", true, "accepted", {
		"building_id": building_id,
		"worker_ids": combined,
	})


func cancel_construction(
	state: StateRecord,
	grid: OccupancyGrid,
	seat: int,
	building_id: int
) -> Dictionary:
	if not state.economy.construction_sites.has(building_id):
		return _receipt(state, seat, "cancel_construction", false, "target_unavailable", {})
	var site: Dictionary = state.economy.construction_sites[building_id]
	if int(site["owner_seat"]) != seat:
		return _receipt(state, seat, "cancel_construction", false, "not_owned", {})
	@warning_ignore("integer_division")
	var progress_bp := (int(site["work_done_bp"]) * 10_000) / maxi(
		1, int(site["work_required_bp"])
	)
	var refund_bp := _cancellation_refund_bp(progress_bp)
	var refund := _refund_cost(
		state.economy.players[seat], int(site["cost_gold"]), int(site["cost_lumber"]), refund_bp
	)
	_remove_construction_site(state, grid, building_id)
	return _receipt(state, seat, "cancel_construction", true, "accepted", {
		"building_id": building_id,
		"progress_bp": progress_bp,
		"refund_gold": int(refund["gold"]),
		"refund_lumber": int(refund["lumber"]),
	})


func assign_repair(
	state: StateRecord,
	seat: int,
	building_id: int,
	worker_ids: Array[int]
) -> Dictionary:
	if not state.economy.entity_records.has(building_id) \
		or not state.entities.has(building_id):
		return _receipt(state, seat, "repair", false, "target_unavailable", {})
	var record: Dictionary = state.economy.entity_records[building_id]
	if int(record["owner_seat"]) != seat:
		return _receipt(state, seat, "repair", false, "not_owned", {})
	if str(record["kind"]) != "structure":
		return _receipt(state, seat, "repair", false, "invalid_target", {})
	var canonical_workers := _unique_sorted(worker_ids)
	if canonical_workers.is_empty() or canonical_workers.size() != worker_ids.size():
		return _receipt(state, seat, "repair", false, "invalid_request", {})
	if canonical_workers.size() > MAX_REPAIR_WORKERS:
		return _receipt(state, seat, "repair", false, "invalid_request", {})
	for worker_id: int in canonical_workers:
		if not _is_owned_worker(state, seat, worker_id):
			return _receipt(state, seat, "repair", false, "not_owned", {})
	for worker_id: int in canonical_workers:
		_clear_worker_assignment(state, worker_id)
	if not state.economy.repair_ledgers.has(building_id):
		state.economy.repair_ledgers[building_id] = {
			"building_id": building_id,
			"gold_remainder": 0,
			"lumber_remainder": 0,
			"owner_seat": seat,
			"worker_ids": canonical_workers,
		}
	else:
		state.economy.repair_ledgers[building_id]["worker_ids"] = canonical_workers
	return _receipt(state, seat, "repair", true, "accepted", {
		"building_id": building_id,
		"worker_ids": canonical_workers,
	})


func queue_production(
	state: StateRecord,
	seat: int,
	producer_id: int,
	unit_catalog_id: String,
	quantity: int
) -> Dictionary:
	if not _ready(state) or not state.economy.players.has(seat):
		return _receipt(state, seat, "produce", false, "invalid_request", {})
	if quantity <= 0 or quantity > QUEUE_CAPACITY \
		or not catalog["units"].has(unit_catalog_id):
		return _receipt(state, seat, "produce", false, "invalid_request", {})
	var producer_check := _validate_producer(state, seat, producer_id)
	if not producer_check.is_empty():
		return _receipt(state, seat, "produce", false, producer_check, {})
	var producer_record: Dictionary = state.economy.entity_records[producer_id]
	var definition: Dictionary = catalog["units"][unit_catalog_id]
	if str(producer_record["semantic_role"]) not in definition["producer_roles"]:
		return _receipt(state, seat, "produce", false, "invalid_producer", {})
	var player: Dictionary = state.economy.players[seat]
	if int(definition["required_tier"]) > int(player["technology_tier"]):
		return _receipt(state, seat, "produce", false, "prerequisite_missing", {})
	var queue: Array = state.economy.production_queues.get(producer_id, [])
	var accepted_quantity := 0
	for _index: int in quantity:
		if queue.size() >= QUEUE_CAPACITY:
			break
		var cost_gold := int(definition["cost_gold"])
		var cost_lumber := int(definition["cost_lumber"])
		var food_cost := int(definition["food_cost"])
		if not _can_reserve(player, cost_gold, cost_lumber):
			break
		if int(player["food_used"]) + int(player["reserved_food"]) + food_cost \
			> int(player["food_capacity"]):
			break
		_reserve(player, cost_gold, cost_lumber)
		player["reserved_food"] += food_cost
		queue.append({
			"catalog_id": unit_catalog_id,
			"cost_gold": cost_gold,
			"cost_lumber": cost_lumber,
			"entry_id": state.economy.allocate_entry_id(),
			"food_committed": false,
			"food_cost": food_cost,
			"kind": "unit",
			"owner_seat": seat,
			"producer_id": producer_id,
			"remaining_ticks": int(definition["train_ticks"]),
			"total_ticks": int(definition["train_ticks"]),
		})
		accepted_quantity += 1
	state.economy.production_queues[producer_id] = queue
	if accepted_quantity == 0:
		return _receipt(state, seat, "produce", false, _queue_failure_code(
			queue, player, definition
		), {"accepted_quantity": 0})
	return _receipt(state, seat, "produce", true, "accepted", {
		"accepted_quantity": accepted_quantity,
		"producer_id": producer_id,
		"requested_quantity": quantity,
		"unit_catalog_id": unit_catalog_id,
	})


func queue_hero_production(
	state: StateRecord,
	seat: int,
	producer_id: int,
	hero_type_id: String,
	hero_definition: Dictionary,
	hero_rules: Dictionary
) -> Dictionary:
	## Heroes share the producer FIFO and reservation ledger with units, while
	## retaining their unique named-archetype and tier-slot rules.
	if not _ready(state) or not state.economy.players.has(seat):
		return _receipt(state, seat, "produce", false, "invalid_request", {})
	if not state.heroes.enabled:
		return _receipt(state, seat, "produce", false, "authority_unavailable", {})
	var required_definition_fields := [
		"base_attributes_centi", "base_body_hp", "base_body_mana", "food",
		"radius_mt", "speed_mt_per_tick",
	]
	for field: String in required_definition_fields:
		if not hero_definition.has(field):
			return _receipt(state, seat, "produce", false, "unknown_catalog_id", {})
	for field: String in ["first_hero", "later_hero", "named_archetype_limit", "slots_by_tier"]:
		if not hero_rules.has(field):
			return _receipt(state, seat, "produce", false, "invalid_request", {})
	if typeof(hero_rules["named_archetype_limit"]) != TYPE_INT \
		or int(hero_rules["named_archetype_limit"]) <= 0 \
		or typeof(hero_rules["slots_by_tier"]) != TYPE_ARRAY \
		or (hero_rules["slots_by_tier"] as Array).size() != 3:
		return _receipt(state, seat, "produce", false, "invalid_request", {})
	var producer_check := _validate_producer(state, seat, producer_id)
	if not producer_check.is_empty():
		return _receipt(state, seat, "produce", false, producer_check, {})
	var producer_record: Dictionary = state.economy.entity_records[producer_id]
	if str(producer_record["semantic_role"]) != "hero_altar":
		return _receipt(state, seat, "produce", false, "invalid_producer", {})
	var producer_definition := _definition(str(producer_record["catalog_id"]))
	if hero_type_id not in producer_definition.get("producer_type_ids", []):
		return _receipt(state, seat, "produce", false, "invalid_producer", {})
	var owned_hero_count := 0
	var owned_named_count := 0
	for hero_id: int in state.heroes.sorted_hero_ids():
		var hero: Dictionary = state.heroes.heroes[hero_id]
		if int(hero["owner_seat"]) != seat:
			continue
		owned_hero_count += 1
		if str(hero["hero_type_id"]) == hero_type_id:
			owned_named_count += 1
	var queued_hero_count := 0
	var queued_named_count := 0
	for producer_key: int in state.economy.sorted_producer_ids():
		for entry_variant: Variant in state.economy.production_queues[producer_key]:
			var existing: Dictionary = entry_variant
			if str(existing.get("kind", "")) != "hero" \
				or int(existing.get("owner_seat", -1)) != seat:
				continue
			queued_hero_count += 1
			if str(existing.get("catalog_id", "")) == hero_type_id:
				queued_named_count += 1
	var player: Dictionary = state.economy.players[seat]
	var named_limit := int(hero_rules["named_archetype_limit"])
	if owned_named_count + queued_named_count >= named_limit:
		return _receipt(
			state, seat, "produce", false,
			"already_completed" if owned_named_count >= named_limit else "already_queued", {}
		)
	var tier := int(player["technology_tier"])
	var slots_by_tier: Array = hero_rules["slots_by_tier"]
	if tier < 1 or tier > slots_by_tier.size() \
		or typeof(slots_by_tier[tier - 1]) != TYPE_INT \
		or int(player["hero_slots"]) != int(slots_by_tier[tier - 1]):
		return _receipt(state, seat, "produce", false, "invalid_state", {})
	if owned_hero_count + queued_hero_count >= int(slots_by_tier[tier - 1]):
		return _receipt(state, seat, "produce", false, "prerequisite_missing", {})
	var queue: Array = state.economy.production_queues.get(producer_id, [])
	if queue.size() >= QUEUE_CAPACITY:
		return _receipt(state, seat, "produce", false, "queue_full", {})
	var first := owned_hero_count + queued_hero_count == 0
	var training: Dictionary = hero_rules["first_hero" if first else "later_hero"]
	for field: String in ["cost_gold", "cost_lumber", "food", "train_ticks"]:
		if typeof(training.get(field, null)) != TYPE_INT or int(training[field]) < 0:
			return _receipt(state, seat, "produce", false, "invalid_request", {})
	var cost_gold := int(training["cost_gold"])
	var cost_lumber := int(training["cost_lumber"])
	var food_cost := int(training["food"])
	if food_cost != int(hero_definition["food"]):
		return _receipt(state, seat, "produce", false, "invalid_request", {})
	if not _can_reserve(player, cost_gold, cost_lumber):
		return _receipt(state, seat, "produce", false, "insufficient_resources", {})
	if int(player["food_used"]) + int(player["reserved_food"]) + food_cost \
		> int(player["food_capacity"]):
		return _receipt(state, seat, "produce", false, "food_cap_blocked", {})
	_reserve(player, cost_gold, cost_lumber)
	player["reserved_food"] += food_cost
	var train_ticks := int(training["train_ticks"])
	queue.append({
		"catalog_id": hero_type_id,
		"cost_gold": cost_gold,
		"cost_lumber": cost_lumber,
		"entry_id": state.economy.allocate_entry_id(),
		"food_committed": false,
		"food_cost": food_cost,
		"kind": "hero",
		"owner_seat": seat,
		"producer_id": producer_id,
		"remaining_ticks": train_ticks,
		"spawn_definition": {
			"base_body_hp": int(hero_definition["base_body_hp"]),
			"base_body_mana": int(hero_definition["base_body_mana"]),
			"food_cost": food_cost,
			"radius_mt": int(hero_definition["radius_mt"]),
			"speed_mt_per_tick": int(hero_definition["speed_mt_per_tick"]),
			"tags": ["biological", "ground", "hero"],
		},
		"total_ticks": train_ticks,
	})
	state.economy.production_queues[producer_id] = queue
	return _receipt(state, seat, "produce", true, "accepted", {
		"accepted_quantity": 1,
		"hero_type_id": hero_type_id,
		"producer_id": producer_id,
		"requested_quantity": 1,
	})


func queue_upgrade(
	state: StateRecord,
	seat: int,
	producer_id: int,
	upgrade_id: String
) -> Dictionary:
	if not _ready(state) or not state.economy.players.has(seat):
		return _receipt(state, seat, "research", false, "invalid_request", {})
	if not catalog["upgrades"].has(upgrade_id):
		return _receipt(state, seat, "research", false, "unknown_catalog_id", {})
	var producer_check := _validate_producer(state, seat, producer_id)
	if not producer_check.is_empty():
		return _receipt(state, seat, "research", false, producer_check, {})
	var upgrade: Dictionary = catalog["upgrades"][upgrade_id]
	var producer_record: Dictionary = state.economy.entity_records[producer_id]
	if str(producer_record["semantic_role"]) not in upgrade["producer_roles"]:
		return _receipt(state, seat, "research", false, "invalid_producer", {})
	var player: Dictionary = state.economy.players[seat]
	var next_level := int(player["completed_upgrades"].get(upgrade_id, 0)) + 1
	var levels: Array = upgrade["levels"]
	if next_level > levels.size():
		return _receipt(state, seat, "research", false, "already_completed", {})
	for producer_key: int in state.economy.sorted_producer_ids():
		for entry_variant: Variant in state.economy.production_queues[producer_key]:
			var existing: Dictionary = entry_variant
			if str(existing["kind"]) == "upgrade" \
				and str(existing["catalog_id"]) == upgrade_id:
				return _receipt(state, seat, "research", false, "already_queued", {})
	var level: Dictionary = levels[next_level - 1]
	if int(level["required_tier"]) > int(player["technology_tier"]):
		return _receipt(state, seat, "research", false, "prerequisite_missing", {})
	var queue: Array = state.economy.production_queues.get(producer_id, [])
	if queue.size() >= QUEUE_CAPACITY:
		return _receipt(state, seat, "research", false, "queue_full", {})
	var cost_gold := int(level["cost_gold"])
	var cost_lumber := int(level["cost_lumber"])
	if not _can_reserve(player, cost_gold, cost_lumber):
		return _receipt(state, seat, "research", false, "insufficient_resources", {})
	_reserve(player, cost_gold, cost_lumber)
	queue.append({
		"catalog_id": upgrade_id,
		"cost_gold": cost_gold,
		"cost_lumber": cost_lumber,
		"entry_id": state.economy.allocate_entry_id(),
		"food_committed": false,
		"food_cost": 0,
		"kind": "upgrade",
		"level": next_level,
		"owner_seat": seat,
		"producer_id": producer_id,
		"remaining_ticks": int(level["research_ticks"]),
		"total_ticks": int(level["research_ticks"]),
	})
	state.economy.production_queues[producer_id] = queue
	return _receipt(state, seat, "research", true, "accepted", {
		"level": next_level,
		"producer_id": producer_id,
		"queue_entry_id": int(queue.back()["entry_id"]),
		"upgrade_id": upgrade_id,
	})


func queue_tier_upgrade(
	state: StateRecord,
	seat: int,
	stronghold_id: int,
	target_tier: int
) -> Dictionary:
	if not _ready(state) or not state.economy.players.has(seat):
		return _receipt(state, seat, "upgrade_tier", false, "invalid_request", {})
	if state.economy.tier_queues.has(seat):
		return _receipt(state, seat, "upgrade_tier", false, "already_queued", {})
	if not state.economy.entity_records.has(stronghold_id):
		return _receipt(state, seat, "upgrade_tier", false, "target_unavailable", {})
	var record: Dictionary = state.economy.entity_records[stronghold_id]
	if int(record["owner_seat"]) != seat:
		return _receipt(state, seat, "upgrade_tier", false, "not_owned", {})
	if str(record["semantic_role"]) != "stronghold":
		return _receipt(state, seat, "upgrade_tier", false, "invalid_target", {})
	var player: Dictionary = state.economy.players[seat]
	if target_tier != int(player["technology_tier"]) + 1 or target_tier > 3:
		return _receipt(state, seat, "upgrade_tier", false, "invalid_request", {})
	var definition: Dictionary = catalog["technology"]["tier_%d" % target_tier]
	var cost_gold := int(definition["cost_gold"])
	var cost_lumber := int(definition["cost_lumber"])
	if not _can_reserve(player, cost_gold, cost_lumber):
		return _receipt(state, seat, "upgrade_tier", false, "insufficient_resources", {})
	_reserve(player, cost_gold, cost_lumber)
	state.economy.tier_queues[seat] = {
		"cost_gold": cost_gold,
		"cost_lumber": cost_lumber,
		"entry_id": state.economy.allocate_entry_id(),
		"owner_seat": seat,
		"remaining_ticks": int(definition["duration_ticks"]),
		"stronghold_id": stronghold_id,
		"target_tier": target_tier,
		"total_ticks": int(definition["duration_ticks"]),
	}
	return _receipt(state, seat, "upgrade_tier", true, "accepted", {
		"queue_entry_id": int(state.economy.tier_queues[seat]["entry_id"]),
		"stronghold_id": stronghold_id,
		"target_tier": target_tier,
	})


func cancel_queue_entry(
	state: StateRecord,
	seat: int,
	producer_id: int,
	entry_id: int
) -> Dictionary:
	if state.economy.tier_queues.has(seat):
		var tier_entry: Dictionary = state.economy.tier_queues[seat]
		if int(tier_entry["stronghold_id"]) == producer_id \
			and int(tier_entry["entry_id"]) == entry_id:
			return _cancel_tier_entry(state, seat, tier_entry)
	if not state.economy.production_queues.has(producer_id):
		return _receipt(state, seat, "cancel_queue", false, "target_unavailable", {})
	var queue: Array = state.economy.production_queues[producer_id]
	for index: int in queue.size():
		var entry: Dictionary = queue[index]
		if int(entry["entry_id"]) != entry_id:
			continue
		if int(entry["owner_seat"]) != seat:
			return _receipt(state, seat, "cancel_queue", false, "not_owned", {})
		if bool(entry["food_committed"]):
			return _receipt(state, seat, "cancel_queue", false, "already_completed", {})
		var progress_bp := _entry_progress_bp(entry)
		var refund_bp := _cancellation_refund_bp(progress_bp)
		var player: Dictionary = state.economy.players[seat]
		var refund := _refund_cost(
			player, int(entry["cost_gold"]), int(entry["cost_lumber"]), refund_bp
		)
		player["reserved_food"] -= int(entry["food_cost"])
		queue.remove_at(index)
		state.economy.production_queues[producer_id] = queue
		return _receipt(state, seat, "cancel_queue", true, "accepted", {
			"progress_bp": progress_bp,
			"queue_entry_id": entry_id,
			"refund_gold": int(refund["gold"]),
			"refund_lumber": int(refund["lumber"]),
		})
	return _receipt(state, seat, "cancel_queue", false, "target_unavailable", {})


## Phase 7 freezes the economic actors allowed to contribute this tick. The
## resulting ID lists are applied only in phase 9, after all work deltas have
## been collected.
func collect_work_intents(state: StateRecord) -> void:
	_pending_worker_ids.clear()
	_pending_construction_ids.clear()
	_pending_repair_ids.clear()
	_pending_producer_ids.clear()
	_pending_tier_seats.clear()
	_events.clear()
	_progress_this_tick = false
	if not _ready(state):
		return
	for worker_id: int in state.economy.sorted_worker_ids():
		if _entity_can_contribute(state, worker_id):
			_pending_worker_ids.append(worker_id)
	for building_id: int in state.economy.sorted_construction_ids():
		if _entity_can_contribute(state, building_id):
			_pending_construction_ids.append(building_id)
	for building_id: int in state.economy.sorted_repair_building_ids():
		if _entity_can_contribute(state, building_id):
			_pending_repair_ids.append(building_id)
	for producer_id: int in state.economy.sorted_producer_ids():
		if _entity_can_contribute(state, producer_id) \
			and not is_production_disabled_by_status(state, producer_id):
			_pending_producer_ids.append(producer_id)
	for seat: int in state.economy.sorted_tier_queue_seats():
		var entry: Dictionary = state.economy.tier_queues[seat]
		if _entity_can_contribute(state, int(entry["stronghold_id"])) \
			and not is_production_disabled_by_status(
				state, int(entry["stronghold_id"])
			):
			_pending_tier_seats.append(seat)


func is_production_disabled_by_status(state: StateRecord, producer_id: int) -> bool:
	if state == null or not state.combat.enabled:
		return false
	for status_id: int in _sorted_int_keys(state.combat.statuses):
		var status: Dictionary = state.combat.statuses[status_id]
		if int(status.get("target_id", 0)) == producer_id \
			and int(status.get("expiry_tick", -1)) > int(state.tick) \
			and str(status.get("effect_kind", "")) \
			== "disable_structure_attack_and_production":
			return true
	return false


func apply_collected_work(state: StateRecord, grid: OccupancyGrid, tick: int) -> bool:
	if not _ready(state):
		return false
	for worker_id: int in _pending_worker_ids:
		_apply_worker_tick(state, worker_id, tick)
	for building_id: int in _pending_construction_ids:
		_apply_construction_tick(state, building_id, tick)
	for building_id: int in _pending_repair_ids:
		_apply_repair_tick(state, building_id, tick)
	for producer_id: int in _pending_producer_ids:
		_apply_production_tick(state, grid, producer_id, tick)
	for seat: int in _pending_tier_seats:
		_apply_tier_tick(state, seat, tick)
	return _progress_this_tick


func resolve_lifecycle(state: StateRecord, grid: OccupancyGrid, tick: int) -> bool:
	if not _ready(state):
		return false
	var made_progress := false
	for building_id: int in state.economy.sorted_construction_ids():
		if state.entities.has(building_id):
			var building: EntityRecord = state.entities[building_id]
			if building.alive and building.hp > 0:
				continue
		var site: Dictionary = state.economy.construction_sites[building_id]
		if not bool(site["refund_applied"]):
			var refund := _refund_cost(
				state.economy.players[int(site["owner_seat"])],
				int(site["cost_gold"]),
				int(site["cost_lumber"]),
				2_500
			)
			site["refund_applied"] = true
			_queue_event(tick, "construction_destroyed", building_id, 0, {
				"refund_gold": int(refund["gold"]),
				"refund_lumber": int(refund["lumber"]),
			})
		_remove_construction_site(state, grid, building_id, false)
		made_progress = true

	for entity_id: int in state.economy.sorted_entity_record_ids():
		if not state.entities.has(entity_id):
			_account_completed_entity_loss(state, entity_id, grid, tick)
			made_progress = true
			continue
		var entity: EntityRecord = state.entities[entity_id]
		if entity.alive and entity.hp > 0:
			continue
		_account_completed_entity_loss(state, entity_id, grid, tick)
		made_progress = true

	for node_id: int in state.economy.sorted_resource_node_ids():
		if state.entities.has(node_id):
			continue
		_cancel_tasks_for_node(state, node_id, tick)
		state.economy.resource_nodes.erase(node_id)
	return made_progress


func take_events() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event: Dictionary in _events:
		result.append(event.duplicate(true))
	_events.clear()
	return result


func clear_pending() -> void:
	_pending_worker_ids.clear()
	_pending_construction_ids.clear()
	_pending_repair_ids.clear()
	_pending_producer_ids.clear()
	_pending_tier_seats.clear()
	_events.clear()
	_progress_this_tick = false


func _apply_worker_tick(state: StateRecord, worker_id: int, tick: int) -> void:
	if not state.economy.worker_tasks.has(worker_id):
		return
	var task: Dictionary = state.economy.worker_tasks[worker_id]
	var node_id := int(task["node_entity_id"])
	if not state.economy.resource_nodes.has(node_id):
		state.economy.worker_tasks.erase(worker_id)
		_queue_event(tick, "gather_failed", worker_id, node_id, {"reason": "target_unavailable"})
		return
	var node: Dictionary = state.economy.resource_nodes[node_id]
	match str(task["phase"]):
		"to_resource":
			if int(task["remaining_travel_ticks"]) > 0:
				task["remaining_travel_ticks"] -= 1
			if int(task["remaining_travel_ticks"]) == 0:
				task["phase"] = "waiting_slot"
		"waiting_slot":
			if int(node["stock"]) <= 0:
				state.economy.worker_tasks.erase(worker_id)
				_queue_event(tick, "gather_failed", worker_id, node_id, {"reason": "depleted"})
				return
			var assigned: Array = node["assigned_worker_ids"]
			if assigned.size() < int(node["slots"]):
				assigned.append(worker_id)
				assigned.sort()
				task["phase"] = "working"
				task["work_progress_ticks"] = 0
				_queue_event(tick, "resource_slot_reserved", worker_id, node_id, {})
		"working":
			task["work_progress_ticks"] += 1
			if int(task["work_progress_ticks"]) < int(task.get("work_ticks", node["work_ticks"])):
				return
			var extracted := mini(
				int(task.get("cargo_amount", node["cargo_amount"])), int(node["stock"])
			)
			(node["assigned_worker_ids"] as Array).erase(worker_id)
			task["work_progress_ticks"] = 0
			if extracted <= 0:
				state.economy.worker_tasks.erase(worker_id)
				_queue_event(tick, "gather_failed", worker_id, node_id, {"reason": "depleted"})
				return
			node["stock"] -= extracted
			task["cargo"] = extracted
			task["phase"] = "to_deposit"
			task["remaining_travel_ticks"] = int(task["travel_return_ticks"])
			if state.entities.has(node_id):
				var resource_entity: EntityRecord = state.entities[node_id]
				resource_entity.integer_attributes["resource_stock"] = int(node["stock"])
			_queue_event(tick, "resource_extracted", worker_id, node_id, {
				"amount": extracted,
				"remaining_stock": int(node["stock"]),
				"resource": str(node["resource_type"]),
			})
			_progress_this_tick = true
			if int(node["stock"]) == 0:
				_queue_event(tick, "resource_depleted", worker_id, node_id, {
					"resource": str(node["resource_type"]),
				})
		"to_deposit":
			if int(task["remaining_travel_ticks"]) > 0:
				task["remaining_travel_ticks"] -= 1
			if int(task["remaining_travel_ticks"]) == 0:
				_deposit_worker_cargo(state, task, tick)


func _deposit_worker_cargo(state: StateRecord, task: Dictionary, tick: int) -> void:
	var worker_id := int(task["worker_id"])
	var deposit_id := int(task["deposit_entity_id"])
	var seat := -1
	if state.entities.has(worker_id):
		seat = int((state.entities[worker_id] as EntityRecord).owner_seat)
	if seat < 0 or not _is_owned_deposit(state, seat, deposit_id):
		state.economy.worker_tasks.erase(worker_id)
		_queue_event(tick, "deposit_failed", worker_id, deposit_id, {"reason": "target_unavailable"})
		return
	var cargo := int(task["cargo"])
	var resource_type := str(task["resource_type"])
	var player: Dictionary = state.economy.players[seat]
	var delivered := cargo
	if resource_type == "gold":
		_update_upkeep(player)
		@warning_ignore("integer_division")
		delivered = (cargo * int(player["gold_delivery_bp"])) / 10_000
		player["gold"] += delivered
	else:
		player["lumber"] += delivered
	task["cargo"] = 0
	task["cycle_index"] += 1
	task["phase"] = "to_resource"
	task["remaining_travel_ticks"] = int(task["travel_to_ticks"])
	_queue_event(tick, "resource_deposited", worker_id, deposit_id, {
		"cargo": cargo,
		"delivered": delivered,
		"resource": resource_type,
		"upkeep_tier": str(player["upkeep_tier"]),
	})
	_progress_this_tick = true


func _apply_construction_tick(state: StateRecord, building_id: int, tick: int) -> void:
	if not state.economy.construction_sites.has(building_id) \
		or not state.entities.has(building_id):
		return
	var site: Dictionary = state.economy.construction_sites[building_id]
	var building: EntityRecord = state.entities[building_id]
	var valid_workers: Array[int] = []
	for worker_id_variant: Variant in site["worker_ids"]:
		var worker_id := int(worker_id_variant)
		if not _entity_can_contribute(state, worker_id):
			continue
		var worker: EntityRecord = state.entities[worker_id]
		var dx := worker.position_x_mt - building.position_x_mt
		var dy := worker.position_y_mt - building.position_y_mt
		var allowed_distance := int(site["worker_range_mt"]) + building.radius_mt
		if dx * dx + dy * dy <= allowed_distance * allowed_distance:
			valid_workers.append(worker_id)
	if valid_workers.is_empty():
		return
	var counted_workers := mini(valid_workers.size(), MAX_REPAIR_WORKERS)
	var speeds: Array = catalog["construction"]["cooperative_speed_bp"]
	@warning_ignore("integer_division")
	var contribution := (
		int(catalog["construction"]["work_bp_per_worker_tick"])
		* int(speeds[counted_workers - 1])
	) / 10_000
	var prior_work := int(site["work_done_bp"])
	site["work_done_bp"] = mini(
		int(site["work_required_bp"]), prior_work + contribution
	)
	@warning_ignore("integer_division")
	var progress_bp := (int(site["work_done_bp"]) * 10_000) / maxi(
		1, int(site["work_required_bp"])
	)
	building.integer_attributes["construction_progress_bp"] = progress_bp
	var minimum_hp_bp := int(catalog["construction"]["minimum_incomplete_hp_bp"])
	var entitled_hp_bp := maxi(minimum_hp_bp, progress_bp)
	@warning_ignore("integer_division")
	var entitled_hp := maxi(1, (building.max_hp * entitled_hp_bp) / 10_000)
	var hp_growth := maxi(0, entitled_hp - int(site["granted_hp"]))
	building.hp = mini(building.max_hp, building.hp + hp_growth)
	site["granted_hp"] = entitled_hp
	_queue_event(tick, "construction_progress", building_id, 0, {
		"progress_bp": progress_bp,
		"worker_count": counted_workers,
		"work_added_bp": int(site["work_done_bp"]) - prior_work,
	})
	_progress_this_tick = true
	if int(site["work_done_bp"]) < int(site["work_required_bp"]):
		return
	building.integer_attributes["construction_complete"] = 1
	building.integer_attributes["construction_progress_bp"] = 10_000
	var registration_errors := register_completed_entity(state, building_id)
	if not registration_errors.is_empty():
		push_error("Completed construction could not register: %s" % "; ".join(registration_errors))
		return
	var site_id := str(site["site_id"])
	state.economy.construction_sites.erase(building_id)
	state.economy.claimed_site_ids.erase(site_id)
	_queue_event(tick, "construction_completed", building_id, 0, {
		"catalog_id": building.catalog_id,
		"site_id": site_id,
	})


func _apply_repair_tick(state: StateRecord, building_id: int, tick: int) -> void:
	if not state.economy.repair_ledgers.has(building_id) \
		or not state.entities.has(building_id) \
		or not state.economy.entity_records.has(building_id):
		return
	var ledger: Dictionary = state.economy.repair_ledgers[building_id]
	var building: EntityRecord = state.entities[building_id]
	if building.hp >= building.max_hp:
		ledger["worker_ids"] = []
		return
	var valid_workers: Array[int] = []
	var definition: Dictionary = _definition(building.catalog_id)
	var worker_range := int(definition.get("worker_range_mt", 2_000)) + building.radius_mt
	for worker_id_variant: Variant in ledger["worker_ids"]:
		var worker_id := int(worker_id_variant)
		if not _entity_can_contribute(state, worker_id):
			continue
		var worker: EntityRecord = state.entities[worker_id]
		var dx := worker.position_x_mt - building.position_x_mt
		var dy := worker.position_y_mt - building.position_y_mt
		if dx * dx + dy * dy <= worker_range * worker_range:
			valid_workers.append(worker_id)
	if valid_workers.is_empty():
		return
	var worker_count := mini(valid_workers.size(), MAX_REPAIR_WORKERS)
	var hp_budget := worker_count * int(catalog["construction"]["repair_hp_per_worker_tick"])
	hp_budget = mini(hp_budget, building.max_hp - building.hp)
	var player: Dictionary = state.economy.players[int(ledger["owner_seat"])]
	var repair_cost_bp := int(catalog["construction"]["full_repair_cost_bp_of_original"])
	var denominator := building.max_hp * 10_000
	var cost_gold := int(definition["cost_gold"])
	var cost_lumber := int(definition["cost_lumber"])
	var repaired := 0
	var charged_gold := 0
	var charged_lumber := 0
	for _hp_point: int in hp_budget:
		var next_gold_numerator := int(ledger["gold_remainder"]) + cost_gold * repair_cost_bp
		var next_lumber_numerator := int(ledger["lumber_remainder"]) + cost_lumber * repair_cost_bp
		@warning_ignore("integer_division")
		var gold_charge := next_gold_numerator / denominator
		@warning_ignore("integer_division")
		var lumber_charge := next_lumber_numerator / denominator
		if int(player["gold"]) < gold_charge or int(player["lumber"]) < lumber_charge:
			break
		player["gold"] -= gold_charge
		player["lumber"] -= lumber_charge
		charged_gold += gold_charge
		charged_lumber += lumber_charge
		ledger["gold_remainder"] = next_gold_numerator % denominator
		ledger["lumber_remainder"] = next_lumber_numerator % denominator
		repaired += 1
	if repaired == 0:
		return
	building.hp += repaired
	_queue_event(tick, "repair_progress", building_id, 0, {
		"charged_gold": charged_gold,
		"charged_lumber": charged_lumber,
		"hp_repaired": repaired,
		"worker_count": worker_count,
	})
	_progress_this_tick = true
	if building.hp >= building.max_hp:
		ledger["worker_ids"] = []


func _apply_production_tick(
	state: StateRecord,
	grid: OccupancyGrid,
	producer_id: int,
	tick: int
) -> void:
	if not state.economy.production_queues.has(producer_id):
		return
	var queue: Array = state.economy.production_queues[producer_id]
	if queue.is_empty() or not state.economy.entity_records.has(producer_id):
		return
	var entry: Dictionary = queue[0]
	if str(entry["kind"]) == "unit" \
		and _worker_training_blocked_by_tier(state, producer_id, entry):
		return
	if int(entry["remaining_ticks"]) > 0:
		entry["remaining_ticks"] -= 1
		_progress_this_tick = true
		if int(entry["remaining_ticks"]) > 0:
			return
	if str(entry["kind"]) == "upgrade":
		var player: Dictionary = state.economy.players[int(entry["owner_seat"])]
		player["completed_upgrades"][str(entry["catalog_id"])] = int(entry["level"])
		queue.pop_front()
		state.economy.production_queues[producer_id] = queue
		_queue_event(tick, "upgrade_completed", producer_id, 0, {
			"level": int(entry["level"]),
			"upgrade_id": str(entry["catalog_id"]),
		})
		return

	var owner_seat := int(entry["owner_seat"])
	var owner: Dictionary = state.economy.players[owner_seat]
	if not bool(entry["food_committed"]):
		owner["reserved_food"] -= int(entry["food_cost"])
		owner["food_used"] += int(entry["food_cost"])
		entry["food_committed"] = true
		_update_upkeep(owner)
	if not _spawn_completed_mobile(state, grid, producer_id, entry, tick):
		return
	queue.pop_front()
	state.economy.production_queues[producer_id] = queue


func _apply_tier_tick(state: StateRecord, seat: int, tick: int) -> void:
	if not state.economy.tier_queues.has(seat):
		return
	var entry: Dictionary = state.economy.tier_queues[seat]
	if int(entry["remaining_ticks"]) > 0:
		entry["remaining_ticks"] -= 1
		_progress_this_tick = true
	if int(entry["remaining_ticks"]) > 0:
		return
	var target_tier := int(entry["target_tier"])
	var player: Dictionary = state.economy.players[seat]
	player["technology_tier"] = target_tier
	player["hero_slots"] = int(catalog["technology"]["tier_%d" % target_tier]["hero_slots"])
	state.economy.tier_queues.erase(seat)
	_queue_event(tick, "tier_completed", int(entry["stronghold_id"]), 0, {
		"tier": target_tier,
	})


func _spawn_completed_mobile(
	state: StateRecord,
	grid: OccupancyGrid,
	producer_id: int,
	entry: Dictionary,
	tick: int
) -> bool:
	if grid == null or not state.entities.has(producer_id):
		return false
	var producer: EntityRecord = state.entities[producer_id]
	var is_hero := str(entry.get("kind", "unit")) == "hero"
	var definition: Dictionary = entry.get("spawn_definition", {}) \
		if is_hero else catalog["units"][str(entry["catalog_id"])]
	var producer_definition := _definition(producer.catalog_id)
	var offsets: Array = producer_definition.get("exit_offsets_cells", [])
	if offsets.is_empty():
		offsets = [
			{"x": 0, "y": -4}, {"x": 1, "y": -4}, {"x": 2, "y": -4},
			{"x": 3, "y": -3}, {"x": 4, "y": -2}, {"x": 4, "y": -1},
			{"x": 4, "y": 0}, {"x": 4, "y": 1}, {"x": 4, "y": 2},
			{"x": 3, "y": 3}, {"x": 2, "y": 4}, {"x": 1, "y": 4},
			{"x": 0, "y": 4}, {"x": -1, "y": 4}, {"x": -2, "y": 4},
			{"x": -3, "y": 3}, {"x": -4, "y": 2}, {"x": -4, "y": 1},
			{"x": -4, "y": 0}, {"x": -4, "y": -1}, {"x": -4, "y": -2},
			{"x": -3, "y": -3}, {"x": -2, "y": -4}, {"x": -1, "y": -4},
		]
	var producer_cell := Vector2i(
		producer.position_x_mt / grid.cell_size_mt,
		producer.position_y_mt / grid.cell_size_mt
	)
	var spawn_cell := Vector2i(-1, -1)
	for offset_variant: Variant in offsets:
		var offset: Dictionary = offset_variant
		var candidate := producer_cell + Vector2i(int(offset["x"]), int(offset["y"]))
		if grid.fits_ground_footprint(
			candidate.x, candidate.y, int(definition["radius_mt"])
		):
			spawn_cell = candidate
			break
	if spawn_cell.x < 0:
		return false
	var position := grid.cell_center_mt(spawn_cell.x, spawn_cell.y)
	var unit_id := state.next_entity_id
	if not grid.reserve_ground_actor(
		unit_id, position.x, position.y, int(definition["radius_mt"])
	):
		return false
	var unit := EntityRecord.new(
		unit_id, int(entry["owner_seat"]), "hero" if is_hero else "unit"
	)
	unit.public_id = "e_runtime_%08d" % unit_id
	unit.catalog_id = str(entry["catalog_id"])
	unit.max_hp = int(definition.get("max_hp", definition.get("base_body_hp", 1)))
	unit.hp = unit.max_hp
	unit.max_mana = int(definition.get("max_mana", definition.get("base_body_mana", 0)))
	unit.mana = unit.max_mana
	unit.radius_mt = int(definition["radius_mt"])
	unit.set_position_mt(position.x, position.y)
	unit.tags.assign(_string_array(definition.get("tags", [])))
	unit.integer_attributes["food_cost"] = int(definition["food_cost"])
	unit.integer_attributes["construction_complete"] = 1
	unit.integer_attributes["construction_progress_bp"] = 10_000
	if state.add_entity(unit) == 0:
		grid.release_ground_actor(unit_id)
		return false
	state.economy.entity_records[unit_id] = {
		"catalog_id": unit.catalog_id,
		"entity_id": unit_id,
		"food_cost": int(definition["food_cost"]),
		"food_provided": 0,
		"kind": "unit",
		"owner_seat": unit.owner_seat,
		"semantic_role": "hero" if is_hero else str(definition.get("semantic_role", "unit")),
	}
	_queue_event(tick, "production_completed", producer_id, unit_id, {
		"catalog_id": unit.catalog_id,
		"kind": "hero" if is_hero else "unit",
		"queue_entry_id": int(entry["entry_id"]),
	})
	return true


func _account_completed_entity_loss(
	state: StateRecord,
	entity_id: int,
	grid: OccupancyGrid,
	tick: int
) -> void:
	if not state.economy.entity_records.has(entity_id):
		return
	var record: Dictionary = state.economy.entity_records[entity_id]
	var seat := int(record["owner_seat"])
	if state.economy.players.has(seat):
		var player: Dictionary = state.economy.players[seat]
		player["food_used"] = maxi(0, int(player["food_used"]) - int(record["food_cost"]))
		player["food_capacity"] = maxi(
			0, int(player["food_capacity"]) - int(record["food_provided"])
		)
		_update_upkeep(player)
	_cancel_producer_queue_destroyed(state, entity_id, tick)
	state.economy.repair_ledgers.erase(entity_id)
	state.economy.entity_records.erase(entity_id)
	_clear_worker_assignment(state, entity_id)
	if grid != null:
		grid.release_ground_actor(entity_id)
	_queue_event(tick, "economic_entity_destroyed", entity_id, 0, {
		"catalog_id": str(record["catalog_id"]),
	})


func _cancel_producer_queue_destroyed(state: StateRecord, producer_id: int, tick: int) -> void:
	if not state.economy.production_queues.has(producer_id):
		return
	var queue: Array = state.economy.production_queues[producer_id]
	for entry_variant: Variant in queue:
		var entry: Dictionary = entry_variant
		var seat := int(entry["owner_seat"])
		var player: Dictionary = state.economy.players[seat]
		var refund := _refund_cost(
			player, int(entry["cost_gold"]), int(entry["cost_lumber"]), 2_500
		)
		if bool(entry["food_committed"]):
			player["food_used"] = maxi(0, int(player["food_used"]) - int(entry["food_cost"]))
		else:
			player["reserved_food"] = maxi(
				0, int(player["reserved_food"]) - int(entry["food_cost"])
			)
		_update_upkeep(player)
		_queue_event(tick, "queue_cancelled_by_destruction", producer_id, 0, {
			"queue_entry_id": int(entry["entry_id"]),
			"refund_gold": int(refund["gold"]),
			"refund_lumber": int(refund["lumber"]),
		})
	state.economy.production_queues.erase(producer_id)


func _cancel_tasks_for_node(state: StateRecord, node_id: int, tick: int) -> void:
	for worker_id: int in state.economy.sorted_worker_ids():
		var task: Dictionary = state.economy.worker_tasks[worker_id]
		if int(task["node_entity_id"]) != node_id:
			continue
		state.economy.worker_tasks.erase(worker_id)
		_queue_event(tick, "gather_failed", worker_id, node_id, {"reason": "target_unavailable"})


func _cancel_tier_entry(
	state: StateRecord,
	seat: int,
	entry: Dictionary
) -> Dictionary:
	var progress_bp := _entry_progress_bp(entry)
	var refund := _refund_cost(
		state.economy.players[seat],
		int(entry["cost_gold"]),
		int(entry["cost_lumber"]),
		_cancellation_refund_bp(progress_bp)
	)
	state.economy.tier_queues.erase(seat)
	return _receipt(state, seat, "cancel_queue", true, "accepted", {
		"progress_bp": progress_bp,
		"queue_entry_id": int(entry["entry_id"]),
		"refund_gold": int(refund["gold"]),
		"refund_lumber": int(refund["lumber"]),
	})


func _remove_construction_site(
	state: StateRecord,
	grid: OccupancyGrid,
	building_id: int,
	remove_entity: bool = true
) -> void:
	if not state.economy.construction_sites.has(building_id):
		return
	var site: Dictionary = state.economy.construction_sites[building_id]
	state.economy.claimed_site_ids.erase(str(site["site_id"]))
	state.economy.construction_sites.erase(building_id)
	if remove_entity:
		if grid != null:
			grid.release_ground_actor(building_id)
		state.remove_entity(building_id)


func _clear_worker_assignment(state: StateRecord, worker_id: int) -> void:
	if state.economy.worker_tasks.has(worker_id):
		var task: Dictionary = state.economy.worker_tasks[worker_id]
		var node_id := int(task["node_entity_id"])
		if state.economy.resource_nodes.has(node_id):
			(state.economy.resource_nodes[node_id]["assigned_worker_ids"] as Array).erase(worker_id)
		state.economy.worker_tasks.erase(worker_id)
	for building_id: int in state.economy.sorted_construction_ids():
		(state.economy.construction_sites[building_id]["worker_ids"] as Array).erase(worker_id)
	for building_id: int in state.economy.sorted_repair_building_ids():
		(state.economy.repair_ledgers[building_id]["worker_ids"] as Array).erase(worker_id)


func _validate_producer(state: StateRecord, seat: int, producer_id: int) -> String:
	if not state.economy.entity_records.has(producer_id) or not state.entities.has(producer_id):
		return "target_unavailable"
	var record: Dictionary = state.economy.entity_records[producer_id]
	if int(record["owner_seat"]) != seat:
		return "not_owned"
	if str(record["kind"]) != "structure":
		return "invalid_producer"
	var entity: EntityRecord = state.entities[producer_id]
	if not entity.alive or entity.hp <= 0 \
		or int(entity.integer_attributes.get("construction_complete", 0)) != 1:
		return "invalid_state"
	return ""


func _worker_training_blocked_by_tier(
	state: StateRecord,
	producer_id: int,
	entry: Dictionary
) -> bool:
	var definition: Dictionary = catalog["units"][str(entry["catalog_id"])]
	if not bool(definition.get("is_worker", false)):
		return false
	var seat := int(entry["owner_seat"])
	return state.economy.tier_queues.has(seat) \
		and int(state.economy.tier_queues[seat]["stronghold_id"]) == producer_id


func _is_owned_worker(state: StateRecord, seat: int, worker_id: int) -> bool:
	if not state.entities.has(worker_id) or not state.economy.entity_records.has(worker_id):
		return false
	var entity: EntityRecord = state.entities[worker_id]
	var record: Dictionary = state.economy.entity_records[worker_id]
	return entity.alive and entity.hp > 0 and entity.owner_seat == seat \
		and str(record["kind"]) == "unit" \
		and (
			bool(_definition(entity.catalog_id).get("is_worker", false)) \
			or str(record.get("semantic_role", "")) == "worker"
		)


func _worker_gather_profiles(worker: EntityRecord) -> Dictionary:
	var definition := _definition(worker.catalog_id)
	var profiles: Dictionary = definition.get("gather_profiles", {}).duplicate(true)
	if int(worker.integer_attributes.get("external_worker", 0)) == 1 \
		and worker.integer_attributes.has("gather_lumber_cargo") \
		and worker.integer_attributes.has("gather_lumber_work_ticks"):
		profiles["lumber"] = {
			"cargo": int(worker.integer_attributes["gather_lumber_cargo"]),
			"work_ticks": int(worker.integer_attributes["gather_lumber_work_ticks"]),
		}
	return profiles


func _is_owned_deposit(state: StateRecord, seat: int, entity_id: int) -> bool:
	if not state.entities.has(entity_id) or not state.economy.entity_records.has(entity_id):
		return false
	var entity: EntityRecord = state.entities[entity_id]
	var record: Dictionary = state.economy.entity_records[entity_id]
	if not entity.alive or entity.hp <= 0 or entity.owner_seat != seat:
		return false
	return bool(_definition(entity.catalog_id).get("is_deposit", false)) \
		and int(entity.integer_attributes.get("construction_complete", 0)) == 1


func _entity_can_contribute(state: StateRecord, entity_id: int) -> bool:
	if not state.entities.has(entity_id):
		return false
	var entity: EntityRecord = state.entities[entity_id]
	return entity.alive and entity.hp > 0


func _definition(catalog_id: String) -> Dictionary:
	if catalog.get("structures", {}).has(catalog_id):
		return catalog["structures"][catalog_id]
	if catalog.get("units", {}).has(catalog_id):
		return catalog["units"][catalog_id]
	return {}


func _ready(state: StateRecord) -> bool:
	return state != null and state.economy != null and is_configured(state.economy)


func _reserve(player: Dictionary, gold: int, lumber: int) -> void:
	player["gold"] -= gold
	player["lumber"] -= lumber


func _can_reserve(player: Dictionary, gold: int, lumber: int) -> bool:
	return gold >= 0 and lumber >= 0 \
		and int(player["gold"]) >= gold and int(player["lumber"]) >= lumber


func _refund_cost(player: Dictionary, gold: int, lumber: int, refund_bp: int) -> Dictionary:
	@warning_ignore("integer_division")
	var refund_gold := (gold * refund_bp) / 10_000
	@warning_ignore("integer_division")
	var refund_lumber := (lumber * refund_bp) / 10_000
	player["gold"] += refund_gold
	player["lumber"] += refund_lumber
	return {"gold": refund_gold, "lumber": refund_lumber}


func _cancellation_refund_bp(progress_bp: int) -> int:
	if progress_bp < 2_500:
		return 9_000
	if progress_bp < 7_500:
		return 7_500
	return 5_000


func _entry_progress_bp(entry: Dictionary) -> int:
	var total := maxi(1, int(entry["total_ticks"]))
	var completed := total - int(entry["remaining_ticks"])
	@warning_ignore("integer_division")
	return clampi((completed * 10_000) / total, 0, 10_000)


static func _sorted_int_keys(source: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for key_variant: Variant in source.keys():
		result.append(int(key_variant))
	result.sort()
	return result


func _update_upkeep(player: Dictionary) -> void:
	var used := int(player["food_used"])
	var upkeep_rows: Array = catalog["food_and_upkeep"]["upkeep"]
	for row_variant: Variant in upkeep_rows:
		var row: Dictionary = row_variant
		if used < int(row["minimum_used"]) or used > int(row["maximum_used"]):
			continue
		player["upkeep_tier"] = str(row["tier"])
		player["gold_delivery_bp"] = int(row["gold_delivery_bp"])
		return


func _queue_failure_code(queue: Array, player: Dictionary, definition: Dictionary) -> String:
	if queue.size() >= QUEUE_CAPACITY:
		return "queue_full"
	if not _can_reserve(player, int(definition["cost_gold"]), int(definition["cost_lumber"])):
		return "insufficient_resources"
	return "food_cap_blocked"


func _receipt(
	state: StateRecord,
	seat: int,
	op: String,
	accepted: bool,
	code: String,
	details: Dictionary
) -> Dictionary:
	var value := {
		"accepted": accepted,
		"code": code,
		"details": details.duplicate(true),
		"op": op,
		"seat": seat,
		"tick": state.tick if state != null else 0,
	}
	if state == null or state.economy == null:
		return value
	return state.economy.append_receipt(value)


func _queue_event(
	tick: int,
	kind: String,
	source_id: int,
	target_id: int,
	payload: Dictionary
) -> void:
	_events.append({
		"event_kind": kind,
		"payload": payload.duplicate(true),
		"source_internal_id": source_id,
		"target_internal_id": target_id,
		"tick": tick,
	})


static func _unique_sorted(values: Array) -> Array[int]:
	var seen: Dictionary = {}
	var result: Array[int] = []
	for value_variant: Variant in values:
		var value := int(value_variant)
		if seen.has(value):
			continue
		seen[value] = true
		result.append(value)
	result.sort()
	return result


static func _string_array(values: Variant) -> Array[String]:
	var result: Array[String] = []
	if typeof(values) != TYPE_ARRAY:
		return result
	for value: Variant in values:
		result.append(str(value))
	result.sort()
	return result


static func _require_non_negative_int(
	object: Dictionary,
	field: String,
	path: String,
	errors: PackedStringArray
) -> void:
	if not object.has(field) or typeof(object[field]) != TYPE_INT \
		or int(object[field]) < 0:
		errors.append("%s.%s must be a non-negative integer" % [path, field])


static func _validate_common_definition(
	catalog_id: String,
	definition: Dictionary,
	kind: String,
	errors: PackedStringArray
) -> void:
	for field: String in ["cost_gold", "cost_lumber", "max_hp"]:
		_require_non_negative_int(definition, field, "%s.%s" % [kind, catalog_id], errors)
	if int(definition.get("max_hp", 0)) <= 0:
		errors.append("%s.%s.max_hp must be positive" % [kind, catalog_id])
