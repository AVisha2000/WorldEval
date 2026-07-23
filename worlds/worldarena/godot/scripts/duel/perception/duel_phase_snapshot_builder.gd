class_name DuelPhaseSnapshotBuilder
extends RefCounted

## Deterministic adapter between the authoritative match authorities and the
## deliberately closed DuelPerceptionRuntime phase-12 input.
##
## The returned phase_snapshot and protected_snapshot_hash are authority-only.
## They contain internal entity references required for observer-specific alias
## projection and MUST never be sent to a controller/provider.  The only legal
## provider output is DuelPerceptionRuntime.phase_12(...)["observations"].

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const ObservationContract := preload("res://scripts/duel/observations/duel_observation_contract.gd")
const PerceptionContract := preload("res://scripts/duel/perception/duel_perception_contract.gd")
const OrderRecord := preload("res://scripts/duel/simulation/duel_order.gd")
const AuthoritativeVisibility := preload(
	"res://scripts/duel/knowledge/duel_authoritative_visibility.gd"
)

const CONTEXT_REQUIRED: Array[String] = [
	"controller_registry",
	"day_phase",
	"neutral_registry",
	"seat_runtime",
	"world_event_seq_after",
]
const CONTROLLER_REQUIRED: Array[String] = ["entity_bindings", "state"]
const CONTROLLER_STATE_FIELDS: Array[String] = [
	"autocast_by_actor",
	"pending_append_order_ids",
	"rally_by_producer",
	"squads",
	"tactics_by_actor",
	"transport_manifests",
]
const NEUTRAL_REQUIRED: Array[String] = ["buildings", "events", "ground_items"]
const SEAT_REQUIRED: Array[String] = [
	"decision", "last_action_receipt", "observation_seq", "seat", "working_memory",
]
const SEAT_OPTIONAL: Array[String] = ["include_brief", "maximum_observation_bytes"]
const NEUTRAL_BUILDING_REQUIRED: Array[String] = [
	"building_id", "building_type", "entity_internal_id", "offers", "owner_seat",
	"position_mt", "region_id",
]
const NEUTRAL_OFFER_REQUIRED: Array[String] = [
	"activated", "cost_gold", "cost_lumber", "current_stock", "initial_tick", "kind",
	"maximum_stock", "next_restock_tick", "offer_id", "requires_service_target",
	"restock_ticks_per_charge",
]
const NEUTRAL_ITEM_REQUIRED: Array[String] = [
	"despawn_tick", "entity_internal_id", "item_type_id", "position_mt",
]
const NEUTRAL_EVENT_REQUIRED: Array[String] = [
	"audience_mask", "event_kind", "event_seq", "owner_seat", "payload", "phase",
	"source_internal_id", "target_internal_id", "tick", "visibility_rule",
]
const CONTROLLER_TACTIC_FIELDS: Array[String] = [
	"focus_tag", "formation", "retreat_hp_threshold_bp", "retreat_target", "stance",
	"subject",
]
const PROTECTED_CONTEXT_KEY_FRAGMENTS: Array[String] = [
	"alias_salt", "checkpoint", "commitment", "hidden_state", "model_identity",
	"omniscient", "opponent_economy", "opponent_inventory", "opponent_queue",
	"opponent_resource", "opponent_upgrade", "provider_identity", "secret", "state_hash",
	"tie_key", "world_hash",
]
const PRIVATE_EVENT_KINDS: Array[String] = [
	"construction_cancelled", "construction_completed", "construction_started",
	"deposit_failed", "hero_ability_learned", "hero_revival_started", "item_picked_up",
	"item_sold", "item_transferred", "item_used", "production_completed",
	"queue_cancelled", "resource_deposited", "tier_completed", "upgrade_completed",
]
const EVENT_PUBLIC_PAYLOAD_KEYS: Array[String] = [
	"ability_id", "amount", "batch_id", "code", "command_id", "compiled_order_id",
	"damage", "day_phase", "details", "healing", "item_id", "level", "offer_id",
	"position_mt", "progress_bp", "queue_entry_id", "region_id", "resource", "site_id",
	"status_id", "terminal_reason", "tier", "type_id", "upgrade_id", "winner", "xp",
]
const ORDER_STATE_NAMES: Dictionary = {
	OrderRecord.Status.QUEUED: "queued",
	OrderRecord.Status.ACTIVE: "active",
	OrderRecord.Status.COMPLETED: "completed",
	OrderRecord.Status.CANCELLED: "failed",
}


static func empty_controller_registry() -> Dictionary:
	return {
		"entity_bindings": {},
		"state": {
			"autocast_by_actor": {},
			"pending_append_order_ids": [],
			"rally_by_producer": {},
			"squads": {},
			"tactics_by_actor": {},
			"transport_manifests": {},
		},
	}


static func empty_neutral_registry() -> Dictionary:
	return {"buildings": [], "events": [], "ground_items": []}


## Builds the narrow neutral-shop registry from the shared neutral authority.
## `building_entity_bindings` is match-lifetime protected coordinator state:
## each key is an authoritative building_id and each value is its stable positive
## backing entity ID. Official map shops are not simulation entities, so callers
## must reserve IDs that will never collide with subsequently spawned entities.
## Ground items and neutral events are intentionally not copied here: the shared
## tick ledger already integrates them into HeroState and DuelState.events.
static func neutral_registry_from_authority(
	simulation: Variant, building_entity_bindings: Dictionary
) -> Dictionary:
	var result := empty_neutral_registry()
	if simulation == null or simulation.state == null \
		or not bool(simulation.state.neutrals.enabled):
		return result
	var building_ids: Array = simulation.state.neutrals.buildings.keys()
	building_ids.sort()
	for building_id_variant: Variant in building_ids:
		var building_id := str(building_id_variant)
		var source: Dictionary = simulation.state.neutrals.buildings[building_id]
		var offers: Array = []
		var offer_ids: Array = source.get("offers", {}).keys()
		offer_ids.sort()
		for offer_id_variant: Variant in offer_ids:
			var offer: Dictionary = source["offers"][offer_id_variant]
			offers.append(_neutral_offer_registry_row(offer))
		result["buildings"].append({
			"building_id": building_id,
			"building_type": str(source.get("building_type", "")),
			"entity_internal_id": int(building_entity_bindings.get(building_id, 0)),
			"offers": offers,
			"owner_seat": int(source.get("owner_seat", -1)),
			"position_mt": source.get("position_mt", []).duplicate(),
			"region_id": str(source.get("region_id", "")),
		})
	return result


func build(simulation: Variant, context_input: Dictionary) -> Dictionary:
	var errors := PackedStringArray()
	if simulation == null or not bool(simulation.get("is_ready")):
		errors.append("phase snapshot builder requires a ready DuelSimulation")
		return _failure(errors)
	for message: String in simulation.validate():
		errors.append("simulation: " + message)
	_validate_context(simulation, context_input, errors)
	if not errors.is_empty():
		return _failure(errors)
	var context := context_input.duplicate(true)
	var controller := _controller_index(context["controller_registry"])
	var grid_snapshot := _grid_snapshot(simulation)
	var entity_snapshots := _entity_snapshots(simulation, controller, grid_snapshot, errors)
	var seat_snapshots := _seat_snapshots(simulation, context, controller, errors)
	var candidate_events := _candidate_events(simulation, context, errors)
	var terminal: Variant = _terminal_snapshot(simulation, errors)
	if not errors.is_empty():
		return _failure(errors)
	var maximum_match_ticks := int(simulation.terminal.maximum_match_ticks)
	if maximum_match_ticks <= 0 or maximum_match_ticks > ObservationContract.MAX_MATCH_TICKS:
		errors.append("terminal authority has an invalid maximum_match_ticks")
		return _failure(errors)
	var phase_snapshot := {
		"candidate_events": candidate_events,
		"day_phase": str(context["day_phase"]),
		"entity_snapshots": entity_snapshots,
		"grid_snapshot": grid_snapshot,
		"no_progress_ticks": int(simulation.state.no_progress_ticks),
		"remaining_match_ticks": 0 if terminal != null else maxi(
			0, maximum_match_ticks - int(simulation.state.tick)
		),
		"seat_snapshots": seat_snapshots,
		"terminal": terminal,
		"tick": int(simulation.state.tick),
	}
	errors.append_array(PerceptionContract.validate_phase_snapshot(phase_snapshot))
	if not errors.is_empty():
		return _failure(errors)
	var canonical_json := Codec.canonical_json(phase_snapshot)
	for forbidden_text: String in [
		"alias_salt", "provider_identity", "model_identity", "tie_key", "commitment",
		"world_hash", "state_hash", "checkpoint",
	]:
		if forbidden_text in canonical_json:
			errors.append("protected phase snapshot contains forbidden authority text: %s" % forbidden_text)
	if not errors.is_empty():
		return _failure(errors)
	return {
		"errors": errors,
		"ok": true,
		"phase_snapshot": phase_snapshot.duplicate(true),
		"protected_canonical_json": canonical_json,
		"protected_snapshot_hash": Codec.sha256_canonical(phase_snapshot),
	}


