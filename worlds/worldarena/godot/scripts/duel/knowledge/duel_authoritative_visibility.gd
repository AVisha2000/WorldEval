class_name DuelAuthoritativeVisibility
extends RefCounted

## Cross-authority visibility adapter used by both phase-12 perception and
## ability candidate selection. It reads only canonical integer simulation
## facts, applies active status modifiers, and delegates LOS/rasterization to
## DuelVisibility. Provider-facing code never receives the internal IDs
## returned here.

const Visibility := preload("res://scripts/duel/knowledge/duel_visibility.gd")

const BP_ONE := 10_000
const VISION_ZONE_EFFECTS: Array[String] = ["reveal", "sight_and_detection"]


static func augment_entity_snapshots(simulation: Variant, source: Array) -> Array:
	var result: Array = source.duplicate(true)
	var status_by_target := _active_statuses_by_target(simulation)
	for index: int in result.size():
		var row: Dictionary = result[index]
		var entity_id := int(row.get("internal_id", 0))
		var entity: Variant = simulation.state.entities.get(entity_id)
		if entity == null:
			continue
		var invisible: bool = "invisible" in entity.tags \
			or bool(row.get("invisible", false))
		var sight_day := maxi(0, int(row.get("sight_day_mt", row.get("sight_radius_mt", 0))))
		var sight_night := maxi(0, int(row.get("sight_night_mt", row.get("sight_radius_mt", 0))))
		var detection := maxi(0, int(row.get("detection_radius_mt", 0)))
		var sight_multiplier_bp := BP_ONE
		for status_variant: Variant in status_by_target.get(entity_id, []):
			var status: Dictionary = status_variant
			var effect_kind := _status_effect_kind(status)
			var magnitude := int(status.get("magnitude", 0))
			match effect_kind:
				"invisibility":
					if magnitude > 0:
						invisible = true
				"sight_radius_mt":
					sight_day += magnitude
					sight_night += magnitude
				"night_sight_radius_mt":
					sight_night += magnitude
				"allied_detection_radius_mt":
					detection += magnitude
				"visible_enemy_sight_bp":
					sight_multiplier_bp += magnitude
				_:
					pass
		sight_multiplier_bp = maxi(0, sight_multiplier_bp)
		@warning_ignore("integer_division")
		row["sight_day_mt"] = maxi(0, sight_day * sight_multiplier_bp / BP_ONE)
		@warning_ignore("integer_division")
		row["sight_night_mt"] = maxi(0, sight_night * sight_multiplier_bp / BP_ONE)
		row["detection_radius_mt"] = maxi(0, detection)
		if invisible:
			row["invisible"] = true
		else:
			row.erase("invisible")
		result[index] = row
	result.sort_custom(_entity_less)
	return result


