class_name DuelMatchRuntime
extends RefCounted

const Simulation := preload("res://scripts/duel/simulation/duel_simulation.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")

## Attaches the protected per-match tie key after public bootstrap. The raw key
## never enters canonical state or returned metadata; only its SHA-256
## commitment is checkpointed by DuelMovementState.
static func attach_protected_authority(
	bootstrap_result: Dictionary,
	protected_tie_key: PackedByteArray
) -> Dictionary:
	var errors := PackedStringArray()
	if not bool(bootstrap_result.get("ok", false)) \
		or bootstrap_result.get("simulation", null) == null \
		or typeof(bootstrap_result.get("runtime", null)) != TYPE_DICTIONARY:
		errors.append("official bootstrap result is not usable")
		return _result(null, [], [], errors)
	if protected_tie_key.is_empty():
		errors.append("protected tie key must not be empty")
		return _result(null, [], [], errors)
	var simulation: Simulation = bootstrap_result["simulation"]
	if simulation.state.movement.enabled:
		errors.append("protected movement authority is already attached")
		return _result(simulation, [], [], errors)
	var runtime: Dictionary = bootstrap_result["runtime"]
	var faction_id := str(runtime.get("faction_id", ""))
	var loaded := CatalogLoader.load_official_catalogs()
	if not bool(loaded.get("ok", false)):
		_append_errors(errors, loaded.get("errors", []))
		return _result(simulation, [], [], errors)
	var faction_key := "faction:%s" % faction_id
	if not loaded["catalogs"].has(faction_key):
		errors.append("selected faction catalog is unavailable")
		return _result(simulation, [], [], errors)
	_append_errors(errors, simulation.configure_movement(
		loaded["catalogs"][faction_key], protected_tie_key
	))
	if not errors.is_empty():
		return _result(simulation, [], [], errors)

	var registered: Array[int] = []
	var units: Dictionary = loaded["catalogs"][faction_key]["units"]
	for entity_id: int in simulation.state.sorted_entity_ids():
		var entity: EntityRecord = simulation.state.entities[entity_id]
		if not entity.alive or entity.owner_seat not in [0, 1] \
			or entity.entity_kind != "unit" or not units.has(entity.catalog_id):
			continue
		var entity_errors := simulation.register_movement_entity(
			entity_id, "unit", entity.catalog_id
		)
		if not entity_errors.is_empty():
			for message: String in entity_errors:
				errors.append("movement entity %d: %s" % [entity_id, message])
			continue
		registered.append(entity_id)
	if not errors.is_empty():
		return _result(simulation, registered, [], errors)

	_append_errors(errors, simulation.configure_neutral_world(protected_tie_key))
	var registered_neutrals: Array[int] = []
	if errors.is_empty():
		_spawn_neutral_creeps(simulation, registered_neutrals, errors)
	if not errors.is_empty():
		return _result(simulation, registered, registered_neutrals, errors)
	_append_errors(errors, simulation.configure_abilities(faction_id))
	if errors.is_empty():
		_register_starting_ability_actors(simulation, errors)
	if not errors.is_empty():
		return _result(simulation, registered, registered_neutrals, errors)
	_append_errors(errors, simulation.validate())
	return _result(simulation, registered, registered_neutrals, errors)


static func _register_starting_ability_actors(
	simulation: Simulation, errors: PackedStringArray
) -> void:
	var owner_types: Dictionary = {}
	for ability_variant: Variant in simulation.abilities.registry.values():
		var ability: Dictionary = ability_variant
		for owner_variant: Variant in ability.get("allowed_owners", []):
			owner_types[str(owner_variant)] = true
	for entity_id: int in simulation.state.sorted_entity_ids():
		var entity: EntityRecord = simulation.state.entities[entity_id]
		if entity.owner_seat not in [0, 1] or not owner_types.has(entity.catalog_id):
			continue
		var actor_errors := simulation.register_ability_actor(entity_id, entity.catalog_id)
		for message: String in actor_errors:
			errors.append("ability entity %d: %s" % [entity_id, message])