func _validate_context(
	simulation: Variant, value: Variant, errors: PackedStringArray
) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("phase snapshot context must be an object")
		return
	var context: Dictionary = value
	_exact_fields(context, CONTEXT_REQUIRED, [], "$.context", errors)
	for message: String in Codec.validate_canonical_value(context, "$.context"):
		errors.append(message)
	if _contains_protected_context_key(context):
		errors.append("phase snapshot context contains a protected authority/provider key")
	if str(context.get("day_phase", "")) not in ObservationContract.DAY_PHASES:
		errors.append("$.context.day_phase is invalid")
	_validate_neutral_authority(simulation, errors)
	if bool(simulation.state.neutrals.enabled):
		var authoritative_phase: Dictionary = simulation.neutrals.day_phase(
			int(simulation.state.tick)
		)
		var expected_day_phase := (
			"forced_night" if bool(authoritative_phase.get("forced", false))
			else str(authoritative_phase.get("phase", ""))
		)
		if str(context.get("day_phase", "")) != expected_day_phase:
			errors.append("$.context.day_phase disagrees with neutral day/night authority")
	if typeof(context.get("world_event_seq_after")) != TYPE_INT \
		or int(context.get("world_event_seq_after", -1)) < 0:
		errors.append("$.context.world_event_seq_after must be a non-negative integer")
	_validate_seat_runtime(simulation, context.get("seat_runtime"), errors)
	_validate_controller_registry(simulation, context.get("controller_registry"), errors)
	_validate_neutral_registry(simulation, context.get("neutral_registry"), errors)


func _validate_seat_runtime(
	simulation: Variant, value: Variant, errors: PackedStringArray
) -> void:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != 2:
		errors.append("$.context.seat_runtime must contain exactly two rows")
		return
	var seen: Dictionary = {}
	var modes: Dictionary = {}
	for index: int in (value as Array).size():
		var path := "$.context.seat_runtime[%d]" % index
		if typeof(value[index]) != TYPE_DICTIONARY:
			errors.append(path + " must be an object")
			continue
		var row: Dictionary = value[index]
		_exact_fields(row, SEAT_REQUIRED, SEAT_OPTIONAL, path, errors)
		var seat := int(row.get("seat", -1))
		if typeof(row.get("seat")) != TYPE_INT or seat not in [0, 1] or seen.has(seat):
			errors.append(path + ".seat is invalid or duplicated")
		else:
			seen[seat] = true
		if typeof(row.get("observation_seq")) != TYPE_INT \
			or int(row.get("observation_seq", -1)) < 0:
			errors.append(path + ".observation_seq must be non-negative")
		if typeof(row.get("working_memory")) != TYPE_STRING:
			errors.append(path + ".working_memory must be a string")
		if typeof(row.get("decision")) == TYPE_DICTIONARY \
			and int((row["decision"] as Dictionary).get("observation_tick", -1)) \
			!= int(simulation.state.tick):
			errors.append(path + ".decision.observation_tick must equal simulation tick")
		if typeof(row.get("decision")) == TYPE_DICTIONARY:
			modes[str((row["decision"] as Dictionary).get("mode", ""))] = true
	if seen.size() != 2:
		errors.append("$.context.seat_runtime must contain seats 0 and 1")
	if modes.size() != 1:
		errors.append("$.context.seat_runtime must use one pregame decision mode for both seats")


func _validate_controller_registry(
	simulation: Variant, value: Variant, errors: PackedStringArray
) -> void:
	var path := "$.context.controller_registry"
	if typeof(value) != TYPE_DICTIONARY:
		errors.append(path + " must be an object")
		return
	var registry: Dictionary = value
	_exact_fields(registry, CONTROLLER_REQUIRED, [], path, errors)
	if typeof(registry.get("entity_bindings")) != TYPE_DICTIONARY:
		errors.append(path + ".entity_bindings must be an object")
		return
	if typeof(registry.get("state")) != TYPE_DICTIONARY:
		errors.append(path + ".state must be an object")
		return
	var state: Dictionary = registry["state"]
	_exact_fields(state, CONTROLLER_STATE_FIELDS, [], path + ".state", errors)
	var reverse: Dictionary = {}
	var bindings: Dictionary = registry["entity_bindings"]
	for alias_variant: Variant in bindings.keys():
		var alias := str(alias_variant)
		var internal_id := int(bindings[alias_variant])
		if typeof(alias_variant) != TYPE_STRING or not ObservationContract.is_entity_id(alias):
			errors.append(path + ".entity_bindings has an invalid public alias")
		elif typeof(bindings[alias_variant]) != TYPE_INT or internal_id <= 0 \
			or not simulation.state.entities.has(internal_id):
			errors.append(path + ".entity_bindings[%s] is not a live authority reference" % alias)
		elif reverse.has(internal_id):
			errors.append(path + ".entity_bindings maps two aliases to one internal entity")
		else:
			reverse[internal_id] = alias
	for field: String in [
		"autocast_by_actor", "rally_by_producer", "squads", "tactics_by_actor",
		"transport_manifests",
	]:
		if typeof(state.get(field)) != TYPE_DICTIONARY:
			errors.append(path + ".state.%s must be an object" % field)
	if typeof(state.get("pending_append_order_ids")) != TYPE_ARRAY:
		errors.append(path + ".state.pending_append_order_ids must be an array")
	if not errors.is_empty():
		return
	for actor_field: String in [
		"autocast_by_actor", "rally_by_producer", "tactics_by_actor", "transport_manifests",
	]:
		for alias_variant: Variant in (state[actor_field] as Dictionary).keys():
			if not bindings.has(str(alias_variant)):
				errors.append("%s.state.%s references an unbound entity alias" % [path, actor_field])
	for alias_variant: Variant in (state["autocast_by_actor"] as Dictionary).keys():
		var settings: Variant = state["autocast_by_actor"][alias_variant]
		if typeof(settings) != TYPE_DICTIONARY:
			errors.append(path + ".state.autocast_by_actor entries must be objects")
			continue
		for ability_variant: Variant in (settings as Dictionary).keys():
			if typeof(ability_variant) != TYPE_STRING \
				or not ObservationContract.is_public_id(str(ability_variant)) \
				or typeof(settings[ability_variant]) != TYPE_BOOL:
				errors.append(path + ".state.autocast_by_actor has an invalid ability toggle")
	for alias_variant: Variant in (state["tactics_by_actor"] as Dictionary).keys():
		_validate_only_fields(
			state["tactics_by_actor"][alias_variant], CONTROLLER_TACTIC_FIELDS,
			path + ".state.tactics_by_actor", errors
		)
	for squad_variant: Variant in (state["squads"] as Dictionary).keys():
		var squad_id := str(squad_variant)
		var squad_value: Variant = state["squads"][squad_variant]
		if not ObservationContract.is_id(squad_id) or typeof(squad_value) != TYPE_DICTIONARY:
			errors.append(path + ".state.squads has an invalid row")
			continue
		var squad: Dictionary = squad_value
		_exact_fields(squad, ["member_ids", "owner_seat", "tactics"], [], path + ".state.squads", errors)
		if typeof(squad.get("owner_seat")) != TYPE_INT or int(squad.get("owner_seat", -1)) not in [0, 1]:
			errors.append(path + ".state.squads owner_seat is invalid")
		if typeof(squad.get("member_ids")) != TYPE_ARRAY or (squad.get("member_ids", []) as Array).is_empty():
			errors.append(path + ".state.squads member_ids must be a non-empty array")
		else:
			for alias: Variant in squad["member_ids"]:
				if typeof(alias) != TYPE_STRING or not bindings.has(str(alias)):
					errors.append(path + ".state.squads references an unbound entity alias")
		_validate_only_fields(
			squad.get("tactics", {}), CONTROLLER_TACTIC_FIELDS,
			path + ".state.squads.tactics", errors
		)
	for alias_variant: Variant in (state["transport_manifests"] as Dictionary).keys():
		var passengers: Variant = state["transport_manifests"][alias_variant]
		if typeof(passengers) != TYPE_ARRAY:
			errors.append(path + ".state.transport_manifests entries must be arrays")
			continue
		for passenger: Variant in passengers:
			if typeof(passenger) != TYPE_STRING or not bindings.has(str(passenger)):
				errors.append(path + ".state.transport_manifests references an unbound passenger")
	for row_variant: Variant in state["pending_append_order_ids"]:
		if typeof(row_variant) != TYPE_DICTIONARY:
			errors.append(path + ".state.pending_append_order_ids entries must be objects")
			continue
		_exact_fields(
			row_variant, ["pending_count", "public_id"], [],
			path + ".state.pending_append_order_ids", errors
		)


