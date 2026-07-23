class_name EmbodimentAuthorityState
extends RefCounted

## State lifecycle and serializable authority snapshot. Values are JSON-compatible integers,
## strings, booleans, arrays, dictionaries, or null; Vector2i is converted at the boundary.

static func reset(authority: Object) -> void:
	authority.tick = 0
	authority.observation_seq = 0
	authority.event_seq = 0
	authority.operator_position_mt = Vector2i(0, 7000)
	authority.operator_heading = 0
	authority.look_accumulator = 0
	authority.beacon_position_mt = Vector2i(0, -7000)
	authority.beacon_hold_ticks = 0
	authority.contact = "clear"
	authority.memory = ""
	authority.terminal = {"ended": false, "outcome": "running", "reason": "running"}
	authority.previous_receipt = null
	authority.recent_events.clear()
	if authority.task_id == "neutral-encounter-v0":
		authority.neutral_home_position_mt = Vector2i(0, -2000)
		authority.relay_position_mt = authority.neutral_home_position_mt
		authority.CombatSystem.reset(authority)
		authority.NeutralController.reset(authority)
	if authority.task_id in ["interaction-v0", "construction-v0"]:
		authority.InteractionSystem.reset(authority)
	if authority.task_id == "construction-v0":
		authority.ConstructionSystem.reset(authority)


static func checkpoint(authority: Object) -> Dictionary:
	var value := {
		"beacon_hold_ticks": authority.beacon_hold_ticks,
		"beacon_position_mt": [authority.beacon_position_mt.x, authority.beacon_position_mt.y],
		"contact": authority.contact,
		"episode_id": authority.episode_id,
		"event_seq": authority.event_seq,
		"look_accumulator": authority.look_accumulator,
		"maximum_episode_ticks": authority.maximum_episode_ticks,
		"mode": authority.mode,
		"observation_seq": authority.observation_seq,
		"observation_profile": authority.observation_profile,
		"operator_heading": authority.operator_heading,
		"operator_position_mt": [authority.operator_position_mt.x, authority.operator_position_mt.y],
		"participant_ids": authority.participant_ids.duplicate(),
		"task_id": authority.task_id,
		"terminal": authority.terminal.duplicate(true),
		"tick": authority.tick,
	}
	if authority.task_id != "orientation-v0":
		value.erase("beacon_hold_ticks")
		value.erase("beacon_position_mt")
	if authority.task_id in ["interaction-v0", "construction-v0"]:
		value.merge({
			"active_interaction": authority.active_interaction,
			"deposited_material_units": authority.deposited_material_units,
			"gather_progress_ticks": authority.gather_progress_ticks,
			"inventory_material_units": authority.inventory_material_units,
			"relay_position_mt": [authority.relay_position_mt.x, authority.relay_position_mt.y],
			"resource_position_mt": [authority.resource_position_mt.x, authority.resource_position_mt.y],
			"resource_units_remaining": authority.resource_units_remaining,
		})
	if authority.task_id == "construction-v0":
		value.merge({
			"barricade_complete": authority.barricade_complete,
			"barricade_progress_ticks": authority.barricade_progress_ticks,
			"build_pad_position_mt": [
				authority.build_pad_position_mt.x, authority.build_pad_position_mt.y,
			],
			"construction_active": authority.construction_active,
		})
	if authority.task_id == "neutral-encounter-v0":
		value.merge({
			"dash_cooldown_ticks": authority.dash_cooldown_ticks,
			"neutral_attack_cooldown_ticks": authority.neutral_attack_cooldown_ticks,
			"neutral_health": authority.neutral_health,
			"neutral_home_position_mt": [
				authority.neutral_home_position_mt.x, authority.neutral_home_position_mt.y,
			],
			"neutral_position_mt": [
				authority.neutral_position_mt.x, authority.neutral_position_mt.y,
			],
			"neutral_state": authority.neutral_state,
			"neutral_state_ticks": authority.neutral_state_ticks,
			"operator_energy": authority.operator_energy,
			"operator_guarding": authority.operator_guarding,
			"operator_health": authority.operator_health,
			"operator_knocked_out": authority.operator_knocked_out,
			"primary_cooldown_ticks": authority.primary_cooldown_ticks,
			"relay_activated": authority.relay_activated,
			"relay_activation_ticks": authority.relay_activation_ticks,
			"relay_position_mt": [authority.relay_position_mt.x, authority.relay_position_mt.y],
		})
	return value