static func _spawn_neutral_creeps(
	simulation: Simulation,
	registered: Array[int],
	errors: PackedStringArray
) -> void:
	for descriptor: Dictionary in simulation.neutrals.creep_spawn_descriptors():
		var definition: Dictionary = descriptor["catalog_definition"]
		var entity_id := simulation.state.next_entity_id
		var entity := EntityRecord.new(entity_id, -1, "neutral_creep")
		entity.public_id = "e_neutral_%08d" % entity_id
		entity.catalog_id = str(descriptor["neutral_id"])
		var position := _resolved_neutral_spawn_position(
			simulation, descriptor, int(definition["radius_mt"])
		)
		if position.is_empty():
			errors.append("could not resolve neutral creep footprint: %s" % str(descriptor["member_id"]))
			return
		entity.set_position_mt(int(position[0]), int(position[1]))
		entity.max_hp = int(definition["hp"])
		entity.hp = entity.max_hp
		entity.max_mana = int(definition["mana"])
		entity.mana = entity.max_mana
		entity.radius_mt = int(definition["radius_mt"])
		entity.tags = ["biological", "ground", "neutral"]
		entity.integer_attributes = {
			"level": int(definition["level"]),
			"sight_day_mt": int(definition["sight_day_mt"]),
			"sight_night_mt": int(definition["sight_night_mt"]),
			"speed_mt_per_tick": int(definition["speed_mt_per_tick"]),
			"xp_bounty": int(definition["xp_bounty"]),
		}
		if simulation.add_entity(entity, true) != entity_id:
			errors.append("could not add neutral creep: %s" % str(descriptor["member_id"]))
			return
		var profile := {
			"armor_centi": int(definition["armor_centi"]),
			"armor_class": str(definition["armor_class"]),
			"attack": definition["attack"].duplicate(true),
			"layer": str(definition["layer"]),
			"radius_mt": int(definition["radius_mt"]),
			"speed_mt_per_tick": int(definition["speed_mt_per_tick"]),
			"tags": entity.tags.duplicate(),
		}
		_append_errors(errors, simulation.register_external_mobile_combat_entity(
			entity_id, "neutral", entity.catalog_id, profile
		))
		if not errors.is_empty():
			return
		_append_errors(errors, simulation.neutrals.bind_member_entity(
			str(descriptor["camp_id"]), str(descriptor["member_id"]), entity_id
		))
		if not errors.is_empty():
			return
		_append_errors(errors, simulation.neutrals.relocate_bound_member_spawn(
			str(descriptor["camp_id"]), str(descriptor["member_id"]), entity_id,
			position
		))
		if not errors.is_empty():
			return
		registered.append(entity_id)


static func _resolved_neutral_spawn_position(
	simulation: Simulation,
	descriptor: Dictionary,
	radius_mt: int
) -> Array:
	var requested: Array = descriptor["position_mt"]
	if simulation.grid.fits_ground_footprint_at_position(
		int(requested[0]), int(requested[1]), radius_mt
	):
		return requested.duplicate()
	var camp: Dictionary = simulation.neutrals.state.camps[str(descriptor["camp_id"])]
	var anchor: Array = camp["position_mt"]
	var direction_x := signi(int(requested[0]) - int(anchor[0]))
	var direction_y := signi(int(requested[1]) - int(anchor[1]))
	if direction_x == 0 and direction_y == 0:
		return []
	for step: int in range(1, 33):
		var candidate := [
			int(requested[0]) + direction_x * step * 500,
			int(requested[1]) + direction_y * step * 500,
		]
		if simulation.grid.fits_ground_footprint_at_position(
			int(candidate[0]), int(candidate[1]), radius_mt
		):
			return candidate
	return []


static func _result(
	simulation: Variant,
	registered: Array[int],
	registered_neutrals: Array[int],
	errors: PackedStringArray
) -> Dictionary:
	return {
		"errors": errors,
		"ok": errors.is_empty(),
		"registered_movement_entity_ids": registered,
		"registered_neutral_entity_ids": registered_neutrals,
		"simulation": simulation,
	}


static func _append_errors(target: PackedStringArray, source: Variant) -> void:
	if typeof(source) == TYPE_PACKED_STRING_ARRAY or typeof(source) == TYPE_ARRAY:
		for message_variant: Variant in source:
			target.append(str(message_variant))
	elif source != null:
		target.append(str(source))