func _validate_neutral_registry(
	simulation: Variant, value: Variant, errors: PackedStringArray
) -> void:
	var path := "$.context.neutral_registry"
	if typeof(value) != TYPE_DICTIONARY:
		errors.append(path + " must be an object")
		return
	var registry: Dictionary = value
	_exact_fields(registry, NEUTRAL_REQUIRED, [], path, errors)
	var arrays_are_valid := true
	for field: String in NEUTRAL_REQUIRED:
		if typeof(registry.get(field)) != TYPE_ARRAY:
			errors.append(path + ".%s must be an array" % field)
			arrays_are_valid = false
	if not arrays_are_valid:
		return
	var protected_ids: Dictionary = {}
	var building_ids: Dictionary = {}
	for index: int in (registry["buildings"] as Array).size():
		var row_path := "%s.buildings[%d]" % [path, index]
		if typeof(registry["buildings"][index]) != TYPE_DICTIONARY:
			errors.append(row_path + " must be an object")
			continue
		var building: Dictionary = registry["buildings"][index]
		_exact_fields(building, NEUTRAL_BUILDING_REQUIRED, [], row_path, errors)
		var building_id := str(building.get("building_id", ""))
		if not ObservationContract.is_public_id(building_id) or building_ids.has(building_id):
			errors.append(row_path + ".building_id is invalid or duplicated")
		else:
			building_ids[building_id] = true
		_validate_registry_internal_id(building, row_path, protected_ids, errors)
		if typeof(building.get("owner_seat")) != TYPE_INT \
			or int(building.get("owner_seat", -2)) not in [-1, 0, 1]:
			errors.append(row_path + ".owner_seat must be -1, 0, or 1")
		_validate_point(building.get("position_mt"), row_path + ".position_mt", errors)
		if not ObservationContract.is_public_id(building.get("region_id")) \
			or not ObservationContract.is_public_id(building.get("building_type")):
			errors.append(row_path + " has an invalid public region/building type")
		if typeof(building.get("offers")) != TYPE_ARRAY:
			errors.append(row_path + ".offers must be an array")
		else:
			var offer_ids: Dictionary = {}
			for offer_index: int in (building["offers"] as Array).size():
				var offer_path := "%s.offers[%d]" % [row_path, offer_index]
				if typeof(building["offers"][offer_index]) != TYPE_DICTIONARY:
					errors.append(offer_path + " must be an object")
					continue
				var offer: Dictionary = building["offers"][offer_index]
				_exact_fields(offer, NEUTRAL_OFFER_REQUIRED, [], offer_path, errors)
				var offer_id := str(offer.get("offer_id", ""))
				if not ObservationContract.is_public_id(offer_id) or offer_ids.has(offer_id):
					errors.append(offer_path + ".offer_id is invalid or duplicated")
				else:
					offer_ids[offer_id] = true
		if bool(simulation.state.neutrals.enabled):
			_validate_authoritative_neutral_building(
				simulation, building, row_path, errors
			)
		var backing_id := int(building.get("entity_internal_id", 0))
		if backing_id > 0 and simulation.state.entities.has(backing_id):
			var backing: Variant = simulation.state.entities[backing_id]
			if int(building.get("owner_seat", -1)) == -1:
				errors.append(row_path + ".entity_internal_id collides with a simulation entity")
			elif int(backing.owner_seat) != int(building.get("owner_seat", -1)) \
				or [int(backing.position_x_mt), int(backing.position_y_mt)] \
				!= building.get("position_mt", []):
				errors.append(row_path + " backing structure disagrees with neutral authority")
	if bool(simulation.state.neutrals.enabled):
		for building_id: String in simulation.state.neutrals.sorted_building_ids():
			if not building_ids.has(building_id):
				errors.append(path + ".buildings is missing authoritative building " + building_id)
	for index: int in (registry["ground_items"] as Array).size():
		var row_path := "%s.ground_items[%d]" % [path, index]
		if typeof(registry["ground_items"][index]) != TYPE_DICTIONARY:
			errors.append(row_path + " must be an object")
			continue
		var item: Dictionary = registry["ground_items"][index]
		_exact_fields(item, NEUTRAL_ITEM_REQUIRED, [], row_path, errors)
		_validate_registry_internal_id(item, row_path, protected_ids, errors)
		_validate_point(item.get("position_mt"), row_path + ".position_mt", errors)
		if not ObservationContract.is_public_id(item.get("item_type_id")):
			errors.append(row_path + ".item_type_id is invalid")
		if bool(simulation.state.neutrals.enabled):
			errors.append(
				row_path + " is forbidden when shared neutral drops are integrated into HeroState"
			)
		if simulation.state.entities.has(int(item.get("entity_internal_id", 0))):
			errors.append(row_path + ".entity_internal_id collides with a simulation entity")
	for index: int in (registry["events"] as Array).size():
		var row_path := "%s.events[%d]" % [path, index]
		if typeof(registry["events"][index]) != TYPE_DICTIONARY:
			errors.append(row_path + " must be an object")
			continue
		var event: Dictionary = registry["events"][index]
		_exact_fields(event, NEUTRAL_EVENT_REQUIRED, [], row_path, errors)
		for field: String in [
			"audience_mask", "event_seq", "owner_seat", "phase", "source_internal_id",
			"target_internal_id", "tick",
		]:
			if typeof(event.get(field)) != TYPE_INT:
				errors.append(row_path + ".%s must be an integer" % field)
		if typeof(event.get("payload")) != TYPE_DICTIONARY:
			errors.append(row_path + ".payload must be an object")


func _validate_neutral_authority(
	simulation: Variant, errors: PackedStringArray
) -> void:
	var authority: Variant = simulation.state.neutrals
	if not bool(authority.enabled):
		return
	if simulation.neutrals == null or simulation.neutrals.state != authority:
		errors.append("shared neutral authority is detached from DuelState")
		return
	var world_tick := int(simulation.state.tick)
	var neutral_tick := int(authority.tick)
	## A completed TickLedger step increments DuelState after phase 14, while the
	## neutral authority retains the just-resolved tick. Direct phase-2 service
	## updates may instead leave the values equal. No older/future state is legal.
	if neutral_tick > world_tick or world_tick - neutral_tick > 1:
		errors.append("shared neutral authority tick is stale or ahead of DuelState")
	var bound_ids: Dictionary = {}
	for camp_id: String in authority.sorted_camp_ids():
		var camp: Dictionary = authority.camps[camp_id]
		var member_ids: Array = camp.get("members", {}).keys()
		member_ids.sort()
		for member_id_variant: Variant in member_ids:
			var member_id := str(member_id_variant)
			var member: Dictionary = camp["members"][member_id]
			var entity_id := int(member.get("internal_id", 0))
			var label := "%s/%s" % [camp_id, member_id]
			if entity_id <= 0 or bound_ids.has(entity_id):
				errors.append("neutral camp member has a missing/duplicate entity binding: " + label)
				continue
			bound_ids[entity_id] = label
			if not simulation.state.entities.has(entity_id):
				errors.append("neutral camp member references a missing entity: " + label)
				continue
			var entity: Variant = simulation.state.entities[entity_id]
			if int(entity.owner_seat) != -1 or str(entity.entity_kind) != "neutral_creep" \
				or str(entity.catalog_id) != str(member.get("neutral_id", "")):
				errors.append("neutral camp member identity disagrees with its entity: " + label)
			if not simulation.state.combat.actors.has(entity_id) \
				or not simulation.state.movement.actors.has(entity_id):
				errors.append("neutral camp member is missing combat/movement registration: " + label)
			## At tick zero relocation is complete and no phase can have advanced the
			## entity beyond its authoritative spawn. Later ticks intentionally allow
			## position/HP skew until the next phase-3 synchronization.
			if int(simulation.state.tick) == 0 and (
				[int(entity.position_x_mt), int(entity.position_y_mt)]
				!= member.get("spawn_position_mt", [])
				or int(entity.hp) != int(member.get("hp", -1))
				or bool(entity.alive) != bool(member.get("alive", false))
			):
				errors.append("neutral camp member spawn state disagrees with its entity: " + label)
	for entity_id: int in simulation.state.sorted_entity_ids():
		var entity: Variant = simulation.state.entities[entity_id]
		if str(entity.entity_kind) == "neutral_creep" and not bound_ids.has(entity_id):
			errors.append("unbound neutral creep entity: %d" % entity_id)


func _validate_authoritative_neutral_building(
	simulation: Variant,
	building: Dictionary,
	path: String,
	errors: PackedStringArray
) -> void:
	var building_id := str(building.get("building_id", ""))
	if not simulation.state.neutrals.buildings.has(building_id):
		errors.append(path + " does not resolve to shared neutral authority")
		return
	var source: Dictionary = simulation.state.neutrals.buildings[building_id]
	for field: String in [
		"building_id", "building_type", "owner_seat", "position_mt", "region_id",
	]:
		if building.get(field) != source.get(field):
			errors.append(path + ".%s disagrees with shared neutral authority" % field)
	var expected_offers: Array = []
	var offer_ids: Array = source.get("offers", {}).keys()
	offer_ids.sort()
	for offer_id_variant: Variant in offer_ids:
		expected_offers.append(_neutral_offer_registry_row(source["offers"][offer_id_variant]))
	var actual_offers: Array = building.get("offers", []).duplicate(true)
	actual_offers.sort_custom(_offer_less)
	if Codec.canonical_json(actual_offers) != Codec.canonical_json(expected_offers):
		errors.append(path + ".offers disagrees with shared neutral authority")