static func observer_overrides(simulation: Variant, observer_seat: int) -> Dictionary:
	var temporary_sources: Array = []
	var revealed_ids: Array[int] = []
	if simulation == null or not bool(simulation.get("is_ready")) \
		or observer_seat not in [0, 1]:
		return {
			"revealed_entity_internal_ids": [],
			"temporary_vision_sources": [],
		}
	## Point-vision casts are authority records even when no entity happened to
	## occupy the revealed area at commit time. Deriving the zone from the cast
	## prevents empty terrain, ground items, or later observation assembly from
	## disappearing merely because an entity-target status was not materialized.
	if simulation.abilities != null and simulation.abilities.is_configured():
		for cast_id: int in _sorted_int_keys(simulation.abilities.state.casts):
			var cast: Dictionary = simulation.abilities.state.casts[cast_id]
			## Windups have not paid/committed yet, while interrupted or cancelled
			## casts must never continue granting terrain knowledge.
			if str(cast.get("status", "")) not in ["committed", "channeling"]:
				continue
			var source_id := int(cast.get("actor_id", 0))
			if not simulation.state.entities.has(source_id) \
				or int(simulation.state.entities[source_id].owner_seat) != observer_seat:
				continue
			var ability: Dictionary = simulation.abilities.ability_definition(
				str(cast.get("ability_id", ""))
			)
			if ability.is_empty():
				continue
			var target: Dictionary = cast.get("target", {})
			var position: Variant = target.get("position_mt")
			if typeof(position) != TYPE_ARRAY or (position as Array).size() != 2:
				continue
			var rank := maxi(1, int(cast.get("rank", 1)))
			var commit_tick := int(cast.get("commit_tick", -1))
			for descriptor_variant: Variant in ability.get("effects", []):
				var descriptor: Dictionary = descriptor_variant
				var effect_kind := str(descriptor.get("kind", ""))
				if effect_kind not in VISION_ZONE_EFFECTS:
					continue
				var duration := _ranked_descriptor_int(
					descriptor, "duration_ticks", rank
				)
				var start_tick := commit_tick
				if str(ability.get("impact_schedule", "")) == "every_10_ticks_for_100_ticks":
					start_tick += 10
				if duration <= 0 or int(simulation.state.tick) < start_tick \
					or int(simulation.state.tick) >= commit_tick + duration:
					continue
				var radius := _ranked_ability_int(
					ability, "area_radius_mt", "area_radius_mt_by_rank", rank
				)
				if radius <= 0:
					continue
				temporary_sources.append({
					"detection_radius_mt": radius,
					"elevation": 2,
					"position_mt": [int(position[0]), int(position[1])],
					"sight_radius_mt": radius,
				})
	## Targeted reveal is dispellable, so it is sourced from the live status
	## ledger rather than the immutable cast record.
	for status_id: int in _sorted_int_keys(simulation.state.combat.statuses):
		var status: Dictionary = simulation.state.combat.statuses[status_id]
		if not _status_is_active(simulation, status) \
			or _status_effect_kind(status) != "reveal_target":
			continue
		var source_id := int(status.get("source_id", 0))
		var target_id := int(status.get("target_id", 0))
		if not simulation.state.entities.has(source_id) \
			or int(simulation.state.entities[source_id].owner_seat) != observer_seat \
			or not simulation.state.entities.has(target_id) \
			or not bool(simulation.state.entities[target_id].alive):
			continue
		if target_id not in revealed_ids:
			revealed_ids.append(target_id)
	temporary_sources.sort_custom(_vision_source_less)
	temporary_sources = _deduplicate_vision_sources(temporary_sources)
	revealed_ids.sort()
	var revealed_untyped: Array = []
	revealed_untyped.assign(revealed_ids)
	return {
		"revealed_entity_internal_ids": revealed_untyped,
		"temporary_vision_sources": temporary_sources,
	}


static func compute_for_seat(
	simulation: Variant,
	observer_seat: int,
	day_phase: String = ""
) -> Dictionary:
	if simulation == null or not bool(simulation.get("is_ready")):
		return _failure("authoritative visibility requires a ready simulation")
	if observer_seat not in [0, 1]:
		return _failure("observer seat must be 0 or 1")
	var resolved_phase := day_phase
	if resolved_phase.is_empty():
		resolved_phase = _day_phase(simulation)
	var grid: Dictionary = simulation.grid.to_canonical_dict()
	var rows := augment_entity_snapshots(simulation, _minimal_entity_snapshots(simulation, grid))
	var overrides := observer_overrides(simulation, observer_seat)
	return Visibility.compute(
		grid,
		rows,
		observer_seat,
		resolved_phase,
		overrides["temporary_vision_sources"],
		overrides["revealed_entity_internal_ids"]
	)


static func candidate_entity_ids(
	simulation: Variant,
	observer_seat: int,
	input_candidates: Array,
	include_owned: bool = true
) -> Array:
	if simulation == null or not bool(simulation.get("is_ready")) \
		or observer_seat not in [0, 1]:
		return []
	var grid: Dictionary = simulation.grid.to_canonical_dict()
	var rows := augment_entity_snapshots(
		simulation, _minimal_entity_snapshots(simulation, grid)
	)
	var overrides := observer_overrides(simulation, observer_seat)
	var computed := Visibility.compute_entity_ids(
		grid,
		rows,
		observer_seat,
		_day_phase(simulation),
		overrides["temporary_vision_sources"],
		overrides["revealed_entity_internal_ids"]
	)
	if not bool(computed.get("ok", false)):
		return []
	var allowed: Dictionary = {}
	for id_variant: Variant in computed.get("visible_entity_ids", []):
		allowed[int(id_variant)] = true
	if include_owned:
		for entity_id: int in simulation.state.sorted_entity_ids():
			var entity: Variant = simulation.state.entities[entity_id]
			if entity.alive and entity.hp > 0 and int(entity.owner_seat) == observer_seat:
				allowed[entity_id] = true
	var result: Array[int] = []
	for candidate_variant: Variant in input_candidates:
		var candidate_id := int(candidate_variant)
		if allowed.has(candidate_id) and candidate_id not in result:
			result.append(candidate_id)
	result.sort()
	var untyped: Array = []
	untyped.assign(result)
	return untyped


