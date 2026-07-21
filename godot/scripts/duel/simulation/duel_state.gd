class_name DuelState
extends RefCounted

const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const OrderRecord := preload("res://scripts/duel/simulation/duel_order.gd")
const EventRecord := preload("res://scripts/duel/simulation/duel_event.gd")
const EconomyState := preload("res://scripts/duel/economy/duel_economy_state.gd")
const CombatState := preload("res://scripts/duel/combat/duel_combat_state.gd")
const MovementState := preload("res://scripts/duel/movement/duel_movement_state.gd")
const HeroState := preload("res://scripts/duel/heroes/duel_hero_state.gd")
const NeutralState := preload("res://scripts/duel/neutrals/duel_neutral_state.gd")
const AbilityState := preload("res://scripts/duel/abilities/duel_ability_state.gd")

## Integer-authoritative, explicitly serializable Duel state. Engine objects,
## floats, Callables, and presentation references are intentionally absent.

var tick: int = 0
var match_seed: int = 0
var protocol_version: String = ""
var protocol_hash: String = ""
var engine_build: String = ""
var engine_build_hash: String = ""
var ruleset_id: String = ""
var ruleset_hash: String = ""
var map_hash: String = ""
var faction_hash: String = ""
var item_hash: String = ""
var neutral_hash: String = ""
var helper_hash: String = ""
var prompt_hash: String = ""
var tie_key_commitment: String = ""

var next_entity_id: int = 1
var next_order_id: int = 1
var next_event_seq: int = 1

var entities: Dictionary = {}
var orders: Dictionary = {}
var events: Array = []
var last_tick_phase_ids: Array[int] = []
var economy: EconomyState = EconomyState.new()
var combat: CombatState = CombatState.new()
var movement: MovementState = MovementState.new()
var heroes: HeroState = HeroState.new()
var neutrals: NeutralState = NeutralState.new()
var abilities: AbilityState = AbilityState.new()

var no_progress_ticks: int = 0
var terminal: Dictionary = {
	"ended": false,
	"reason": "",
	"result": "in_progress",
	"winner_seat": -1,
}


func reset(config: Dictionary) -> void:
	tick = 0
	match_seed = int(config.get("match_seed", 0))
	protocol_version = str(config.get("protocol_version", ""))
	protocol_hash = str(config.get("protocol_hash", ""))
	engine_build = str(config.get("engine_build", ""))
	engine_build_hash = str(config.get("engine_build_hash", ""))
	ruleset_id = str(config.get("ruleset_id", ""))
	ruleset_hash = str(config.get("ruleset_hash", ""))
	map_hash = str(config.get("map_hash", ""))
	faction_hash = str(config.get("faction_hash", ""))
	item_hash = str(config.get("item_hash", ""))
	neutral_hash = str(config.get("neutral_hash", ""))
	helper_hash = str(config.get("helper_hash", ""))
	prompt_hash = str(config.get("prompt_hash", ""))
	tie_key_commitment = str(config.get("tie_key_commitment", ""))
	next_entity_id = 1
	next_order_id = 1
	next_event_seq = 1
	entities.clear()
	orders.clear()
	events.clear()
	last_tick_phase_ids.clear()
	economy = EconomyState.new()
	combat = CombatState.new()
	movement = MovementState.new()
	heroes = HeroState.new()
	neutrals = NeutralState.new()
	abilities = AbilityState.new()
	no_progress_ticks = 0
	terminal = {
		"ended": false,
		"reason": "",
		"result": "in_progress",
		"winner_seat": -1,
	}


func add_entity(entity: EntityRecord) -> int:
	if entity.internal_id == 0:
		entity.internal_id = next_entity_id
	if entity.internal_id <= 0 or entities.has(entity.internal_id):
		return 0
	if entity.public_id.is_empty():
		entity.public_id = "entity-%08d" % entity.internal_id
	var errors := entity.validate()
	if not errors.is_empty():
		return 0
	entities[entity.internal_id] = entity
	next_entity_id = maxi(next_entity_id, entity.internal_id + 1)
	return entity.internal_id


func remove_entity(entity_id: int) -> bool:
	if not entities.has(entity_id):
		return false
	entities.erase(entity_id)
	for order_id: int in sorted_order_ids():
		var order: OrderRecord = orders[order_id]
		if order.actor_id == entity_id and order.status <= OrderRecord.Status.ACTIVE:
			order.status = OrderRecord.Status.CANCELLED
	return true