func _validate_registry_internal_id(
	row: Dictionary, path: String, seen: Dictionary, errors: PackedStringArray
) -> void:
	var value: Variant = row.get("entity_internal_id")
	if typeof(value) != TYPE_INT or int(value) <= 0:
		errors.append(path + ".entity_internal_id must be positive")
		return
	var internal_id := int(value)
	if seen.has(internal_id):
		errors.append(path + ".entity_internal_id collides with another authority entity")
	else:
		seen[internal_id] = path


func _controller_index(registry: Dictionary) -> Dictionary:
	var bindings: Dictionary = registry["entity_bindings"]
	var alias_by_internal: Dictionary = {}
	for alias_variant: Variant in bindings.keys():
		alias_by_internal[int(bindings[alias_variant])] = str(alias_variant)
	return {
		"alias_by_internal": alias_by_internal,
		"bindings": bindings.duplicate(),
		"state": (registry["state"] as Dictionary).duplicate(true),
	}


func _grid_snapshot(simulation: Variant) -> Dictionary:
	var source: Dictionary = simulation.grid.to_canonical_dict()
	return {
		"cell_size_mt": int(source["cell_size_mt"]),
		"elevations": (source["elevations"] as Array).duplicate(),
		"height": int(source["height"]),
		"los_block_heights": (source["los_block_heights"] as Array).duplicate(),
		"region_ids": (source["region_ids"] as Array).duplicate(),
		"terrain_ids": (source["terrain_ids"] as Array).duplicate(),
		"width": int(source["width"]),
	}


func _entity_snapshots(
	simulation: Variant,
	controller: Dictionary,
	grid_snapshot: Dictionary,
	errors: PackedStringArray
) -> Array:
	var result: Array = []
	for entity_id: int in simulation.state.sorted_entity_ids():
		var entity: Variant = simulation.state.entities[entity_id]
		var definition := _entity_definition(simulation, entity_id)
		var cells := _entity_cells(simulation, entity_id)
		var node_id := _position_node_id(
			[int(entity.position_x_mt), int(entity.position_y_mt)], grid_snapshot
		)
		if cells.is_empty() and node_id >= 0:
			cells = [node_id]
		var layer := _entity_layer(simulation, entity_id)
		var sight_day := int(definition.get(
			"sight_day_mt", entity.integer_attributes.get("sight_day_mt", 0)
		))
		var sight_night := int(definition.get(
			"sight_night_mt", entity.integer_attributes.get("sight_night_mt", 0)
		))
		var detection := int(definition.get(
			"detection_radius_mt", entity.integer_attributes.get("detection_radius_mt", 0)
		))
		if simulation.state.heroes.heroes.has(entity_id):
			var derived: Dictionary = simulation.state.heroes.heroes[entity_id]["derived"]
			sight_day += int(derived.get("sight_radius_mt", 0))
			sight_night += int(derived.get("sight_radius_mt", 0))
			detection += int(derived.get("detection_radius_mt", 0))
		var row := {
			"alive": bool(entity.alive),
			"catalog_id": _entity_type_id(entity),
			"detection_radius_mt": maxi(0, detection),
			"elevation": _grid_int_at(grid_snapshot["elevations"], node_id, 0),
			"facing_mdeg": int(entity.facing_mdeg),
			"hero_level": _hero_level(simulation, entity_id),
			"hp": int(entity.hp),
			"internal_id": entity_id,
			"is_air": layer == "air",
			"layer": layer,
			"mana": int(entity.mana),
			"mana_hidden": false,
			"max_hp": maxi(1, int(entity.max_hp)),
			"observable_activity": _observable_activity(simulation, entity_id, controller),
			"occupied_cell_ids": cells,
			"owner_seat": int(entity.owner_seat),
			"position_mt": [int(entity.position_x_mt), int(entity.position_y_mt)],
			"region_id": _entity_region(grid_snapshot, node_id),
			"sight_day_mt": maxi(0, sight_day),
			"sight_night_mt": maxi(0, sight_night),
			"tags": _sorted_unique_strings(entity.tags),
			"type_id": _entity_type_id(entity),
			## Visible-status source aliases are observer-specific and therefore
			## cannot exist in the shared frozen snapshot. Owned statuses are
			## projected safely below; visible enemy status detail stays omitted.
			"visible_statuses": [],
		}
		if int(entity.owner_seat) in [0, 1]:
			row["owned_observation"] = _owned_observation(
				simulation, entity_id, controller, definition, errors
			)
		result.append(row)
	result.sort_custom(_internal_id_less)
	return AuthoritativeVisibility.augment_entity_snapshots(simulation, result)


func _owned_observation(
	simulation: Variant,
	entity_id: int,
	controller: Dictionary,
	definition: Dictionary,
	errors: PackedStringArray
) -> Dictionary:
	var state: Variant = simulation.state
	var entity: Variant = state.entities[entity_id]
	var combat_actor: Dictionary = state.combat.actors.get(entity_id, {})
	var alias := str(controller["alias_by_internal"].get(entity_id, entity.public_id))
	var tactics: Dictionary = controller["state"]["tactics_by_actor"].get(alias, {})
	var statuses := _owned_statuses(simulation, entity_id)
	var result := {
		"abilities": _owned_abilities(simulation, entity_id, alias, controller, definition),
		"armor_centi": int(combat_actor.get("armor_centi", 0)),
		"armor_class": str(combat_actor.get(
			"armor_class", "fortified" if entity.entity_kind == "structure" else "light"
		)),
		"attack_cooldown_remaining_ticks": maxi(
			0, int(combat_actor.get("cooldown_until_tick", 0)) - int(state.tick)
		),
		"cargo": _entity_cargo(simulation, entity_id),
		"current_order": _current_order(simulation, entity_id),
		"formation_id": str(tactics.get("formation", "none")),
		"hp": int(entity.hp),
		"mana": int(entity.mana),
		"max_hp": maxi(1, int(entity.max_hp)),
		"max_mana": maxi(0, int(entity.max_mana)),
		"movement_state": _movement_state(simulation, entity_id, controller),
		"queued_orders": _queued_orders(simulation, entity_id),
		"selected_by_squad_ids": _squad_ids_for_entity(controller, entity_id),
		"stance": str(tactics.get("stance", "defensive")),
		"statuses": statuses,
	}
	if state.heroes.heroes.has(entity_id):
		var hero: Dictionary = state.heroes.heroes[entity_id]
		var revival: Variant = null
		if state.heroes.revivals.has(entity_id):
			var entry: Dictionary = state.heroes.revivals[entity_id]
			var total := maxi(1, int(entry["total_ticks"]))
			@warning_ignore("integer_division")
			var progress := clampi(
				((total - int(entry["remaining_ticks"])) * 10_000) / total, 0, 10_000
			)
			revival = {
				"method": str(entry["method"]),
				"progress_bp": progress,
				"remaining_ticks": int(entry["remaining_ticks"]),
				"reviver_internal_id": int(entry["requested_reviver_id"]),
			}
		var inventory: Array = []
		for instance_variant: Variant in hero["inventory"]:
			var instance: Dictionary = instance_variant
			inventory.append({
				"charges": int(instance["charges"]),
				"cooldown_remaining_ticks": maxi(
					0, int(instance["cooldown_until_tick"]) - int(state.tick)
				),
				"item_instance_id": str(instance["item_instance_id"]),
				"item_type_id": str(instance["item_type_id"]),
				"slot": int(instance["slot"]),
			})
		inventory.sort_custom(_slot_less)
		result["attributes"] = hero["attributes_centi"].duplicate(true)
		result["death_state"] = (
			"reviving" if state.heroes.revivals.has(entity_id)
			else ("alive" if bool(entity.alive) else "dead")
		)
		result["hero_level"] = int(hero["level"])
		result["inventory"] = inventory
		result["revival_state"] = revival
		result["skill_points"] = int(hero["skill_points"])
		result["xp"] = int(hero["xp"])
	elif entity.entity_kind == "structure" or "structure" in entity.tags:
		var economy_record: Dictionary = state.economy.entity_records.get(entity_id, {})
		var construction: Dictionary = state.economy.construction_sites.get(entity_id, {})
		var progress := int(entity.integer_attributes.get("construction_progress_bp", 10_000))
		result["builder_internal_ids"] = _sorted_ints(construction.get("worker_ids", []))
		result["class"] = str(economy_record.get("semantic_role", entity.catalog_id))
		result["construction_progress_bp"] = progress
		result["movement_state"] = "rooted"
		result["pause_reason"] = null
		result["producer_queue"] = _producer_queue(simulation, entity_id, errors)
		result["rally_target"] = _rally_target(
			controller["state"]["rally_by_producer"].get(alias, null)
		)
	return result


