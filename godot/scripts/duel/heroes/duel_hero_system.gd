class_name DuelHeroSystem
extends RefCounted

const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const OccupancyGrid := preload("res://scripts/duel/simulation/duel_occupancy_grid.gd")
const Pathfinder := preload("res://scripts/duel/simulation/duel_pathfinder.gd")
const HeroState := preload("res://scripts/duel/heroes/duel_hero_state.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const BP_ONE := 10_000
const MAX_LEVEL := 10
const INVENTORY_SLOTS := 6

var catalog: Dictionary = {}
var _events: Array[Dictionary] = []
var _progress_this_tick: bool = false


func configure(
	hero_state: HeroState,
	rules_catalog: Dictionary,
	faction_catalog: Dictionary,
	item_catalog: Dictionary
) -> PackedStringArray:
	var errors := validate_catalogs(rules_catalog, faction_catalog, item_catalog)
	if not errors.is_empty():
		return errors
	catalog = {
		"faction": faction_catalog.duplicate(true),
		"items": item_catalog.duplicate(true),
		"rules": rules_catalog.duplicate(true),
	}
	hero_state.reset()
	hero_state.enabled = true
	hero_state.rules_catalog_id = str(rules_catalog["catalog_id"])
	hero_state.faction_catalog_id = str(faction_catalog["catalog_id"])
	hero_state.item_catalog_id = str(item_catalog["catalog_id"])
	clear_pending()
	return errors


func validate_catalogs(
	rules_catalog: Dictionary,
	faction_catalog: Dictionary,
	item_catalog: Dictionary
) -> PackedStringArray:
	var errors := PackedStringArray()
	if not rules_catalog.has("catalog_id") or typeof(rules_catalog["catalog_id"]) != TYPE_STRING:
		errors.append("rules catalog is missing catalog_id")
	if not rules_catalog.has("heroes") or typeof(rules_catalog["heroes"]) != TYPE_DICTIONARY:
		errors.append("rules catalog is missing heroes")
	for field: String in ["catalog_id", "faction_id", "heroes", "abilities"]:
		if not faction_catalog.has(field):
			errors.append("faction catalog is missing %s" % field)
	for field: String in [
		"catalog_id", "inventory_slots_per_hero", "pickup_range_mt", "transfer_range_mt",
		"dropped_despawn_ticks", "sell_return_bp", "personal_potion_cooldown_ticks", "items",
	]:
		if not item_catalog.has(field):
			errors.append("item catalog is missing %s" % field)
	if not errors.is_empty():
		return errors
	if int(item_catalog["inventory_slots_per_hero"]) != INVENTORY_SLOTS:
		errors.append("item inventory slot count must equal six")
	var hero_rules: Dictionary = rules_catalog["heroes"]
	if hero_rules.get("xp_thresholds", []).size() != MAX_LEVEL:
		errors.append("Hero XP thresholds must contain levels 1 through 10")
	for entry: Dictionary in [
		{"label": "rules", "value": rules_catalog},
		{"label": "faction", "value": faction_catalog},
		{"label": "items", "value": item_catalog},
	]:
		for message: String in Codec.validate_canonical_value(entry["value"], "$.%s" % entry["label"]):
			errors.append(message)
	return errors


func register_hero(
	state: Variant,
	entity_id: int,
	hero_type_id: String,
	opaque_order_key: String = ""
) -> PackedStringArray:
	var errors := PackedStringArray()
	if not _ready(state):
		errors.append("Hero system is not configured")
		return errors
	if not state.entities.has(entity_id):
		errors.append("Hero entity does not exist")
		return errors
	if state.heroes.heroes.has(entity_id):
		errors.append("Hero entity is already registered")
		return errors
	if not catalog["faction"]["heroes"].has(hero_type_id):
		errors.append("unknown selected-faction Hero type: %s" % hero_type_id)
		return errors
	var entity: EntityRecord = state.entities[entity_id]
	if entity.owner_seat < 0:
		errors.append("Hero must have a player owner")
		return errors
	for other_id: int in state.heroes.sorted_hero_ids():
		var other: Dictionary = state.heroes.heroes[other_id]
		if int(other["owner_seat"]) == entity.owner_seat \
			and str(other["hero_type_id"]) == hero_type_id:
			errors.append("named Hero archetype is already owned")
			return errors
	var definition: Dictionary = catalog["faction"]["heroes"][hero_type_id]
	var record := {
		"attributes_centi": definition["base_attributes_centi"].duplicate(true),
		"base_attributes_centi": definition["base_attributes_centi"].duplicate(true),
		"death_tick": -1,
		"derived": {},
		"entity_id": entity_id,
		"growth_per_level_centi": definition["growth_per_level_centi"].duplicate(true),
		"hero_type_id": hero_type_id,
		"inventory": [],
		"hp_regen_numerator": 0,
		"learned_abilities": {},
		"level": 1,
		"mana_regen_numerator": 0,
		"opaque_order_key": opaque_order_key if not opaque_order_key.is_empty() else entity.public_id,
		"owner_seat": entity.owner_seat,
		"personal_potion_cooldown_until_tick": 0,
		"primary_attribute": str(definition["primary_attribute"]),
		"skill_points": 1,
		"xp": 0,
	}
	state.heroes.heroes[entity_id] = record
	if "hero" not in entity.tags:
		entity.tags.append("hero")
	entity.tags.sort()
	_recalculate_derived(state, entity_id, false)
	return errors


func award_xp(
	state: Variant,
	beneficiary_seat: int,
	source_position_mt: Array,
	total_xp: int
) -> Dictionary:
	if not _ready(state) or beneficiary_seat not in [0, 1] or total_xp <= 0 \
		or source_position_mt.size() != 2:
		return _receipt(false, "invalid_request", {})
	var eligible: Array[int] = []
	var radius := int(catalog["rules"]["heroes"]["xp_proximity_radius_mt"])
	for hero_id: int in state.heroes.sorted_hero_ids():
		var record: Dictionary = state.heroes.heroes[hero_id]
		if int(record["owner_seat"]) != beneficiary_seat or not state.entities.has(hero_id):
			continue
		var entity: EntityRecord = state.entities[hero_id]
		if not entity.alive:
			continue
		var dx := entity.position_x_mt - int(source_position_mt[0])
		var dy := entity.position_y_mt - int(source_position_mt[1])
		if dx * dx + dy * dy <= radius * radius:
			eligible.append(hero_id)
	eligible.sort_custom(_opaque_hero_less.bind(state.heroes.heroes))
	if eligible.is_empty():
		return _receipt(false, "target_unavailable", {"unassigned_xp": total_xp})
	@warning_ignore("integer_division")
	var share := total_xp / eligible.size()
	var remainder := total_xp % eligible.size()
	var awards: Array = []
	for index: int in eligible.size():
		var amount := share + (1 if index < remainder else 0)
		_apply_xp(state, eligible[index], amount)
		awards.append({"amount": amount, "hero_id": eligible[index]})
	_progress_this_tick = true
	return _receipt(true, "accepted", {"awards": awards, "total_xp": total_xp})


func learn_ability(state: Variant, seat: int, hero_id: int, ability_id: String) -> Dictionary:
	var check := _owned_hero(state, seat, hero_id, true)
	if not check.is_empty():
		return _receipt(false, check, {})
	var record: Dictionary = state.heroes.heroes[hero_id]
	if int(record["skill_points"]) <= 0:
		return _receipt(false, "insufficient_resource", {})
	if not catalog["faction"]["abilities"].has(ability_id):
		return _receipt(false, "unknown_catalog_id", {})
	var ability: Dictionary = catalog["faction"]["abilities"][ability_id]
	if str(record["hero_type_id"]) not in ability["allowed_owners"]:
		return _receipt(false, "invalid_actor", {})
	var current_rank := int(record["learned_abilities"].get(ability_id, 0))
	var ultimate := "ultimate" in str(ability["activation_kind"])
	var maximum_rank := 1 if ultimate else 3
	if current_rank >= maximum_rank:
		return _receipt(false, "already_completed", {})
	var next_rank := current_rank + 1
	var required_level := int(catalog["rules"]["heroes"]["ultimate_level_requirement"]) \
		if ultimate else next_rank * 2 - 1
	if int(record["level"]) < required_level:
		return _receipt(false, "prerequisite_missing", {"required_level": required_level})
	record["learned_abilities"][ability_id] = next_rank
	record["skill_points"] -= 1
	_sync_entity_attributes(state, hero_id)
	_queue_event(state, "hero_ability_learned", hero_id, 0, {
		"ability_id": ability_id, "rank": next_rank,
	})
	return _receipt(true, "accepted", {"ability_id": ability_id, "rank": next_rank})


func mark_dead(
	state: Variant,
	grid: OccupancyGrid,
	hero_id: int,
	death_tick: int
) -> Dictionary:
	if not _ready(state) or not state.heroes.heroes.has(hero_id) \
		or not state.entities.has(hero_id):
		return _receipt(false, "invalid_target", {})
	var entity: EntityRecord = state.entities[hero_id]
	if not entity.alive:
		return _receipt(false, "already_completed", {})
	entity.alive = false
	entity.hp = 0
	entity.active_order_id = 0
	if grid != null:
		grid.release_ground_actor(hero_id)
	var record: Dictionary = state.heroes.heroes[hero_id]
	record["death_tick"] = death_tick
	_cancel_breakable_effects(state, hero_id, "death")
	_queue_event(state, "hero_died", hero_id, 0, {"level": int(record["level"])})
	_progress_this_tick = true
	return _receipt(true, "accepted", {"death_tick": death_tick})


## The generic lifecycle phase owns the alive -> dead transition so every
## subsystem observes the same simultaneous damage ledger. This hook records
## the Hero-specific consequences immediately afterwards without attempting a
## second transition.
func resolve_lifecycle(state: Variant, death_tick: int) -> void:
	if not _ready(state):
		return
	for hero_id: int in state.heroes.sorted_hero_ids():
		if not state.entities.has(hero_id):
			continue
		var entity: EntityRecord = state.entities[hero_id]
		var record: Dictionary = state.heroes.heroes[hero_id]
		if entity.alive or entity.hp > 0 or int(record["death_tick"]) >= 0:
			continue
		record["death_tick"] = death_tick
		_cancel_breakable_effects(state, hero_id, "death")
		_queue_event(state, "hero_died", hero_id, 0, {"level": int(record["level"])})
		_progress_this_tick = true


func start_altar_revival(
	state: Variant,
	seat: int,
	reviver_id: int,
	hero_id: int,
	tick: int
) -> Dictionary:
	var check := _owned_hero(state, seat, hero_id, false)
	if not check.is_empty():
		return _receipt(false, check, {})
	if state.entities[hero_id].alive:
		return _receipt(false, "invalid_target", {})
	if state.heroes.revivals.has(hero_id):
		return _receipt(false, "already_queued", {})
	if not _is_completed_altar(state, seat, reviver_id):
		return _receipt(false, "invalid_producer", {})
	var record: Dictionary = state.heroes.heroes[hero_id]
	var revival_rules: Dictionary = catalog["rules"]["heroes"]["revival"]
	var cost := int(revival_rules["altar_base_gold"]) \
		+ int(revival_rules["altar_gold_per_level"]) * int(record["level"])
	var duration := int(revival_rules["altar_base_ticks"]) \
		+ int(revival_rules["altar_ticks_per_level"]) * int(record["level"])
	if not _charge_gold(state, seat, cost):
		return _receipt(false, "insufficient_resources", {})
	state.heroes.revivals[hero_id] = {
		"cost_gold": cost,
		"hero_id": hero_id,
		"method": "altar",
		"owner_seat": seat,
		"remaining_ticks": duration,
		"requested_reviver_id": reviver_id,
		"start_tick": tick,
		"total_ticks": duration,
	}
	_queue_event(state, "hero_revival_started", reviver_id, hero_id, {
		"cost_gold": cost, "duration_ticks": duration, "method": "altar",
	})
	return _receipt(true, "accepted", {"cost_gold": cost, "duration_ticks": duration})


func field_revive(
	state: Variant,
	grid: OccupancyGrid,
	seat: int,
	tavern_id: int,
	hero_id: int,
	tick: int
) -> Dictionary:
	var check := _owned_hero(state, seat, hero_id, false)
	if not check.is_empty():
		return _receipt(false, check, {})
	if state.entities[hero_id].alive or state.heroes.revivals.has(hero_id):
		return _receipt(false, "invalid_target", {})
	if not state.entities.has(tavern_id) or "tavern" not in state.entities[tavern_id].tags:
		return _receipt(false, "invalid_producer", {})
	var record: Dictionary = state.heroes.heroes[hero_id]
	var revival: Dictionary = catalog["rules"]["heroes"]["revival"]
	if tick - int(record["death_tick"]) < int(revival["tavern_available_after_death_ticks"]):
		return _receipt(false, "prerequisite_missing", {})
	var altar_cost := int(revival["altar_base_gold"]) \
		+ int(revival["altar_gold_per_level"]) * int(record["level"])
	@warning_ignore("integer_division")
	var cost := (altar_cost * int(revival["tavern_cost_bp_of_altar"])) / BP_ONE
	if not _charge_gold(state, seat, cost):
		return _receipt(false, "insufficient_resources", {})
	if not _place_revived_hero(
		state, grid, hero_id, tavern_id,
		int(revival["tavern_return_hp_bp"]), int(revival["tavern_return_mana_bp"])
	):
		state.economy.players[seat]["gold"] += cost
		return _receipt(false, "placement_blocked", {})
	_queue_event(state, "hero_revived", tavern_id, hero_id, {
		"cost_gold": cost, "method": "tavern",
	})
	_progress_this_tick = true
	return _receipt(true, "accepted", {"cost_gold": cost, "method": "tavern"})


func grant_item(state: Variant, hero_id: int, item_type_id: String) -> Dictionary:
	if not _ready(state) or not state.heroes.heroes.has(hero_id) \
		or not catalog["items"]["items"].has(item_type_id):
		return _receipt(false, "unknown_catalog_id", {})
	var record: Dictionary = state.heroes.heroes[hero_id]
	var slot := _first_open_slot(record["inventory"])
	if slot < 0:
		return _receipt(false, "inventory_full", {})
	var definition: Dictionary = catalog["items"]["items"][item_type_id]
	var instance := {
		"charges": int(definition["charges"]),
		"cooldown_until_tick": 0,
		"item_instance_id": state.heroes.allocate_item_instance_id(),
		"item_type_id": item_type_id,
		"slot": slot,
	}
	record["inventory"].append(instance)
	_recalculate_derived(state, hero_id, true)
	return _receipt(true, "accepted", {"item": instance.duplicate(true)})


func spawn_ground_item(
	state: Variant,
	item_type_id: String,
	position_mt: Array,
	tick: int,
	despawn_tick: int = 0,
	source_id: String = ""
) -> Dictionary:
	## Neutral drops and scripted rewards enter through the same inventory
	## authority as Hero-dropped items. The caller may preserve an authored
	## absolute despawn tick; zero selects the locked ordinary item lifetime.
	if not _ready(state) or not catalog["items"]["items"].has(item_type_id) \
		or position_mt.size() != 2 or typeof(position_mt[0]) != TYPE_INT \
		or typeof(position_mt[1]) != TYPE_INT or tick < 0:
		return _receipt(false, "invalid_request", {})
	var expiry := despawn_tick
	if expiry == 0:
		expiry = tick + int(catalog["items"]["dropped_despawn_ticks"])
	if expiry <= tick:
		return _receipt(false, "invalid_request", {})
	var definition: Dictionary = catalog["items"]["items"][item_type_id]
	var instance := {
		"charges": int(definition["charges"]),
		"cooldown_until_tick": 0,
		"item_instance_id": state.heroes.allocate_item_instance_id(),
		"item_type_id": item_type_id,
		"slot": -1,
	}
	var entity_id := int(state.next_entity_id)
	var item_entity := EntityRecord.new(entity_id, -1, "item")
	item_entity.public_id = "e_item_%08d" % entity_id
	item_entity.catalog_id = item_type_id
	item_entity.hp = 1
	item_entity.max_hp = 1
	item_entity.radius_mt = 0
	item_entity.tags = ["ground", "item"]
	item_entity.set_position_mt(int(position_mt[0]), int(position_mt[1]))
	if state.add_entity(item_entity) != entity_id:
		return _receipt(false, "execution_failed", {})
	state.heroes.ground_items[entity_id] = {
		"despawn_tick": expiry,
		"drop_tick": tick,
		"entity_id": entity_id,
		"item": instance,
		"source_id": source_id,
	}
	_queue_event(state, "item_spawned", 0, entity_id, {
		"item_instance_id": str(instance["item_instance_id"]),
		"source_id": source_id,
	})
	_progress_this_tick = true
	return _receipt(true, "accepted", {
		"item_entity_id": entity_id,
		"item_instance_id": instance["item_instance_id"],
	})


func drop_item(
	state: Variant,
	hero_id: int,
	item_instance_id: String,
	position_mt: Array,
	tick: int
) -> Dictionary:
	if not _ready(state) or not state.heroes.heroes.has(hero_id) \
		or position_mt.size() != 2 or not state.entities[hero_id].alive:
		return _receipt(false, "invalid_request", {})
	var record: Dictionary = state.heroes.heroes[hero_id]
	var index := _inventory_index(record["inventory"], item_instance_id)
	if index < 0:
		return _receipt(false, "target_unavailable", {})
	var instance: Dictionary = record["inventory"].pop_at(index)
	var entity_id: int = int(state.next_entity_id)
	var item_entity := EntityRecord.new(entity_id, -1, "item")
	item_entity.public_id = "e_item_%08d" % entity_id
	item_entity.catalog_id = str(instance["item_type_id"])
	item_entity.hp = 1
	item_entity.max_hp = 1
	item_entity.radius_mt = 0
	item_entity.tags = ["ground", "item"]
	item_entity.set_position_mt(int(position_mt[0]), int(position_mt[1]))
	if state.add_entity(item_entity) == 0:
		record["inventory"].append(instance)
		return _receipt(false, "execution_failed", {})
	state.heroes.ground_items[entity_id] = {
		"despawn_tick": tick + int(catalog["items"]["dropped_despawn_ticks"]),
		"drop_tick": tick,
		"entity_id": entity_id,
		"item": instance,
	}
	_recalculate_derived(state, hero_id, true)
	_queue_event(state, "item_dropped", hero_id, entity_id, {
		"item_instance_id": item_instance_id,
	})
	return _receipt(true, "accepted", {"item_entity_id": entity_id})


func pick_up_item(state: Variant, hero_id: int, item_entity_id: int) -> Dictionary:
	if not _ready(state) or not state.heroes.heroes.has(hero_id) \
		or not state.heroes.ground_items.has(item_entity_id) \
		or not state.entities.has(item_entity_id) or not state.entities[hero_id].alive:
		return _receipt(false, "target_unavailable", {})
	var record: Dictionary = state.heroes.heroes[hero_id]
	var slot := _first_open_slot(record["inventory"])
	if slot < 0:
		return _receipt(false, "inventory_full", {})
	if not _within_entity_range(
		state, hero_id, item_entity_id, int(catalog["items"]["pickup_range_mt"])
	):
		return _receipt(false, "out_of_range", {})
	var ground: Dictionary = state.heroes.ground_items[item_entity_id]
	var instance: Dictionary = ground["item"]
	instance["slot"] = slot
	record["inventory"].append(instance)
	state.heroes.ground_items.erase(item_entity_id)
	state.remove_entity(item_entity_id)
	_recalculate_derived(state, hero_id, true)
	_queue_event(state, "item_picked_up", hero_id, item_entity_id, {
		"item_instance_id": str(instance["item_instance_id"]),
	})
	return _receipt(true, "accepted", {"item_instance_id": instance["item_instance_id"]})


func transfer_item(
	state: Variant,
	seat: int,
	from_hero_id: int,
	to_hero_id: int,
	item_instance_id: String
) -> Dictionary:
	for hero_id: int in [from_hero_id, to_hero_id]:
		var check := _owned_hero(state, seat, hero_id, true)
		if not check.is_empty():
			return _receipt(false, check, {})
	if from_hero_id == to_hero_id or not _within_entity_range(
		state, from_hero_id, to_hero_id, int(catalog["items"]["transfer_range_mt"])
	):
		return _receipt(false, "out_of_range", {})
	var source: Dictionary = state.heroes.heroes[from_hero_id]
	var target: Dictionary = state.heroes.heroes[to_hero_id]
	var source_index := _inventory_index(source["inventory"], item_instance_id)
	var target_slot := _first_open_slot(target["inventory"])
	if source_index < 0:
		return _receipt(false, "target_unavailable", {})
	if target_slot < 0:
		return _receipt(false, "inventory_full", {})
	var instance: Dictionary = source["inventory"].pop_at(source_index)
	instance["slot"] = target_slot
	target["inventory"].append(instance)
	_recalculate_derived(state, from_hero_id, true)
	_recalculate_derived(state, to_hero_id, true)
	_queue_event(state, "item_transferred", from_hero_id, to_hero_id, {
		"item_instance_id": item_instance_id,
	})
	_progress_this_tick = true
	return _receipt(true, "accepted", {})


func sell_item(
	state: Variant,
	seat: int,
	hero_id: int,
	shop_id: int,
	item_instance_id: String
) -> Dictionary:
	var check := _owned_hero(state, seat, hero_id, true)
	if not check.is_empty():
		return _receipt(false, check, {})
	if not state.entities.has(shop_id) or "shop" not in state.entities[shop_id].tags \
		or not _within_entity_range(
			state, hero_id, shop_id, int(catalog["items"]["transfer_range_mt"])
		):
		return _receipt(false, "invalid_producer", {})
	var record: Dictionary = state.heroes.heroes[hero_id]
	var index := _inventory_index(record["inventory"], item_instance_id)
	if index < 0:
		return _receipt(false, "target_unavailable", {})
	var instance: Dictionary = record["inventory"].pop_at(index)
	var definition: Dictionary = catalog["items"]["items"][str(instance["item_type_id"])]
	var gold := int(definition["sell_gold"])
	state.economy.players[seat]["gold"] += gold
	_recalculate_derived(state, hero_id, true)
	_queue_event(state, "item_sold", hero_id, shop_id, {
		"gold": gold, "item_instance_id": item_instance_id,
	})
	_progress_this_tick = true
	return _receipt(true, "accepted", {"gold": gold})


func use_item(
	state: Variant,
	seat: int,
	hero_id: int,
	item_instance_id: String,
	tick: int
) -> Dictionary:
	var check := _owned_hero(state, seat, hero_id, true)
	if not check.is_empty():
		return _receipt(false, check, {})
	var record: Dictionary = state.heroes.heroes[hero_id]
	var index := _inventory_index(record["inventory"], item_instance_id)
	if index < 0:
		return _receipt(false, "target_unavailable", {})
	var instance: Dictionary = record["inventory"][index]
	var definition: Dictionary = catalog["items"]["items"][str(instance["item_type_id"])]
	if str(definition["activation_kind"]) != "active" or int(instance["charges"]) <= 0:
		return _receipt(false, "invalid_target", {})
	if tick < int(instance["cooldown_until_tick"]):
		return _receipt(false, "cooldown", {})
	var stacking_key := str(definition["status_stacking_key"])
	if stacking_key in ["focus_draught", "vitality_draught"] \
		and tick < int(record["personal_potion_cooldown_until_tick"]):
		return _receipt(false, "cooldown", {})
	var external_effects: Array = []
	for effect_variant: Variant in definition["effects"]:
		var effect: Dictionary = effect_variant
		match str(effect["kind"]):
			"restore_hp":
				var entity: EntityRecord = state.entities[hero_id]
				entity.hp = mini(entity.max_hp, entity.hp + int(effect["value"]))
			"restore_mana_total":
				_schedule_periodic_restore(
					state, hero_id, "mana", int(effect["value"]),
					int(effect["duration_ticks"]), tick, "damage" in definition["interruption_flags"]
				)
			_:
				external_effects.append(effect.duplicate(true))
	instance["charges"] -= 1
	instance["cooldown_until_tick"] = tick + int(definition["cooldown_ticks"])
	if stacking_key in ["focus_draught", "vitality_draught"]:
		record["personal_potion_cooldown_until_tick"] = tick + int(
			catalog["items"]["personal_potion_cooldown_ticks"]
		)
	if int(instance["charges"]) <= 0:
		record["inventory"].pop_at(index)
	_queue_event(state, "item_used", hero_id, 0, {
		"external_effects": external_effects,
		"item_instance_id": item_instance_id,
		"item_type_id": str(instance["item_type_id"]),
	})
	_progress_this_tick = true
	return _receipt(true, "accepted", {"external_effects": external_effects})


func notify_damage(state: Variant, target_id: int) -> void:
	_cancel_breakable_effects(state, target_id, "damage")


func process_tick(state: Variant, grid: OccupancyGrid, tick: int) -> void:
	if not _ready(state):
		return
	_process_attribute_regeneration(state)
	_process_periodic_effects(state, tick)
	_process_revivals(state, grid, tick)
	for entity_id: int in state.heroes.sorted_ground_item_ids():
		var ground: Dictionary = state.heroes.ground_items[entity_id]
		if int(ground["despawn_tick"]) > tick:
			continue
		state.heroes.ground_items.erase(entity_id)
		state.remove_entity(entity_id)
		_queue_event(state, "item_despawned", entity_id, 0, {})


func take_events() -> Array[Dictionary]:
	var result := _events.duplicate(true)
	_events.clear()
	return result


func take_progress() -> bool:
	var result := _progress_this_tick
	_progress_this_tick = false
	return result


func clear_pending() -> void:
	_events.clear()
	_progress_this_tick = false


func _apply_xp(state: Variant, hero_id: int, amount: int) -> void:
	var record: Dictionary = state.heroes.heroes[hero_id]
	record["xp"] += amount
	var thresholds: Array = catalog["rules"]["heroes"]["xp_thresholds"]
	var prior_level := int(record["level"])
	var next_level := prior_level
	while next_level < MAX_LEVEL and int(record["xp"]) >= int(thresholds[next_level]):
		next_level += 1
	if next_level > prior_level:
		record["level"] = next_level
		record["skill_points"] += next_level - prior_level
		_recalculate_derived(state, hero_id, true)
		_queue_event(state, "hero_level_up", hero_id, 0, {
			"from_level": prior_level, "to_level": next_level,
		})
	_sync_entity_attributes(state, hero_id)
	_queue_event(state, "hero_xp_awarded", hero_id, 0, {"amount": amount})


func _recalculate_derived(state: Variant, hero_id: int, preserve_ratios: bool) -> void:
	var record: Dictionary = state.heroes.heroes[hero_id]
	var definition: Dictionary = catalog["faction"]["heroes"][str(record["hero_type_id"])]
	var level_offset := int(record["level"]) - 1
	var attributes: Dictionary = {}
	for attribute: String in ["agility", "intellect", "strength"]:
		attributes[attribute] = int(record["base_attributes_centi"][attribute]) \
			+ int(record["growth_per_level_centi"][attribute]) * level_offset
	var passive := _passive_item_modifiers(record["inventory"])
	for attribute: String in ["agility", "intellect", "strength"]:
		attributes[attribute] += int(passive["attribute_%s_centi" % attribute])
	var effects: Dictionary = catalog["rules"]["heroes"]["attribute_effects"]
	@warning_ignore("integer_division")
	var max_hp := int(definition["base_body_hp"]) \
		+ int(attributes["strength"]) * int(effects["strength_hp_per_point"]) / 100
	@warning_ignore("integer_division")
	var max_mana := int(definition["base_body_mana"]) \
		+ int(attributes["intellect"]) * int(effects["intellect_mana_per_point"]) / 100
	@warning_ignore("integer_division")
	var armor_centi := int(definition["base_armor_centi"]) \
		+ int(attributes["agility"]) * int(effects["agility_armor_centi_per_point"]) / 100 \
		+ int(passive["armor_centi"])
	@warning_ignore("integer_division")
	var attack_damage := int(definition["base_damage_before_primary"]) \
		+ int(attributes[str(record["primary_attribute"])]) \
			* int(effects["primary_damage_per_point"]) / 100 \
		+ int(passive["hero_attack_damage_flat"])
	@warning_ignore("integer_division")
	var hp_regen_per_100_ticks := int(attributes["strength"]) \
		* int(effects["strength_hp_regen_per_100_ticks"]) / 100
	@warning_ignore("integer_division")
	var mana_regen_per_200_ticks := int(attributes["intellect"]) \
		* int(effects["intellect_mana_regen_per_200_ticks"]) / 100
	@warning_ignore("integer_division")
	var attack_speed_bp := int(attributes["agility"]) \
		* int(effects["agility_attack_speed_bp_per_point"]) / 100
	var derived := {
		"armor_centi": armor_centi,
		"attack_damage": attack_damage,
		"attack_speed_bp": attack_speed_bp,
		"detection_radius_mt": int(passive["detection_radius_mt"]),
		"hp_regen_per_100_ticks": hp_regen_per_100_ticks,
		"mana_regen_per_200_ticks": mana_regen_per_200_ticks,
		"max_hp": max_hp,
		"max_mana": max_mana,
		"movement_speed_bp": int(passive["movement_speed_bp"]),
		"sight_radius_mt": int(passive["sight_radius_mt"]),
	}
	var entity: EntityRecord = state.entities[hero_id]
	var prior_max_hp := maxi(1, entity.max_hp)
	var prior_max_mana := maxi(1, entity.max_mana)
	var prior_hp := entity.hp
	var prior_mana := entity.mana
	entity.max_hp = max_hp
	entity.max_mana = max_mana
	if preserve_ratios:
		@warning_ignore("integer_division")
		entity.hp = mini(max_hp, (prior_hp * max_hp) / prior_max_hp)
		@warning_ignore("integer_division")
		entity.mana = mini(max_mana, (prior_mana * max_mana) / prior_max_mana)
	else:
		entity.hp = max_hp
		entity.mana = max_mana
	record["attributes_centi"] = attributes
	record["derived"] = derived
	_sync_entity_attributes(state, hero_id)


func _passive_item_modifiers(inventory: Array) -> Dictionary:
	var result := {
		"armor_centi": 0,
		"attribute_agility_centi": 0,
		"attribute_intellect_centi": 0,
		"attribute_strength_centi": 0,
		"detection_radius_mt": 0,
		"hero_attack_damage_flat": 0,
		"movement_speed_bp": 0,
		"sight_radius_mt": 0,
	}
	var boots_applied := false
	for instance_variant: Variant in inventory:
		var instance: Dictionary = instance_variant
		var definition: Dictionary = catalog["items"]["items"][str(instance["item_type_id"])]
		if str(definition["activation_kind"]) != "passive":
			continue
		for effect_variant: Variant in definition["effects"]:
			var effect: Dictionary = effect_variant
			var kind := str(effect["kind"])
			if kind == "movement_speed_bp" and boots_applied:
				continue
			if result.has(kind):
				result[kind] += int(effect["value"])
				if kind == "movement_speed_bp":
					boots_applied = true
	return result


func _sync_entity_attributes(state: Variant, hero_id: int) -> void:
	var record: Dictionary = state.heroes.heroes[hero_id]
	var entity: EntityRecord = state.entities[hero_id]
	for attribute: String in ["agility", "intellect", "strength"]:
		entity.integer_attributes["%s_centi" % attribute] = int(record["attributes_centi"][attribute])
	for key_variant: Variant in record["derived"].keys():
		entity.integer_attributes[str(key_variant)] = int(record["derived"][key_variant])
	entity.integer_attributes["hero_level"] = int(record["level"])
	entity.integer_attributes["hero_xp"] = int(record["xp"])
	entity.integer_attributes["skill_points"] = int(record["skill_points"])


func _process_periodic_effects(state: Variant, tick: int) -> void:
	for effect_id: int in _sorted_int_keys(state.heroes.periodic_effects):
		if not state.heroes.periodic_effects.has(effect_id):
			continue
		var effect: Dictionary = state.heroes.periodic_effects[effect_id]
		if tick <= int(effect["start_tick"]):
			continue
		if not state.entities.has(int(effect["target_id"])):
			state.heroes.periodic_effects.erase(effect_id)
			continue
		if int(effect["elapsed_ticks"]) >= int(effect["duration_ticks"]):
			state.heroes.periodic_effects.erase(effect_id)
			continue
		effect["elapsed_ticks"] += 1
		effect["numerator"] += int(effect["total"])
		@warning_ignore("integer_division")
		var amount := int(effect["numerator"]) / int(effect["duration_ticks"])
		effect["numerator"] %= int(effect["duration_ticks"])
		var entity: EntityRecord = state.entities[int(effect["target_id"])]
		if str(effect["attribute"]) == "mana":
			entity.mana = mini(entity.max_mana, entity.mana + amount)
		else:
			entity.hp = mini(entity.max_hp, entity.hp + amount)
		if int(effect["elapsed_ticks"]) >= int(effect["duration_ticks"]):
			state.heroes.periodic_effects.erase(effect_id)
		_progress_this_tick = true


func _process_attribute_regeneration(state: Variant) -> void:
	for hero_id: int in state.heroes.sorted_hero_ids():
		if not state.entities.has(hero_id):
			continue
		var entity: EntityRecord = state.entities[hero_id]
		if not entity.alive:
			continue
		var record: Dictionary = state.heroes.heroes[hero_id]
		var derived: Dictionary = record["derived"]
		record["hp_regen_numerator"] += int(derived["hp_regen_per_100_ticks"])
		@warning_ignore("integer_division")
		var hp_amount := int(record["hp_regen_numerator"]) / 100
		record["hp_regen_numerator"] %= 100
		record["mana_regen_numerator"] += int(derived["mana_regen_per_200_ticks"])
		@warning_ignore("integer_division")
		var mana_amount := int(record["mana_regen_numerator"]) / 200
		record["mana_regen_numerator"] %= 200
		var prior_hp := entity.hp
		var prior_mana := entity.mana
		if hp_amount > 0:
			entity.hp = mini(entity.max_hp, entity.hp + hp_amount)
		if mana_amount > 0:
			entity.mana = mini(entity.max_mana, entity.mana + mana_amount)
		if entity.hp != prior_hp or entity.mana != prior_mana:
			_progress_this_tick = true


func _process_revivals(state: Variant, grid: OccupancyGrid, _tick: int) -> void:
	for hero_id: int in _sorted_int_keys(state.heroes.revivals):
		var entry: Dictionary = state.heroes.revivals[hero_id]
		var altar_id := _first_completed_altar(state, int(entry["owner_seat"]))
		if altar_id == 0:
			continue
		if int(entry["remaining_ticks"]) > 0:
			entry["remaining_ticks"] -= 1
			_progress_this_tick = true
		if int(entry["remaining_ticks"]) > 0:
			continue
		var revival: Dictionary = catalog["rules"]["heroes"]["revival"]
		if not _place_revived_hero(
			state, grid, hero_id, altar_id,
			int(revival["altar_return_hp_bp"]), int(revival["altar_return_mana_bp"])
		):
			continue
		state.heroes.revivals.erase(hero_id)
		_queue_event(state, "hero_revived", altar_id, hero_id, {"method": "altar"})


func _place_revived_hero(
	state: Variant,
	grid: OccupancyGrid,
	hero_id: int,
	origin_id: int,
	hp_bp: int,
	mana_bp: int
) -> bool:
	if grid == null or not state.entities.has(origin_id) or not state.entities.has(hero_id):
		return false
	var origin: EntityRecord = state.entities[origin_id]
	var hero: EntityRecord = state.entities[hero_id]
	var pathfinder := Pathfinder.new(grid)
	var cell := pathfinder.nearest_fitting_cell(
		origin.position_x_mt, origin.position_y_mt, hero.radius_mt, hero_id
	)
	if cell.x < 0:
		return false
	var position := grid.cell_center_mt(cell.x, cell.y)
	if not grid.reserve_ground_actor(hero_id, position.x, position.y, hero.radius_mt):
		return false
	hero.set_position_mt(position.x, position.y)
	hero.alive = true
	@warning_ignore("integer_division")
	hero.hp = maxi(1, (hero.max_hp * hp_bp) / BP_ONE)
	@warning_ignore("integer_division")
	hero.mana = (hero.max_mana * mana_bp) / BP_ONE
	state.heroes.heroes[hero_id]["death_tick"] = -1
	_progress_this_tick = true
	return true


func _schedule_periodic_restore(
	state: Variant,
	target_id: int,
	attribute: String,
	total: int,
	duration_ticks: int,
	start_tick: int,
	break_on_damage: bool
) -> void:
	var effect_id: int = int(state.heroes.allocate_effect_id())
	state.heroes.periodic_effects[effect_id] = {
		"attribute": attribute,
		"break_on_damage": break_on_damage,
		"duration_ticks": duration_ticks,
		"effect_id": effect_id,
		"elapsed_ticks": 0,
		"numerator": 0,
		"start_tick": start_tick,
		"target_id": target_id,
		"total": total,
	}


func _cancel_breakable_effects(state: Variant, target_id: int, reason: String) -> void:
	for effect_id: int in _sorted_int_keys(state.heroes.periodic_effects):
		var effect: Dictionary = state.heroes.periodic_effects[effect_id]
		if int(effect["target_id"]) != target_id:
			continue
		if reason == "death" or reason == "damage" and bool(effect["break_on_damage"]):
			state.heroes.periodic_effects.erase(effect_id)
			_queue_event(state, "periodic_effect_interrupted", target_id, 0, {"reason": reason})


func _owned_hero(state: Variant, seat: int, hero_id: int, require_alive: bool) -> String:
	if not _ready(state) or not state.heroes.heroes.has(hero_id) or not state.entities.has(hero_id):
		return "target_unavailable"
	var record: Dictionary = state.heroes.heroes[hero_id]
	if int(record["owner_seat"]) != seat:
		return "not_owned"
	if require_alive and not state.entities[hero_id].alive:
		return "invalid_actor"
	return ""


func _is_completed_altar(state: Variant, seat: int, entity_id: int) -> bool:
	if not state.entities.has(entity_id) or not state.entities[entity_id].alive \
		or not state.economy.entity_records.has(entity_id):
		return false
	var record: Dictionary = state.economy.entity_records[entity_id]
	return int(record["owner_seat"]) == seat and str(record["semantic_role"]) == "hero_altar"


func _first_completed_altar(state: Variant, seat: int) -> int:
	for entity_id: int in state.economy.sorted_entity_record_ids():
		if _is_completed_altar(state, seat, entity_id):
			return entity_id
	return 0


func _charge_gold(state: Variant, seat: int, amount: int) -> bool:
	if not state.economy.players.has(seat) \
		or int(state.economy.players[seat]["gold"]) < amount:
		return false
	state.economy.players[seat]["gold"] -= amount
	return true


static func _inventory_index(inventory: Array, item_instance_id: String) -> int:
	for index: int in inventory.size():
		if str((inventory[index] as Dictionary)["item_instance_id"]) == item_instance_id:
			return index
	return -1


static func _first_open_slot(inventory: Array) -> int:
	var occupied: Dictionary = {}
	for item_variant: Variant in inventory:
		occupied[int((item_variant as Dictionary)["slot"])] = true
	for slot: int in INVENTORY_SLOTS:
		if not occupied.has(slot):
			return slot
	return -1


static func _within_entity_range(state: Variant, first_id: int, second_id: int, range_mt: int) -> bool:
	if not state.entities.has(first_id) or not state.entities.has(second_id):
		return false
	var first: EntityRecord = state.entities[first_id]
	var second: EntityRecord = state.entities[second_id]
	var dx := first.position_x_mt - second.position_x_mt
	var dy := first.position_y_mt - second.position_y_mt
	return dx * dx + dy * dy <= range_mt * range_mt


func _ready(state: Variant) -> bool:
	return state != null and state.heroes != null and state.heroes.enabled and not catalog.is_empty()


func _queue_event(
	state: Variant,
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
		"tick": int(state.tick),
	})


static func _receipt(accepted: bool, code: String, details: Dictionary) -> Dictionary:
	return {"accepted": accepted, "code": code, "details": details}


static func _sorted_int_keys(value: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for key_variant: Variant in value.keys():
		result.append(int(key_variant))
	result.sort()
	return result


static func _opaque_hero_less(left_id: int, right_id: int, heroes: Dictionary) -> bool:
	var left: Dictionary = heroes[left_id]
	var right: Dictionary = heroes[right_id]
	var left_key := str(left["opaque_order_key"])
	var right_key := str(right["opaque_order_key"])
	if left_key != right_key:
		return left_key < right_key
	return left_id < right_id