static func _minimal_entity_snapshots(simulation: Variant, grid: Dictionary) -> Array:
	var result: Array = []
	for entity_id: int in simulation.state.sorted_entity_ids():
		var entity: Variant = simulation.state.entities[entity_id]
		var definition := _definition(simulation, entity_id)
		var layer := _entity_layer(simulation, entity_id)
		var cells: Array = []
		if simulation.state.movement.enabled \
			and simulation.state.movement.actors.has(entity_id):
			cells = simulation.state.movement.actors[entity_id].get(
				"occupied_cells", []
			).duplicate()
		else:
			cells = simulation.grid.ground_cells_for_actor(entity_id)
		cells.sort()
		if cells.is_empty():
			var node_id := _position_node_id(
				[int(entity.position_x_mt), int(entity.position_y_mt)], grid
			)
			if node_id >= 0:
				cells = [node_id]
		var sight_day := int(definition.get(
			"sight_day_mt", entity.integer_attributes.get("sight_day_mt", 0)
		))
		var sight_night := int(definition.get(
			"sight_night_mt", entity.integer_attributes.get("sight_night_mt", 0)
		))
		var detection := int(definition.get(
			"detection_radius_mt",
			entity.integer_attributes.get("detection_radius_mt", 0)
		))
		if simulation.state.heroes.enabled \
			and simulation.state.heroes.heroes.has(entity_id):
			var derived: Dictionary = simulation.state.heroes.heroes[entity_id].get(
				"derived", {}
			)
			sight_day += int(derived.get("sight_radius_mt", 0))
			sight_night += int(derived.get("sight_radius_mt", 0))
			detection += int(derived.get("detection_radius_mt", 0))
		result.append({
			"alive": bool(entity.alive),
			"detection_radius_mt": maxi(0, detection),
			"internal_id": entity_id,
			"is_air": layer == "air",
			"layer": layer,
			"occupied_cell_ids": cells,
			"owner_seat": int(entity.owner_seat),
			"position_mt": [int(entity.position_x_mt), int(entity.position_y_mt)],
			"sight_day_mt": maxi(0, sight_day),
			"sight_night_mt": maxi(0, sight_night),
			"tags": entity.tags.duplicate(),
		})
	return result


static func _active_statuses_by_target(simulation: Variant) -> Dictionary:
	var result: Dictionary = {}
	if simulation == null or simulation.state == null \
		or not simulation.state.combat.enabled:
		return result
	for status_id: int in _sorted_int_keys(simulation.state.combat.statuses):
		var status: Dictionary = simulation.state.combat.statuses[status_id]
		if not _status_is_active(simulation, status):
			continue
		var target_id := int(status.get("target_id", 0))
		var rows: Array = result.get(target_id, [])
		rows.append(status.duplicate(true))
		result[target_id] = rows
	return result


static func _status_is_active(simulation: Variant, status: Dictionary) -> bool:
	return int(status.get("expiry_tick", -1)) > int(simulation.state.tick)


static func _status_effect_kind(status: Dictionary) -> String:
	return str(status.get("effect_kind", status.get("status_kind", "")))


static func _definition(simulation: Variant, entity_id: int) -> Dictionary:
	var entity: Variant = simulation.state.entities[entity_id]
	if simulation.state.heroes.enabled and simulation.state.heroes.heroes.has(entity_id):
		return simulation.heroes.catalog.get("faction", {}).get("heroes", {}).get(
			entity.catalog_id, {}
		)
	if simulation.ability_effects != null \
		and simulation.ability_effects.is_configured() \
		and simulation.ability_effects.faction_catalog.get(
			"summoned_entities", {}
		).has(entity.catalog_id):
		return simulation.ability_effects.faction_catalog["summoned_entities"][entity.catalog_id]
	if simulation.state.neutrals.enabled \
		and simulation.neutrals.neutrals.get("units", {}).has(entity.catalog_id):
		return simulation.neutrals.neutrals["units"][entity.catalog_id]
	var faction: Dictionary = simulation.combat.catalog.get("faction", {})
	if faction.get("units", {}).has(entity.catalog_id):
		return faction["units"][entity.catalog_id]
	if simulation.economy.catalog.get("structures", {}).has(entity.catalog_id):
		return simulation.economy.catalog["structures"][entity.catalog_id]
	if simulation.economy.catalog.get("units", {}).has(entity.catalog_id):
		return simulation.economy.catalog["units"][entity.catalog_id]
	return {}