func _seat_snapshots(
	simulation: Variant,
	context: Dictionary,
	controller: Dictionary,
	errors: PackedStringArray
) -> Array:
	var rows: Array = []
	var runtime_by_seat: Dictionary = {}
	for runtime_variant: Variant in context["seat_runtime"]:
		var runtime: Dictionary = runtime_variant
		runtime_by_seat[int(runtime["seat"])] = runtime
	for seat: int in [0, 1]:
		var runtime: Dictionary = runtime_by_seat[seat]
		var visibility_overrides := AuthoritativeVisibility.observer_overrides(
			simulation, seat
		)
		var row := {
			"decision": (runtime["decision"] as Dictionary).duplicate(true),
			"economy": _seat_economy(simulation, seat),
			"food": _seat_food(simulation, seat),
			"last_action_receipt": _deep_copy(runtime["last_action_receipt"]),
			"local_context_candidates": [],
			"observation_seq": int(runtime["observation_seq"]),
			"own_technology": _seat_technology(simulation, seat, errors),
			"seat": seat,
			"squad_candidates": _seat_squads(simulation, seat, controller),
			"structure_type_ids": _structure_type_ids(simulation, seat),
			"upkeep": _seat_upkeep(simulation, seat),
			"visible_item_candidates": _visible_item_candidates(simulation, context),
			"visible_shop_candidates": _visible_shop_candidates(context),
			"working_memory": str(runtime["working_memory"]),
		}
		for optional: String in SEAT_OPTIONAL:
			if runtime.has(optional):
				row[optional] = runtime[optional]
		if not (visibility_overrides["revealed_entity_internal_ids"] as Array).is_empty():
			row["revealed_entity_internal_ids"] = visibility_overrides[
				"revealed_entity_internal_ids"
			]
		if not (visibility_overrides["temporary_vision_sources"] as Array).is_empty():
			row["temporary_vision_sources"] = visibility_overrides[
				"temporary_vision_sources"
			]
		rows.append(row)
	return rows


func _seat_economy(simulation: Variant, seat: int) -> Dictionary:
	var state: Variant = simulation.state
	var player: Dictionary = state.economy.players[seat]
	var workers := {"building": 0, "gold": 0, "idle": 0, "lumber": 0, "repairing": 0, "total": 0}
	var cargo := {"gold": 0, "lumber": 0}
	var building_workers: Dictionary = {}
	var repair_workers: Dictionary = {}
	for building_id: int in state.economy.sorted_construction_ids():
		for worker_variant: Variant in state.economy.construction_sites[building_id]["worker_ids"]:
			building_workers[int(worker_variant)] = true
	for building_id: int in state.economy.sorted_repair_building_ids():
		for worker_variant: Variant in state.economy.repair_ledgers[building_id]["worker_ids"]:
			repair_workers[int(worker_variant)] = true
	for entity_id: int in state.economy.sorted_entity_record_ids():
		var record: Dictionary = state.economy.entity_records[entity_id]
		if int(record["owner_seat"]) != seat or str(record["semantic_role"]) != "worker" \
			and "worker" not in state.entities[entity_id].tags \
			and "lumber_worker" not in state.entities[entity_id].tags:
			continue
		workers["total"] += 1
		if repair_workers.has(entity_id):
			workers["repairing"] += 1
		elif building_workers.has(entity_id):
			workers["building"] += 1
		elif state.economy.worker_tasks.has(entity_id):
			var task: Dictionary = state.economy.worker_tasks[entity_id]
			var resource := str(task["resource_type"])
			workers[resource] += 1
			cargo[resource] += int(task["cargo"])
		else:
			workers["idle"] += 1
	var income := _income_last_600_ticks(simulation, seat)
	var reserved := _reserved_resources(simulation, seat)
	return {
		"cargo_summary": cargo,
		"gold": int(player["gold"]),
		"gold_income_last_600_ticks": int(income["gold"]),
		"lumber": int(player["lumber"]),
		"lumber_income_last_600_ticks": int(income["lumber"]),
		"reserved_gold": int(reserved["gold"]),
		"reserved_lumber": int(reserved["lumber"]),
		"worker_summary": workers,
	}


func _income_last_600_ticks(simulation: Variant, seat: int) -> Dictionary:
	var result := {"gold": 0, "lumber": 0}
	var minimum_tick := maxi(0, int(simulation.state.tick) - 599)
	for event_variant: Variant in simulation.state.events:
		var event: Variant = event_variant
		if str(event.event_kind) != "resource_deposited" or int(event.tick) < minimum_tick:
			continue
		var source_id := int(event.source_internal_id)
		if not simulation.state.entities.has(source_id) \
			or int(simulation.state.entities[source_id].owner_seat) != seat:
			continue
		var resource := str(event.payload.get("resource", ""))
		if resource in ["gold", "lumber"]:
			result[resource] += int(event.payload.get("delivered", event.payload.get("amount", 0)))
	return result


func _reserved_resources(simulation: Variant, seat: int) -> Dictionary:
	var result := {"gold": 0, "lumber": 0}
	var economy: Variant = simulation.state.economy
	for building_id: int in economy.sorted_construction_ids():
		var site: Dictionary = economy.construction_sites[building_id]
		if int(site["owner_seat"]) == seat:
			result["gold"] += int(site["cost_gold"])
			result["lumber"] += int(site["cost_lumber"])
	for producer_id: int in economy.sorted_producer_ids():
		for entry_variant: Variant in economy.production_queues[producer_id]:
			var entry: Dictionary = entry_variant
			if int(entry["owner_seat"]) == seat:
				result["gold"] += int(entry["cost_gold"])
				result["lumber"] += int(entry["cost_lumber"])
	if economy.tier_queues.has(seat):
		result["gold"] += int(economy.tier_queues[seat]["cost_gold"])
		result["lumber"] += int(economy.tier_queues[seat]["cost_lumber"])
	for hero_id: int in _sorted_int_keys(simulation.state.heroes.revivals):
		var revival: Dictionary = simulation.state.heroes.revivals[hero_id]
		if int(revival["owner_seat"]) == seat:
			result["gold"] += int(revival["cost_gold"])
	return result


func _seat_food(simulation: Variant, seat: int) -> Dictionary:
	var player: Dictionary = simulation.state.economy.players[seat]
	return {
		"cap": int(player["food_capacity"]),
		"maximum": 100,
		"reserved": int(player["reserved_food"]),
		"used": int(player["food_used"]),
	}


func _seat_upkeep(simulation: Variant, seat: int) -> Dictionary:
	var player: Dictionary = simulation.state.economy.players[seat]
	return {
		"gold_delivery_bp": int(player["gold_delivery_bp"]),
		"tier": str(player["upkeep_tier"]),
	}


func _seat_technology(
	simulation: Variant, seat: int, errors: PackedStringArray
) -> Dictionary:
	var state: Variant = simulation.state
	var player: Dictionary = state.economy.players[seat]
	var upgrades: Array[String] = []
	var upgrade_ids: Array = (player["completed_upgrades"] as Dictionary).keys()
	upgrade_ids.sort()
	for upgrade_variant: Variant in upgrade_ids:
		var upgrade_id := str(upgrade_variant)
		var level := int(player["completed_upgrades"][upgrade_variant])
		if level > 0:
			upgrades.append("%s_%d" % [upgrade_id, level])
	var researching: Array = []
	for producer_id: int in state.economy.sorted_producer_ids():
		if not state.entities.has(producer_id) \
			or int(state.entities[producer_id].owner_seat) != seat:
			continue
		for entry_variant: Variant in state.economy.production_queues[producer_id]:
			var entry: Dictionary = entry_variant
			if str(entry["kind"]) == "upgrade":
				researching.append({
					"entry": _queue_entry(entry),
					"producer_internal_id": producer_id,
				})
	if state.economy.tier_queues.has(seat):
		var tier_entry: Dictionary = state.economy.tier_queues[seat]
		var producer_id := int(tier_entry["stronghold_id"])
		if not state.entities.has(producer_id):
			errors.append("tier queue references a missing stronghold")
		else:
			researching.append({
				"entry": _queue_entry(tier_entry),
				"producer_internal_id": producer_id,
			})
	researching.sort_custom(_producer_internal_id_less)
	var used_slots := 0
	for hero_id: int in state.heroes.sorted_hero_ids():
		if int(state.heroes.heroes[hero_id]["owner_seat"]) == seat:
			used_slots += 1
	var completed_untyped: Array = []
	completed_untyped.assign(upgrades)
	return {
		"completed_upgrades": completed_untyped,
		"hero_slots": {"available": int(player["hero_slots"]), "used": used_slots},
		"researching": researching,
		"tier": int(player["technology_tier"]),
	}


