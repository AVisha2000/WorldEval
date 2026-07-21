class_name DuelTickLedger
extends RefCounted

const Rules := preload("res://scripts/duel/simulation/duel_rules.gd")
const StateRecord := preload("res://scripts/duel/simulation/duel_state.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const OrderRecord := preload("res://scripts/duel/simulation/duel_order.gd")
const EventRecord := preload("res://scripts/duel/simulation/duel_event.gd")
const DeltaRecord := preload("res://scripts/duel/simulation/duel_delta.gd")
const OccupancyGrid := preload("res://scripts/duel/simulation/duel_occupancy_grid.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const EconomySystem := preload("res://scripts/duel/economy/duel_economy.gd")
const CombatSystem := preload("res://scripts/duel/combat/duel_combat.gd")
const MovementSystem := preload("res://scripts/duel/movement/duel_movement.gd")
const HeroSystem := preload("res://scripts/duel/heroes/duel_hero_system.gd")
const TerminalSystem := preload("res://scripts/duel/simulation/duel_terminal.gd")
const NeutralWorld := preload("res://scripts/duel/neutrals/duel_neutral_world.gd")
const AbilityRuntime := preload("res://scripts/duel/abilities/duel_ability_runtime.gd")
const AbilityEffectBridge := preload("res://scripts/duel/abilities/duel_ability_effect_bridge.gd")

## The ledger is the only component allowed to apply collected simultaneous
## deltas. Generic HP/mana/integer deltas and economy work share the frozen
## phase schedule; combat will attach through the same explicit boundary.

var _pending_deltas: Array = []
var _pending_events: Array[Dictionary] = []
var _phase_trace: Array[int] = []
var _event_local_seq: int = 0
var _running_tick: int = -1
var _pre_tick_hash: String = ""
var _frozen_pre_tick_snapshot: Dictionary = {}
var economy: EconomySystem = null
var combat: CombatSystem = null
var movement: MovementSystem = null
var heroes: HeroSystem = null
var terminal: TerminalSystem = null
var neutrals: NeutralWorld = null
var abilities: AbilityRuntime = null
var ability_effects: AbilityEffectBridge = null
var _simulation: Variant = null
var _economy_progress: bool = false
var _combat_progress: bool = false
var _movement_progress: bool = false
var _hero_progress: bool = false
var _neutral_progress: bool = false
var _neutral_event_cursor: int = 0
var _ability_event_cursor: int = 0


func set_economy(system: EconomySystem) -> void:
	economy = system


func set_combat(system: CombatSystem) -> void:
	combat = system


func set_movement(system: MovementSystem) -> void:
	movement = system


func set_heroes(system: HeroSystem) -> void:
	heroes = system


func set_terminal(system: TerminalSystem) -> void:
	terminal = system


func set_neutrals(system: NeutralWorld) -> void:
	neutrals = system
	_neutral_event_cursor = 0


func set_abilities(runtime: AbilityRuntime, effects: AbilityEffectBridge) -> void:
	abilities = runtime
	ability_effects = effects
	_ability_event_cursor = 0


func set_simulation(simulation: Variant) -> void:
	_simulation = simulation


func queue_delta(delta: DeltaRecord) -> PackedStringArray:
	var errors := delta.validate()
	if errors.is_empty():
		_pending_deltas.append(delta)
	return errors


func pending_deltas_canonical() -> Array:
	var sorted: Array = _pending_deltas.duplicate()
	sorted.sort_custom(_delta_less_variant)
	var result: Array = []
	for delta_variant: Variant in sorted:
		var delta: DeltaRecord = delta_variant
		result.append(delta.to_canonical_dict())
	return result


func run_tick(
	state: StateRecord,
	grid: OccupancyGrid = null,
	capture_pre_tick_checkpoint: bool = true
) -> Dictionary:
	_running_tick = state.tick
	if capture_pre_tick_checkpoint:
		_frozen_pre_tick_snapshot = {
			"grid": grid.to_canonical_dict() if grid != null else {},
			"pending_deltas": pending_deltas_canonical(),
			"state": state.to_canonical_dict(),
		}
		_pre_tick_hash = Codec.sha256_canonical(_frozen_pre_tick_snapshot)
	else:
		## The authoritative phase order is deterministic without serializing a
		## second copy of the whole 192x128 world. Official matches capture hashes
		## at decision, 300-tick, and final boundaries instead of every 100 ms.
		_frozen_pre_tick_snapshot.clear()
		_pre_tick_hash = ""
	_phase_trace.clear()
	_pending_events.clear()
	_event_local_seq = 0
	_economy_progress = false
	_combat_progress = false
	_movement_progress = false
	_hero_progress = false
	_neutral_progress = false

	for phase: Dictionary in Rules.TICK_PHASES:
		var phase_id := int(phase["id"])
		_phase_trace.append(phase_id)
		_run_phase(state, grid, phase_id)

	state.last_tick_phase_ids.assign(_phase_trace)
	state.tick += 1
	var result := {
		"completed_tick": _running_tick,
		"phase_ids": _phase_trace.duplicate(),
		"pre_tick_state_hash": _pre_tick_hash,
	}
	_running_tick = -1
	return result


func clear() -> void:
	_pending_deltas.clear()
	_pending_events.clear()
	_phase_trace.clear()
	_event_local_seq = 0
	_running_tick = -1
	_pre_tick_hash = ""
	_frozen_pre_tick_snapshot.clear()
	_economy_progress = false
	_combat_progress = false
	_movement_progress = false
	_hero_progress = false
	_neutral_progress = false
	_neutral_event_cursor = 0
	_ability_event_cursor = 0
	if economy != null:
		economy.clear_pending()
	if combat != null:
		combat.clear_pending()
	if movement != null:
		movement.clear_pending()
	if heroes != null:
		heroes.clear_pending()
	if terminal != null:
		terminal.clear_pending()


func frozen_pre_tick_snapshot() -> Dictionary:
	return _frozen_pre_tick_snapshot.duplicate(true)


func _run_phase(state: StateRecord, grid: OccupancyGrid, phase_id: int) -> void:
	match phase_id:
		Rules.TickPhase.ACTIVATE_ORDERS:
			_advance_abilities(state, "activation", Rules.TickPhase.ACTIVATE_ORDERS)
			_activate_orders(state)
		Rules.TickPhase.EXPIRE_TEMPORARY_STATE:
			if neutrals != null and state.neutrals.enabled:
				var neutral_errors := neutrals.advance_phase2(_running_tick)
				for message: String in neutral_errors:
					_queue_event(
						Rules.TickPhase.EXPIRE_TEMPORARY_STATE,
						"neutral_authority_error", 0, 0, {"message": message}
					)
				_drain_neutral_events(Rules.TickPhase.EXPIRE_TEMPORARY_STATE)
			if combat != null:
				combat.expire_statuses(state, _running_tick)
				_drain_combat_events(state)
			if ability_effects != null:
				ability_effects.resolve_lifecycle(_simulation)
		Rules.TickPhase.COMPILE_INTENTS:
			if neutrals != null and state.neutrals.enabled:
				_compile_neutral_intents(state, grid)
				_drain_neutral_events(Rules.TickPhase.COMPILE_INTENTS)
			if movement != null:
				movement.compile_intents(state, grid, _running_tick)
				_drain_movement_events()
			if combat != null:
				combat.compile_intents(state, _running_tick)
				_drain_combat_events(state)
		Rules.TickPhase.COMPUTE_PATHS:
			if movement != null:
				movement.compute_paths(state, grid, _running_tick)
				_drain_movement_events()
		Rules.TickPhase.RESOLVE_MOVEMENT:
			if movement != null:
				movement.resolve_movement(state, grid, _running_tick)
				_movement_progress = movement.take_progress() or _movement_progress
				_drain_movement_events()
		Rules.TickPhase.START_WINDUPS:
			if combat != null:
				combat.start_windups(state, _running_tick)
				_drain_combat_events(state)
		Rules.TickPhase.RESOLVE_IMPACTS:
			_advance_abilities(state, "commit", Rules.TickPhase.RESOLVE_IMPACTS)
			_advance_abilities(state, "periodic", Rules.TickPhase.RESOLVE_IMPACTS)
			if combat != null:
				combat.resolve_impacts(state, _running_tick)
				_drain_combat_deltas()
				_drain_combat_events(state)
			if economy != null:
				economy.collect_work_intents(state)
		Rules.TickPhase.APPLY_DELTAS:
			if ability_effects != null:
				for delta_variant: Variant in ability_effects.regeneration_deltas(
					_simulation
				):
					_pending_deltas.append(delta_variant)
			if combat != null:
				combat.apply_shield_updates(state)
			_apply_due_deltas(state)
			if economy != null:
				_economy_progress = economy.apply_collected_work(state, grid, _running_tick) \
					or _economy_progress
				_drain_economy_events(Rules.TickPhase.APPLY_DELTAS)
		Rules.TickPhase.RESOLVE_LIFECYCLE:
			if ability_effects != null:
				ability_effects.resolve_lifecycle(_simulation)
			_resolve_lifecycle(state, grid)
			if neutrals != null and state.neutrals.enabled:
				_resolve_neutral_lifecycle(state)
				_drain_neutral_events(Rules.TickPhase.RESOLVE_LIFECYCLE)
			if heroes != null:
				heroes.resolve_lifecycle(state, _running_tick)
				_hero_progress = heroes.take_progress() or _hero_progress
				_drain_hero_events(Rules.TickPhase.RESOLVE_LIFECYCLE)
			if movement != null:
				movement.resolve_lifecycle(state)
				_drain_movement_events()
			if combat != null:
				combat.resolve_lifecycle(state, _running_tick)
				_drain_combat_events(state)
			if economy != null:
				_economy_progress = economy.resolve_lifecycle(state, grid, _running_tick) \
					or _economy_progress
				_drain_economy_events(Rules.TickPhase.RESOLVE_LIFECYCLE)
		Rules.TickPhase.RESOLVE_HERO_AND_INVENTORY:
			if heroes != null:
				heroes.process_tick(state, grid, _running_tick)
				_hero_progress = heroes.take_progress() or _hero_progress
				_drain_hero_events(Rules.TickPhase.RESOLVE_HERO_AND_INVENTORY)
		Rules.TickPhase.TEST_TERMINAL:
			if combat != null and state.combat.enabled:
				_combat_progress = combat.take_progress()
			if state.economy.enabled or state.combat.enabled or state.movement.enabled \
				or state.heroes.enabled or state.neutrals.enabled:
				state.no_progress_ticks = 0 if (
					_economy_progress or _combat_progress or _movement_progress or _hero_progress \
					or _neutral_progress
				) \
					else state.no_progress_ticks + 1
			if terminal != null:
				terminal.test(state, _running_tick)
				_drain_terminal_events()
		Rules.TickPhase.EMIT_EVENTS_AND_CHECKPOINT:
			_emit_events(state)
		_:
			pass


func _activate_orders(state: StateRecord) -> void:
	var activated := state.activate_due_orders(_running_tick)
	for order_id: int in activated:
		var order: OrderRecord = state.orders[order_id]
		_queue_event(
			Rules.TickPhase.ACTIVATE_ORDERS,
			"order_activated",
			order.actor_id,
			0,
			{"internal_order_id": order.internal_order_id, "order_kind": order.order_kind}
		)


func _apply_due_deltas(state: StateRecord) -> void:
	var due: Array = []
	var retained: Array = []
	for delta_variant: Variant in _pending_deltas:
		var delta: DeltaRecord = delta_variant
		if delta.application_tick == _running_tick:
			due.append(delta)
		elif delta.application_tick > _running_tick:
			retained.append(delta)
		else:
			_queue_event(
				Rules.TickPhase.APPLY_DELTAS,
				"stale_delta_discarded",
				delta.source_internal_id,
				delta.entity_id,
				{"application_tick": delta.application_tick, "kind": delta.kind}
			)
	_pending_deltas = retained
	due.sort_custom(_delta_less_variant)

	## Aggregate first, then mutate in entity/kind/key order so all deltas observe
	## the frozen pre-application value.
	var totals: Dictionary = {}
	var descriptors: Dictionary = {}
	var hp_damage_targets: Dictionary = {}
	for delta_variant: Variant in due:
		var delta: DeltaRecord = delta_variant
		if delta.kind == DeltaRecord.Kind.HP and delta.amount < 0:
			## Combat has already applied mitigation and shields before creating a
			## negative HP delta. Preserve that fact independently of simultaneous
			## healing; a positive net aggregate must not conceal real damage from
			## damage-triggered status consumers such as Sleep.
			hp_damage_targets[delta.entity_id] = true
		var key := "%d|%d|%s" % [delta.entity_id, delta.kind, delta.attribute_key]
		totals[key] = int(totals.get(key, 0)) + delta.amount
		if not descriptors.has(key):
			descriptors[key] = {
				"attribute_key": delta.attribute_key,
				"entity_id": delta.entity_id,
				"kind": delta.kind,
			}

	var aggregate_keys: Array = descriptors.keys()
	aggregate_keys.sort_custom(_aggregate_key_less.bind(descriptors))
	for key_variant: Variant in aggregate_keys:
		var key := str(key_variant)
		var descriptor: Dictionary = descriptors[key]
		var entity_id := int(descriptor["entity_id"])
		if not state.entities.has(entity_id):
			continue
		var entity: EntityRecord = state.entities[entity_id]
		var amount := int(totals[key])
		match int(descriptor["kind"]):
			DeltaRecord.Kind.HP:
				entity.hp = clampi(entity.hp + amount, 0, entity.max_hp)
				if hp_damage_targets.has(entity_id) and combat != null:
					combat.notify_hp_damage_applied(state, entity_id, _running_tick)
				if amount < 0 and heroes != null:
					heroes.notify_damage(state, entity_id)
			DeltaRecord.Kind.MANA:
				entity.mana = clampi(entity.mana + amount, 0, entity.max_mana)
			DeltaRecord.Kind.INTEGER_ATTRIBUTE:
				var attribute_key := str(descriptor["attribute_key"])
				entity.integer_attributes[attribute_key] = int(
					entity.integer_attributes.get(attribute_key, 0)
				) + amount
		_queue_event(
			Rules.TickPhase.APPLY_DELTAS,
			"delta_applied",
			0,
			entity_id,
			{
				"amount": amount,
				"attribute_key": str(descriptor["attribute_key"]),
				"kind": int(descriptor["kind"]),
			}
		)


func _resolve_lifecycle(state: StateRecord, grid: OccupancyGrid) -> void:
	for entity_id: int in state.sorted_entity_ids():
		var entity: EntityRecord = state.entities[entity_id]
		var hired_expiry_tick := int(entity.integer_attributes.get("hired_expiry_tick", 0))
		if entity.alive and hired_expiry_tick > 0 and hired_expiry_tick <= _running_tick:
			entity.alive = false
			entity.hp = 0
			entity.integer_attributes["despawned"] = 1
			if grid != null:
				grid.release_ground_actor(entity_id)
			if entity.active_order_id != 0 and state.orders.has(entity.active_order_id):
				var expired_order: OrderRecord = state.orders[entity.active_order_id]
				if expired_order.status == OrderRecord.Status.ACTIVE:
					expired_order.status = OrderRecord.Status.CANCELLED
			entity.active_order_id = 0
			_queue_event(
				Rules.TickPhase.RESOLVE_LIFECYCLE,
				"hired_unit_expired",
				entity_id,
				0,
				{"catalog_id": entity.catalog_id}
			)
			continue
		if not entity.alive or entity.hp > 0:
			continue
		entity.alive = false
		if grid != null:
			grid.release_ground_actor(entity_id)
		if entity.active_order_id != 0 and state.orders.has(entity.active_order_id):
			var order: OrderRecord = state.orders[entity.active_order_id]
			if order.status == OrderRecord.Status.ACTIVE:
				order.status = OrderRecord.Status.CANCELLED
		entity.active_order_id = 0
		_queue_event(
			Rules.TickPhase.RESOLVE_LIFECYCLE,
			"entity_died",
			entity_id,
			0,
			{}
		)


func _compile_neutral_intents(state: StateRecord, grid: OccupancyGrid) -> void:
	var contacts_by_camp: Dictionary = {}
	for camp_id: String in state.neutrals.sorted_camp_ids():
		var camp: Dictionary = state.neutrals.camps[camp_id]
		var contacts: Array[Dictionary] = []
		for entity_id: int in state.sorted_entity_ids():
			var entity: EntityRecord = state.entities[entity_id]
			if entity.owner_seat not in [0, 1] or not entity.alive or entity.hp <= 0:
				continue
			var combat_actor: Dictionary = state.combat.actors.get(entity_id, {})
			var targetable := not combat_actor.is_empty() \
				and not bool(combat_actor.get("invulnerable", false)) \
				and not bool(combat_actor.get("transported", false))
			var dx := entity.position_x_mt - int(camp["position_mt"][0])
			var dy := entity.position_y_mt - int(camp["position_mt"][1])
			contacts.append({
				"alive": true,
				"attacked_camp": _entity_targets_camp(state, entity, camp_id),
				"hostile": true,
				"internal_id": entity_id,
				"path_cost": absi(dx) + absi(dy),
				"position_mt": [entity.position_x_mt, entity.position_y_mt],
				"region_id": grid.region_id_at_mt(entity.position_x_mt, entity.position_y_mt) \
					if grid != null else "",
				"targetable": targetable,
			})
		contacts_by_camp[camp_id] = contacts

	for camp_id: String in state.neutrals.sorted_camp_ids():
		var camp: Dictionary = state.neutrals.camps[camp_id]
		var member_ids: Array = camp["members"].keys()
		member_ids.sort()
		for member_id_variant: Variant in member_ids:
			var member_id := str(member_id_variant)
			var member: Dictionary = camp["members"][member_id]
			var entity_id := int(member.get("internal_id", 0))
			if entity_id <= 0 or not state.entities.has(entity_id):
				continue
			var entity: EntityRecord = state.entities[entity_id]
			var sync_errors := neutrals.synchronize_member(camp_id, member_id, {
				"alive": entity.alive,
				"hp": entity.hp,
				"max_hp": entity.max_hp,
				"position_mt": [entity.position_x_mt, entity.position_y_mt],
			})
			for message: String in sync_errors:
				_queue_event(
					Rules.TickPhase.COMPILE_INTENTS, "neutral_authority_error",
					entity_id, 0, {"message": message}
				)

	var intents := neutrals.compile_camp_intents(_running_tick, contacts_by_camp)
	for intent: Dictionary in intents:
		var actor_id := int(intent.get("neutral_internal_id", 0))
		if actor_id <= 0 or not state.entities.has(actor_id) \
			or not state.entities[actor_id].alive:
			continue
		var kind := str(intent.get("kind", ""))
		var payload: Dictionary = intent.get("payload", {})
		match kind:
			"attack_entity":
				var target_id := int(payload.get("target_internal_id", 0))
				var attack_range := 0
				if state.combat.actors.has(actor_id):
					attack_range = int(state.combat.actors[actor_id]["attack"].get(
						"attack_range_mt", 0
					))
				_set_neutral_order(state, intent, actor_id, "attack_entity", {
					"distance_mt": attack_range,
					"entity_id": target_id,
				})
			"return_to_spawn":
				_set_neutral_order(state, intent, actor_id, "move", {
					"position_mt": payload.get("position_mt", []).duplicate(),
				})
			"idle", "sleep":
				_set_neutral_order(state, intent, actor_id, "hold_position", {})
			"regenerate":
				var maximum: int = int(state.entities[actor_id].max_hp)
				@warning_ignore("integer_division")
				var amount: int = maximum * int(payload.get("max_hp_basis_points", 0)) / 10_000
				if amount > 0:
					var delta := DeltaRecord.new()
					delta.application_tick = _running_tick
					delta.entity_id = actor_id
					delta.kind = DeltaRecord.Kind.HP
					delta.amount = amount
					delta.source_internal_id = actor_id
					delta.local_seq = _event_local_seq
					_pending_deltas.append(delta)
					_neutral_progress = true
			_:
				_queue_event(
					Rules.TickPhase.COMPILE_INTENTS, "neutral_intent_rejected",
					actor_id, 0, {"kind": kind, "reason": "unsupported_kind"}
				)


func _set_neutral_order(
	state: StateRecord,
	intent: Dictionary,
	actor_id: int,
	order_kind: String,
	target: Dictionary
) -> void:
	var entity: EntityRecord = state.entities[actor_id]
	if entity.active_order_id != 0 and state.orders.has(entity.active_order_id):
		var current: OrderRecord = state.orders[entity.active_order_id]
		if current.status == OrderRecord.Status.ACTIVE \
			and current.order_kind == order_kind and current.target == target:
			return
		if current.status == OrderRecord.Status.ACTIVE:
			current.status = OrderRecord.Status.CANCELLED
	var order := OrderRecord.new(state.next_order_id, -1, actor_id, order_kind)
	order.issued_tick = _running_tick
	order.activation_tick = _running_tick
	order.command_digest = Codec.sha256_canonical(intent)
	order.target = target.duplicate(true)
	if state.add_order(order) == 0:
		_queue_event(
			Rules.TickPhase.COMPILE_INTENTS, "neutral_intent_rejected", actor_id, 0,
			{"kind": order_kind, "reason": "order_rejected"}
		)
		return
	order.status = OrderRecord.Status.ACTIVE
	entity.active_order_id = order.internal_order_id
	_neutral_progress = true
	_queue_event(
		Rules.TickPhase.COMPILE_INTENTS, "neutral_order_activated", actor_id,
		int(target.get("entity_id", 0)),
		{"camp_id": str(intent.get("camp_id", "")), "order_kind": order_kind}
	)


func _entity_targets_camp(
	state: StateRecord,
	entity: EntityRecord,
	camp_id: String
) -> bool:
	if entity.active_order_id == 0 or not state.orders.has(entity.active_order_id):
		return false
	var order: OrderRecord = state.orders[entity.active_order_id]
	var target_id := int(order.target.get("entity_id", order.target.get("target_id", 0)))
	if target_id <= 0:
		return false
	var membership := _neutral_membership(state, target_id)
	return str(membership.get("camp_id", "")) == camp_id


func _resolve_neutral_lifecycle(state: StateRecord) -> void:
	for camp_id: String in state.neutrals.sorted_camp_ids():
		var camp: Dictionary = state.neutrals.camps[camp_id]
		var member_ids: Array = camp["members"].keys()
		member_ids.sort()
		for member_id_variant: Variant in member_ids:
			var member_id := str(member_id_variant)
			var member: Dictionary = camp["members"][member_id]
			var entity_id := int(member.get("internal_id", 0))
			if not bool(member.get("alive", false)) or entity_id <= 0 \
				or not state.entities.has(entity_id):
				continue
			var entity: EntityRecord = state.entities[entity_id]
			if entity.alive or entity.hp > 0:
				continue
			var death := neutrals.mark_member_dead(camp_id, member_id, _running_tick)
			if not bool(death.get("accepted", false)):
				continue
			var handoff: Dictionary = death.get("handoff", {})
			var beneficiary := int(entity.integer_attributes.get("last_damage_owner_seat", -1))
			if heroes != null and beneficiary in [0, 1]:
				var xp_receipt := heroes.award_xp(
					state, beneficiary, handoff.get("position_mt", []).duplicate(),
					int(handoff.get("xp_bounty", 0))
				)
				if bool(xp_receipt.get("accepted", false)):
					_hero_progress = true
			_neutral_progress = true

	for camp_id: String in state.neutrals.sorted_camp_ids():
		var result := neutrals.resolve_camp_clear(_running_tick, camp_id)
		if not bool(result.get("cleared", false)):
			continue
		for handoff_variant: Variant in result.get("handoffs", []):
			var handoff: Dictionary = handoff_variant
			match str(handoff.get("kind", "")):
				"award_camp_clear_gold":
					if economy != null:
						var receipt := economy.apply_external_resource_delta(
							state, int(handoff["owner_seat"]), int(handoff["amount"]), 0,
							"camp_clear", camp_id
						)
						_economy_progress = bool(receipt.get("accepted", false)) \
							or _economy_progress
				"spawn_ground_item":
					if heroes != null:
						var drop: Dictionary = handoff["drop"]
						var receipt := heroes.spawn_ground_item(
							state, str(drop["item_type_id"]), drop["position_mt"].duplicate(),
							_running_tick, int(drop["despawn_tick"]), str(drop["drop_id"])
						)
						_hero_progress = bool(receipt.get("accepted", false)) \
							or _hero_progress
		_neutral_progress = true


func _neutral_membership(state: StateRecord, entity_id: int) -> Dictionary:
	if not state.neutrals.enabled:
		return {}
	for camp_id: String in state.neutrals.sorted_camp_ids():
		var members: Dictionary = state.neutrals.camps[camp_id]["members"]
		var member_ids: Array = members.keys()
		member_ids.sort()
		for member_id_variant: Variant in member_ids:
			var member_id := str(member_id_variant)
			if int(members[member_id].get("internal_id", 0)) == entity_id:
				return {"camp_id": camp_id, "member_id": member_id}
	return {}


func _advance_abilities(state: StateRecord, phase: String, phase_id: int) -> void:
	if abilities == null or ability_effects == null or not state.abilities.enabled \
		or _simulation == null:
		return
	var result := ability_effects.advance_phase(_simulation, abilities, phase)
	for message: Variant in result.get("errors", []):
		_queue_event(
			phase_id, "ability_authority_error", 0, 0, {"message": str(message)}
		)
	if phase == "activation":
		var trigger_result: Dictionary = abilities.resolve_armed_triggers(_simulation)
		for message: Variant in trigger_result.get("errors", []):
			_queue_event(
				phase_id, "ability_authority_error", 0, 0,
				{"message": str(message)}
			)
		abilities.prune_illegal_persistent_visibility_statuses(_simulation)
	_drain_ability_events(phase_id)


func _drain_ability_events(phase: int) -> void:
	if abilities != null:
		while _ability_event_cursor < abilities.state.events.size():
			var source: Dictionary = abilities.state.events[_ability_event_cursor]
			_ability_event_cursor += 1
			var payload: Dictionary = source.get("payload", {}).duplicate(true)
			payload["ability_event_seq"] = int(source.get("event_seq", 0))
			_queue_event(
				phase, str(source.get("kind", "ability_event")),
				int(source.get("source_id", 0)), int(source.get("target_id", 0)), payload
			)
	if ability_effects != null:
		for source: Dictionary in ability_effects.take_events():
			_queue_event(
				phase, str(source.get("event_kind", "ability_effect")),
				int(source.get("source_internal_id", 0)),
				int(source.get("target_internal_id", 0)),
				source.get("payload", {}).duplicate(true)
			)


func _queue_event(
	phase: int,
	kind: String,
	source_id: int,
	target_id: int,
	payload: Dictionary
) -> void:
	var event := EventRecord.new(_running_tick, phase, kind)
	event.source_internal_id = source_id
	event.target_internal_id = target_id
	event.payload = payload
	_pending_events.append({"event": event, "local_seq": _event_local_seq})
	_event_local_seq += 1


func _emit_events(state: StateRecord) -> void:
	_pending_events.sort_custom(_event_record_less)
	for record: Dictionary in _pending_events:
		var event: EventRecord = record["event"]
		state.append_event(event)
	_pending_events.clear()


func _drain_economy_events(phase: int) -> void:
	for event: Dictionary in economy.take_events():
		if str(event.get("event_kind", "")) == "production_completed" \
			and _simulation != null:
			var registration_errors: PackedStringArray = \
				_simulation.register_completed_mobile_authorities(
					int(event.get("target_internal_id", 0)),
					str((event.get("payload", {}) as Dictionary).get("kind", "unit"))
				)
			for message: String in registration_errors:
				_queue_event(
					phase, "spawn_authority_error",
					int(event.get("source_internal_id", 0)),
					int(event.get("target_internal_id", 0)),
					{"message": message}
				)
		_queue_event(
			phase,
			str(event["event_kind"]),
			int(event["source_internal_id"]),
			int(event["target_internal_id"]),
			event["payload"]
		)


func _drain_combat_events(state: StateRecord) -> void:
	for event: Dictionary in combat.take_events():
		_attribute_neutral_damage(state, event)
		_queue_event(
			int(event["phase"]),
			str(event["event_kind"]),
			int(event["source_internal_id"]),
			int(event["target_internal_id"]),
			event["payload"]
		)


func _attribute_neutral_damage(state: StateRecord, event: Dictionary) -> void:
	if neutrals == null or not state.neutrals.enabled \
		or str(event.get("event_kind", "")) not in ["attack_impacted", "effect_impacted"]:
		return
	var payload: Dictionary = event.get("payload", {})
	var hp_damage := int(payload.get("hp_damage", 0))
	var source_id := int(event.get("source_internal_id", 0))
	var target_id := int(event.get("target_internal_id", 0))
	if hp_damage <= 0 or not state.entities.has(source_id) or not state.entities.has(target_id):
		return
	var source: EntityRecord = state.entities[source_id]
	if source.owner_seat not in [0, 1]:
		return
	var membership := _neutral_membership(state, target_id)
	if membership.is_empty():
		return
	var command_digest := ""
	if source.active_order_id != 0 and state.orders.has(source.active_order_id):
		command_digest = str(state.orders[source.active_order_id].command_digest)
	if command_digest.length() != 64:
		command_digest = Codec.sha256_canonical({
			"event": event,
			"source_id": source_id,
			"target_id": target_id,
			"tick": _running_tick,
		})
	var errors := neutrals.record_camp_damage(
		str(membership["camp_id"]), source.owner_seat, source_id, hp_damage, command_digest
	)
	for message: String in errors:
		_queue_event(
			int(event.get("phase", Rules.TickPhase.RESOLVE_IMPACTS)),
			"neutral_authority_error", source_id, target_id, {"message": message}
		)
	if errors.is_empty():
		neutrals.note_member_damaged(
			str(membership["camp_id"]), str(membership["member_id"]), _running_tick
		)
		var target: EntityRecord = state.entities[target_id]
		target.integer_attributes["last_damage_owner_seat"] = source.owner_seat
		target.integer_attributes["last_damage_source_id"] = source_id
		_neutral_progress = true


func _drain_combat_deltas() -> void:
	for delta_variant: Variant in combat.take_deltas():
		_pending_deltas.append(delta_variant)


func _drain_movement_events() -> void:
	for event: Dictionary in movement.take_events():
		_queue_event(
			int(event["phase"]),
			str(event["event_kind"]),
			int(event["source_internal_id"]),
			int(event["target_internal_id"]),
			event["payload"]
		)


func _drain_hero_events(phase: int) -> void:
	for event: Dictionary in heroes.take_events():
		_queue_event(
			phase,
			str(event["event_kind"]),
			int(event["source_internal_id"]),
			int(event["target_internal_id"]),
			event["payload"]
		)


func _drain_terminal_events() -> void:
	for event: Dictionary in terminal.take_events():
		_queue_event(
			Rules.TickPhase.TEST_TERMINAL,
			str(event["event_kind"]),
			int(event["source_internal_id"]),
			int(event["target_internal_id"]),
			event["payload"]
		)


func _drain_neutral_events(phase: int) -> void:
	if neutrals == null or not neutrals.state.enabled:
		return
	while _neutral_event_cursor < neutrals.state.events.size():
		var source: Dictionary = neutrals.state.events[_neutral_event_cursor]
		_neutral_event_cursor += 1
		var payload: Dictionary = source.get("payload", {}).duplicate(true)
		payload["neutral_event_seq"] = int(source.get("event_seq", 0))
		payload["neutral_source_id"] = str(source.get("source_id", ""))
		payload["neutral_target_id"] = str(source.get("target_id", ""))
		_queue_event(
			phase, str(source.get("event_kind", "neutral_event")), 0, 0, payload
		)


static func _delta_less_variant(left_variant: Variant, right_variant: Variant) -> bool:
	var left: DeltaRecord = left_variant
	var right: DeltaRecord = right_variant
	var left_key: Array[int] = [
		left.application_tick, left.entity_id, left.kind, left.source_internal_id, left.local_seq,
	]
	var right_key: Array[int] = [
		right.application_tick, right.entity_id, right.kind, right.source_internal_id, right.local_seq,
	]
	for index: int in left_key.size():
		if left_key[index] != right_key[index]:
			return left_key[index] < right_key[index]
	if left.attribute_key != right.attribute_key:
		return left.attribute_key < right.attribute_key
	return false


static func _aggregate_key_less(left: Variant, right: Variant, descriptors: Dictionary) -> bool:
	var left_descriptor: Dictionary = descriptors[left]
	var right_descriptor: Dictionary = descriptors[right]
	for field: String in ["entity_id", "kind"]:
		var left_value := int(left_descriptor[field])
		var right_value := int(right_descriptor[field])
		if left_value != right_value:
			return left_value < right_value
	return str(left_descriptor["attribute_key"]) < str(right_descriptor["attribute_key"])


static func _event_record_less(left: Dictionary, right: Dictionary) -> bool:
	var left_event: EventRecord = left["event"]
	var right_event: EventRecord = right["event"]
	for field: String in ["phase", "source_internal_id", "target_internal_id"]:
		var left_value: int = left_event.get(field)
		var right_value: int = right_event.get(field)
		if left_value != right_value:
			return left_value < right_value
	if left_event.event_kind != right_event.event_kind:
		return left_event.event_kind < right_event.event_kind
	return int(left["local_seq"]) < int(right["local_seq"])