func add_order(order: OrderRecord) -> int:
	if order.internal_order_id == 0:
		order.internal_order_id = next_order_id
	if order.internal_order_id <= 0 or orders.has(order.internal_order_id):
		return 0
	if not entities.has(order.actor_id):
		return 0
	var actor: EntityRecord = entities[order.actor_id]
	if actor.owner_seat != order.owner_seat:
		return 0
	var errors := order.validate()
	if not errors.is_empty():
		return 0
	orders[order.internal_order_id] = order
	next_order_id = maxi(next_order_id, order.internal_order_id + 1)
	return order.internal_order_id


func activate_due_orders(activation_tick: int) -> Array[int]:
	var activated: Array[int] = []
	for order_id: int in order_ids_fifo():
		var order: OrderRecord = orders[order_id]
		if order.status != OrderRecord.Status.QUEUED:
			continue
		if order.activation_tick > activation_tick:
			continue
		if not entities.has(order.actor_id):
			order.status = OrderRecord.Status.CANCELLED
			continue
		var actor: EntityRecord = entities[order.actor_id]
		if not actor.alive:
			order.status = OrderRecord.Status.CANCELLED
			continue
		if actor.active_order_id != 0 and orders.has(actor.active_order_id):
			var previous: OrderRecord = orders[actor.active_order_id]
			if previous.status == OrderRecord.Status.ACTIVE:
				previous.status = OrderRecord.Status.CANCELLED
		order.status = OrderRecord.Status.ACTIVE
		actor.active_order_id = order.internal_order_id
		activated.append(order.internal_order_id)
	return activated


func append_event(event: EventRecord) -> int:
	event.event_seq = next_event_seq
	next_event_seq += 1
	events.append(event)
	return event.event_seq


func sorted_entity_ids() -> Array[int]:
	var ids: Array[int] = []
	for id_variant: Variant in entities.keys():
		ids.append(int(id_variant))
	ids.sort()
	return ids


func sorted_order_ids() -> Array[int]:
	var ids: Array[int] = []
	for id_variant: Variant in orders.keys():
		ids.append(int(id_variant))
	ids.sort()
	return ids


func order_ids_fifo() -> Array[int]:
	var ids := sorted_order_ids()
	ids.sort_custom(_order_id_fifo_less)
	return ids


func to_canonical_dict() -> Dictionary:
	var canonical_entities: Array = []
	for entity_id: int in sorted_entity_ids():
		var entity: EntityRecord = entities[entity_id]
		canonical_entities.append(entity.to_canonical_dict())

	var canonical_orders: Array = []
	for order_id: int in order_ids_fifo():
		var order: OrderRecord = orders[order_id]
		canonical_orders.append(order.to_canonical_dict())

	var sorted_events: Array = events.duplicate()
	sorted_events.sort_custom(_event_less)
	var canonical_events: Array = []
	for event_variant: Variant in sorted_events:
		var event: EventRecord = event_variant
		canonical_events.append(event.to_canonical_dict())

	var canonical_phase_ids: Array = []
	for phase_id: int in last_tick_phase_ids:
		canonical_phase_ids.append(phase_id)

	var result := {
		"engine_build": engine_build,
		"engine_build_hash": engine_build_hash,
		"entities": canonical_entities,
		"events": canonical_events,
		"faction_hash": faction_hash,
		"helper_hash": helper_hash,
		"item_hash": item_hash,
		"last_tick_phase_ids": canonical_phase_ids,
		"map_hash": map_hash,
		"match_seed": match_seed,
		"neutral_hash": neutral_hash,
		"next_entity_id": next_entity_id,
		"next_event_seq": next_event_seq,
		"next_order_id": next_order_id,
		"no_progress_ticks": no_progress_ticks,
		"orders": canonical_orders,
		"prompt_hash": prompt_hash,
		"protocol_hash": protocol_hash,
		"protocol_version": protocol_version,
		"ruleset_hash": ruleset_hash,
		"ruleset_id": ruleset_id,
		"terminal": terminal.duplicate(true),
		"tick": tick,
		"tie_key_commitment": tie_key_commitment,
	}
	## Economy is an optional vertical slice for kernel-only fixtures. Once
	## configured it is mandatory checkpoint authority; leaving it absent while
	## disabled preserves the frozen Phase-2 kernel golden.
	if economy.enabled:
		result["economy"] = economy.to_canonical_dict()
	## As with economy, combat is omitted only for deliberately unconfigured
	## kernel fixtures. Once enabled it is checkpoint authority.
	if combat.enabled:
		result["combat"] = combat.to_canonical_dict()
	## Movement follows the same optional-slice rule. Once configured, routes,
	## conflict counters, altitude lanes, and rounding remainders are mandatory
	## checkpoint authority.
	if movement.enabled:
		result["movement"] = movement.to_canonical_dict()
	## Hero levels, inventories, revival queues, and periodic item effects are
	## authoritative as soon as the selected-faction Hero catalog is enabled.
	if heroes.enabled:
		result["heroes"] = heroes.to_canonical_dict()
	## Camps, neutral services, expansion gates, drops, and keyed contests become
	## checkpoint authority as soon as protected match authority is attached.
	if neutrals.enabled:
		result["neutrals"] = neutrals.to_canonical_dict()
	## Casts, cooldowns, scheduled impacts, toggles, and passive effects are
	## checkpoint authority as soon as the selected faction ability runtime is
	## configured.
	if abilities.enabled:
		result["abilities"] = abilities.to_canonical_dict()
	return result