func _producer_queue(
	simulation: Variant, producer_id: int, errors: PackedStringArray
) -> Array:
	var entries: Array = []
	var production_paused := _producer_is_status_disabled(simulation, producer_id)
	for entry_variant: Variant in simulation.state.economy.production_queues.get(producer_id, []):
		var entry := _queue_entry(entry_variant)
		entry["paused"] = production_paused
		entries.append(entry)
	for seat: int in [0, 1]:
		if simulation.state.economy.tier_queues.has(seat) \
			and int(simulation.state.economy.tier_queues[seat]["stronghold_id"]) == producer_id:
			var entry := _queue_entry(simulation.state.economy.tier_queues[seat])
			entry["paused"] = production_paused
			entries.append(entry)
	for hero_id: int in _sorted_int_keys(simulation.state.heroes.revivals):
		var revival: Dictionary = simulation.state.heroes.revivals[hero_id]
		if int(revival["requested_reviver_id"]) == producer_id:
			entries.append(_revival_queue_entry(revival, hero_id))
	entries.sort_custom(_queue_entry_less)
	if entries.size() > 5:
		errors.append("producer %d has more than five public queue entries" % producer_id)
	return entries


func _producer_is_status_disabled(simulation: Variant, producer_id: int) -> bool:
	return simulation.economy.is_production_disabled_by_status(
		simulation.state, producer_id
	)


func _queue_entry(source_variant: Variant) -> Dictionary:
	var source: Dictionary = source_variant
	var total := maxi(1, int(source.get("total_ticks", source.get("duration_ticks", 1))))
	var remaining := maxi(0, int(source.get("remaining_ticks", source.get("duration_ticks", 0))))
	@warning_ignore("integer_division")
	var progress := clampi(((total - remaining) * 10_000) / total, 0, 10_000)
	var raw_kind := str(source.get("kind", "tier" if source.has("target_tier") else "unit"))
	var kind := "research" if raw_kind == "upgrade" else raw_kind
	var type_id := str(source.get(
		"catalog_id", "tier_%d" % int(source.get("target_tier", 1))
	))
	return {
		"kind": kind,
		"paused": bool(source.get("paused", false)),
		"progress_bp": progress,
		"queue_entry_id": _opaque_public_ref("queue", [
			int(source.get("entry_id", 0)), int(source.get("producer_id", source.get("stronghold_id", 0))),
		]),
		"remaining_ticks": remaining,
		"reserved_food": int(source.get("food_cost", 0)),
		"reserved_gold": int(source.get("cost_gold", 0)),
		"reserved_lumber": int(source.get("cost_lumber", 0)),
		"type_id": type_id,
	}


func _revival_queue_entry(source: Dictionary, hero_id: int) -> Dictionary:
	var total := maxi(1, int(source["total_ticks"]))
	var remaining := maxi(0, int(source["remaining_ticks"]))
	@warning_ignore("integer_division")
	return {
		"kind": "revival",
		"paused": false,
		"progress_bp": clampi(((total - remaining) * 10_000) / total, 0, 10_000),
		"queue_entry_id": _opaque_public_ref("revival", [hero_id, int(source["start_tick"])]),
		"remaining_ticks": remaining,
		"reserved_food": 0,
		"reserved_gold": int(source["cost_gold"]),
		"reserved_lumber": 0,
		"type_id": str(simulation_type_placeholder(hero_id)),
	}


## Kept as a separate pure helper so revival queue IDs/types never serialize an
## internal-id field name. The type is intentionally generic until Hero queues
## store their public archetype directly.
static func simulation_type_placeholder(_hero_id: int) -> String:
	return "hero_revival"


func _seat_squads(
	simulation: Variant, seat: int, controller: Dictionary
) -> Array:
	var result: Array = []
	var squads: Dictionary = controller["state"]["squads"]
	var squad_ids: Array = squads.keys()
	squad_ids.sort()
	for squad_variant: Variant in squad_ids:
		var squad_id := str(squad_variant)
		var source: Dictionary = squads[squad_variant]
		if int(source["owner_seat"]) != seat:
			continue
		var members: Array[int] = []
		for alias_variant: Variant in source["member_ids"]:
			var internal_id := int(controller["bindings"].get(str(alias_variant), 0))
			if internal_id > 0 and simulation.state.entities.has(internal_id) \
				and int(simulation.state.entities[internal_id].owner_seat) == seat:
				members.append(internal_id)
		members.sort()
		if members.is_empty():
			continue
		var tactics: Dictionary = source["tactics"]
		var first_alias := str(controller["alias_by_internal"].get(members[0], ""))
		var actor_tactics: Dictionary = controller["state"]["tactics_by_actor"].get(first_alias, {})
		var row := {
			"current_order": _current_order(simulation, members[0]),
			"formation": str(tactics.get("formation", actor_tactics.get("formation", "none"))),
			"member_internal_ids": members,
			"squad_id": squad_id,
			"stance": str(tactics.get("stance", actor_tactics.get("stance", "defensive"))),
		}
		if tactics.has("retreat_hp_threshold_bp") or actor_tactics.has("retreat_hp_threshold_bp"):
			row["retreat_hp_threshold_bp"] = int(tactics.get(
				"retreat_hp_threshold_bp", actor_tactics.get("retreat_hp_threshold_bp", 0)
			))
		result.append(row)
	return result


func _visible_item_candidates(simulation: Variant, context: Dictionary) -> Array:
	var result: Array = []
	for entity_id: int in simulation.state.heroes.sorted_ground_item_ids():
		if not simulation.state.entities.has(entity_id):
			continue
		var ground: Dictionary = simulation.state.heroes.ground_items[entity_id]
		var entity: Variant = simulation.state.entities[entity_id]
		var item: Dictionary = ground["item"]
		result.append({
			"charges": int(item["charges"]),
			"despawn_tick": int(ground["despawn_tick"]),
			"entity_internal_id": entity_id,
			"item_type_id": str(item["item_type_id"]),
			"position_mt": [int(entity.position_x_mt), int(entity.position_y_mt)],
			"region_id": _region_at_position(simulation, [entity.position_x_mt, entity.position_y_mt]),
		})
	for item_variant: Variant in context["neutral_registry"]["ground_items"]:
		var source: Dictionary = item_variant
		var item_definition: Dictionary = simulation.heroes.catalog["items"]["items"].get(
			str(source["item_type_id"]), {}
		)
		result.append({
			"charges": int(item_definition.get("charges", 1)),
			"despawn_tick": int(source["despawn_tick"]),
			"entity_internal_id": int(source["entity_internal_id"]),
			"item_type_id": str(source["item_type_id"]),
			"position_mt": (source["position_mt"] as Array).duplicate(),
			"region_id": _region_at_position(simulation, source["position_mt"]),
		})
	result.sort_custom(_candidate_internal_id_less)
	return result


func _visible_shop_candidates(context: Dictionary) -> Array:
	var result: Array = []
	for building_variant: Variant in context["neutral_registry"]["buildings"]:
		var building: Dictionary = building_variant
		var offers: Array = []
		for offer_variant: Variant in building["offers"]:
			var source: Dictionary = offer_variant
			offers.append({
				"available": bool(source["activated"]) and int(source["current_stock"]) != 0,
				"cost_gold": int(source["cost_gold"]),
				"cost_lumber": int(source["cost_lumber"]),
				"kind": str(source["kind"]),
				"next_restock_tick": null if int(source["next_restock_tick"]) < 0 else int(source["next_restock_tick"]),
				"offer_id": str(source["offer_id"]),
				"requires_service_target": bool(source["requires_service_target"]),
				"stock": null if int(source["maximum_stock"]) < 0 else int(source["current_stock"]),
			})
		offers.sort_custom(_offer_less)
		result.append({
			"entity_internal_id": int(building["entity_internal_id"]),
			"offers": offers,
			"position_mt": (building["position_mt"] as Array).duplicate(),
			"region_id": str(building["region_id"]),
			"shop_type": str(building["building_type"]),
			"site_id": str(building["building_id"]),
		})
	result.sort_custom(_site_id_less)
	return result


func _candidate_events(
	simulation: Variant, context: Dictionary, errors: PackedStringArray
) -> Array:
	var result: Array = []
	var cursor := int(context["world_event_seq_after"])
	for event_variant: Variant in simulation.state.events:
		var event: Variant = event_variant
		if int(event.event_seq) <= cursor:
			continue
		result.append(_state_event_candidate(simulation, event))
	for event_variant: Variant in context["neutral_registry"]["events"]:
		var event: Dictionary = event_variant
		if int(event["event_seq"]) <= cursor:
			continue
		result.append({
			"audience_mask": int(event["audience_mask"]),
			"event_kind": str(event["event_kind"]),
			"owner_seat": int(event["owner_seat"]),
			"phase": int(event["phase"]),
			"public_payload": _public_event_payload(event["event_kind"], event["payload"]),
			"source_internal_id": int(event["source_internal_id"]),
			"target_internal_id": int(event["target_internal_id"]),
			"tick": int(event["tick"]),
			"visibility_rule": str(event["visibility_rule"]),
			"world_event_seq": int(event["event_seq"]),
		})
	result.sort_custom(_event_candidate_less)
	for index: int in result.size():
		var candidate: Dictionary = result[index]
		if int(candidate["world_event_seq"]) <= cursor:
			errors.append("candidate event cursor ordering is invalid")
	return result


