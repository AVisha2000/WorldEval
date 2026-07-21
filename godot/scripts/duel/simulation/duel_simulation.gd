class_name DuelSimulation
extends RefCounted

const Rules := preload("res://scripts/duel/simulation/duel_rules.gd")
const StateRecord := preload("res://scripts/duel/simulation/duel_state.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const EventRecord := preload("res://scripts/duel/simulation/duel_event.gd")
const OrderRecord := preload("res://scripts/duel/simulation/duel_order.gd")
const DeltaRecord := preload("res://scripts/duel/simulation/duel_delta.gd")
const OccupancyGrid := preload("res://scripts/duel/simulation/duel_occupancy_grid.gd")
const MapLoader := preload("res://scripts/duel/simulation/duel_map_loader.gd")
const Pathfinder := preload("res://scripts/duel/simulation/duel_pathfinder.gd")
const TickLedger := preload("res://scripts/duel/simulation/duel_tick_ledger.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const EconomySystem := preload("res://scripts/duel/economy/duel_economy.gd")
const CombatSystem := preload("res://scripts/duel/combat/duel_combat.gd")
const MovementSystem := preload("res://scripts/duel/movement/duel_movement.gd")
const MovementStateRecord := preload("res://scripts/duel/movement/duel_movement_state.gd")
const HeroSystem := preload("res://scripts/duel/heroes/duel_hero_system.gd")
const TerminalSystem := preload("res://scripts/duel/simulation/duel_terminal.gd")
const NeutralWorld := preload("res://scripts/duel/neutrals/duel_neutral_world.gd")
const AbilityRuntime := preload("res://scripts/duel/abilities/duel_ability_runtime.gd")
const AbilityEffectBridge := preload("res://scripts/duel/abilities/duel_ability_effect_bridge.gd")

var config: Dictionary = {}
var state: StateRecord = StateRecord.new()
var grid: OccupancyGrid = OccupancyGrid.new()
var pathfinder: Pathfinder = Pathfinder.new(grid)
var ledger: TickLedger = TickLedger.new()
var economy: EconomySystem = EconomySystem.new()
var combat: CombatSystem = CombatSystem.new()
var movement: MovementSystem = MovementSystem.new()
var heroes: HeroSystem = HeroSystem.new()
var terminal: TerminalSystem = TerminalSystem.new()
var neutrals: NeutralWorld = NeutralWorld.new()
var abilities: AbilityRuntime = AbilityRuntime.new()
var ability_effects: AbilityEffectBridge = AbilityEffectBridge.new()
var last_errors := PackedStringArray()
var is_ready: bool = false


func _init(initial_config: Dictionary = {}) -> void:
	reset(initial_config)


func reset(config_overrides: Dictionary = {}) -> PackedStringArray:
	is_ready = false
	last_errors.clear()
	config = Rules.merge_with_defaults(config_overrides)
	last_errors.append_array(Rules.validate_config(config))
	if not last_errors.is_empty():
		return last_errors

	if config.has("map_manifest"):
		if typeof(config["map_manifest"]) != TYPE_DICTIONARY:
			last_errors.append("map_manifest must be an object")
			return last_errors
		var result := MapLoader.load_manifest(config["map_manifest"])
		if not bool(result["ok"]):
			last_errors.append_array(result["errors"])
			return last_errors
		grid = result["grid"]
		if grid.width != int(config["grid_width"]) or grid.height != int(config["grid_height"]):
			last_errors.append("map dimensions do not match match config")
			return last_errors
	else:
		grid = OccupancyGrid.new()
		last_errors.append_array(grid.configure(
			int(config["grid_width"]), int(config["grid_height"]), int(config["cell_size_mt"])
		))
		if not last_errors.is_empty():
			return last_errors

	state = StateRecord.new()
	state.reset(config)
	ledger = TickLedger.new()
	economy = EconomySystem.new()
	combat = CombatSystem.new()
	movement = MovementSystem.new()
	heroes = HeroSystem.new()
	terminal = TerminalSystem.new()
	neutrals = NeutralWorld.new()
	abilities = AbilityRuntime.new()
	ability_effects = AbilityEffectBridge.new()
	ledger.set_economy(economy)
	ledger.set_combat(combat)
	ledger.set_movement(movement)
	ledger.set_heroes(heroes)
	ledger.set_terminal(terminal)
	ledger.set_neutrals(neutrals)
	ledger.set_abilities(abilities, ability_effects)
	ledger.set_simulation(self)
	pathfinder = Pathfinder.new(grid)
	is_ready = true
	return last_errors


func add_entity(entity: EntityRecord, reserve_occupancy: bool = true) -> int:
	if not is_ready:
		return 0
	if entity.internal_id == 0:
		entity.internal_id = state.next_entity_id
	var reserve_ground := reserve_occupancy and not "air" in entity.tags
	if reserve_ground and not grid.reserve_ground_actor(
		entity.internal_id, entity.position_x_mt, entity.position_y_mt, entity.radius_mt
	):
		return 0
	var entity_id := state.add_entity(entity)
	if entity_id == 0 and reserve_ground:
		grid.release_ground_actor(entity.internal_id)
	return entity_id


func queue_order(order: OrderRecord) -> int:
	if not is_ready:
		return 0
	return state.add_order(order)


func queue_delta(delta: DeltaRecord) -> PackedStringArray:
	if not is_ready:
		return PackedStringArray(["simulation is not ready"])
	return ledger.queue_delta(delta)


func configure_economy(merged_catalog: Dictionary) -> PackedStringArray:
	if not is_ready:
		return PackedStringArray(["simulation is not ready"])
	return economy.configure(state.economy, merged_catalog)


func configure_combat(
	attack_armor_catalog: Dictionary,
	faction_catalog: Dictionary,
	rules_catalog: Dictionary = {}
) -> PackedStringArray:
	if not is_ready:
		return PackedStringArray(["simulation is not ready"])
	return combat.configure(state.combat, attack_armor_catalog, faction_catalog, rules_catalog)


func register_combat_entity(
	entity_id: int,
	section: String,
	catalog_key: String,
	overrides: Dictionary = {}
) -> PackedStringArray:
	if not is_ready:
		return PackedStringArray(["simulation is not ready"])
	return combat.register_entity(state, entity_id, section, catalog_key, overrides)


func configure_movement(
	faction_catalog: Dictionary,
	protected_tie_key: PackedByteArray
) -> PackedStringArray:
	if not is_ready:
		return PackedStringArray(["simulation is not ready"])
	var errors := movement.configure(state.movement, faction_catalog, protected_tie_key)
	if errors.is_empty() and not state.tie_key_commitment.is_empty() \
		and state.tie_key_commitment != state.movement.protected_tie_key_digest:
		## Do not leave a partially configured authoritative slice behind.
		state.movement = MovementStateRecord.new()
		movement = MovementSystem.new()
		ledger.set_movement(movement)
		return PackedStringArray(["movement protected tie key does not match tie_key_commitment"])
	return errors


func register_movement_entity(
	entity_id: int,
	section: String,
	catalog_key: String,
	overrides: Dictionary = {}
) -> PackedStringArray:
	if not is_ready:
		return PackedStringArray(["simulation is not ready"])
	return movement.register_entity(state, grid, entity_id, section, catalog_key, overrides)


func configure_neutral_world(protected_tie_key: PackedByteArray) -> PackedStringArray:
	if not is_ready:
		return PackedStringArray(["simulation is not ready"])
	var errors := neutrals.configure_official(state.match_seed, protected_tie_key)
	if errors.is_empty() and not state.tie_key_commitment.is_empty() \
		and state.tie_key_commitment != neutrals.state.protected_tie_key_commitment:
		errors.append("neutral protected tie key does not match tie_key_commitment")
	if not errors.is_empty():
		neutrals = NeutralWorld.new()
		ledger.set_neutrals(neutrals)
		return errors
	state.neutrals = neutrals.state
	ledger.set_neutrals(neutrals)
	return errors


func register_external_mobile_combat_entity(
	entity_id: int,
	section: String,
	catalog_key: String,
	definition: Dictionary
) -> PackedStringArray:
	if not is_ready:
		return PackedStringArray(["simulation is not ready"])
	var errors := PackedStringArray()
	errors.append_array(combat.install_external_profile(
		state.combat, section, catalog_key, definition
	))
	if errors.is_empty():
		errors.append_array(movement.install_external_profile(
			state.movement, section, catalog_key, definition
		))
	if errors.is_empty():
		errors.append_array(combat.register_entity(
			state, entity_id, section, catalog_key
		))
	if errors.is_empty():
		errors.append_array(movement.register_entity(
			state, grid, entity_id, section, catalog_key
		))
	return errors


func configure_abilities(selected_faction_id: String) -> PackedStringArray:
	if not is_ready:
		return PackedStringArray(["simulation is not ready"])
	var errors := abilities.configure(selected_faction_id)
	if errors.is_empty():
		errors.append_array(ability_effects.configure(selected_faction_id))
	if not errors.is_empty():
		abilities = AbilityRuntime.new()
		ability_effects = AbilityEffectBridge.new()
		ledger.set_abilities(abilities, ability_effects)
		return errors
	state.abilities = abilities.state
	ledger.set_abilities(abilities, ability_effects)
	return errors


func register_ability_actor(
	entity_id: int, actor_type_id: String = "", explicit_ranks: Dictionary = {}
) -> PackedStringArray:
	if not is_ready:
		return PackedStringArray(["simulation is not ready"])
	return abilities.register_actor(self, entity_id, actor_type_id, explicit_ranks)


func configure_heroes(
	rules_catalog: Dictionary,
	faction_catalog: Dictionary,
	item_catalog: Dictionary
) -> PackedStringArray:
	if not is_ready:
		return PackedStringArray(["simulation is not ready"])
	return heroes.configure(state.heroes, rules_catalog, faction_catalog, item_catalog)


func register_hero(
	entity_id: int,
	hero_type_id: String,
	opaque_order_key: String = ""
) -> PackedStringArray:
	if not is_ready:
		return PackedStringArray(["simulation is not ready"])
	return heroes.register_hero(state, entity_id, hero_type_id, opaque_order_key)


func register_completed_mobile_authorities(
	entity_id: int,
	completion_kind: String = "unit"
) -> PackedStringArray:
	## Phase-9 production handoff. Economy has already created and registered the
	## entity; this method binds every other enabled authority exactly once.
	var errors := PackedStringArray()
	if not is_ready or not state.entities.has(entity_id):
		return PackedStringArray(["completed mobile entity does not exist"])
	var entity: EntityRecord = state.entities[entity_id]
	var is_hero := completion_kind == "hero" or "hero" in entity.tags
	var section := "hero" if is_hero else "unit"
	if is_hero and state.heroes.enabled and not state.heroes.heroes.has(entity_id):
		errors.append_array(register_hero(
			entity_id, entity.catalog_id, "hero_order_%08d" % entity_id
		))
	if errors.is_empty() and state.combat.enabled and not state.combat.actors.has(entity_id):
		var overrides: Dictionary = {}
		if is_hero and state.heroes.heroes.has(entity_id):
			var derived: Dictionary = state.heroes.heroes[entity_id].get("derived", {})
			overrides = {
				"armor_centi": int(derived.get("armor_centi", 0)),
				"net_attack_speed_bp": int(derived.get("attack_speed_bp", 0)),
				"attack": {"damage": int(derived.get("attack_damage", 0))},
			}
		errors.append_array(register_combat_entity(
			entity_id, section, entity.catalog_id, overrides
		))
	if errors.is_empty() and state.movement.enabled and not state.movement.actors.has(entity_id):
		errors.append_array(register_movement_entity(entity_id, section, entity.catalog_id))
	if errors.is_empty() and abilities.is_configured() \
		and not state.abilities.actors.has(entity_id) \
		and _ability_owner_type_supported(entity.catalog_id):
		errors.append_array(register_ability_actor(entity_id, entity.catalog_id))
	return errors


func preflight_hired_unit(
	owner_seat: int,
	hire_type_id: String,
	definition: Dictionary,
	approach_cells: Array
) -> Dictionary:
	if not is_ready or owner_seat not in [0, 1] \
		or hire_type_id.is_empty() or not state.economy.players.has(owner_seat):
		return {"code": "invalid_actor", "ok": false}
	if not state.economy.enabled or not state.combat.enabled or not state.movement.enabled:
		return {"code": "authority_unavailable", "ok": false}
	for field: String in [
		"armor_centi", "armor_class", "duration_ticks", "food", "hp", "mana",
		"radius_mt", "speed_mt_per_tick", "tags",
	]:
		if not definition.has(field):
			return {"code": "unknown_catalog_id", "ok": false}
	if typeof(definition["tags"]) != TYPE_ARRAY or approach_cells.is_empty():
		return {"code": "invalid_target", "ok": false}
	var player: Dictionary = state.economy.players[owner_seat]
	if int(player["food_used"]) + int(player["reserved_food"]) + int(definition["food"]) \
		> int(player["food_capacity"]):
		return {"code": "food_cap_blocked", "ok": false}
	var tags: Array = definition["tags"]
	var layer := "air" if "air" in tags else "ground"
	var radius_mt := int(definition["radius_mt"])
	for cell_variant: Variant in approach_cells:
		if typeof(cell_variant) != TYPE_ARRAY or (cell_variant as Array).size() != 2:
			continue
		var cell: Array = cell_variant
		var cell_x := int(cell[0])
		var cell_y := int(cell[1])
		if not grid.in_bounds(cell_x, cell_y):
			continue
		var position := grid.cell_center_mt(cell_x, cell_y)
		if layer == "ground":
			if not grid.fits_ground_footprint(cell_x, cell_y, radius_mt):
				continue
		else:
			if not grid.is_air_pathable(cell_x, cell_y) \
				or not _air_position_has_open_lane(position, radius_mt):
				continue
		return {
			"code": "accepted",
			"layer": layer,
			"ok": true,
			"position_mt": [position.x, position.y],
		}
	return {"code": "invalid_placement", "ok": false}


func spawn_hired_unit(handoff: Dictionary) -> Dictionary:
	## Applies only a handoff produced by DuelNeutralMarket. Catalog stats and
	## approach cells stay authoritative; no controller-supplied spawn data enters.
	for field: String in [
		"hire_definition", "hire_type_id", "owner_seat", "spawn_approach_cells",
	]:
		if not handoff.has(field):
			return {"accepted": false, "code": "invalid_request"}
	var definition: Dictionary = handoff["hire_definition"]
	var preflight := preflight_hired_unit(
		int(handoff["owner_seat"]), str(handoff["hire_type_id"]), definition,
		handoff["spawn_approach_cells"]
	)
	if not bool(preflight.get("ok", false)):
		return {"accepted": false, "code": str(preflight.get("code", "execution_failed"))}
	var hire_type_id := str(handoff["hire_type_id"])
	var layer := str(preflight["layer"])
	var profile := {
		"armor_centi": int(definition["armor_centi"]),
		"armor_class": str(definition["armor_class"]),
		"attack": {},
		"layer": layer,
		"radius_mt": int(definition["radius_mt"]),
		"speed_mt_per_tick": int(definition["speed_mt_per_tick"]),
		"tags": definition["tags"].duplicate(),
	}
	if int(definition.get("attack_damage", 0)) > 0:
		return {"accepted": false, "code": "unsupported_attack_profile"}
	var profile_errors := PackedStringArray()
	profile_errors.append_array(combat.install_external_profile(
		state.combat, "hire", hire_type_id, profile
	))
	profile_errors.append_array(movement.install_external_profile(
		state.movement, "hire", hire_type_id, profile
	))
	if not profile_errors.is_empty():
		return {"accepted": false, "code": "invalid_catalog", "errors": profile_errors}
	var entity_id := state.next_entity_id
	var entity := EntityRecord.new(entity_id, int(handoff["owner_seat"]), "unit")
	entity.public_id = "e_runtime_%08d" % entity_id
	entity.catalog_id = hire_type_id
	entity.max_hp = int(definition["hp"])
	entity.hp = entity.max_hp
	entity.max_mana = int(definition["mana"])
	entity.mana = entity.max_mana
	entity.radius_mt = int(definition["radius_mt"])
	entity.tags.assign(_sorted_string_values(definition["tags"]))
	var position: Array = preflight["position_mt"]
	entity.set_position_mt(int(position[0]), int(position[1]))
	for field: String in [
		"detection_radius_mt", "passenger_food_capacity", "sight_day_mt",
		"sight_night_mt", "speed_mt_per_tick", "xp_bounty",
	]:
		if definition.has(field):
			entity.integer_attributes[field] = int(definition[field])
	var duration_ticks := int(definition["duration_ticks"])
	if duration_ticks > 0:
		entity.integer_attributes["hired_expiry_tick"] = state.tick + duration_ticks
	if add_entity(entity, false) != entity_id:
		return {"accepted": false, "code": "invalid_placement"}
	var errors := PackedStringArray()
	errors.append_array(economy.register_external_unit(
		state, entity_id, definition, "hire"
	))
	if errors.is_empty():
		errors.append_array(combat.register_entity(
			state, entity_id, "hire", hire_type_id
		))
	if errors.is_empty():
		errors.append_array(movement.register_entity(
			state, grid, entity_id, "hire", hire_type_id
		))
	if not errors.is_empty():
		return {"accepted": false, "code": "execution_failed", "errors": errors}
	return {
		"accepted": true,
		"code": "accepted",
		"entity_id": entity_id,
		"hire_type_id": hire_type_id,
	}


func configure_terminal(
	rules_catalog: Dictionary,
	economy_catalog: Dictionary
) -> PackedStringArray:
	if not is_ready:
		return PackedStringArray(["simulation is not ready"])
	return terminal.configure(rules_catalog, economy_catalog)


func declare_technical_forfeit(losing_seats: Array[int]) -> Dictionary:
	var receipt := terminal.technical_forfeit(state, losing_seats, state.tick)
	_flush_external_terminal_events()
	return receipt


func declare_infrastructure_void(reason: String) -> Dictionary:
	var receipt := terminal.infrastructure_void(state, state.tick, reason)
	_flush_external_terminal_events()
	return receipt


func _flush_external_terminal_events() -> void:
	for data: Dictionary in terminal.take_events():
		var event := EventRecord.new(
			state.tick,
			Rules.TickPhase.TEST_TERMINAL,
			str(data["event_kind"])
		)
		event.source_internal_id = int(data["source_internal_id"])
		event.target_internal_id = int(data["target_internal_id"])
		event.payload = data["payload"].duplicate(true)
		state.append_event(event)


func step_tick(capture_pre_tick_checkpoint: bool = true) -> Dictionary:
	if not is_ready:
		return {
			"completed_tick": -1,
			"phase_ids": [],
			"pre_tick_state_hash": "",
			"skipped_invalid_config": true,
		}
	if bool(state.terminal["ended"]):
		return {
			"completed_tick": state.tick - 1,
			"phase_ids": [],
			"pre_tick_state_hash": "",
			"skipped_terminal": true,
		}
	return ledger.run_tick(state, grid, capture_pre_tick_checkpoint)


func snapshot() -> Dictionary:
	return {
		"grid": grid.to_canonical_dict(),
		"pending_deltas": ledger.pending_deltas_canonical(),
		"state": state.to_canonical_dict(),
	}


func checkpoint_hash() -> String:
	return Codec.sha256_canonical(snapshot())


func terminal_result() -> Dictionary:
	return state.terminal.duplicate(true)


func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	errors.append_array(Rules.validate_config(config))
	errors.append_array(state.validate())
	return errors


func _ability_owner_type_supported(owner_type_id: String) -> bool:
	for ability_variant: Variant in abilities.registry.values():
		var ability: Dictionary = ability_variant
		if owner_type_id in ability.get("allowed_owners", []):
			return true
	return false


func _air_position_has_open_lane(position: Vector2i, radius_mt: int) -> bool:
	var occupied_nodes := grid.footprint_cells_for_center_mt(position.x, position.y, radius_mt)
	for slot: int in range(4):
		var available := true
		for node_id_variant: Variant in occupied_nodes:
			var lanes: Dictionary = state.movement.air_occupancy.get(int(node_id_variant), {})
			if lanes.has(slot):
				available = false
				break
		if available:
			return true
	return false


static func _sorted_string_values(values: Variant) -> Array[String]:
	var result: Array[String] = []
	if typeof(values) == TYPE_ARRAY:
		for value: Variant in values:
			var text := str(value)
			if text not in result:
				result.append(text)
	result.sort()
	return result