func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if tick < 0:
		errors.append("state tick must be non-negative")
	if next_entity_id <= 0 or next_order_id <= 0 or next_event_seq <= 0:
		errors.append("next IDs must be positive")
	for entity_id: int in sorted_entity_ids():
		var entity: EntityRecord = entities[entity_id]
		if entity.internal_id != entity_id:
			errors.append("entity dictionary key mismatch for %d" % entity_id)
		for error: String in entity.validate():
			errors.append("entity[%d]: %s" % [entity_id, error])
	for order_id: int in sorted_order_ids():
		var order: OrderRecord = orders[order_id]
		if order.internal_order_id != order_id:
			errors.append("order dictionary key mismatch for %d" % order_id)
		for error: String in order.validate():
			errors.append("order[%d]: %s" % [order_id, error])
	for error: String in economy.validate(entities):
		errors.append("economy: %s" % error)
	for error: String in combat.validate(entities):
		errors.append("combat: %s" % error)
	for error: String in movement.validate(entities):
		errors.append("movement: %s" % error)
	for error: String in heroes.validate(entities):
		errors.append("heroes: %s" % error)
	if neutrals.enabled:
		for error: String in neutrals.validate():
			errors.append("neutrals: %s" % error)
	if abilities.enabled:
		for error: String in abilities.validate():
			errors.append("abilities: %s" % error)
	var terminal_keys: Array = terminal.keys()
	terminal_keys.sort()
	if terminal_keys != ["ended", "reason", "result", "winner_seat"]:
		errors.append("terminal state must contain exactly ended/reason/result/winner_seat")
	elif typeof(terminal["ended"]) != TYPE_BOOL \
		or typeof(terminal["reason"]) != TYPE_STRING \
		or typeof(terminal["result"]) != TYPE_STRING \
		or typeof(terminal["winner_seat"]) != TYPE_INT:
		errors.append("terminal state field types are invalid")
	elif bool(terminal["ended"]):
		if str(terminal["reason"]).is_empty():
			errors.append("ended terminal state requires a reason")
		if str(terminal["result"]) not in [
			"draw", "infrastructure_void", "normal", "technical_forfeit",
		]:
			errors.append("ended terminal result is invalid")
		var requires_winner := str(terminal["result"]) in ["normal", "technical_forfeit"]
		if requires_winner and int(terminal["winner_seat"]) not in [0, 1]:
			errors.append("winning terminal result requires winner seat 0 or 1")
		if not requires_winner and int(terminal["winner_seat"]) != -1:
			errors.append("non-winning terminal result must not have a winner")
	elif str(terminal["reason"]) != "" or str(terminal["result"]) != "in_progress" \
		or int(terminal["winner_seat"]) != -1:
		errors.append("active terminal state has non-default result fields")
	return errors


func _order_id_fifo_less(left_id: int, right_id: int) -> bool:
	var left: OrderRecord = orders[left_id]
	var right: OrderRecord = orders[right_id]
	var left_key: Array[int] = [
		left.activation_tick, left.issued_tick, left.command_index, left.internal_order_id,
	]
	var right_key: Array[int] = [
		right.activation_tick, right.issued_tick, right.command_index, right.internal_order_id,
	]
	return _int_key_less(left_key, right_key)


static func _event_less(left_variant: Variant, right_variant: Variant) -> bool:
	var left: EventRecord = left_variant
	var right: EventRecord = right_variant
	return left.event_seq < right.event_seq


static func _int_key_less(left: Array[int], right: Array[int]) -> bool:
	for index: int in mini(left.size(), right.size()):
		if left[index] != right[index]:
			return left[index] < right[index]
	return left.size() < right.size()