func _state_event_candidate(simulation: Variant, event: Variant) -> Dictionary:
	var kind := str(event.event_kind)
	var owner_seat := _event_owner_seat(
		simulation, int(event.source_internal_id), int(event.target_internal_id)
	)
	var rule := "source_or_target_visible"
	if kind == "match_ended":
		rule = "always"
	elif kind in PRIVATE_EVENT_KINDS and owner_seat in [0, 1]:
		rule = "owner"
	return {
		"audience_mask": int(event.audience_mask),
		"event_kind": kind,
		"owner_seat": owner_seat,
		"phase": int(event.phase),
		"public_payload": _public_event_payload(kind, event.payload),
		"source_internal_id": int(event.source_internal_id),
		"target_internal_id": int(event.target_internal_id),
		"tick": int(event.tick),
		"visibility_rule": rule,
		"world_event_seq": int(event.event_seq),
	}


func _public_event_payload(kind: String, payload_variant: Variant) -> Dictionary:
	var payload: Dictionary = payload_variant if typeof(payload_variant) == TYPE_DICTIONARY else {}
	var result: Dictionary = {}
	for key: String in EVENT_PUBLIC_PAYLOAD_KEYS:
		if payload.has(key):
			result[key] = _deep_copy(payload[key])
	if kind == "resource_deposited":
		result["amount"] = int(payload.get("delivered", payload.get("amount", 0)))
		result["resource"] = str(payload.get("resource", "gold"))
	elif kind == "match_ended":
		result["terminal_reason"] = str(payload.get("reason", "match_ended"))
		result["winner"] = int(payload.get("winner_seat", -1))
	return result


func _terminal_snapshot(simulation: Variant, errors: PackedStringArray) -> Variant:
	var terminal: Dictionary = simulation.state.terminal
	if not bool(terminal["ended"]):
		return null
	var event_tick := -1
	for event_variant: Variant in simulation.state.events:
		var event: Variant = event_variant
		if str(event.event_kind) != "match_ended":
			continue
		if int(event.payload.get("terminal_tick", -1)) != int(event.tick):
			errors.append("match_ended event terminal_tick does not match its event tick")
			continue
		event_tick = int(event.tick)
	if event_tick < 0:
		errors.append("terminal state has no authoritative match_ended event")
		return null
	var result_kind := str(terminal["result"])
	var kind := "draw"
	if result_kind == "normal":
		kind = "victory"
	elif result_kind == "technical_forfeit":
		kind = "forfeit"
	elif result_kind == "infrastructure_void":
		kind = "infrastructure_void"
	elif result_kind != "draw":
		errors.append("terminal state result cannot be mapped to perception")
	return {
		"kind": kind,
		"reason": str(terminal["reason"]),
		"terminal_tick": event_tick,
		"winner_seat": null if int(terminal["winner_seat"]) < 0 else int(terminal["winner_seat"]),
	}


func _entity_definition(simulation: Variant, entity_id: int) -> Dictionary:
	var entity: Variant = simulation.state.entities[entity_id]
	if simulation.state.heroes.heroes.has(entity_id):
		return simulation.heroes.catalog["faction"]["heroes"].get(entity.catalog_id, {})
	if bool(simulation.state.neutrals.enabled) \
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


func _owned_abilities(
	simulation: Variant,
	entity_id: int,
	alias: String,
	controller: Dictionary,
	definition: Dictionary
) -> Array:
	var ability_ids: Array[String] = []
	for ability_variant: Variant in definition.get("abilities", []):
		var ability_id := str(ability_variant)
		if not ability_ids.has(ability_id):
			ability_ids.append(ability_id)
	if simulation.state.heroes.heroes.has(entity_id):
		for ability_variant: Variant in simulation.state.heroes.heroes[entity_id]["learned_abilities"].keys():
			var ability_id := str(ability_variant)
			if not ability_ids.has(ability_id):
				ability_ids.append(ability_id)
	ability_ids.sort()
	var autocast: Dictionary = controller["state"]["autocast_by_actor"].get(alias, {})
	var result: Array = []
	for ability_id: String in ability_ids:
		var rank := 1
		if simulation.state.heroes.heroes.has(entity_id):
			rank = int(simulation.state.heroes.heroes[entity_id]["learned_abilities"].get(ability_id, 0))
		result.append({
			"ability_id": ability_id,
			"autocast_enabled": bool(autocast.get(ability_id, false)),
			"cooldown_remaining_ticks": 0,
			"rank": clampi(rank, 0, 3),
		})
	return result


func _owned_statuses(simulation: Variant, entity_id: int) -> Array:
	var result: Array = []
	for status_id: int in _sorted_int_keys(simulation.state.combat.statuses):
		var status: Dictionary = simulation.state.combat.statuses[status_id]
		if int(status["target_id"]) != entity_id:
			continue
		result.append({
			"dispel_class": str(status["dispel_class"]),
			"expiry_tick": int(status["expiry_tick"]),
			"magnitude": int(status["magnitude"]),
			"source_internal_id": int(status["source_id"]),
			"stacking_key": str(status["stacking_key"]),
			"stacks": 1,
			"start_tick": int(status["start_tick"]),
			"status_id": str(status["status_kind"]),
		})
	result.sort_custom(_status_less)
	return result


func _entity_cargo(simulation: Variant, entity_id: int) -> Dictionary:
	if not simulation.state.economy.worker_tasks.has(entity_id):
		return {"amount": 0, "resource": "none"}
	var task: Dictionary = simulation.state.economy.worker_tasks[entity_id]
	var amount := int(task["cargo"])
	return {
		"amount": amount,
		"resource": str(task["resource_type"]) if amount > 0 else "none",
	}


func _current_order(simulation: Variant, entity_id: int) -> Variant:
	var entity: Variant = simulation.state.entities[entity_id]
	var order_id := int(entity.active_order_id)
	if order_id <= 0 or not simulation.state.orders.has(order_id):
		return null
	return _public_order(simulation.state.orders[order_id])


func _queued_orders(simulation: Variant, entity_id: int) -> Array:
	var result: Array = []
	for order_id: int in simulation.state.order_ids_fifo():
		var order: Variant = simulation.state.orders[order_id]
		if int(order.actor_id) == entity_id and int(order.status) == OrderRecord.Status.QUEUED:
			result.append(_public_order(order))
			if result.size() == ObservationContract.MAX_QUEUE_ENTRIES:
				break
	return result


func _public_order(order: Variant) -> Dictionary:
	var result := {
		"compiled_order_id": _opaque_public_ref("order", [
			str(order.command_digest), int(order.command_index), int(order.internal_order_id),
		]),
		"issued_tick": int(order.issued_tick),
		"op": str(order.order_kind),
		"state": str(ORDER_STATE_NAMES.get(int(order.status), "failed")),
	}
	var target: Dictionary = order.target
	if int(target.get("entity_id", target.get("target_id", 0))) > 0:
		result["target_internal_id"] = int(target.get("entity_id", target.get("target_id", 0)))
	elif typeof(target.get("xy_mt")) == TYPE_ARRAY:
		result["target_position_mt"] = (target["xy_mt"] as Array).duplicate()
	elif typeof(target.get("position_mt")) == TYPE_ARRAY:
		result["target_position_mt"] = (target["position_mt"] as Array).duplicate()
	return result


func _movement_state(simulation: Variant, entity_id: int, controller: Dictionary) -> String:
	var alias := str(controller["alias_by_internal"].get(entity_id, ""))
	for transport_variant: Variant in controller["state"]["transport_manifests"].keys():
		if alias in controller["state"]["transport_manifests"][transport_variant]:
			return "transported"
	var entity: Variant = simulation.state.entities[entity_id]
	if entity.entity_kind == "structure" or "structure" in entity.tags:
		return "rooted"
	if simulation.state.movement.actors.has(entity_id):
		var actor: Dictionary = simulation.state.movement.actors[entity_id]
		if int(actor.get("goal_x_mt", entity.position_x_mt)) != int(entity.position_x_mt) \
			or int(actor.get("goal_y_mt", entity.position_y_mt)) != int(entity.position_y_mt):
			return "moving"
	return "idle"


func _observable_activity(simulation: Variant, entity_id: int, controller: Dictionary) -> String:
	if _movement_state(simulation, entity_id, controller) == "transported":
		return "transported"
	if simulation.state.economy.worker_tasks.has(entity_id):
		return "gathering"
	for building_id: int in simulation.state.economy.sorted_construction_ids():
		if entity_id in simulation.state.economy.construction_sites[building_id]["worker_ids"]:
			return "building"
	for building_id: int in simulation.state.economy.sorted_repair_building_ids():
		if entity_id in simulation.state.economy.repair_ledgers[building_id]["worker_ids"]:
			return "repairing"
	if simulation.state.combat.attack_orders.has(entity_id) \
		or int(simulation.state.combat.actors.get(entity_id, {}).get("pending_attack_sequence_id", 0)) > 0:
		return "attacking"
	if _movement_state(simulation, entity_id, controller) == "moving":
		return "moving"
	return "idle"


