class_name DuelOfficialReplayProjectionBuilder
extends RefCounted

## Builds a detached post-match spectator projection from verified authority.
## The returned dictionary contains public IDs only and can cross into the
## presentation layer; no simulation/session object is retained.


func omniscient(session: Variant, maximum_tick: int) -> Dictionary:
	if session == null or session.simulation == null:
		return {}
	var simulation: Variant = session.simulation
	var entity_ids: Array = simulation.state.entities.keys()
	entity_ids.sort()
	var entities: Array = []
	for entity_id_variant: Variant in entity_ids:
		var entity: Variant = simulation.state.entities[entity_id_variant]
		if not bool(entity.alive):
			continue
		entities.append({
			"catalog_id": str(entity.catalog_id),
			"entity_id": str(entity.public_id),
			"hp": int(entity.hp),
			"id": str(entity.public_id),
			"kind": str(entity.entity_kind),
			"mana": int(entity.mana),
			"max_hp": int(entity.max_hp),
			"max_mana": int(entity.max_mana),
			"player_slot": int(entity.owner_seat),
			"position_mt": [int(entity.position_x_mt), int(entity.position_y_mt)],
			"tags": entity.tags.duplicate(),
		})
	var players: Array = []
	for seat: int in [0, 1]:
		var economy: Dictionary = simulation.state.economy.players.get(seat, {})
		players.append({
			"heroes": _heroes(simulation, seat),
			"label": "Model %s" % ("A" if seat == 0 else "B"),
			"resources": {
				"food_cap": int(economy.get("food_capacity", 0)),
				"food_used": int(economy.get("food_used", 0)),
				"gold": int(economy.get("gold", 0)),
				"lumber": int(economy.get("lumber", 0)),
				"upkeep": str(economy.get("upkeep_tier", "none")),
			},
			"stronghold": _stronghold(simulation, seat),
			"tier": int(economy.get("technology_tier", 1)),
		})
	var coordinate_system: Dictionary = session.map_manifest.get("coordinate_system", {})
	var bounds: Dictionary = coordinate_system.get("bounds_mt", {})
	var maximum: Array = bounds.get("max_exclusive", [192_000, 128_000])
	return {
		"day_phase": _day_phase(simulation),
		"decision_mode": str(session.decision_mode),
		"entities": entities,
		"map": {
			"height_mt": int(maximum[1]) if maximum.size() == 2 else 128_000,
			"width_mt": int(maximum[0]) if maximum.size() == 2 else 192_000,
		},
		"maximum_match_ticks": maximum_tick,
		"objective": "Destroy the opposing Stronghold",
		"perspective_id": "omniscient",
		"players": players,
		"projection_kind": "verified_omniscient_authority",
		"simulation_hz": 10,
		"tick": int(simulation.state.tick),
	}


static func _heroes(simulation: Variant, seat: int) -> Array:
	var result: Array = []
	var entity_ids: Array = simulation.state.entities.keys()
	entity_ids.sort()
	for entity_id_variant: Variant in entity_ids:
		var entity: Variant = simulation.state.entities[entity_id_variant]
		if int(entity.owner_seat) != seat or not bool(entity.alive) \
			or not simulation.state.heroes.heroes.has(int(entity.internal_id)):
			continue
		var hero: Dictionary = simulation.state.heroes.heroes[int(entity.internal_id)]
		result.append({
			"hp": int(entity.hp),
			"level": int(hero.get("level", 1)),
			"max_hp": int(entity.max_hp),
			"name": str(entity.catalog_id),
			"state": str(hero.get("life_state", "alive")),
		})
	return result


static func _stronghold(simulation: Variant, seat: int) -> Dictionary:
	var entity_ids: Array = simulation.state.entities.keys()
	entity_ids.sort()
	for entity_id_variant: Variant in entity_ids:
		var entity: Variant = simulation.state.entities[entity_id_variant]
		if int(entity.owner_seat) == seat and "stronghold" in entity.tags:
			return {"hp": int(entity.hp), "max_hp": int(entity.max_hp)}
	return {}


static func _day_phase(simulation: Variant) -> String:
	if simulation.neutrals != null and bool(simulation.state.neutrals.enabled):
		var phase: Dictionary = simulation.neutrals.day_phase(int(simulation.state.tick))
		return "forced_night" if bool(phase.get("forced", false)) \
			else str(phase.get("phase", "day"))
	return "day"
