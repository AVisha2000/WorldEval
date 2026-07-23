class_name DuelMovement
extends RefCounted

const Rules := preload("res://scripts/duel/simulation/duel_rules.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const OrderRecord := preload("res://scripts/duel/simulation/duel_order.gd")
const OccupancyGrid := preload("res://scripts/duel/simulation/duel_occupancy_grid.gd")
const MovementState := preload("res://scripts/duel/movement/duel_movement_state.gd")
const KeyedRandom := preload("res://scripts/duel/simulation/duel_keyed_random.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const BP_ONE := 10_000
const ALTITUDE_SLOT_COUNT := 4
const IDENTICAL_CONFLICT_TICKS := 3
const MOBILE_ORDER_KINDS := [
	"attack_entity", "attack_move", "attack_move_to", "follow", "move", "move_to", "patrol", "retreat",
]
const HALTING_ORDER_KINDS := ["hold", "hold_position", "stop"]

var _protected_tie_key := PackedByteArray()
var _intents: Dictionary = {}
var _proposals: Dictionary = {}
var _events: Array[Dictionary] = []
var _progress_this_tick: bool = false


func configure(
	movement_state: MovementState,
	faction_catalog: Dictionary,
	protected_tie_key: PackedByteArray
) -> PackedStringArray:
	var errors := validate_catalog(faction_catalog)
	if protected_tie_key.is_empty():
		errors.append("movement requires a non-empty protected tie key")
	if not errors.is_empty():
		return errors
	movement_state.enabled = true
	movement_state.faction_catalog_id = str(faction_catalog["catalog_id"])
	movement_state.protected_tie_key_digest = Codec.sha256_bytes(protected_tie_key)
	movement_state.catalog_profiles = _compile_profiles(faction_catalog)
	movement_state.actors.clear()
	movement_state.conflicts.clear()
	movement_state.air_occupancy.clear()
	movement_state.next_sequence_id = 1
	_protected_tie_key = protected_tie_key.duplicate()
	clear_pending()
	return errors


func validate_catalog(faction_catalog: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	for field: String in ["catalog_id", "faction_id", "units", "heroes"]:
		if not faction_catalog.has(field):
			errors.append("movement faction catalog is missing %s" % field)
	if not errors.is_empty():
		return errors
	for section: String in ["units", "heroes"]:
		if typeof(faction_catalog[section]) != TYPE_DICTIONARY:
			errors.append("movement faction %s must be an object" % section)
			continue
		var definitions: Dictionary = faction_catalog[section]
		var keys: Array = definitions.keys()
		keys.sort()
		for key_variant: Variant in keys:
			var key := str(key_variant)
			if typeof(definitions[key]) != TYPE_DICTIONARY:
				errors.append("movement definition %s.%s must be an object" % [section, key])
				continue
			var definition: Dictionary = definitions[key]
			for integer_field: String in ["radius_mt", "speed_mt_per_second", "speed_mt_per_tick"]:
				if typeof(definition.get(integer_field, null)) != TYPE_INT:
					errors.append("movement definition %s.%s.%s must be an integer" % [section, key, integer_field])
			if section == "units" and typeof(definition.get("tags", null)) != TYPE_ARRAY:
				errors.append("movement definition %s.%s.tags must be an array" % [section, key])
			if typeof(definition.get("speed_mt_per_second", null)) == TYPE_INT \
				and typeof(definition.get("speed_mt_per_tick", null)) == TYPE_INT:
				@warning_ignore("integer_division")
				var converted := int(definition["speed_mt_per_second"]) / Rules.TICKS_PER_SECOND
				if int(definition["speed_mt_per_tick"]) != converted:
					errors.append("movement definition %s.%s has a non-canonical speed conversion" % [section, key])
	for message: String in Codec.validate_canonical_value(faction_catalog, "$.faction"):
		errors.append(message)
	return errors


func install_external_profile(
	movement_state: MovementState,
	section: String,
	catalog_key: String,
	definition: Dictionary
) -> PackedStringArray:
	## Neutral, hired, and summoned movers share the ordinary movement solver but
	## originate outside the selected faction catalog. Compile only the closed,
	## integer movement facts required by the solver.
	var errors := PackedStringArray()
	if not movement_state.enabled:
		errors.append("movement is not configured")
		return errors
	if section not in ["hire", "neutral", "summon"]:
		errors.append("external movement profile section is invalid")
	if catalog_key.is_empty():
		errors.append("external movement profile key must not be empty")
	for field: String in ["layer", "radius_mt", "speed_mt_per_tick"]:
		if not definition.has(field):
			errors.append("external movement definition is missing %s" % field)
	if typeof(definition.get("layer", null)) == TYPE_STRING \
		and str(definition["layer"]) not in ["air", "ground"]:
		errors.append("external movement layer is invalid")
	for field: String in ["radius_mt", "speed_mt_per_tick"]:
		if definition.has(field) and (
			typeof(definition[field]) != TYPE_INT or int(definition[field]) < 0
		):
			errors.append("external movement %s must be a non-negative integer" % field)
	if not errors.is_empty():
		return errors
	var profile_id := "%s:%s:%s" % [
		str(movement_state.faction_catalog_id).trim_prefix("faction."), section, catalog_key,
	]
	## register_entity() resolves profiles by the unique section/key suffix, so
	## the stable prefix is descriptive and never changes lookup semantics.
	var tags: Array[String] = []
	for tag_variant: Variant in definition.get("tags", []):
		tags.append(str(tag_variant))
	tags.sort()
	var profile := {
		"layer": str(definition["layer"]),
		"profile_id": profile_id,
		"radius_mt": int(definition["radius_mt"]),
		"speed_mt_per_tick": int(definition["speed_mt_per_tick"]),
		"tags": tags,
	}
	if movement_state.catalog_profiles.has(profile_id) \
		and movement_state.catalog_profiles[profile_id] != profile:
		errors.append("external movement profile conflicts with existing profile")
		return errors
	movement_state.catalog_profiles[profile_id] = profile
	return errors


func register_entity(
	state: Variant,
	grid: OccupancyGrid,
	entity_id: int,
	section: String,
	catalog_key: String,
	overrides: Dictionary = {}
) -> PackedStringArray:
	var errors := PackedStringArray()
	if not state.movement.enabled:
		errors.append("movement is not configured")
		return errors
	if not state.entities.has(entity_id):
		errors.append("movement entity does not exist")
		return errors
	if state.movement.actors.has(entity_id):
		errors.append("movement entity is already registered")
		return errors
	for key_variant: Variant in overrides.keys():
		if str(key_variant) not in ["altitude_slot", "layer", "radius_mt", "speed_mt_per_tick"]:
			errors.append("unknown movement registration override: %s" % str(key_variant))
		elif str(key_variant) == "layer" and typeof(overrides[key_variant]) != TYPE_STRING:
			errors.append("movement layer override must be a string")
		elif str(key_variant) != "layer" and typeof(overrides[key_variant]) != TYPE_INT:
			errors.append("movement numeric overrides must be integers")
	if not errors.is_empty():
		return errors
	var profile_id := "%s:%s:%s" % [
		str(state.movement.faction_catalog_id).trim_suffix("-catalog"), section, catalog_key,
	]
	## Catalog IDs are content labels (for example `faction.vanguard-v1`) while
	## profile IDs use the faction's declared ID. Resolve by suffix when callers
	## use the public singular section API shared with combat.
	if not state.movement.catalog_profiles.has(profile_id):
		profile_id = _find_profile_id(state.movement.catalog_profiles, section, catalog_key)
	if profile_id.is_empty():
		errors.append("movement catalog profile does not exist: %s:%s" % [section, catalog_key])
		return errors
	var profile: Dictionary = state.movement.catalog_profiles[profile_id]
	var layer := str(overrides.get("layer", profile["layer"]))
	var radius_mt := int(overrides.get("radius_mt", profile["radius_mt"]))
	var speed_mt_per_tick := int(overrides.get("speed_mt_per_tick", profile["speed_mt_per_tick"]))
	if layer not in ["air", "ground"]:
		errors.append("movement layer must be air or ground")
	if radius_mt < 0 or speed_mt_per_tick < 0:
		errors.append("movement radius and speed must be non-negative")
	if not errors.is_empty():
		return errors

	var entity: EntityRecord = state.entities[entity_id]
	var old_radius := entity.radius_mt
	grid.release_ground_actor(entity_id)
	entity.radius_mt = radius_mt
	var occupied_cells := grid.footprint_cells_for_center_mt(
		entity.position_x_mt, entity.position_y_mt, radius_mt
	)
	if not _static_fits_position(
		grid, entity.position_x_mt, entity.position_y_mt, radius_mt, layer, []
	):
		entity.radius_mt = old_radius
		if layer == "ground":
			grid.reserve_ground_actor(entity_id, entity.position_x_mt, entity.position_y_mt, old_radius)
		errors.append("movement entity does not fit its static footprint")
		return errors

	var altitude_slot := -1
	if layer == "ground":
		if not grid.reserve_ground_actor(entity_id, entity.position_x_mt, entity.position_y_mt, radius_mt):
			entity.radius_mt = old_radius
			grid.reserve_ground_actor(entity_id, entity.position_x_mt, entity.position_y_mt, old_radius)
			errors.append("movement ground footprint is occupied")
			return errors
	else:
		var preferred_slot := int(overrides.get("altitude_slot", -1))
		altitude_slot = _select_air_slot(state.movement, occupied_cells, preferred_slot, entity_id)
		if altitude_slot < 0:
			entity.radius_mt = old_radius
			errors.append("movement air footprint has no free altitude lane")
			return errors
		_reserve_air(state.movement, entity_id, occupied_cells, altitude_slot)

	state.movement.actors[entity_id] = {
		"active_order_id": 0,
		"altitude_slot": altitude_slot,
		"avoid_cells": [],
		"entity_id": entity_id,
		"force_replan": false,
		"goal_x_mt": entity.position_x_mt,
		"goal_y_mt": entity.position_y_mt,
		"last_grid_revision": grid.revision,
		"layer": layer,
		"occupied_cells": occupied_cells,
		"path_generation": 0,
		"patrol_index": 0,
		"profile_id": profile_id,
		"radius_mt": radius_mt,
		"segment_origin_x_mt": entity.position_x_mt,
		"segment_origin_y_mt": entity.position_y_mt,
		"speed_mt_per_tick": speed_mt_per_tick,
		"speed_remainder_bp": 0,
	}
	entity.next_replan_tick = Rules.ordinary_replan_tick(entity_id, state.tick)
	return errors


func compile_intents(state: Variant, grid: OccupancyGrid, tick: int) -> void:
	_intents.clear()
	_proposals.clear()
	_progress_this_tick = false
	if not state.movement.enabled:
		return
	for actor_id: int in _sorted_int_keys(state.movement.actors):
		if not state.entities.has(actor_id):
			continue
		var entity: EntityRecord = state.entities[actor_id]
		var actor: Dictionary = state.movement.actors[actor_id]
		if not entity.alive or entity.hp <= 0:
			continue
		if entity.active_order_id == 0 or not state.orders.has(entity.active_order_id):
			continue
		var order: OrderRecord = state.orders[entity.active_order_id]
		if order.status != OrderRecord.Status.ACTIVE:
			continue
		if order.order_kind in HALTING_ORDER_KINDS:
			_clear_motion(entity, actor)
			if order.order_kind == "stop":
				_finish_order(state, entity, actor, order, tick, "stopped")
			continue
		if order.order_kind not in MOBILE_ORDER_KINDS:
			continue
		if _movement_is_prevented(state, actor_id, str(actor["layer"])):
			_queue_event(3, "movement_waited", actor_id, 0, {"reason": "movement_disabled_by_status"})
			continue
		var goal_result := _resolve_order_goal(state, entity, actor, order)
		if not bool(goal_result.get("ok", false)):
			_queue_event(3, "movement_waited", actor_id, 0, {
				"reason": str(goal_result.get("reason", "invalid_target")),
			})
			continue
		if bool(goal_result.get("hold", false)):
			_clear_route_progress(entity, actor)
			continue
		var goal_x_mt := int(goal_result["x_mt"])
		var goal_y_mt := int(goal_result["y_mt"])
		var goal_changed := goal_x_mt != int(actor["goal_x_mt"]) \
			or goal_y_mt != int(actor["goal_y_mt"]) \
			or int(actor["active_order_id"]) != order.internal_order_id
		if goal_changed:
			actor["goal_x_mt"] = goal_x_mt
			actor["goal_y_mt"] = goal_y_mt
			actor["force_replan"] = true
			actor["avoid_cells"] = []
		actor["active_order_id"] = order.internal_order_id
		_intents[actor_id] = {
			"actor_id": actor_id,
			"command_digest": order.command_digest,
			"goal_x_mt": goal_x_mt,
			"goal_y_mt": goal_y_mt,
			"order_id": order.internal_order_id,
			"order_kind": order.order_kind,
		}


func compute_paths(state: Variant, grid: OccupancyGrid, tick: int) -> void:
	if not state.movement.enabled:
		return
	for actor_id: int in _sorted_int_keys(_intents):
		var entity: EntityRecord = state.entities[actor_id]
		var actor: Dictionary = state.movement.actors[actor_id]
		var intent: Dictionary = _intents[actor_id]
		var invalid_next := not _next_route_footprint_is_static_legal(entity, actor, grid)
		if invalid_next and not entity.route.is_empty():
			actor["force_replan"] = true
			_queue_event(4, "route_invalidated", actor_id, 0, {
				"grid_revision": grid.revision, "reason": "next_footprint_closed",
			})
		var scheduled := tick >= entity.next_replan_tick
		var needs_path := entity.route.is_empty() or bool(actor["force_replan"]) or scheduled
		if not needs_path:
			continue
		var start := _cell_for_position(grid, entity.position_x_mt, entity.position_y_mt)
		var avoid_cells: Array[int] = []
		for cell_variant: Variant in actor.get("avoid_cells", []):
			avoid_cells.append(int(cell_variant))
		avoid_cells.sort()
		var goal := _nearest_static_fitting_cell(
			grid,
			int(intent["goal_x_mt"]),
			int(intent["goal_y_mt"]),
			int(actor["radius_mt"]),
			str(actor["layer"]),
			avoid_cells
		)
		var route: Array[Vector2i] = []
		if goal.x >= 0:
			route = _find_path(
				grid, start, goal, int(actor["radius_mt"]), str(actor["layer"]), avoid_cells
			)
		if route.is_empty():
			entity.route.clear()
			entity.route_index = 0
			entity.segment_numerator = 0
			entity.segment_denominator = 1
			entity.next_replan_tick = Rules.ordinary_replan_tick(actor_id, tick)
			actor["force_replan"] = false
			actor["avoid_cells"] = []
			actor["last_grid_revision"] = grid.revision
			_queue_event(4, "route_failed", actor_id, 0, {
				"goal_x_mt": int(intent["goal_x_mt"]), "goal_y_mt": int(intent["goal_y_mt"]),
			})
			continue
		_set_entity_route(entity, actor, grid, route)
		entity.next_replan_tick = Rules.ordinary_replan_tick(actor_id, tick)
		actor["force_replan"] = false
		actor["avoid_cells"] = []
		actor["last_grid_revision"] = grid.revision
		actor["path_generation"] = int(actor["path_generation"]) + 1
		_queue_event(4, "route_planned", actor_id, 0, {
			"goal_cell": {"x": goal.x, "y": goal.y},
			"path_generation": int(actor["path_generation"]),
			"route_length": route.size(),
			"scheduled_replan": scheduled,
		})


func resolve_movement(state: Variant, grid: OccupancyGrid, tick: int) -> void:
	if not state.movement.enabled:
		return
	_proposals.clear()
	for actor_id: int in _sorted_int_keys(_intents):
		var proposal := _build_proposal(state, grid, actor_id)
		if proposal.is_empty():
			continue
		var actor: Dictionary = state.movement.actors[actor_id]
		actor["speed_remainder_bp"] = int(proposal["speed_remainder_bp"])
		if bool(proposal["arrived"]) and not bool(proposal["moved"]):
			_handle_arrival(state, actor_id, tick)
			continue
		_proposals[actor_id] = proposal

	var adjacency: Dictionary = {}
	var stationary_blockers: Dictionary = {}
	var proposal_ids := _sorted_int_keys(_proposals)
	for actor_id: int in proposal_ids:
		adjacency[actor_id] = []
		var blockers := _stationary_blockers_for(state, grid, actor_id, _proposals[actor_id])
		if not blockers.is_empty():
			stationary_blockers[actor_id] = blockers
	for left_index: int in proposal_ids.size():
		var left_id := proposal_ids[left_index]
		for right_index: int in range(left_index + 1, proposal_ids.size()):
			var right_id := proposal_ids[right_index]
			if _proposals_conflict(_proposals[left_id], _proposals[right_id]):
				(adjacency[left_id] as Array).append(right_id)
				(adjacency[right_id] as Array).append(left_id)

	var accepted: Dictionary = {}
	var rejected: Dictionary = {}
	for actor_id: int in proposal_ids:
		if stationary_blockers.has(actor_id):
			rejected[actor_id] = "stationary_blocker"
			_mark_dynamic_route_blocked(state, grid, actor_id, stationary_blockers[actor_id], tick)

	var visited: Dictionary = {}
	var next_conflicts: Dictionary = {}
	for actor_id: int in proposal_ids:
		if visited.has(actor_id):
			continue
		var component := _connected_component(actor_id, adjacency, visited)
		if component.size() == 1 and (adjacency[actor_id] as Array).is_empty():
			if not rejected.has(actor_id):
				accepted[actor_id] = true
			continue
		_resolve_conflict_component(
			state, tick, component, accepted, rejected, next_conflicts
		)
	state.movement.conflicts = next_conflicts

	## A proposal selected by the keyed resolver is still forbidden from entering
	## a loser's frozen current footprint. Direct swaps therefore remain all-wait
	## and never create authoritative overlap.
	for actor_id: int in _sorted_int_keys(accepted):
		if not _legal_if_other_requests_wait(state, actor_id, _proposals[actor_id], accepted):
			accepted.erase(actor_id)
			rejected[actor_id] = "frozen_occupancy"

	_commit_accepted(state, grid, accepted, tick)
	for actor_id: int in proposal_ids:
		if accepted.has(actor_id):
			continue
		var entity: EntityRecord = state.entities[actor_id]
		entity.movement_remainder_mt = 0
		_queue_event(5, "movement_waited", actor_id, 0, {
			"reason": str(rejected.get(actor_id, "reservation_conflict")),
		})


func resolve_lifecycle(state: Variant) -> void:
	if not state.movement.enabled:
		return
	for actor_id: int in _sorted_int_keys(state.movement.actors):
		if not state.entities.has(actor_id):
			continue
		var entity: EntityRecord = state.entities[actor_id]
		var actor: Dictionary = state.movement.actors[actor_id]
		if entity.alive and entity.hp > 0:
			continue
		if str(actor["layer"]) == "air":
			_release_air(state.movement, actor_id, actor["occupied_cells"], int(actor["altitude_slot"]))
		actor["occupied_cells"] = []
		actor["force_replan"] = false
		actor["avoid_cells"] = []


func take_events() -> Array[Dictionary]:
	var result := _events.duplicate(true)
	_events.clear()
	return result


func take_progress() -> bool:
	var result := _progress_this_tick
	_progress_this_tick = false
	return result


func clear_pending() -> void:
	_intents.clear()
	_proposals.clear()
	_events.clear()
	_progress_this_tick = false


func static_find_path(
	grid: OccupancyGrid,
	start: Vector2i,
	goal: Vector2i,
	radius_mt: int,
	layer: String = "ground",
	avoid_cells: Array[int] = []
) -> Array[Vector2i]:
	return _find_path(grid, start, goal, radius_mt, layer, avoid_cells)


func _compile_profiles(faction: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var faction_id := str(faction["faction_id"])
	for section: String in ["units", "heroes"]:
		var singular := "unit" if section == "units" else "hero"
		var definitions: Dictionary = faction[section]
		var keys: Array = definitions.keys()
		keys.sort()
		for key_variant: Variant in keys:
			var key := str(key_variant)
			var definition: Dictionary = definitions[key]
			var tags: Array[String] = []
			for tag_variant: Variant in definition.get("tags", ["ground"] if section == "units" else ["ground", "hero"]):
				tags.append(str(tag_variant))
			tags.sort()
			var profile_id := "%s:%s:%s" % [faction_id, singular, key]
			result[profile_id] = {
				"layer": "air" if "air" in tags else "ground",
				"profile_id": profile_id,
				"radius_mt": int(definition["radius_mt"]),
				"speed_mt_per_tick": int(definition["speed_mt_per_tick"]),
				"tags": tags,
			}
	return result


static func _find_profile_id(profiles: Dictionary, section: String, catalog_key: String) -> String:
	var suffix := ":%s:%s" % [section, catalog_key]
	var matches: Array[String] = []
	for key_variant: Variant in profiles.keys():
		var key := str(key_variant)
		if key.ends_with(suffix):
			matches.append(key)
	matches.sort()
	return matches[0] if matches.size() == 1 else ""


func _resolve_order_goal(
	state: Variant,
	entity: EntityRecord,
	actor: Dictionary,
	order: OrderRecord
) -> Dictionary:
	if order.order_kind == "patrol":
		var targets_variant: Variant = order.target.get("targets", order.target.get("patrol_points", null))
		if typeof(targets_variant) != TYPE_ARRAY or (targets_variant as Array).size() < 2:
			return {"ok": false, "reason": "invalid_patrol_targets"}
		var targets: Array = targets_variant
		var index := posmod(int(actor["patrol_index"]), targets.size())
		return _target_to_point(state, entity, actor, targets[index], order.order_kind, order.target)
	return _target_to_point(state, entity, actor, order.target, order.order_kind, order.target)


func _target_to_point(
	state: Variant,
	entity: EntityRecord,
	actor: Dictionary,
	target_variant: Variant,
	order_kind: String,
	root_target: Dictionary
) -> Dictionary:
	if typeof(target_variant) != TYPE_DICTIONARY:
		return {"ok": false, "reason": "invalid_target"}
	var target: Dictionary = target_variant
	if target.has("entity_id") or target.has("target_id"):
		var target_id := int(target.get("entity_id", target.get("target_id", 0)))
		if not state.entities.has(target_id):
			return {"ok": false, "reason": "target_unavailable"}
		var target_entity: EntityRecord = state.entities[target_id]
		if not target_entity.alive:
			return {"ok": false, "reason": "target_unavailable"}
		var desired_distance := int(root_target.get("distance_mt", 0))
		if order_kind == "retreat" and desired_distance == 0:
			desired_distance = entity.radius_mt + target_entity.radius_mt + 1
		var dx := entity.position_x_mt - target_entity.position_x_mt
		var dy := entity.position_y_mt - target_entity.position_y_mt
		var distance := _integer_sqrt(dx * dx + dy * dy)
		if order_kind == "follow" and distance <= desired_distance:
			return {"hold": true, "ok": true}
		if desired_distance > 0:
			if distance == 0:
				return {
					"ok": true,
					"x_mt": target_entity.position_x_mt - desired_distance,
					"y_mt": target_entity.position_y_mt,
				}
			@warning_ignore("integer_division")
			return {
				"ok": true,
				"x_mt": target_entity.position_x_mt + dx * desired_distance / distance,
				"y_mt": target_entity.position_y_mt + dy * desired_distance / distance,
			}
		return {"ok": true, "x_mt": target_entity.position_x_mt, "y_mt": target_entity.position_y_mt}

	var point := _extract_point(target)
	if point.x < 0:
		return {"ok": false, "reason": "unresolved_target"}
	var offset_variant: Variant = root_target.get("formation_offset_mt", null)
	if typeof(offset_variant) == TYPE_ARRAY and (offset_variant as Array).size() == 2 \
		and typeof((offset_variant as Array)[0]) == TYPE_INT \
		and typeof((offset_variant as Array)[1]) == TYPE_INT:
		point.x += int((offset_variant as Array)[0])
		point.y += int((offset_variant as Array)[1])
	return {"ok": true, "x_mt": point.x, "y_mt": point.y}


static func _extract_point(target: Dictionary) -> Vector2i:
	var xy_variant: Variant = target.get("xy_mt", target.get("position_mt", null))
	if typeof(xy_variant) == TYPE_ARRAY and (xy_variant as Array).size() == 2 \
		and typeof((xy_variant as Array)[0]) == TYPE_INT \
		and typeof((xy_variant as Array)[1]) == TYPE_INT:
		return Vector2i(int((xy_variant as Array)[0]), int((xy_variant as Array)[1]))
	if typeof(xy_variant) == TYPE_DICTIONARY:
		var xy: Dictionary = xy_variant
		if typeof(xy.get("x", null)) == TYPE_INT and typeof(xy.get("y", null)) == TYPE_INT:
			return Vector2i(int(xy["x"]), int(xy["y"]))
	if typeof(target.get("x_mt", null)) == TYPE_INT and typeof(target.get("y_mt", null)) == TYPE_INT:
		return Vector2i(int(target["x_mt"]), int(target["y_mt"]))
	return Vector2i(-1, -1)


func _set_entity_route(
	entity: EntityRecord,
	actor: Dictionary,
	grid: OccupancyGrid,
	route: Array[Vector2i]
) -> void:
	entity.set_route_cells(route)
	actor["segment_origin_x_mt"] = entity.position_x_mt
	actor["segment_origin_y_mt"] = entity.position_y_mt
	var first_center := grid.cell_center_mt(route[0].x, route[0].y)
	entity.route_index = 1 if first_center == Vector2i(entity.position_x_mt, entity.position_y_mt) \
		and route.size() > 1 else 0
	entity.segment_numerator = 0
	entity.segment_denominator = _segment_cost(
		grid,
		Vector2i(entity.position_x_mt, entity.position_y_mt),
		_route_point_mt(entity, grid, entity.route_index),
		str(actor["layer"])
	)
	entity.movement_remainder_mt = 0


func _build_proposal(state: Variant, grid: OccupancyGrid, actor_id: int) -> Dictionary:
	var entity: EntityRecord = state.entities[actor_id]
	var actor: Dictionary = state.movement.actors[actor_id]
	if entity.route.is_empty() or entity.route_index < 0 or entity.route_index >= entity.route.size():
		return {}
	var multiplier_bp := _movement_multiplier_bp(state, actor_id)
	var speed_numerator := int(actor["speed_mt_per_tick"]) * multiplier_bp \
		+ int(actor["speed_remainder_bp"])
	@warning_ignore("integer_division")
	var budget := speed_numerator / BP_ONE
	var speed_remainder_bp := posmod(speed_numerator, BP_ONE)
	if budget <= 0:
		return {}
	var position := Vector2i(entity.position_x_mt, entity.position_y_mt)
	var origin := Vector2i(int(actor["segment_origin_x_mt"]), int(actor["segment_origin_y_mt"]))
	var route_index := entity.route_index
	var numerator := entity.segment_numerator
	var denominator := entity.segment_denominator
	var swept := _footprint_for_layer(grid, position.x, position.y, int(actor["radius_mt"]), str(actor["layer"]))
	var arrived := false
	while budget > 0 and route_index < entity.route.size():
		var target := _route_point_mt(entity, grid, route_index)
		if denominator <= 0:
			denominator = _segment_cost(grid, origin, target, str(actor["layer"]))
		var remaining := maxi(0, denominator - numerator)
		var spent := mini(budget, remaining)
		numerator += spent
		budget -= spent
		@warning_ignore("integer_division")
		position = Vector2i(
			origin.x + (target.x - origin.x) * numerator / denominator,
			origin.y + (target.y - origin.y) * numerator / denominator
		)
		_append_unique_cells(
			swept,
			_footprint_for_layer(grid, position.x, position.y, int(actor["radius_mt"]), str(actor["layer"]))
		)
		if numerator < denominator:
			break
		position = target
		origin = target
		route_index += 1
		numerator = 0
		if route_index >= entity.route.size():
			arrived = true
			denominator = 1
			break
		denominator = _segment_cost(
			grid, origin, _route_point_mt(entity, grid, route_index), str(actor["layer"])
		)
	var occupied := _footprint_for_layer(
		grid, position.x, position.y, int(actor["radius_mt"]), str(actor["layer"])
	)
	if not _static_fits_position(
		grid, position.x, position.y, int(actor["radius_mt"]), str(actor["layer"]), []
	):
		actor["force_replan"] = true
		return {}
	var altitude_slot := int(actor["altitude_slot"])
	if str(actor["layer"]) == "air":
		altitude_slot = _select_air_slot(state.movement, occupied, altitude_slot, actor_id)
		if altitude_slot < 0:
			altitude_slot = int(actor["altitude_slot"])
	return {
		"actor_id": actor_id,
		"altitude_slot": altitude_slot,
		"arrived": arrived,
		"command_digest": str(_intents[actor_id]["command_digest"]),
		"current_cells": (actor["occupied_cells"] as Array).duplicate(),
		"denominator": denominator,
		"layer": str(actor["layer"]),
		"moved": position.x != entity.position_x_mt or position.y != entity.position_y_mt,
		"numerator": numerator,
		"occupied_cells": occupied,
		"origin_x_mt": origin.x,
		"origin_y_mt": origin.y,
		"position_x_mt": position.x,
		"position_y_mt": position.y,
		"route_index": route_index,
		"speed_remainder_bp": speed_remainder_bp,
		"swept_cells": swept,
		"unspent_budget_mt": budget if arrived else 0,
	}


func _resolve_conflict_component(
	state: Variant,
	tick: int,
	component: Array[int],
	accepted: Dictionary,
	rejected: Dictionary,
	next_conflicts: Dictionary
) -> void:
	component.sort()
	var footprint: Array[int] = []
	for actor_id: int in component:
		_append_unique_cells(footprint, _proposals[actor_id]["swept_cells"])
	footprint.sort()
	var signature_payload := {
		"contender_ids": component,
		"footprint_node_ids": footprint,
		"layer": str(_proposals[component[0]]["layer"]),
	}
	var signature := Codec.sha256_canonical(signature_payload)
	var previous: Dictionary = state.movement.conflicts.get(signature, {})
	var count := 1
	if int(previous.get("last_tick", -2)) == tick - 1:
		count = int(previous.get("consecutive_ticks", 0)) + 1
	if count < IDENTICAL_CONFLICT_TICKS:
		next_conflicts[signature] = {
			"consecutive_ticks": count,
			"contender_ids": component.duplicate(),
			"footprint_node_ids": footprint,
			"last_tick": tick,
			"signature": signature,
		}
		for actor_id: int in component:
			rejected[actor_id] = "reservation_conflict"
		return

	var claims: Array[Dictionary] = []
	for actor_id: int in component:
		if rejected.has(actor_id) and str(rejected[actor_id]) == "stationary_blocker":
			continue
		claims.append({
			"canonical_command_digest": str(_proposals[actor_id]["command_digest"]),
			"internal_actor_id": actor_id,
		})
	var group_key := "movement|%d|%s" % [tick, signature]
	var ranked := KeyedRandom.rank_claimants(_protected_tie_key, group_key, claims)
	var winner_id := 0
	for claim: Dictionary in ranked:
		var candidate_id := int(claim["internal_actor_id"])
		if _legal_if_component_others_wait(state, candidate_id, component):
			winner_id = candidate_id
			break
	for actor_id: int in component:
		if actor_id == winner_id:
			accepted[actor_id] = true
		else:
			rejected[actor_id] = "keyed_reservation_loss" if winner_id != 0 else "keyed_swap_still_blocked"
	_queue_event(5, "movement_conflict_ranked", winner_id, 0, {
		"contender_ids": component,
		"group_key_digest": Codec.sha256_text(group_key),
		"signature": signature,
		"winner_actor_id": winner_id,
	})


func _commit_accepted(
	state: Variant,
	grid: OccupancyGrid,
	accepted: Dictionary,
	tick: int
) -> void:
	var accepted_ids := _sorted_int_keys(accepted)
	for actor_id: int in accepted_ids:
		var actor: Dictionary = state.movement.actors[actor_id]
		if str(actor["layer"]) == "ground":
			grid.release_ground_actor(actor_id)
		else:
			_release_air(state.movement, actor_id, actor["occupied_cells"], int(actor["altitude_slot"]))
	for actor_id: int in accepted_ids:
		var proposal: Dictionary = _proposals[actor_id]
		var actor: Dictionary = state.movement.actors[actor_id]
		var entity: EntityRecord = state.entities[actor_id]
		var reserved := true
		if str(actor["layer"]) == "ground":
			reserved = grid.reserve_ground_actor(
				actor_id, int(proposal["position_x_mt"]), int(proposal["position_y_mt"]), int(actor["radius_mt"])
			)
		else:
			reserved = _reserve_air(
				state.movement,
				actor_id,
				proposal["occupied_cells"],
				int(proposal["altitude_slot"])
			)
		if not reserved:
			push_error("deterministic movement reservation preflight diverged for actor %d" % actor_id)
			continue
		var previous_x_mt := entity.position_x_mt
		var previous_y_mt := entity.position_y_mt
		entity.position_x_mt = int(proposal["position_x_mt"])
		entity.position_y_mt = int(proposal["position_y_mt"])
		if entity.position_x_mt != previous_x_mt or entity.position_y_mt != previous_y_mt:
			entity.facing_mdeg = _facing_from_delta(
				entity.position_x_mt - previous_x_mt, entity.position_y_mt - previous_y_mt
			)
		entity.route_index = int(proposal["route_index"])
		entity.segment_numerator = int(proposal["numerator"])
		entity.segment_denominator = int(proposal["denominator"])
		entity.movement_remainder_mt = int(proposal["unspent_budget_mt"])
		actor["segment_origin_x_mt"] = int(proposal["origin_x_mt"])
		actor["segment_origin_y_mt"] = int(proposal["origin_y_mt"])
		actor["occupied_cells"] = (proposal["occupied_cells"] as Array).duplicate()
		actor["altitude_slot"] = int(proposal["altitude_slot"])
		actor["last_grid_revision"] = grid.revision
		_queue_event(5, "movement_committed", actor_id, 0, {
			"position_mt": {"x": entity.position_x_mt, "y": entity.position_y_mt},
			"route_index": entity.route_index,
		})
		_progress_this_tick = true
		if bool(proposal["arrived"]):
			_handle_arrival(state, actor_id, tick)


func _handle_arrival(state: Variant, actor_id: int, tick: int) -> void:
	if not state.entities.has(actor_id):
		return
	var entity: EntityRecord = state.entities[actor_id]
	var actor: Dictionary = state.movement.actors[actor_id]
	if entity.active_order_id == 0 or not state.orders.has(entity.active_order_id):
		return
	var order: OrderRecord = state.orders[entity.active_order_id]
	_queue_event(5, "movement_arrived", actor_id, 0, {
		"internal_order_id": order.internal_order_id, "order_kind": order.order_kind,
	})
	if order.order_kind == "patrol":
		var targets: Array = order.target.get("targets", order.target.get("patrol_points", []))
		if not targets.is_empty():
			actor["patrol_index"] = posmod(int(actor["patrol_index"]) + 1, targets.size())
		actor["force_replan"] = true
		return
	if order.order_kind == "follow":
		actor["force_replan"] = true
		return
	_finish_order(state, entity, actor, order, tick, "arrived")


func _finish_order(
	state: Variant,
	entity: EntityRecord,
	actor: Dictionary,
	order: OrderRecord,
	tick: int,
	reason: String
) -> void:
	order.status = OrderRecord.Status.COMPLETED
	entity.active_order_id = 0
	actor["active_order_id"] = 0
	actor["force_replan"] = false
	actor["avoid_cells"] = []
	_queue_event(5 if reason == "arrived" else 3, "movement_order_completed", entity.internal_id, 0, {
		"internal_order_id": order.internal_order_id, "reason": reason, "tick": tick,
	})


static func _clear_motion(entity: EntityRecord, actor: Dictionary) -> void:
	_clear_route_progress(entity, actor)
	actor["force_replan"] = false
	actor["avoid_cells"] = []


static func _clear_route_progress(entity: EntityRecord, actor: Dictionary) -> void:
	entity.route.clear()
	entity.route_index = 0
	entity.segment_numerator = 0
	entity.segment_denominator = 1
	entity.movement_remainder_mt = 0
	actor["segment_origin_x_mt"] = entity.position_x_mt
	actor["segment_origin_y_mt"] = entity.position_y_mt


func _mark_dynamic_route_blocked(
	state: Variant,
	grid: OccupancyGrid,
	actor_id: int,
	blocker_ids: Array[int],
	tick: int
) -> void:
	var actor: Dictionary = state.movement.actors[actor_id]
	var avoid_cells: Array[int] = []
	var unresolved_blockers: Dictionary = {}
	for blocker_id: int in blocker_ids:
		if state.movement.actors.has(blocker_id):
			_append_unique_cells(avoid_cells, state.movement.actors[blocker_id]["occupied_cells"])
		else:
			unresolved_blockers[blocker_id] = true
	if not unresolved_blockers.is_empty():
		var canonical_grid := grid.to_canonical_dict()
		for occupancy_variant: Variant in canonical_grid["ground_occupancy"]:
			var occupancy: Dictionary = occupancy_variant
			for occupant_variant: Variant in occupancy["actor_ids"]:
				if unresolved_blockers.has(int(occupant_variant)):
					avoid_cells.append(int(occupancy["node_id"]))
					break
	avoid_cells.sort()
	actor["force_replan"] = true
	actor["avoid_cells"] = avoid_cells
	var entity: EntityRecord = state.entities[actor_id]
	entity.next_replan_tick = tick + 1
	_queue_event(5, "route_invalidated", actor_id, 0, {
		"blocker_count": blocker_ids.size(), "reason": "dynamic_occupancy",
	})


func _stationary_blockers_for(
	state: Variant,
	grid: OccupancyGrid,
	actor_id: int,
	proposal: Dictionary
) -> Array[int]:
	var blockers: Array[int] = []
	## Ground occupancy may also contain buildings or not-yet movement-registered
	## actors. They are frozen stationary blockers even though they have no
	## MovementState record.
	if str(proposal["layer"]) == "ground":
		for node_variant: Variant in proposal["swept_cells"]:
			var cell := grid.cell_from_node_id(int(node_variant))
			for occupant_id: int in grid.occupied_actor_ids(cell.x, cell.y):
				if occupant_id != actor_id and not _proposals.has(occupant_id) \
					and occupant_id not in blockers:
					blockers.append(occupant_id)
	for other_id: int in _sorted_int_keys(state.movement.actors):
		if other_id == actor_id or _proposals.has(other_id):
			continue
		var other: Dictionary = state.movement.actors[other_id]
		if str(other["layer"]) != str(proposal["layer"]):
			continue
		if str(proposal["layer"]) == "air" \
			and int(other["altitude_slot"]) != int(proposal["altitude_slot"]):
			continue
		if _arrays_intersect(proposal["swept_cells"], other["occupied_cells"]):
			if other_id not in blockers:
				blockers.append(other_id)
	blockers.sort()
	return blockers


static func _proposals_conflict(left: Dictionary, right: Dictionary) -> bool:
	if str(left["layer"]) != str(right["layer"]):
		return false
	if str(left["layer"]) == "air" and int(left["altitude_slot"]) != int(right["altitude_slot"]):
		return false
	return _arrays_intersect(left["swept_cells"], right["swept_cells"])


func _legal_if_component_others_wait(
	state: Variant,
	candidate_id: int,
	component: Array[int]
) -> bool:
	var proposal: Dictionary = _proposals[candidate_id]
	for other_id: int in component:
		if other_id == candidate_id:
			continue
		var other: Dictionary = state.movement.actors[other_id]
		if str(other["layer"]) != str(proposal["layer"]):
			continue
		if str(proposal["layer"]) == "air" \
			and int(other["altitude_slot"]) != int(proposal["altitude_slot"]):
			continue
		if _arrays_intersect(proposal["swept_cells"], other["occupied_cells"]):
			return false
	return true


func _legal_if_other_requests_wait(
	state: Variant,
	candidate_id: int,
	proposal: Dictionary,
	accepted: Dictionary
) -> bool:
	for other_id: int in _sorted_int_keys(_proposals):
		if other_id == candidate_id or accepted.has(other_id):
			continue
		var other: Dictionary = state.movement.actors[other_id]
		if str(other["layer"]) != str(proposal["layer"]):
			continue
		if str(proposal["layer"]) == "air" \
			and int(other["altitude_slot"]) != int(proposal["altitude_slot"]):
			continue
		if _arrays_intersect(proposal["swept_cells"], other["occupied_cells"]):
			return false
	return true


static func _connected_component(
	start_id: int,
	adjacency: Dictionary,
	visited: Dictionary
) -> Array[int]:
	var result: Array[int] = []
	var pending: Array[int] = [start_id]
	while not pending.is_empty():
		var actor_id: int = pending.pop_back()
		if visited.has(actor_id):
			continue
		visited[actor_id] = true
		result.append(actor_id)
		var neighbors: Array = adjacency[actor_id]
		neighbors.sort()
		for neighbor_variant: Variant in neighbors:
			var neighbor := int(neighbor_variant)
			if not visited.has(neighbor):
				pending.append(neighbor)
	result.sort()
	return result


func _movement_multiplier_bp(state: Variant, actor_id: int) -> int:
	var result := BP_ONE
	var entity: EntityRecord = state.entities[actor_id]
	result += int(entity.integer_attributes.get("movement_speed_bp", 0))
	if state.combat.enabled:
		var status_ids := _sorted_int_keys(state.combat.statuses)
		for status_id: int in status_ids:
			var status: Dictionary = state.combat.statuses[status_id]
			if int(status.get("target_id", 0)) == actor_id \
				and str(status.get("status_kind", "")) == "movement_speed_bp":
				result += int(status.get("magnitude", 0))
	return clampi(result, 5_000, 20_000)


func _movement_is_prevented(state: Variant, actor_id: int, layer: String) -> bool:
	if not state.combat.enabled:
		return false
	for status_id: int in _sorted_int_keys(state.combat.statuses):
		var status: Dictionary = state.combat.statuses[status_id]
		if int(status.get("target_id", 0)) != actor_id:
			continue
		var kind := str(status.get("status_kind", ""))
		if kind in ["disable", "stun"] or (kind == "root" and layer == "ground"):
			return true
	return false


func _next_route_footprint_is_static_legal(
	entity: EntityRecord,
	actor: Dictionary,
	grid: OccupancyGrid
) -> bool:
	if entity.route.is_empty():
		return true
	if entity.route_index < 0 or entity.route_index >= entity.route.size():
		return false
	var point := _route_point_mt(entity, grid, entity.route_index)
	return _static_fits_position(
		grid, point.x, point.y, int(actor["radius_mt"]), str(actor["layer"]), []
	)


func _nearest_static_fitting_cell(
	grid: OccupancyGrid,
	requested_x_mt: int,
	requested_y_mt: int,
	radius_mt: int,
	layer: String,
	avoid_cells: Array[int]
) -> Vector2i:
	if requested_x_mt < 0 or requested_y_mt < 0 \
		or requested_x_mt >= grid.width * grid.cell_size_mt \
		or requested_y_mt >= grid.height * grid.cell_size_mt:
		return Vector2i(-1, -1)
	var best := Vector2i(-1, -1)
	var best_distance_squared := 9_223_372_036_854_775_807
	for y: int in grid.height:
		for x: int in grid.width:
			var center := grid.cell_center_mt(x, y)
			if not _static_fits_position(
				grid, center.x, center.y, radius_mt, layer, avoid_cells
			):
				continue
			var dx := center.x - requested_x_mt
			var dy := center.y - requested_y_mt
			var distance_squared := dx * dx + dy * dy
			if distance_squared < best_distance_squared:
				best_distance_squared = distance_squared
				best = Vector2i(x, y)
			elif distance_squared == best_distance_squared \
				and (best.y < 0 or y < best.y or (y == best.y and x < best.x)):
				best = Vector2i(x, y)
	return best


func _find_path(
	grid: OccupancyGrid,
	start: Vector2i,
	goal: Vector2i,
	radius_mt: int,
	layer: String,
	avoid_cells: Array[int]
) -> Array[Vector2i]:
	var empty: Array[Vector2i] = []
	if not grid.in_bounds(start.x, start.y) or not grid.in_bounds(goal.x, goal.y):
		return empty
	var start_center := grid.cell_center_mt(start.x, start.y)
	var goal_center := grid.cell_center_mt(goal.x, goal.y)
	if not _static_fits_position(grid, start_center.x, start_center.y, radius_mt, layer, []) \
		or not _static_fits_position(grid, goal_center.x, goal_center.y, radius_mt, layer, avoid_cells):
		return empty
	if start == goal:
		return [start]

	var start_id := grid.node_id(start.x, start.y)
	var goal_id := grid.node_id(goal.x, goal.y)
	var open_heap: Array[Dictionary] = []
	var g_score: Dictionary = {start_id: 0}
	var turn_score: Dictionary = {start_id: 0}
	var incoming_direction: Dictionary = {start_id: -1}
	var came_from: Dictionary = {}
	var closed: Dictionary = {}
	var heuristic_terrain := Rules.TERRAIN_COST_BASE \
		if layer == "air" else grid.minimum_ground_terrain_cost_permille()
	var start_h := _scaled_octile(start, goal, heuristic_terrain)
	_heap_push(open_heap, _path_record(start_id, start, 0, start_h, 0, -1))
	while not open_heap.is_empty():
		var current_record := _heap_pop(open_heap)
		var current_id := int(current_record["node_id"])
		if closed.has(current_id) or not g_score.has(current_id):
			continue
		if int(current_record["g_cost"]) != int(g_score[current_id]) \
			or int(current_record["turn_count"]) != int(turn_score[current_id]):
			continue
		var current := Vector2i(int(current_record["node_x"]), int(current_record["node_y"]))
		if current_id == goal_id:
			return _reconstruct_path(grid, came_from, current_id)
		closed[current_id] = true
		var current_direction := int(incoming_direction[current_id])
		for neighbor: Dictionary in Rules.NEIGHBORS:
			var next := Vector2i(current.x + int(neighbor["dx"]), current.y + int(neighbor["dy"]))
			if not grid.in_bounds(next.x, next.y):
				continue
			var next_center := grid.cell_center_mt(next.x, next.y)
			if not _static_fits_position(
				grid, next_center.x, next_center.y, radius_mt, layer, avoid_cells
			):
				continue
			if bool(neighbor["diagonal"]) and layer == "ground" \
				and not _static_diagonal_legal(
					grid, current, int(neighbor["dx"]), int(neighbor["dy"]), radius_mt, avoid_cells
				):
				continue
			var next_id := grid.node_id(next.x, next.y)
			if closed.has(next_id):
				continue
			var terrain_cost := Rules.TERRAIN_COST_BASE \
				if layer == "air" else grid.terrain_cost_permille(next.x, next.y)
			var step_cost := _scaled_step(int(neighbor["base_cost"]), terrain_cost)
			var tentative_g := int(g_score[current_id]) + step_cost
			var next_direction := int(neighbor["direction"])
			var tentative_turns := int(turn_score[current_id])
			if current_direction >= 0 and current_direction != next_direction:
				tentative_turns += 1
			var better := not g_score.has(next_id) or tentative_g < int(g_score[next_id])
			if not better and tentative_g == int(g_score[next_id]) \
				and tentative_turns < int(turn_score[next_id]):
				better = true
			if not better:
				continue
			came_from[next_id] = current_id
			g_score[next_id] = tentative_g
			turn_score[next_id] = tentative_turns
			incoming_direction[next_id] = next_direction
			var h_cost := _scaled_octile(next, goal, heuristic_terrain)
			_heap_push(
				open_heap,
				_path_record(next_id, next, tentative_g, h_cost, tentative_turns, next_direction)
			)
	return empty


func _static_diagonal_legal(
	grid: OccupancyGrid,
	current: Vector2i,
	dx: int,
	dy: int,
	radius_mt: int,
	avoid_cells: Array[int]
) -> bool:
	for cell: Vector2i in [Vector2i(current.x + dx, current.y), Vector2i(current.x, current.y + dy)]:
		if not grid.in_bounds(cell.x, cell.y):
			return false
		var center := grid.cell_center_mt(cell.x, cell.y)
		if not _static_fits_position(grid, center.x, center.y, radius_mt, "ground", avoid_cells):
			return false
	return true


func _static_fits_position(
	grid: OccupancyGrid,
	x_mt: int,
	y_mt: int,
	radius_mt: int,
	layer: String,
	avoid_cells: Array[int]
) -> bool:
	if radius_mt < 0 or x_mt - radius_mt < 0 or y_mt - radius_mt < 0 \
		or x_mt + radius_mt > grid.width * grid.cell_size_mt \
		or y_mt + radius_mt > grid.height * grid.cell_size_mt:
		return false
	var cells := grid.footprint_cells_for_center_mt(x_mt, y_mt, radius_mt)
	if cells.is_empty():
		return false
	for node_id: int in cells:
		var cell := grid.cell_from_node_id(node_id)
		if layer == "air":
			if not grid.is_air_pathable(cell.x, cell.y):
				return false
		elif not grid.is_ground_pathable(cell.x, cell.y):
			return false
		if node_id in avoid_cells:
			return false
	return true


static func _cell_for_position(grid: OccupancyGrid, x_mt: int, y_mt: int) -> Vector2i:
	@warning_ignore("integer_division")
	return Vector2i(
		clampi(x_mt / grid.cell_size_mt, 0, grid.width - 1),
		clampi(y_mt / grid.cell_size_mt, 0, grid.height - 1)
	)


static func _route_point_mt(entity: EntityRecord, grid: OccupancyGrid, route_index: int) -> Vector2i:
	if route_index < 0 or route_index >= entity.route.size():
		return Vector2i(entity.position_x_mt, entity.position_y_mt)
	var point: Dictionary = entity.route[route_index]
	return grid.cell_center_mt(int(point["x"]), int(point["y"]))


static func _segment_cost(
	grid: OccupancyGrid,
	from_mt: Vector2i,
	to_mt: Vector2i,
	layer: String
) -> int:
	var dx := to_mt.x - from_mt.x
	var dy := to_mt.y - from_mt.y
	var distance := _integer_sqrt(dx * dx + dy * dy)
	if distance <= 0:
		return 1
	var terrain_cost := Rules.TERRAIN_COST_BASE
	if layer == "ground":
		var target_cell := _cell_for_position(grid, to_mt.x, to_mt.y)
		terrain_cost = grid.terrain_cost_permille(target_cell.x, target_cell.y)
	@warning_ignore("integer_division")
	return maxi(1, distance * terrain_cost / Rules.TERRAIN_COST_BASE)


static func _footprint_for_layer(
	grid: OccupancyGrid,
	x_mt: int,
	y_mt: int,
	radius_mt: int,
	_layer: String
) -> Array[int]:
	return grid.footprint_cells_for_center_mt(x_mt, y_mt, radius_mt)


static func _select_air_slot(
	movement_state: MovementState,
	cells: Array[int],
	preferred_slot: int,
	ignored_actor_id: int
) -> int:
	var candidates: Array[int] = []
	if preferred_slot >= 0 and preferred_slot < ALTITUDE_SLOT_COUNT:
		candidates.append(preferred_slot)
	for slot: int in ALTITUDE_SLOT_COUNT:
		if slot not in candidates:
			candidates.append(slot)
	for slot: int in candidates:
		var legal := true
		for node_id: int in cells:
			var lanes: Dictionary = movement_state.air_occupancy.get(node_id, {})
			if lanes.has(slot) and int(lanes[slot]) != ignored_actor_id:
				legal = false
				break
		if legal:
			return slot
	return -1


static func _reserve_air(
	movement_state: MovementState,
	actor_id: int,
	cells_variant: Variant,
	slot: int
) -> bool:
	var cells: Array = cells_variant
	if actor_id <= 0 or slot < 0 or slot >= ALTITUDE_SLOT_COUNT:
		return false
	for node_variant: Variant in cells:
		var node_id := int(node_variant)
		var lanes: Dictionary = movement_state.air_occupancy.get(node_id, {})
		if lanes.has(slot) and int(lanes[slot]) != actor_id:
			return false
	for node_variant: Variant in cells:
		var node_id := int(node_variant)
		var lanes: Dictionary = movement_state.air_occupancy.get(node_id, {}).duplicate()
		lanes[slot] = actor_id
		movement_state.air_occupancy[node_id] = lanes
	return true


static func _release_air(
	movement_state: MovementState,
	actor_id: int,
	cells_variant: Variant,
	slot: int
) -> void:
	var cells: Array = cells_variant
	for node_variant: Variant in cells:
		var node_id := int(node_variant)
		if not movement_state.air_occupancy.has(node_id):
			continue
		var lanes: Dictionary = movement_state.air_occupancy[node_id]
		if lanes.has(slot) and int(lanes[slot]) == actor_id:
			lanes.erase(slot)
		if lanes.is_empty():
			movement_state.air_occupancy.erase(node_id)
		else:
			movement_state.air_occupancy[node_id] = lanes


func _queue_event(
	phase: int,
	kind: String,
	source_id: int,
	target_id: int,
	payload: Dictionary
) -> void:
	_events.append({
		"event_kind": kind,
		"payload": payload,
		"phase": phase,
		"source_internal_id": source_id,
		"target_internal_id": target_id,
	})


static func _append_unique_cells(target: Array[int], source_variant: Variant) -> void:
	var seen: Dictionary = {}
	for value: int in target:
		seen[value] = true
	var source: Array = source_variant
	for value_variant: Variant in source:
		var value := int(value_variant)
		if not seen.has(value):
			target.append(value)
			seen[value] = true
	target.sort()


static func _arrays_intersect(left_variant: Variant, right_variant: Variant) -> bool:
	var left: Array = left_variant
	var right: Array = right_variant
	var left_index := 0
	var right_index := 0
	while left_index < left.size() and right_index < right.size():
		var left_value := int(left[left_index])
		var right_value := int(right[right_index])
		if left_value == right_value:
			return true
		if left_value < right_value:
			left_index += 1
		else:
			right_index += 1
	return false


static func _sorted_int_keys(source: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for key_variant: Variant in source.keys():
		result.append(int(key_variant))
	result.sort()
	return result


static func _integer_sqrt(value: int) -> int:
	if value <= 0:
		return 0
	var result := 0
	var bit := 1
	while bit <= value / 4:
		bit <<= 2
	while bit != 0:
		if value >= result + bit:
			value -= result + bit
			result = (result >> 1) + bit
		else:
			result >>= 1
		bit >>= 2
	return result


static func _facing_from_delta(dx: int, dy: int) -> int:
	if dx > 0:
		if dy > 0:
			return 45_000
		if dy < 0:
			return 315_000
		return 0
	if dx < 0:
		if dy > 0:
			return 135_000
		if dy < 0:
			return 225_000
		return 180_000
	return 90_000 if dy > 0 else 270_000


static func _scaled_step(base_cost: int, terrain_cost: int) -> int:
	@warning_ignore("integer_division")
	return base_cost * terrain_cost / Rules.TERRAIN_COST_BASE


static func _scaled_octile(from_cell: Vector2i, to_cell: Vector2i, terrain_cost: int) -> int:
	var dx := absi(to_cell.x - from_cell.x)
	var dy := absi(to_cell.y - from_cell.y)
	var diagonal_steps := mini(dx, dy)
	var cardinal_steps := maxi(dx, dy) - diagonal_steps
	return diagonal_steps * _scaled_step(Rules.DIAGONAL_COST, terrain_cost) \
		+ cardinal_steps * _scaled_step(Rules.CARDINAL_COST, terrain_cost)


static func _path_record(
	node_id: int,
	cell: Vector2i,
	g_cost: int,
	h_cost: int,
	turn_count: int,
	direction: int
) -> Dictionary:
	return {
		"direction": direction,
		"f_cost": g_cost + h_cost,
		"g_cost": g_cost,
		"h_cost": h_cost,
		"node_id": node_id,
		"node_x": cell.x,
		"node_y": cell.y,
		"turn_count": turn_count,
	}


static func _path_record_less(left: Dictionary, right: Dictionary) -> bool:
	for key: String in ["f_cost", "h_cost", "turn_count", "node_y", "node_x", "node_id"]:
		if int(left[key]) != int(right[key]):
			return int(left[key]) < int(right[key])
	return false


static func _heap_push(heap: Array[Dictionary], record: Dictionary) -> void:
	heap.append(record)
	var index := heap.size() - 1
	while index > 0:
		@warning_ignore("integer_division")
		var parent: int = (index - 1) / 2
		if not _path_record_less(heap[index], heap[parent]):
			break
		var swap := heap[parent]
		heap[parent] = heap[index]
		heap[index] = swap
		index = parent


static func _heap_pop(heap: Array[Dictionary]) -> Dictionary:
	var root: Dictionary = heap[0]
	var tail: Dictionary = heap.pop_back()
	if heap.is_empty():
		return root
	heap[0] = tail
	var index := 0
	while true:
		var left := index * 2 + 1
		var right := left + 1
		var smallest := index
		if left < heap.size() and _path_record_less(heap[left], heap[smallest]):
			smallest = left
		if right < heap.size() and _path_record_less(heap[right], heap[smallest]):
			smallest = right
		if smallest == index:
			break
		var swap := heap[index]
		heap[index] = heap[smallest]
		heap[smallest] = swap
		index = smallest
	return root


static func _reconstruct_path(
	grid: OccupancyGrid,
	came_from: Dictionary,
	goal_id: int
) -> Array[Vector2i]:
	var reversed: Array[Vector2i] = [grid.cell_from_node_id(goal_id)]
	var current_id := goal_id
	while came_from.has(current_id):
		current_id = int(came_from[current_id])
		reversed.append(grid.cell_from_node_id(current_id))
	reversed.reverse()
	return reversed