func _squad_ids_for_entity(controller: Dictionary, entity_id: int) -> Array:
	var result: Array[String] = []
	var alias := str(controller["alias_by_internal"].get(entity_id, ""))
	for squad_variant: Variant in controller["state"]["squads"].keys():
		var squad: Dictionary = controller["state"]["squads"][squad_variant]
		if alias in squad["member_ids"]:
			result.append(str(squad_variant))
	result.sort()
	var untyped: Array = []
	untyped.assign(result)
	return untyped


func _structure_type_ids(simulation: Variant, seat: int) -> Array:
	var result: Array[String] = []
	for entity_id: int in simulation.state.economy.sorted_entity_record_ids():
		var record: Dictionary = simulation.state.economy.entity_records[entity_id]
		if int(record["owner_seat"]) == seat and str(record["kind"]) == "structure":
			var type_id := str(record["catalog_id"])
			if not result.has(type_id):
				result.append(type_id)
	result.sort()
	var untyped: Array = []
	untyped.assign(result)
	return untyped


func _entity_cells(simulation: Variant, entity_id: int) -> Array:
	if simulation.state.movement.actors.has(entity_id):
		return _sorted_ints(simulation.state.movement.actors[entity_id].get("occupied_cells", []))
	return _sorted_ints(simulation.grid.ground_cells_for_actor(entity_id))


func _entity_layer(simulation: Variant, entity_id: int) -> String:
	if simulation.state.combat.actors.has(entity_id):
		return str(simulation.state.combat.actors[entity_id].get("layer", "ground"))
	if simulation.state.movement.actors.has(entity_id):
		return str(simulation.state.movement.actors[entity_id].get("layer", "ground"))
	return "air" if "air" in simulation.state.entities[entity_id].tags else "ground"


func _hero_level(simulation: Variant, entity_id: int) -> Variant:
	if simulation.state.heroes.heroes.has(entity_id):
		return int(simulation.state.heroes.heroes[entity_id]["level"])
	return null


static func _entity_type_id(entity: Variant) -> String:
	var value := str(entity.catalog_id)
	return value if not value.is_empty() else str(entity.entity_kind)


func _region_at_position(simulation: Variant, position: Array) -> String:
	var grid := _grid_snapshot(simulation)
	return _entity_region(grid, _position_node_id(position, grid))


static func _entity_region(grid: Dictionary, node_id: int) -> String:
	if node_id < 0 or node_id >= (grid["region_ids"] as Array).size():
		return "unknown"
	var value := str(grid["region_ids"][node_id])
	return value if not value.is_empty() else "unknown"


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


static func _grid_int_at(values: Array, index: int, fallback: int) -> int:
	return int(values[index]) if index >= 0 and index < values.size() else fallback


static func _event_owner_seat(simulation: Variant, source_id: int, target_id: int) -> int:
	for entity_id: int in [source_id, target_id]:
		if simulation.state.entities.has(entity_id):
			var seat := int(simulation.state.entities[entity_id].owner_seat)
			if seat in [0, 1]:
				return seat
	return -1


static func _rally_target(value: Variant) -> Variant:
	if value == null or typeof(value) != TYPE_DICTIONARY:
		return null
	var target: Dictionary = value
	if str(target.get("kind", "")) == "entity":
		return str(target.get("public_id", ""))
	if str(target.get("kind", "")) == "point":
		return (target.get("xy_mt", []) as Array).duplicate()
	return null


static func _opaque_public_ref(prefix: String, scope: Array) -> String:
	return "%s.%s" % [prefix, Codec.sha256_canonical(scope).substr(0, 20)]


static func _neutral_offer_registry_row(source: Dictionary) -> Dictionary:
	return {
		"activated": bool(source.get("activated", false)),
		"cost_gold": int(source.get("cost_gold", 0)),
		"cost_lumber": int(source.get("cost_lumber", 0)),
		"current_stock": int(source.get("current_stock", 0)),
		"initial_tick": int(source.get("initial_tick", 0)),
		"kind": str(source.get("kind", "")),
		"maximum_stock": int(source.get("maximum_stock", 0)),
		"next_restock_tick": int(source.get("next_restock_tick", -1)),
		"offer_id": str(source.get("offer_id", "")),
		"requires_service_target": bool(source.get("requires_service_target", false)),
		"restock_ticks_per_charge": int(source.get("restock_ticks_per_charge", 0)),
	}


static func _contains_protected_context_key(value: Variant) -> bool:
	if typeof(value) == TYPE_DICTIONARY:
		for key_variant: Variant in (value as Dictionary).keys():
			var key := str(key_variant).to_lower()
			for fragment: String in PROTECTED_CONTEXT_KEY_FRAGMENTS:
				if fragment in key:
					return true
			if _contains_protected_context_key((value as Dictionary)[key_variant]):
				return true
	elif typeof(value) == TYPE_ARRAY:
		for child: Variant in value:
			if _contains_protected_context_key(child):
				return true
	return false


static func _exact_fields(
	value: Dictionary,
	required: Array[String],
	optional: Array[String],
	path: String,
	errors: PackedStringArray
) -> void:
	var allowed: Dictionary = {}
	for field: String in required:
		allowed[field] = true
		if not value.has(field):
			errors.append(path + " is missing " + field)
	for field: String in optional:
		allowed[field] = true
	for key_variant: Variant in value.keys():
		if typeof(key_variant) != TYPE_STRING or not allowed.has(str(key_variant)):
			errors.append(path + " has unknown field " + str(key_variant))


static func _validate_only_fields(
	value: Variant, allowed: Array[String], path: String, errors: PackedStringArray
) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append(path + " entry must be an object")
		return
	for key_variant: Variant in (value as Dictionary).keys():
		if typeof(key_variant) != TYPE_STRING or str(key_variant) not in allowed:
			errors.append(path + " entry has unknown field " + str(key_variant))


static func _validate_point(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != 2 \
		or typeof(value[0]) != TYPE_INT or typeof(value[1]) != TYPE_INT \
		or int(value[0]) < 0 or int(value[1]) < 0:
		errors.append(path + " must be a non-negative integer pair")


static func _sorted_unique_strings(value: Variant) -> Array:
	var typed: Array[String] = []
	if typeof(value) == TYPE_ARRAY:
		for child: Variant in value:
			var text := str(child)
			if not typed.has(text):
				typed.append(text)
	typed.sort()
	var result: Array = []
	result.assign(typed)
	return result


static func _sorted_ints(value: Variant) -> Array:
	var typed: Array[int] = []
	if typeof(value) == TYPE_ARRAY:
		for child: Variant in value:
			var integer := int(child)
			if not typed.has(integer):
				typed.append(integer)
	typed.sort()
	var result: Array = []
	result.assign(typed)
	return result


static func _sorted_int_keys(value: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for key_variant: Variant in value.keys():
		result.append(int(key_variant))
	result.sort()
	return result


static func _deep_copy(value: Variant) -> Variant:
	return value.duplicate(true) if typeof(value) in [TYPE_ARRAY, TYPE_DICTIONARY] else value


static func _internal_id_less(left: Dictionary, right: Dictionary) -> bool:
	return int(left["internal_id"]) < int(right["internal_id"])


static func _candidate_internal_id_less(left: Dictionary, right: Dictionary) -> bool:
	return int(left["entity_internal_id"]) < int(right["entity_internal_id"])


static func _producer_internal_id_less(left: Dictionary, right: Dictionary) -> bool:
	return int(left["producer_internal_id"]) < int(right["producer_internal_id"])


static func _slot_less(left: Dictionary, right: Dictionary) -> bool:
	return int(left["slot"]) < int(right["slot"])


static func _queue_entry_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left["queue_entry_id"]) < str(right["queue_entry_id"])


static func _status_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left["status_id"]) < str(right["status_id"])


static func _offer_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left["offer_id"]) < str(right["offer_id"])


static func _site_id_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left["site_id"]) < str(right["site_id"])


static func _event_candidate_less(left: Dictionary, right: Dictionary) -> bool:
	var left_key := [
		int(left["tick"]), int(left["phase"]), int(left["world_event_seq"]),
		str(left["event_kind"]), Codec.sha256_canonical(left),
	]
	var right_key := [
		int(right["tick"]), int(right["phase"]), int(right["world_event_seq"]),
		str(right["event_kind"]), Codec.sha256_canonical(right),
	]
	return left_key < right_key


static func _failure(errors: PackedStringArray) -> Dictionary:
	return {
		"errors": errors,
		"ok": false,
		"phase_snapshot": {},
		"protected_canonical_json": "",
		"protected_snapshot_hash": "",
	}