static func _entity_layer(simulation: Variant, entity_id: int) -> String:
	if simulation.state.combat.enabled and simulation.state.combat.actors.has(entity_id):
		return str(simulation.state.combat.actors[entity_id].get("layer", "ground"))
	if simulation.state.movement.enabled and simulation.state.movement.actors.has(entity_id):
		return str(simulation.state.movement.actors[entity_id].get("layer", "ground"))
	return "air" if "air" in simulation.state.entities[entity_id].tags else "ground"


static func _position_node_id(position: Array, grid: Dictionary) -> int:
	if position.size() != 2:
		return -1
	@warning_ignore("integer_division")
	var x := int(position[0]) / int(grid["cell_size_mt"])
	@warning_ignore("integer_division")
	var y := int(position[1]) / int(grid["cell_size_mt"])
	if x < 0 or y < 0 or x >= int(grid["width"]) or y >= int(grid["height"]):
		return -1
	return y * int(grid["width"]) + x


static func _day_phase(simulation: Variant) -> String:
	if simulation.state.neutrals.enabled and simulation.neutrals != null:
		var phase: Dictionary = simulation.neutrals.day_phase(int(simulation.state.tick))
		return "forced_night" if bool(phase.get("forced", false)) \
			else str(phase.get("phase", "day"))
	return "day"


static func _ranked_descriptor_int(
	descriptor: Dictionary, field: String, rank: int
) -> int:
	var values: Variant = descriptor.get(field, [])
	if typeof(values) == TYPE_ARRAY and not (values as Array).is_empty():
		return int(values[clampi(rank - 1, 0, (values as Array).size() - 1)])
	return int(values) if typeof(values) == TYPE_INT else 0


static func _ranked_ability_int(
	ability: Dictionary, scalar_field: String, ranked_field: String, rank: int
) -> int:
	var ranked: Variant = ability.get(ranked_field, [])
	if typeof(ranked) == TYPE_ARRAY and not (ranked as Array).is_empty():
		return int(ranked[clampi(rank - 1, 0, (ranked as Array).size() - 1)])
	return int(ability.get(scalar_field, 0))


static func _deduplicate_vision_sources(source: Array) -> Array:
	var result: Array = []
	var prior := ""
	for row_variant: Variant in source:
		var row: Dictionary = row_variant
		var key := "%d|%d|%d|%d|%d" % [
			int(row["position_mt"][0]), int(row["position_mt"][1]),
			int(row["sight_radius_mt"]), int(row["detection_radius_mt"]),
			int(row["elevation"]),
		]
		if key == prior:
			continue
		result.append(row.duplicate(true))
		prior = key
	return result


static func _vision_source_less(left: Dictionary, right: Dictionary) -> bool:
	return [
		int(left["position_mt"][0]), int(left["position_mt"][1]),
		int(left["sight_radius_mt"]), int(left["detection_radius_mt"]),
		int(left["elevation"]),
	] < [
		int(right["position_mt"][0]), int(right["position_mt"][1]),
		int(right["sight_radius_mt"]), int(right["detection_radius_mt"]),
		int(right["elevation"]),
	]


static func _entity_less(left: Dictionary, right: Dictionary) -> bool:
	return int(left.get("internal_id", 0)) < int(right.get("internal_id", 0))


static func _sorted_int_keys(source: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for key_variant: Variant in source.keys():
		result.append(int(key_variant))
	result.sort()
	return result


static func _failure(message: String) -> Dictionary:
	return {
		"detected_entity_ids": [],
		"errors": PackedStringArray([message]),
		"ok": false,
		"visible_cell_ids": [],
		"visible_entity_ids": [],
	}
