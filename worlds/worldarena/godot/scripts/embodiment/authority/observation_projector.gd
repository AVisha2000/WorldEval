class_name EmbodimentObservationProjector
extends RefCounted

const Visibility := preload("res://scripts/embodiment/authority/visibility.gd")
const ArenaMap := preload("res://scripts/embodiment/authority/arena_map.gd")
const FACING_NAMES := [
	"north", "north_east", "east", "south_east",
	"south", "south_west", "west", "north_west",
]


static func project(authority: Object) -> Dictionary:
	var visible_entities := _visible_entities(authority)
	var inventory: Array[Dictionary] = []
	var health_percent := 100
	var energy_percent := 100
	var status: Array[String] = []
	if authority.task_id in ["interaction-v0", "construction-v0"] \
		and authority.inventory_material_units > 0:
		inventory.append({
			"kind": "material",
			"count": authority.inventory_material_units,
			"selected": true,
		})
	if authority.task_id == "neutral-encounter-v0":
		health_percent = ArenaMap.divide_toward_zero(
			authority.operator_health * 100, authority.CombatSystem.OPERATOR_MAX_HEALTH
		)
		energy_percent = ArenaMap.divide_toward_zero(
			authority.operator_energy * 100, authority.CombatSystem.OPERATOR_MAX_ENERGY
		)
		if authority.operator_guarding:
			status.append("guarding")
		if authority.primary_cooldown_ticks > 0:
			status.append("primary_cooldown")
		if authority.dash_cooldown_ticks > 0:
			status.append("dash_cooldown")
	return {
		"protocol_version": authority.PROTOCOL_VERSION,
		"episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq,
		"tick": authority.tick,
		"profile": authority.observation_profile,
		"goal": _goal(authority.task_id),
		"remaining_ticks": maxi(authority.maximum_episode_ticks - authority.tick, 0),
		"self": {
			"health_percent": health_percent,
			"energy_percent": energy_percent,
			"facing": FACING_NAMES[authority.operator_heading],
			"contact": authority.contact,
			"inventory": inventory,
			"status": status,
		},
		"visible_entities": visible_entities,
		"recent_events": authority.recent_events.duplicate(true),
		"previous_receipt": authority.previous_receipt.duplicate(true)
			if authority.previous_receipt is Dictionary else null,
		"memory": authority.memory,
		"terminal": authority.terminal.duplicate(true),
	}


static func _visible_entities(authority: Object) -> Array[Dictionary]:
	if authority.task_id == "orientation-v0":
		var beacon_state := "active"
		if authority.beacon_hold_ticks > 0:
			beacon_state = "holding_%s" % _progress_band(
				authority.beacon_hold_ticks, authority.BEACON_HOLD_TICKS
			)
		return [_entity(
			authority, "v_beacon_1", "beacon", authority.beacon_position_mt,
			["goal"], beacon_state, authority.BEACON_RADIUS_MT,
		)]
	if authority.task_id in ["interaction-v0", "construction-v0"]:
		var resource_state := "depleted" if authority.resource_units_remaining <= 0 else "available"
		if authority.gather_progress_ticks > 0:
			resource_state = "gathering_%s" % _progress_band(
				authority.gather_progress_ticks,
				authority.InteractionSystem.GATHER_TICKS_PER_UNIT,
			)
		var relay_state := "empty"
		if authority.deposited_material_units >= authority.ConstructionSystem.BARRICADE_MATERIAL_REQUIRED:
			relay_state = "materials_ready"
		elif authority.deposited_material_units > 0:
			relay_state = "materials_present"
		var entities: Array[Dictionary] = [
			_entity(
				authority, "v_resource_1", "resource", authority.resource_position_mt,
				["interactable", "gather"],
				resource_state, authority.InteractionSystem.INTERACTION_RANGE_MT,
			),
			_entity(
				authority, "v_relay_1", "relay", authority.relay_position_mt,
				["interactable", "deposit"],
				relay_state,
				authority.InteractionSystem.INTERACTION_RANGE_MT,
			),
		]
		if authority.task_id == "construction-v0":
			var pad_state := "needs_materials"
			if authority.barricade_complete:
				pad_state = "complete"
			elif authority.barricade_progress_ticks > 0:
				pad_state = "building_%s" % _progress_band(
					authority.barricade_progress_ticks,
					authority.ConstructionSystem.BARRICADE_BUILD_TICKS_REQUIRED,
				)
			elif authority.deposited_material_units >= authority.ConstructionSystem.BARRICADE_MATERIAL_REQUIRED:
				pad_state = "ready"
			entities.append(_entity(
				authority, "v_build_pad_1", "build_pad", authority.build_pad_position_mt,
				["interactable", "construct"],
				pad_state, authority.ConstructionSystem.BUILD_RANGE_MT,
			))
		return entities
	if authority.task_id == "neutral-encounter-v0":
		var relay_state := "defended"
		if authority.relay_activated:
			relay_state = "activated"
		elif authority.relay_activation_ticks > 0:
			relay_state = "activating_%s" % _progress_band(
				authority.relay_activation_ticks,
				authority.NeutralController.RELAY_ACTIVATION_TICKS,
			)
		elif authority.neutral_state in authority.NeutralController.RELAY_SAFE_STATES:
			relay_state = "available"
		return [
			_entity(
				authority, "v_neutral_1", "neutral", authority.neutral_position_mt,
				["hostile"], "%s_%s" % [
					authority.neutral_state, _health_band(
						authority.neutral_health,
						authority.NeutralController.NEUTRAL_MAX_HEALTH,
				),
				], authority.CombatSystem.PRIMARY_RANGE_MT,
			),
			_entity(
				authority, "v_relay_1", "relay", authority.relay_position_mt,
				["interactable", "activate"],
				relay_state, authority.NeutralController.RELAY_RADIUS_MT,
			),
		]
	return []


static func _progress_band(progress: int, required: int) -> String:
	assert(required > 0 and progress > 0)
	if progress * 3 < required:
		return "started"
	if progress * 3 < required * 2:
		return "mid"
	return "near_complete"


static func _health_band(health: int, maximum: int) -> String:
	if health <= 0:
		return "defeated"
	if health * 3 <= maximum:
		return "critical"
	if health * 3 <= maximum * 2:
		return "damaged"
	return "healthy"


static func _entity(
	authority: Object,
	id: String,
	kind: String,
	position_mt: Vector2i,
	affordances: Array,
	state: String,
	touching_radius_mt: int,
) -> Dictionary:
	var offset: Vector2i = position_mt - authority.operator_position_mt
	return {
		"id": id,
		"kind": kind,
		"bearing": Visibility.relative_bearing(offset, authority.operator_heading),
		"distance": Visibility.distance_band(offset, touching_radius_mt),
		"affordances": affordances,
		"state": state,
	}


static func _goal(task_id: String) -> String:
	match task_id:
		"interaction-v0":
			return "Collect one marked resource and deposit it at the home relay."
		"construction-v0":
			return "Gather material and construct one barricade on the marked pad."
		"neutral-encounter-v0":
			return "Activate the relay defended by a deterministic neutral."
	return "Reach and hold the visible beacon."
