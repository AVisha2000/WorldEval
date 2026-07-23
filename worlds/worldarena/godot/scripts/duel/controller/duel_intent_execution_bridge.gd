class_name DuelIntentExecutionBridge
extends RefCounted

const Contract := preload("res://scripts/duel/actions/duel_action_contract.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const OrderRecord := preload("res://scripts/duel/simulation/duel_order.gd")
const ContestResolver := preload("res://scripts/duel/controller/duel_contest_resolver.gd")

## Explicit compiled-intent -> authoritative subsystem bridge.
##
## This is intentionally not reflective.  Every compiler operation reaches a
## named branch, and every public action operation appears in dispatch_coverage.
## No receipt is allowed to contain an internal entity/order/queue/contest ID.

const INTENT_FIELDS: Array[String] = [
	"apply_tick", "intent_digest", "intent_id", "intent_type", "operation",
	"owner_seat", "parameters", "queue_policy", "source", "subject", "target",
]
const SOURCE_FIELDS: Array[String] = [
	"batch_id", "command_digest", "command_id", "command_index", "expansion_index",
	"match_id", "observation_seq",
]
const COMPILED_ONLY_OPERATIONS: Array[String] = ["hold_area", "patrol_points"]
const ORDER_OPERATIONS: Array[String] = [
	"attack_entity", "attack_ground", "attack_move", "follow", "hold_area", "hold_position",
	"move", "patrol", "patrol_points", "retreat", "stop",
]
const UNSUPPORTED_EXECUTION: Dictionary = {}

var squads: Dictionary = {}
var tactics_by_actor: Dictionary = {}
var rally_by_producer: Dictionary = {}
var autocast_by_actor: Dictionary = {}
var transport_manifests: Dictionary = {}
var pending_append_order_ids: Dictionary = {}
var _actor_public_aliases: Dictionary = {}
var _applied_intent_ids: Dictionary = {}
var _protected_contest_audit: Array[Dictionary] = []
var _build_groups: Dictionary = {}
var _build_group_results: Dictionary = {}
var _services: Dictionary = {}


func execute(
	simulation: Variant,
	intents_input: Array[Dictionary],
	resolution_context: DuelIntentResolutionContext,
	services: Dictionary = {}
) -> Dictionary:
	var top_errors := PackedStringArray()
	if simulation == null or not bool(simulation.get("is_ready")):
		top_errors.append("intent bridge requires a ready DuelSimulation")
	if resolution_context == null or not resolution_context.is_configured():
		top_errors.append("intent bridge requires a configured closed resolution context")
	for key_variant: Variant in services.keys():
		if str(key_variant) not in ["abilities", "neutral_market"]:
			top_errors.append("intent bridge service is not allowed: %s" % str(key_variant))
	if not top_errors.is_empty():
		return {"errors": top_errors, "ok": false, "protected_contest_audit": [], "receipts": []}

	var intents: Array[Dictionary] = []
	_services = services.duplicate()
	for intent_input: Dictionary in intents_input:
		intents.append(intent_input.duplicate(true))
	intents.sort_custom(_intent_less)
	var prepass_intents: Array[Dictionary] = []
	var prepass_seen: Dictionary = {}
	for intent: Dictionary in intents:
		var intent_id := str(intent.get("intent_id", "invalid"))
		if _applied_intent_ids.has(intent_id) or prepass_seen.has(intent_id):
			continue
		prepass_seen[intent_id] = true
		prepass_intents.append(intent)
	_build_groups = _group_build_intents(prepass_intents)
	_build_group_results.clear()
	var audit_start: int = _protected_contest_audit.size()
	var contest_result := _resolve_local_contests(simulation, prepass_intents, resolution_context)
	if not (contest_result["errors"] as PackedStringArray).is_empty():
		return {
			"errors": contest_result["errors"], "ok": false,
			"protected_contest_audit": contest_result["audit"], "receipts": [],
		}
	_protected_contest_audit.append_array(contest_result["audit"])
	var local_rejections: Dictionary = contest_result["rejected_intent_ids"]
	var market_results := _resolve_market_purchase_batch(
		simulation, prepass_intents, resolution_context, services.get("neutral_market", null)
	)
	_protected_contest_audit.append_array(market_results["audit"])

	var receipts: Array[Dictionary] = []
	for intent: Dictionary in intents:
		var intent_id := str(intent.get("intent_id", "invalid"))
		var code := _intent_code(intent)
		if not code.is_empty():
			receipts.append(_receipt(intent, "rejected", code, {}, resolution_context))
			continue
		if _applied_intent_ids.has(intent_id):
			receipts.append(_receipt(intent, "rejected", "conflicting_order", {}, resolution_context))
			continue
		if local_rejections.has(intent_id):
			receipts.append(_receipt(intent, "rejected", "target_unavailable", {}, resolution_context))
			_applied_intent_ids[intent_id] = true
			continue
		if str(intent["operation"]) == "purchase_offer":
			var market_outcome: Dictionary = market_results["outcomes"].get(
				intent_id, _outcome(false, "execution_failed", {})
			)
			receipts.append(_receipt_from_outcome(intent, market_outcome, resolution_context))
			_applied_intent_ids[intent_id] = true
			continue
		var outcome := _dispatch(simulation, intent, resolution_context)
		receipts.append(_receipt_from_outcome(intent, outcome, resolution_context))
		_applied_intent_ids[intent_id] = true

	return {
		"controller_state": to_canonical_dict(),
		"errors": top_errors,
		"ok": true,
		"protected_contest_audit": _protected_contest_audit.slice(audit_start).duplicate(true),
		"receipts": receipts,
	}


func activate_pending_appends(simulation: Variant) -> PackedStringArray:
	## Integration hook for phase 1: when an actor has no active order, release
	## exactly the first append order.  Until DuelTickLedger calls this hook,
	## replace/front orders are fully live and append orders remain safely queued.
	var errors := PackedStringArray()
	if simulation == null or not bool(simulation.get("is_ready")):
		errors.append("intent bridge requires a ready DuelSimulation")
		return errors
	var actor_ids: Array = pending_append_order_ids.keys()
	actor_ids.sort()
	for actor_variant: Variant in actor_ids:
		var actor_id := int(actor_variant)
		if not simulation.state.entities.has(actor_id):
			pending_append_order_ids.erase(actor_id)
			continue
		var actor: Variant = simulation.state.entities[actor_id]
		if int(actor.active_order_id) != 0 \
			and simulation.state.orders.has(int(actor.active_order_id)) \
			and int(simulation.state.orders[int(actor.active_order_id)].status) \
			== OrderRecord.Status.ACTIVE:
			continue
		var queue: Array = pending_append_order_ids[actor_id]
		while not queue.is_empty():
			var order_id := int(queue.pop_front())
			if not simulation.state.orders.has(order_id):
				continue
			var order: OrderRecord = simulation.state.orders[order_id]
			if order.status == OrderRecord.Status.QUEUED:
				order.activation_tick = simulation.state.tick
				break
		if queue.is_empty():
			pending_append_order_ids.erase(actor_id)
		else:
			pending_append_order_ids[actor_id] = queue
	return errors


func protected_contest_audit() -> Array[Dictionary]:
	return _protected_contest_audit.duplicate(true)


func to_canonical_dict() -> Dictionary:
	return {
		"autocast_by_actor": _sorted_nested_dictionary(autocast_by_actor),
		"pending_append_order_ids": _canonical_pending_appends(),
		"rally_by_producer": _sorted_nested_dictionary(rally_by_producer),
		"squads": _sorted_nested_dictionary(squads),
		"tactics_by_actor": _sorted_nested_dictionary(tactics_by_actor),
		"transport_manifests": _canonical_transport_manifests(),
	}


static func dispatch_coverage() -> Dictionary:
	## Values describe the execution owner; keys are asserted against the locked
	## action contract by the headless runner.
	return {
		"attack_entity": "core_order_combat",
		"attack_ground": "core_order_ground_projectile_area",
		"attack_move": "core_order_movement",
		"build": "economy",
		"cancel_construction": "economy",
		"cancel_queue": "economy",
		"cast": "ability_service",
		"define_squad": "controller_state",
		"disband_squad": "controller_state",
		"drop_item": "heroes",
		"follow": "core_order_movement",
		"gather": "economy",
		"hold_position": "core_order_movement",
		"learn_ability": "heroes",
		"load_transport": "controller_transport",
		"move": "core_order_movement",
		"order_squad": "compiler_expands_to_core_orders",
		"patrol": "core_order_movement",
		"pick_up_item": "heroes_exclusive_claim",
		"produce": "economy",
		"purchase_offer": "neutral_market_exclusive_claim",
		"repair": "economy",
		"research": "economy",
		"retreat": "core_order_movement",
		"return_cargo": "economy",
		"revive_hero": "heroes_exclusive_claim",
		"sell_item": "heroes",
		"set_autocast": "ability_service_and_controller_state",
		"set_rally": "controller_state",
		"set_stance": "controller_state",
		"set_tactics": "controller_state",
		"stop": "core_order_movement",
		"transfer_item": "heroes",
		"unload_transport": "controller_transport",
		"update_squad": "controller_state",
		"upgrade_tier": "economy",
		"use_item": "heroes",
	}


func _dispatch(
	simulation: Variant,
	intent: Dictionary,
	context: DuelIntentResolutionContext
) -> Dictionary:
	var operation := str(intent["operation"])
	if UNSUPPORTED_EXECUTION.has(operation):
		return _unsupported(str(UNSUPPORTED_EXECUTION[operation]))
	if operation in ORDER_OPERATIONS:
		return _execute_order(simulation, intent, context)
	match operation:
		"build":
			return _execute_build_group(simulation, intent, context)
		"cancel_construction":
			return _execute_cancel_construction(simulation, intent, context)
		"cancel_queue":
			return _execute_cancel_queue(simulation, intent, context)
		"cast":
			return _execute_cast(simulation, intent, context)
		"define_squad":
			return _execute_define_squad(simulation, intent, context, false)
		"disband_squad":
			return _execute_disband_squad(intent)
		"drop_item":
			return _execute_drop_item(simulation, intent, context)
		"gather":
			return _execute_gather(simulation, intent, context)
		"learn_ability":
			return _execute_learn_ability(simulation, intent, context)
		"load_transport":
			return _execute_load_transport(simulation, intent, context)
		"pick_up_item":
			return _execute_pick_up_item(simulation, intent, context)
		"produce":
			return _execute_produce(simulation, intent, context)
		"repair":
			return _execute_repair(simulation, intent, context)
		"research":
			return _execute_research(simulation, intent, context)
		"return_cargo":
			return _execute_return_cargo(simulation, intent, context)
		"revive_hero":
			return _execute_revive_hero(simulation, intent, context)
		"sell_item":
			return _execute_sell_item(simulation, intent, context)
		"set_autocast":
			return _execute_set_autocast(simulation, intent, context)
		"set_rally":
			return _execute_set_rally(simulation, intent, context)
		"set_stance", "set_tactics":
			return _execute_tactics(simulation, intent, context)
		"transfer_item":
			return _execute_transfer_item(simulation, intent, context)
		"unload_transport":
			return _execute_unload_transport(simulation, intent, context)
		"update_squad":
			return _execute_define_squad(simulation, intent, context, true)
		"upgrade_tier":
			return _execute_upgrade_tier(simulation, intent, context)
		"use_item":
			return _execute_use_item(simulation, intent, context)
	return _outcome(false, "unsupported_operation", {})


func _execute_order(
	simulation: Variant,
	intent: Dictionary,
	context: DuelIntentResolutionContext
) -> Dictionary:
	var subject := _resolve_owned_subject(simulation, intent, context)
	if not bool(subject.get("ok", false)):
		return _outcome(false, str(subject["code"]), {})
	var target: Dictionary = {}
	if not (intent["target"] as Dictionary).is_empty():
		var resolved_target := context.resolve_target(intent["target"])
		if not bool(resolved_target.get("ok", false)):
			return _outcome(false, str(resolved_target["code"]), {})
		target = _core_target(resolved_target)
	var parameters: Dictionary = intent["parameters"]
	if str(intent["operation"]) in ["patrol", "patrol_points"]:
		var patrol_targets: Array = []
		var raw_targets: Array = parameters.get("targets", [])
		if raw_targets.is_empty() and not target.is_empty():
			raw_targets = [intent["target"]]
		for raw_target: Variant in raw_targets:
			var resolved := context.resolve_target(raw_target)
			if not bool(resolved.get("ok", false)):
				return _outcome(false, str(resolved["code"]), {})
			patrol_targets.append(_core_target(resolved))
		target = {"targets": patrol_targets}
	for field: String in ["distance_mt", "engagement", "formation", "objective", "squad_id"]:
		if parameters.has(field):
			target[field] = parameters[field]
	var order_kind := str(intent["operation"])
	if order_kind == "attack_ground":
		if str(target.get("kind", "")) != "point" \
			or typeof(target.get("xy_mt", null)) != TYPE_ARRAY:
			return _outcome(false, "invalid_target", {})
		var ground_code: String = simulation.combat.ground_attack_request_code(
			simulation.state, int(subject["internal_id"]), target["xy_mt"]
		)
		if not ground_code.is_empty():
			return _outcome(false, ground_code, {})
	if order_kind == "hold_area":
		order_kind = "hold_position"
	elif order_kind == "patrol_points":
		order_kind = "patrol"
	return _queue_core_order(
		simulation, intent, int(subject["internal_id"]), str(subject["public_id"]),
		order_kind, target
	)


func _queue_core_order(
	simulation: Variant,
	intent: Dictionary,
	actor_id: int,
	actor_public_id: String,
	order_kind: String,
	target: Dictionary
) -> Dictionary:
	_actor_public_aliases[actor_id] = actor_public_id
	var queue_policy := str(intent["queue_policy"])
	if queue_policy in ["replace", "front"]:
		_cancel_open_orders(simulation, actor_id)
		pending_append_order_ids.erase(actor_id)
	var order := OrderRecord.new(0, int(intent["owner_seat"]), actor_id, order_kind)
	order.issued_tick = simulation.state.tick
	order.activation_tick = maxi(simulation.state.tick, int(intent["apply_tick"]))
	order.command_index = int(intent["source"]["command_index"])
	order.command_digest = str(intent["source"]["command_digest"])
	order.target = target.duplicate(true)
	if queue_policy == "append":
		order.activation_tick = 2_147_483_647
	var order_id := int(simulation.queue_order(order))
	if order_id <= 0:
		return _outcome(false, "execution_failed", {})
	if queue_policy == "append":
		var pending: Array = pending_append_order_ids.get(actor_id, [])
		pending.append(order_id)
		pending_append_order_ids[actor_id] = pending
	return _outcome(true, "accepted", {
		"actor_id": actor_public_id,
		"order_ref": _public_runtime_ref("order", intent),
		"queued": queue_policy == "append",
	})


func _execute_build_group(
	simulation: Variant,
	intent: Dictionary,
	context: DuelIntentResolutionContext
) -> Dictionary:
	var group_id := str(intent["parameters"].get("construction_group_id", intent["intent_id"]))
	if _build_group_results.has(group_id):
		return (_build_group_results[group_id] as Dictionary).duplicate(true)
	var group: Array = _build_groups.get(group_id, [intent])
	var workers: Array[int] = []
	var public_workers: Array[String] = []
	for group_intent_variant: Variant in group:
		var group_intent: Dictionary = group_intent_variant
		var worker := _resolve_owned_subject(simulation, group_intent, context)
		if not bool(worker.get("ok", false)):
			var failed := _outcome(false, str(worker["code"]), {})
			_build_group_results[group_id] = failed
			return failed
		workers.append(int(worker["internal_id"]))
		public_workers.append(str(worker["public_id"]))
	workers.sort()
	public_workers.sort()
	var site := context.resolve_target(intent["target"])
	if not bool(site.get("ok", false)) or str(site.get("kind", "")) != "site":
		var site_failed := _outcome(false, str(site.get("code", "invalid_target")), {})
		_build_group_results[group_id] = site_failed
		return site_failed
	var raw: Dictionary = simulation.economy.begin_construction(
		simulation.state, simulation.grid, int(intent["owner_seat"]),
		str(intent["parameters"]["building_type_id"]), str(site["site_id"]),
		int(site["xy_mt"][0]), int(site["xy_mt"][1]), workers
	)
	var outcome := _from_subsystem_receipt(raw, {
		"building_ref": _public_runtime_ref("entity", intent),
		"building_type_id": str(intent["parameters"]["building_type_id"]),
		"builders": public_workers,
		"site_id": str(site["site_id"]),
	})
	_build_group_results[group_id] = outcome
	return outcome.duplicate(true)


func _execute_cancel_construction(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var subject := _resolve_owned_subject(simulation, intent, context)
	if not bool(subject.get("ok", false)):
		return _outcome(false, str(subject["code"]), {})
	var raw: Dictionary = simulation.economy.cancel_construction(
		simulation.state, simulation.grid, int(intent["owner_seat"]), int(subject["internal_id"])
	)
	return _from_subsystem_receipt(raw, {"building_id": str(subject["public_id"])})


func _execute_cancel_queue(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var producer := _resolve_owned_subject(simulation, intent, context)
	if not bool(producer.get("ok", false)):
		return _outcome(false, str(producer["code"]), {})
	var public_entry_id := str(intent["parameters"]["queue_entry_id"])
	var entry := context.resolve_queue_entry(public_entry_id, str(producer["public_id"]))
	if not bool(entry.get("ok", false)):
		return _outcome(false, str(entry["code"]), {})
	var raw: Dictionary = simulation.economy.cancel_queue_entry(
		simulation.state, int(intent["owner_seat"]), int(producer["internal_id"]),
		int(entry["internal_entry_id"])
	)
	return _from_subsystem_receipt(raw, {
		"producer_id": str(producer["public_id"]), "queue_entry_id": public_entry_id,
	})


func _execute_gather(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var worker := _resolve_owned_subject(simulation, intent, context)
	if not bool(worker.get("ok", false)):
		return _outcome(false, str(worker["code"]), {})
	var resource := context.resolve_target(intent["target"])
	if not bool(resource.get("ok", false)) or str(resource.get("kind", "")) != "entity":
		return _outcome(false, str(resource.get("code", "invalid_target")), {})
	var deposit := context.default_deposit_for_seat(int(intent["owner_seat"]))
	if not bool(deposit.get("ok", false)):
		return _outcome(false, str(deposit["code"]), {})
	var travel := context.gather_travel_ticks()
	var worker_ids: Array[int] = []
	worker_ids.append(int(worker["internal_id"]))
	var raw: Dictionary = simulation.economy.assign_gather(
		simulation.state, int(intent["owner_seat"]), worker_ids,
		int(resource["internal_id"]), int(deposit["internal_id"]),
		int(travel["to_resource"]), int(travel["return"])
	)
	return _from_subsystem_receipt(raw, {
		"deposit_id": str(deposit["public_id"]), "resource_target": resource["public"],
		"worker_id": str(worker["public_id"]),
	})


func _execute_return_cargo(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var worker := _resolve_owned_subject(simulation, intent, context)
	if not bool(worker.get("ok", false)):
		return _outcome(false, str(worker["code"]), {})
	var deposit: Dictionary
	if (intent["target"] as Dictionary).is_empty():
		deposit = context.default_deposit_for_seat(int(intent["owner_seat"]))
	else:
		deposit = context.resolve_target(intent["target"])
	if not bool(deposit.get("ok", false)):
		return _outcome(false, str(deposit["code"]), {})
	var worker_ids: Array[int] = []
	worker_ids.append(int(worker["internal_id"]))
	var raw: Dictionary = simulation.economy.return_cargo(
		simulation.state, int(intent["owner_seat"]), worker_ids,
		int(deposit["internal_id"])
	)
	return _from_subsystem_receipt(raw, {
		"deposit_id": _resolved_public_entity_id(deposit), "worker_id": str(worker["public_id"]),
	})


func _execute_repair(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var worker := _resolve_owned_subject(simulation, intent, context)
	if not bool(worker.get("ok", false)):
		return _outcome(false, str(worker["code"]), {})
	var building := context.resolve_target(intent["target"])
	if not bool(building.get("ok", false)) or str(building.get("kind", "")) != "entity":
		return _outcome(false, str(building.get("code", "invalid_target")), {})
	var worker_ids: Array[int] = []
	worker_ids.append(int(worker["internal_id"]))
	var raw: Dictionary = simulation.economy.assign_repair(
		simulation.state, int(intent["owner_seat"]), int(building["internal_id"]),
		worker_ids
	)
	return _from_subsystem_receipt(raw, {
		"building_id": _resolved_public_entity_id(building), "worker_id": str(worker["public_id"]),
	})


func _execute_produce(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var producer := _resolve_owned_subject(simulation, intent, context)
	if not bool(producer.get("ok", false)):
		return _outcome(false, str(producer["code"]), {})
	var type_id := str(intent["parameters"]["unit_type_id"])
	var hero_definitions: Dictionary = simulation.heroes.catalog.get("faction", {}).get("heroes", {}) \
		if not simulation.heroes.catalog.is_empty() else {}
	if hero_definitions.has(type_id):
		var raw_hero: Dictionary = simulation.economy.queue_hero_production(
			simulation.state, int(intent["owner_seat"]), int(producer["internal_id"]),
			type_id, hero_definitions[type_id],
			simulation.heroes.catalog["rules"]["heroes"]
		)
		return _from_subsystem_receipt(raw_hero, {
			"producer_id": str(producer["public_id"]),
			"quantity_index": int(intent["parameters"].get("quantity_index", 0)),
			"unit_type_id": type_id,
		})
	var raw: Dictionary = simulation.economy.queue_production(
		simulation.state, int(intent["owner_seat"]), int(producer["internal_id"]),
		type_id, 1
	)
	return _from_subsystem_receipt(raw, {
		"producer_id": str(producer["public_id"]),
		"quantity_index": int(intent["parameters"].get("quantity_index", 0)),
		"unit_type_id": type_id,
	})


func _execute_research(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var producer := _resolve_owned_subject(simulation, intent, context)
	if not bool(producer.get("ok", false)):
		return _outcome(false, str(producer["code"]), {})
	var raw: Dictionary = simulation.economy.queue_upgrade(
		simulation.state, int(intent["owner_seat"]), int(producer["internal_id"]),
		str(intent["parameters"]["upgrade_id"])
	)
	return _from_subsystem_receipt(raw, {
		"producer_id": str(producer["public_id"]),
		"queue_entry_ref": _public_runtime_ref("queue", intent),
		"upgrade_id": str(intent["parameters"]["upgrade_id"]),
	})


func _execute_upgrade_tier(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var stronghold := _resolve_owned_subject(simulation, intent, context)
	if not bool(stronghold.get("ok", false)):
		return _outcome(false, str(stronghold["code"]), {})
	var raw: Dictionary = simulation.economy.queue_tier_upgrade(
		simulation.state, int(intent["owner_seat"]), int(stronghold["internal_id"]),
		int(intent["parameters"]["target_tier"])
	)
	return _from_subsystem_receipt(raw, {
		"queue_entry_ref": _public_runtime_ref("queue", intent),
		"stronghold_id": str(stronghold["public_id"]),
		"target_tier": int(intent["parameters"]["target_tier"]),
	})


func _execute_learn_ability(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var hero := _resolve_owned_subject(simulation, intent, context)
	if not bool(hero.get("ok", false)):
		return _outcome(false, str(hero["code"]), {})
	var raw: Dictionary = simulation.heroes.learn_ability(
		simulation.state, int(intent["owner_seat"]), int(hero["internal_id"]),
		str(intent["parameters"]["ability_id"])
	)
	return _from_hero_receipt(raw, {
		"ability_id": str(intent["parameters"]["ability_id"]), "hero_id": str(hero["public_id"]),
	})


func _execute_cast(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var actor := _resolve_owned_subject(simulation, intent, context)
	if not bool(actor.get("ok", false)):
		return _outcome(false, str(actor["code"]), {})
	var ability_service: Variant = _services.get("abilities", null)
	if ability_service == null:
		return _unsupported("ability service is not configured")
	var target: Dictionary = {}
	if not (intent["target"] as Dictionary).is_empty():
		var resolved := context.resolve_target(intent["target"])
		if not bool(resolved.get("ok", false)):
			return _outcome(false, str(resolved["code"]), {})
		match str(resolved["kind"]):
			"entity":
				target = {"entity_id": int(resolved["internal_id"]), "kind": "entity"}
			"site":
				target = {
					"kind": "site", "position_mt": (resolved["xy_mt"] as Array).duplicate(),
					"site_id": str(resolved["site_id"]),
				}
			"point", "region_slot":
				target = {"kind": "point", "position_mt": (resolved["xy_mt"] as Array).duplicate()}
	var actor_id := int(actor["internal_id"])
	var ability_id := str(intent["parameters"]["ability_id"])
	var completed_upgrades: Array[String] = []
	if simulation.state.economy.players.has(int(intent["owner_seat"])):
		var completed: Dictionary = simulation.state.economy.players[int(intent["owner_seat"])].get(
			"completed_upgrades", {}
		)
		for upgrade_variant: Variant in completed.keys():
			if int(completed[upgrade_variant]) > 0:
				completed_upgrades.append(str(upgrade_variant))
		completed_upgrades.sort()
	var request := {
		"actor_type_id": str(simulation.state.entities[actor_id].catalog_id),
		"completed_upgrade_ids": completed_upgrades,
		"owner_seat": int(intent["owner_seat"]),
		"rank": _ability_rank(simulation, actor_id, ability_id),
	}
	var raw: Dictionary = ability_service.execute_cast(
		simulation, actor_id, ability_id, target, request
	)
	var details: Dictionary = raw.get("details", {})
	var public_result := {
		"ability_id": ability_id,
		"actor_id": str(actor["public_id"]),
	}
	if bool(raw.get("accepted", false)):
		public_result["cast_ref"] = _public_runtime_ref("cast", intent)
	for field: String in ["cooldown_until_tick", "mana_cost", "rank"]:
		if raw.has(field) and typeof(raw[field]) == TYPE_INT:
			public_result[field] = int(raw[field])
	for field: String in ["commit_tick", "rank"]:
		if details.has(field) and typeof(details[field]) == TYPE_INT:
			public_result[field] = int(details[field])
	return _outcome(
		bool(raw.get("accepted", false)), str(raw.get("code", "execution_failed")), public_result
	)


func _execute_revive_hero(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var reviver := _resolve_owned_subject(simulation, intent, context)
	if not bool(reviver.get("ok", false)):
		return _outcome(false, str(reviver["code"]), {})
	var hero := context.resolve_entity(intent["parameters"]["hero"], int(intent["owner_seat"]))
	if not bool(hero.get("ok", false)):
		return _outcome(false, str(hero["code"]), {})
	if not _state_entity_matches(simulation, hero, int(intent["owner_seat"]), false):
		return _outcome(false, "reference_mismatch", {})
	var method := str(intent["parameters"]["revival_method"])
	var raw: Dictionary
	if method == "altar":
		raw = simulation.heroes.start_altar_revival(
			simulation.state, int(intent["owner_seat"]), int(reviver["internal_id"]),
			int(hero["internal_id"]), simulation.state.tick
		)
	else:
		var tavern := context.field_revival_tavern_for_seat(int(intent["owner_seat"]))
		if not bool(tavern.get("ok", false)) \
			or not _state_entity_matches(simulation, tavern, -1, true):
			return _outcome(false, str(tavern.get("code", "target_unavailable")), {})
		raw = simulation.heroes.field_revive(
			simulation.state, simulation.grid, int(intent["owner_seat"]),
			int(tavern["internal_id"]), int(hero["internal_id"]), simulation.state.tick
		)
	return _from_hero_receipt(raw, {
		"hero_id": str(hero["public_id"]), "method": method,
		"reviver_id": str(reviver["public_id"]),
	})


func _execute_drop_item(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var hero := _resolve_owned_subject(simulation, intent, context)
	if not bool(hero.get("ok", false)):
		return _outcome(false, str(hero["code"]), {})
	var target := context.resolve_target(intent["target"])
	if not bool(target.get("ok", false)) or str(target.get("kind", "")) != "point":
		return _outcome(false, str(target.get("code", "invalid_target")), {})
	var raw: Dictionary = simulation.heroes.drop_item(
		simulation.state, int(hero["internal_id"]),
		str(intent["parameters"]["item_instance_id"]), target["xy_mt"], simulation.state.tick
	)
	return _from_hero_receipt(raw, {
		"ground_item_ref": _public_runtime_ref("entity", intent),
		"hero_id": str(hero["public_id"]),
		"item_instance_id": str(intent["parameters"]["item_instance_id"]),
	})


func _execute_pick_up_item(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var hero := _resolve_owned_subject(simulation, intent, context)
	if not bool(hero.get("ok", false)):
		return _outcome(false, str(hero["code"]), {})
	var item := context.resolve_target(intent["target"])
	if not bool(item.get("ok", false)) or str(item.get("kind", "")) != "entity":
		return _outcome(false, str(item.get("code", "invalid_target")), {})
	var raw: Dictionary = simulation.heroes.pick_up_item(
		simulation.state, int(hero["internal_id"]), int(item["internal_id"])
	)
	return _from_hero_receipt(raw, {
		"hero_id": str(hero["public_id"]), "item_entity": item["public"],
	})


func _execute_transfer_item(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var source := _resolve_owned_subject(simulation, intent, context)
	if not bool(source.get("ok", false)):
		return _outcome(false, str(source["code"]), {})
	var target := context.resolve_entity(intent["parameters"]["to_hero"], int(intent["owner_seat"]))
	if not bool(target.get("ok", false)) or not _state_entity_matches(
		simulation, target, int(intent["owner_seat"]), true
	):
		return _outcome(false, str(target.get("code", "reference_mismatch")), {})
	var raw: Dictionary = simulation.heroes.transfer_item(
		simulation.state, int(intent["owner_seat"]), int(source["internal_id"]),
		int(target["internal_id"]), str(intent["parameters"]["item_instance_id"])
	)
	return _from_hero_receipt(raw, {
		"from_hero_id": str(source["public_id"]),
		"item_instance_id": str(intent["parameters"]["item_instance_id"]),
		"to_hero_id": str(target["public_id"]),
	})


func _execute_sell_item(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var hero := _resolve_owned_subject(simulation, intent, context)
	if not bool(hero.get("ok", false)):
		return _outcome(false, str(hero["code"]), {})
	var shop := context.resolve_target(intent["target"])
	if not bool(shop.get("ok", false)) or str(shop.get("kind", "")) != "entity":
		return _outcome(false, str(shop.get("code", "invalid_target")), {})
	var raw: Dictionary = simulation.heroes.sell_item(
		simulation.state, int(intent["owner_seat"]), int(hero["internal_id"]),
		int(shop["internal_id"]), str(intent["parameters"]["item_instance_id"])
	)
	return _from_hero_receipt(raw, {
		"hero_id": str(hero["public_id"]),
		"item_instance_id": str(intent["parameters"]["item_instance_id"]),
		"shop": shop["public"],
	})


func _execute_use_item(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var hero := _resolve_owned_subject(simulation, intent, context)
	if not bool(hero.get("ok", false)):
		return _outcome(false, str(hero["code"]), {})
	var raw: Dictionary = simulation.heroes.use_item(
		simulation.state, int(intent["owner_seat"]), int(hero["internal_id"]),
		str(intent["parameters"]["item_instance_id"]), simulation.state.tick
	)
	return _from_hero_receipt(raw, {
		"hero_id": str(hero["public_id"]),
		"item_instance_id": str(intent["parameters"]["item_instance_id"]),
	})


func _execute_define_squad(
	simulation: Variant,
	intent: Dictionary,
	context: DuelIntentResolutionContext,
	require_existing: bool
) -> Dictionary:
	var squad_id := str(intent["parameters"]["squad_id"])
	if require_existing != squads.has(squad_id):
		return _outcome(false, "requirement_not_met", {})
	var public_members: Array[String] = []
	for public_variant: Variant in intent["parameters"]["member_ids"]:
		var member := context.resolve_public_entity(str(public_variant), int(intent["owner_seat"]))
		if not bool(member.get("ok", false)) \
			or not _state_entity_matches(simulation, member, int(intent["owner_seat"]), true):
			return _outcome(false, str(member.get("code", "reference_mismatch")), {})
		public_members.append(str(member["public_id"]))
	public_members.sort()
	squads[squad_id] = {
		"member_ids": public_members,
		"owner_seat": int(intent["owner_seat"]),
		"tactics": (squads.get(squad_id, {}) as Dictionary).get("tactics", {}).duplicate(true),
	}
	return _outcome(true, "accepted", {"member_ids": public_members, "squad_id": squad_id})


func _execute_disband_squad(intent: Dictionary) -> Dictionary:
	var squad_id := str(intent["parameters"]["squad_id"])
	if not squads.has(squad_id) \
		or int((squads[squad_id] as Dictionary)["owner_seat"]) != int(intent["owner_seat"]):
		return _outcome(false, "requirement_not_met", {})
	squads.erase(squad_id)
	return _outcome(true, "accepted", {"squad_id": squad_id})


func _execute_tactics(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var subject := _resolve_owned_subject(simulation, intent, context)
	if not bool(subject.get("ok", false)):
		return _outcome(false, str(subject["code"]), {})
	var public_actor := str(subject["public_id"])
	var value: Dictionary = (tactics_by_actor.get(public_actor, {}) as Dictionary).duplicate(true)
	for field: String in ["focus_tag", "formation", "retreat_hp_threshold_bp", "stance", "subject"]:
		if intent["parameters"].has(field):
			value[field] = intent["parameters"][field]
	if not (intent["target"] as Dictionary).is_empty():
		var target := context.resolve_target(intent["target"])
		if not bool(target.get("ok", false)):
			return _outcome(false, str(target["code"]), {})
		value["retreat_target"] = target["public"]
	tactics_by_actor[public_actor] = value
	return _outcome(true, "accepted", {"actor_id": public_actor, "tactics": value.duplicate(true)})


func _execute_set_autocast(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var subject := _resolve_owned_subject(simulation, intent, context)
	if not bool(subject.get("ok", false)):
		return _outcome(false, str(subject["code"]), {})
	var ability_service: Variant = _services.get("abilities", null)
	if ability_service == null:
		return _unsupported("ability service is not configured")
	var public_actor := str(subject["public_id"])
	var ability_id := str(intent["parameters"]["ability_id"])
	var enabled := bool(intent["parameters"]["enabled"])
	var raw: Dictionary = ability_service.set_autocast(
		simulation, int(subject["internal_id"]), ability_id, enabled,
		{"owner_seat": int(intent["owner_seat"])}
	)
	if not bool(raw.get("accepted", false)):
		return _outcome(false, str(raw.get("code", "execution_failed")), {
			"ability_id": ability_id, "actor_id": public_actor, "enabled": enabled,
		})
	var values: Dictionary = (autocast_by_actor.get(public_actor, {}) as Dictionary).duplicate(true)
	values[ability_id] = enabled
	autocast_by_actor[public_actor] = values
	return _outcome(true, "accepted", {
		"ability_id": ability_id,
		"actor_id": public_actor, "enabled": enabled,
	})


func _execute_set_rally(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var producer := _resolve_owned_subject(simulation, intent, context)
	if not bool(producer.get("ok", false)):
		return _outcome(false, str(producer["code"]), {})
	var target := context.resolve_target(intent["target"])
	if not bool(target.get("ok", false)):
		return _outcome(false, str(target["code"]), {})
	var public_id := str(producer["public_id"])
	rally_by_producer[public_id] = target["public"]
	return _outcome(true, "accepted", {"producer_id": public_id, "target": target["public"]})


func _execute_load_transport(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var transport := _resolve_owned_subject(simulation, intent, context)
	if not bool(transport.get("ok", false)):
		return _outcome(false, str(transport["code"]), {})
	var passenger := context.resolve_entity(
		intent["parameters"]["passenger"], int(intent["owner_seat"])
	)
	if not bool(passenger.get("ok", false)) \
		or not _state_entity_matches(simulation, passenger, int(intent["owner_seat"]), true):
		return _outcome(false, str(passenger.get("code", "reference_mismatch")), {})
	if int(transport["internal_id"]) == int(passenger["internal_id"]):
		return _outcome(false, "invalid_target", {})
	var manifest: Array = transport_manifests.get(str(transport["public_id"]), [])
	if str(passenger["public_id"]) in manifest:
		return _outcome(false, "already_completed", {})
	var capacity := context.transport_capacity(str(transport["public_id"]))
	if capacity <= 0 or manifest.size() >= capacity:
		return _outcome(false, "capacity_blocked", {})
	if not _entities_within_range(
		simulation, int(transport["internal_id"]), int(passenger["internal_id"]),
		context.transport_range_mt()
	):
		return _outcome(false, "out_of_range", {})
	var passenger_id := int(passenger["internal_id"])
	simulation.grid.release_ground_actor(passenger_id)
	var passenger_entity: Variant = simulation.state.entities[passenger_id]
	passenger_entity.active_order_id = 0
	passenger_entity.route.clear()
	passenger_entity.set_position_mt(
		simulation.state.entities[int(transport["internal_id"])].position_x_mt,
		simulation.state.entities[int(transport["internal_id"])].position_y_mt
	)
	if simulation.state.combat.actors.has(passenger_id):
		simulation.state.combat.actors[passenger_id]["transported"] = true
	manifest.append(str(passenger["public_id"]))
	manifest.sort()
	transport_manifests[str(transport["public_id"])] = manifest
	return _outcome(true, "accepted", {
		"passenger_id": str(passenger["public_id"]), "transport_id": str(transport["public_id"]),
	})


func _execute_unload_transport(simulation: Variant, intent: Dictionary, context: DuelIntentResolutionContext) -> Dictionary:
	var transport := _resolve_owned_subject(simulation, intent, context)
	if not bool(transport.get("ok", false)):
		return _outcome(false, str(transport["code"]), {})
	var passenger := context.resolve_entity(
		intent["parameters"]["passenger"], int(intent["owner_seat"])
	)
	if not bool(passenger.get("ok", false)):
		return _outcome(false, str(passenger["code"]), {})
	var target := context.resolve_target(intent["target"])
	if not bool(target.get("ok", false)) or str(target.get("kind", "")) != "point":
		return _outcome(false, str(target.get("code", "invalid_target")), {})
	var transport_public := str(transport["public_id"])
	var passenger_public := str(passenger["public_id"])
	var manifest: Array = transport_manifests.get(transport_public, [])
	if passenger_public not in manifest:
		return _outcome(false, "target_unavailable", {})
	var passenger_id := int(passenger["internal_id"])
	var entity: Variant = simulation.state.entities[passenger_id]
	if not simulation.grid.reserve_ground_actor(
		passenger_id, int(target["xy_mt"][0]), int(target["xy_mt"][1]), int(entity.radius_mt)
	):
		return _outcome(false, "placement_blocked", {})
	entity.set_position_mt(int(target["xy_mt"][0]), int(target["xy_mt"][1]))
	if simulation.state.combat.actors.has(passenger_id):
		simulation.state.combat.actors[passenger_id]["transported"] = false
	manifest.erase(passenger_public)
	transport_manifests[transport_public] = manifest
	return _outcome(true, "accepted", {
		"passenger_id": passenger_public, "target": target["public"],
		"transport_id": transport_public,
	})


func _resolve_local_contests(
	simulation: Variant,
	intents: Array[Dictionary],
	context: DuelIntentResolutionContext
) -> Dictionary:
	var claims: Array[Dictionary] = []
	var capacities: Dictionary = {}
	var claim_to_intents: Dictionary = {}
	var build_claim_seen: Dictionary = {}
	var hero_revival_claim_ids: Array[String] = []
	for intent: Dictionary in intents:
		if not _intent_code(intent).is_empty():
			continue
		var operation := str(intent["operation"])
		if operation == "build":
			var group_id := str(intent["parameters"].get("construction_group_id", intent["intent_id"]))
			if build_claim_seen.has(group_id):
				continue
			build_claim_seen[group_id] = true
			var group: Array = _build_groups.get(group_id, [intent])
			var actor := _resolve_owned_subject(simulation, group[0], context)
			var site := context.resolve_target(intent["target"])
			if not bool(actor.get("ok", false)) or not bool(site.get("ok", false)):
				continue
			var claim_id := "build:%s" % group_id
			claims.append(_claim(intent, claim_id, "build_site", str(site["internal_object_id"]), int(actor["internal_id"])))
			capacities[ContestResolver.group_id("build_site", str(site["internal_object_id"]))] = 1
			var group_intent_ids: Array[String] = []
			for group_intent_variant: Variant in group:
				group_intent_ids.append(str((group_intent_variant as Dictionary)["intent_id"]))
			claim_to_intents[claim_id] = group_intent_ids
		elif operation == "pick_up_item":
			var actor := _resolve_owned_subject(simulation, intent, context)
			var item := context.resolve_target(intent["target"])
			if not bool(actor.get("ok", false)) or not bool(item.get("ok", false)):
				continue
			var claim_id := str(intent["intent_id"])
			claims.append(_claim(intent, claim_id, "ground_item", str(item["internal_id"]), int(actor["internal_id"])))
			capacities[ContestResolver.group_id("ground_item", str(item["internal_id"]))] = 1
			claim_to_intents[claim_id] = [claim_id]
		elif operation == "load_transport":
			var transport := _resolve_owned_subject(simulation, intent, context)
			var passenger := context.resolve_entity(
				intent["parameters"].get("passenger", {}), int(intent["owner_seat"])
			)
			if not bool(transport.get("ok", false)) or not bool(passenger.get("ok", false)) \
				or not _state_entity_matches(
					simulation, passenger, int(intent["owner_seat"]), true
				) or int(transport["internal_id"]) == int(passenger["internal_id"]):
				continue
			var transport_public := str(transport["public_id"])
			var manifest: Array = transport_manifests.get(transport_public, [])
			if str(passenger["public_id"]) in manifest or not _entities_within_range(
				simulation, int(transport["internal_id"]), int(passenger["internal_id"]),
				context.transport_range_mt()
			):
				continue
			var open_seats := context.transport_capacity(transport_public) - manifest.size()
			if open_seats <= 0:
				continue
			var transport_object := str(transport["internal_id"])
			var claim_id := str(intent["intent_id"])
			claims.append(_claim(
				intent, claim_id, "transport_seat", transport_object,
				int(passenger["internal_id"])
			))
			capacities[ContestResolver.group_id(
				"transport_seat", transport_object
			)] = open_seats
			claim_to_intents[claim_id] = [claim_id]
		elif operation == "revive_hero":
			var actor := _resolve_owned_subject(simulation, intent, context)
			var hero := context.resolve_entity(intent["parameters"].get("hero", {}), int(intent["owner_seat"]))
			if not bool(actor.get("ok", false)) or not bool(hero.get("ok", false)):
				continue
			var claim_id := "hero:%s" % str(intent["intent_id"])
			claims.append(_claim(intent, claim_id, "hero_revival", str(hero["internal_id"]), int(actor["internal_id"])))
			capacities[ContestResolver.group_id("hero_revival", str(hero["internal_id"]))] = 1
			claim_to_intents[claim_id] = [str(intent["intent_id"])]
			hero_revival_claim_ids.append(claim_id)

	var first := ContestResolver.new().resolve(
		simulation.state.tick, claims, capacities, context.protected_tie_key()
	)
	var rejected_intent_ids: Dictionary = {}
	for claim_id: String in first["rejected_claim_ids"]:
		for intent_id: String in claim_to_intents.get(claim_id, []):
			rejected_intent_ids[intent_id] = true

	## A Tavern is a second independent one-slot constraint after unique-Hero
	## resolution. Only survivors enter this second protected contest.
	var tavern_claims: Array[Dictionary] = []
	var tavern_capacities: Dictionary = {}
	var accepted_first: Dictionary = {}
	for claim_id: String in first["accepted_claim_ids"]:
		accepted_first[claim_id] = true
	for intent: Dictionary in intents:
		if str(intent.get("operation", "")) != "revive_hero" \
			or str(intent.get("parameters", {}).get("revival_method", "")) != "tavern":
			continue
		var first_claim_id := "hero:%s" % str(intent["intent_id"])
		if not accepted_first.has(first_claim_id):
			continue
		var reviver := _resolve_owned_subject(simulation, intent, context)
		var tavern := context.field_revival_tavern_for_seat(int(intent["owner_seat"]))
		if not bool(reviver.get("ok", false)) or not bool(tavern.get("ok", false)):
			continue
		var tavern_object := str(tavern["neutral_building_id"])
		var claim_id := "tavern:%s" % str(intent["intent_id"])
		tavern_claims.append(_claim(intent, claim_id, "field_revival_slot", tavern_object, int(reviver["internal_id"])))
		tavern_capacities[ContestResolver.group_id("field_revival_slot", tavern_object)] = 1
		claim_to_intents[claim_id] = [str(intent["intent_id"])]
	var second := ContestResolver.new().resolve(
		simulation.state.tick, tavern_claims, tavern_capacities, context.protected_tie_key()
	)
	for claim_id: String in second["rejected_claim_ids"]:
		for intent_id: String in claim_to_intents.get(claim_id, []):
			rejected_intent_ids[intent_id] = true
	var errors := PackedStringArray()
	errors.append_array(first["errors"])
	errors.append_array(second["errors"])
	return {
		"audit": (first["audit"] as Array) + (second["audit"] as Array),
		"errors": errors,
		"rejected_intent_ids": rejected_intent_ids,
	}


func _resolve_market_purchase_batch(
	simulation: Variant,
	intents: Array[Dictionary],
	context: DuelIntentResolutionContext,
	neutral_market: Variant
) -> Dictionary:
	var outcomes: Dictionary = {}
	var claims: Array[Dictionary] = []
	var purchase_intents: Dictionary = {}
	var hire_food_shadow := {
		0: int(simulation.state.economy.players.get(0, {}).get("food_used", 0)) \
			+ int(simulation.state.economy.players.get(0, {}).get("reserved_food", 0)),
		1: int(simulation.state.economy.players.get(1, {}).get("food_used", 0)) \
			+ int(simulation.state.economy.players.get(1, {}).get("reserved_food", 0)),
	}
	for intent: Dictionary in intents:
		if str(intent.get("operation", "")) != "purchase_offer" \
			or not _intent_code(intent).is_empty():
			continue
		var intent_id := str(intent["intent_id"])
		if neutral_market == null:
			outcomes[intent_id] = _unsupported("neutral market service is not configured")
			continue
		var buyer := _resolve_owned_subject(simulation, intent, context)
		var shop := context.resolve_target(intent["target"])
		if not bool(buyer.get("ok", false)) or not bool(shop.get("ok", false)):
			outcomes[intent_id] = _outcome(false, "target_unavailable", {})
			continue
		var building_id := context.neutral_building_id(str(shop["public"]["public_id"]))
		if building_id.is_empty():
			outcomes[intent_id] = _outcome(false, "target_unavailable", {})
			continue
		var offer_id := str(intent["parameters"]["offer_id"])
		if not neutral_market.state.buildings.has(building_id) \
			or not neutral_market.state.buildings[building_id]["offers"].has(offer_id):
			outcomes[intent_id] = _outcome(false, "target_unavailable", {})
			continue
		var offer: Dictionary = neutral_market.state.buildings[building_id]["offers"][offer_id]
		if str(offer["kind"]) == "unit":
			if not neutral_market.neutrals.has("laboratory_hires") \
				or not neutral_market.neutrals["laboratory_hires"].has(offer_id):
				outcomes[intent_id] = _outcome(false, "target_unavailable", {})
				continue
			var hire_definition: Dictionary = neutral_market.neutrals["laboratory_hires"][offer_id]
			var seat := int(intent["owner_seat"])
			var capacity := int(simulation.state.economy.players[seat]["food_capacity"])
			if int(hire_food_shadow[seat]) + int(hire_definition["food"]) > capacity:
				outcomes[intent_id] = _outcome(false, "food_cap_blocked", {})
				continue
			var preflight: Dictionary = simulation.preflight_hired_unit(
				seat, offer_id, hire_definition,
				neutral_market.state.buildings[building_id]["approach_cells"]
			)
			if not bool(preflight.get("ok", false)):
				outcomes[intent_id] = _outcome(
					false, str(preflight.get("code", "execution_failed")), {}
				)
				continue
			hire_food_shadow[seat] = int(hire_food_shadow[seat]) + int(hire_definition["food"])
		var buyer_entity: Variant = simulation.state.entities[int(buyer["internal_id"])]
		var claim := {
			"building_id": building_id,
			"buyer_alive": bool(buyer_entity.alive),
			"buyer_internal_id": int(buyer["internal_id"]),
			"buyer_owned": int(buyer_entity.owner_seat) == int(intent["owner_seat"]),
			"buyer_position_mt": [int(buyer_entity.position_x_mt), int(buyer_entity.position_y_mt)],
			"buyer_tags": buyer_entity.tags.duplicate(),
			"canonical_command_digest": str(intent["source"]["command_digest"]),
			"claim_id": intent_id,
			"command_index": int(intent["source"]["command_index"]),
			"interaction_legal": true,
			"offer_id": offer_id,
			"owner_seat": int(intent["owner_seat"]),
			"shop_visible": true,
		}
		if intent["parameters"].has("service_target"):
			var service_target := context.resolve_target(intent["parameters"]["service_target"])
			if not bool(service_target.get("ok", false)):
				outcomes[intent_id] = _outcome(false, str(service_target["code"]), {})
				continue
			claim["service_target_xy_mt"] = service_target["xy_mt"]
		claims.append(claim)
		purchase_intents[intent_id] = intent
	if claims.is_empty():
		return {"audit": [], "outcomes": outcomes}
	var resources := {
		0: simulation.state.economy.players.get(0, {"gold": 0, "lumber": 0}),
		1: simulation.state.economy.players.get(1, {"gold": 0, "lumber": 0}),
	}
	var audit_start: int = neutral_market.state.contest_audit.size()
	var resolved: Dictionary = neutral_market.resolve_shop_claims(
		simulation.state.tick, claims, resources
	)
	var audit: Array[Dictionary] = []
	for index: int in range(audit_start, neutral_market.state.contest_audit.size()):
		audit.append(neutral_market.state.contest_audit[index].duplicate(true))
	for delta_variant: Variant in resolved.get("resource_deltas", []):
		var delta: Dictionary = delta_variant
		var seat := int(delta["seat"])
		if simulation.state.economy.players.has(seat):
			simulation.state.economy.players[seat]["gold"] += int(delta["gold"])
			simulation.state.economy.players[seat]["lumber"] += int(delta["lumber"])
	for result_variant: Variant in resolved.get("rejected", []):
		var result: Dictionary = result_variant
		outcomes[str(result["claim_id"])] = _outcome(false, str(result["code"]), {})
	for result_variant: Variant in resolved.get("accepted", []):
		var result: Dictionary = result_variant
		var intent_id := str(result["claim_id"])
		var intent: Dictionary = purchase_intents[intent_id]
		var handoff: Dictionary = result["handoff"]
		var public_result := {
			"offer_id": str(intent["parameters"]["offer_id"]),
			"quantity_index": int(intent["parameters"].get("quantity_index", 0)),
		}
		if str(handoff.get("kind", "")) == "grant_purchased_item":
			var grant: Dictionary = simulation.heroes.grant_item(
				simulation.state, int(handoff["buyer_internal_id"]), str(handoff["item_type_id"])
			)
			if not bool(grant.get("accepted", false)):
				outcomes[intent_id] = _outcome(false, "execution_failed", public_result)
				continue
			public_result["item_instance_id"] = str(grant["details"]["item"]["item_instance_id"])
		elif str(handoff.get("kind", "")) == "create_private_reveal_source":
			public_result["service_applied"] = true
		elif str(handoff.get("kind", "")) == "spawn_hired_unit":
			var spawned: Dictionary = simulation.spawn_hired_unit(handoff)
			if not bool(spawned.get("accepted", false)):
				outcomes[intent_id] = _outcome(
					false, str(spawned.get("code", "execution_failed")), public_result
				)
				continue
			public_result["hired_unit_ref"] = _public_runtime_ref("entity", intent)
			public_result["unit_type_id"] = str(handoff["hire_type_id"])
		outcomes[intent_id] = _outcome(true, "accepted", public_result)
	return {"audit": audit, "outcomes": outcomes}


func _resolve_owned_subject(
	simulation: Variant,
	intent: Dictionary,
	context: DuelIntentResolutionContext
) -> Dictionary:
	var resolved := context.resolve_entity(intent["subject"], int(intent["owner_seat"]))
	if not bool(resolved.get("ok", false)):
		return resolved
	if not _state_entity_matches(simulation, resolved, int(intent["owner_seat"]), true):
		return {"code": "reference_mismatch", "ok": false}
	return resolved


static func _state_entity_matches(
	simulation: Variant,
	resolved: Dictionary,
	expected_owner: int,
	require_alive: bool
) -> bool:
	var internal_id := int(resolved["internal_id"])
	if not simulation.state.entities.has(internal_id):
		return false
	var entity: Variant = simulation.state.entities[internal_id]
	return int(entity.owner_seat) == expected_owner and (not require_alive or bool(entity.alive))


func _intent_code(intent: Dictionary) -> String:
	if not _has_exact_fields(intent, INTENT_FIELDS):
		return "invalid_intent"
	if typeof(intent["apply_tick"]) != TYPE_INT or int(intent["apply_tick"]) < 0 \
		or typeof(intent["owner_seat"]) != TYPE_INT \
		or int(intent["owner_seat"]) not in [0, 1] \
		or typeof(intent["intent_type"]) != TYPE_STRING \
		or typeof(intent["operation"]) != TYPE_STRING \
		or str(intent["operation"]) not in Contract.OPERATIONS + COMPILED_ONLY_OPERATIONS \
		or typeof(intent["parameters"]) != TYPE_DICTIONARY \
		or typeof(intent["queue_policy"]) != TYPE_STRING \
		or str(intent["queue_policy"]) not in ["append", "front", "none", "replace"] \
		or typeof(intent["subject"]) != TYPE_DICTIONARY \
		or typeof(intent["target"]) != TYPE_DICTIONARY \
		or typeof(intent["source"]) != TYPE_DICTIONARY \
		or not _has_exact_fields(intent["source"], SOURCE_FIELDS):
		return "invalid_intent"
	if str(intent["intent_type"]) != _expected_intent_type(str(intent["operation"])):
		return "invalid_intent_type"
	var source: Dictionary = intent["source"]
	if not Contract.is_batch_id(source["batch_id"]) \
		or not Contract.is_command_id(source["command_id"]) \
		or not Contract.is_match_id(source["match_id"]) \
		or not Contract.is_sha256(source["command_digest"]) \
		or typeof(source["command_index"]) != TYPE_INT \
		or int(source["command_index"]) < 0 \
		or typeof(source["expansion_index"]) != TYPE_INT \
		or int(source["expansion_index"]) < 0 \
		or typeof(source["observation_seq"]) != TYPE_INT \
		or int(source["observation_seq"]) < 0:
		return "invalid_intent_source"
	if typeof(intent["intent_id"]) != TYPE_STRING \
		or not str(intent["intent_id"]).begins_with("ci_") \
		or typeof(intent["intent_digest"]) != TYPE_STRING \
		or str(intent["intent_id"]) != "ci_" + str(intent["intent_digest"]):
		return "invalid_intent"
	var body := intent.duplicate(true)
	body.erase("intent_digest")
	body.erase("intent_id")
	if Codec.sha256_canonical(body) != str(intent["intent_digest"]):
		return "intent_digest_mismatch"
	return ""


static func _expected_intent_type(operation: String) -> String:
	match operation:
		"attack_entity", "attack_ground", "attack_move", "follow", "hold_area", \
		"hold_position", "move", "patrol", "patrol_points", "retreat", "stop":
			return "order"
		"build", "cancel_construction", "cancel_queue", "gather", "produce", \
		"repair", "research", "return_cargo", "revive_hero", "set_rally", \
		"upgrade_tier":
			return "economy"
		"cast", "learn_ability", "set_autocast":
			return "ability"
		"drop_item", "pick_up_item", "purchase_offer", "sell_item", \
		"transfer_item", "use_item":
			return "item"
		"load_transport", "unload_transport":
			return "transport"
		"define_squad", "disband_squad", "update_squad":
			return "squad_state"
		"set_stance", "set_tactics":
			return "tactics"
	## `order_squad` itself is never emitted by DuelOrderCompiler; its actor
	## expansions use one of the explicit order operations above.
	return ""


static func _group_build_intents(intents: Array[Dictionary]) -> Dictionary:
	var result: Dictionary = {}
	for intent: Dictionary in intents:
		if str(intent.get("operation", "")) != "build":
			continue
		var parameters: Dictionary = intent.get("parameters", {})
		var group_id := str(parameters.get("construction_group_id", intent.get("intent_id", "")))
		if not result.has(group_id):
			result[group_id] = []
		(result[group_id] as Array).append(intent)
	return result


static func _claim(
	intent: Dictionary,
	claim_id: String,
	claim_kind: String,
	object_id: String,
	actor_id: int
) -> Dictionary:
	return {
		"canonical_command_digest": str(intent["source"]["command_digest"]),
		"claim_id": claim_id,
		"claim_kind": claim_kind,
		"internal_actor_id": actor_id,
		"object_id": object_id,
	}


static func _core_target(resolved: Dictionary) -> Dictionary:
	match str(resolved["kind"]):
		"entity":
			return {"entity_id": int(resolved["internal_id"]), "kind": "entity"}
		"point", "region_slot", "site":
			return {"kind": "point", "xy_mt": (resolved["xy_mt"] as Array).duplicate()}
	return {}


static func _resolved_public_entity_id(resolved: Dictionary) -> String:
	return str((resolved.get("public", {}) as Dictionary).get("public_id", resolved.get("public_id", "")))


static func _ability_rank(simulation: Variant, actor_id: int, ability_id: String) -> int:
	if simulation.state.heroes.heroes.has(actor_id):
		var hero: Dictionary = simulation.state.heroes.heroes[actor_id]
		return maxi(1, int((hero.get("learned_abilities", {}) as Dictionary).get(ability_id, 0)))
	return 1


static func _from_subsystem_receipt(raw: Dictionary, public_result: Dictionary) -> Dictionary:
	var accepted := bool(raw.get("accepted", false))
	return _outcome(accepted, str(raw.get("code", "execution_failed")), public_result)


static func _from_hero_receipt(raw: Dictionary, public_result: Dictionary) -> Dictionary:
	var accepted := bool(raw.get("accepted", false))
	var result := public_result.duplicate(true)
	var details: Dictionary = raw.get("details", {})
	for field: String in ["ability_id", "cost_gold", "duration_ticks", "gold", "item_instance_id", "method", "rank"]:
		if details.has(field):
			result[field] = details[field]
	return _outcome(accepted, str(raw.get("code", "execution_failed")), result)


static func _outcome(accepted: bool, code: String, public_result: Dictionary) -> Dictionary:
	return {
		"accepted": accepted,
		"code": code if accepted else _stable_execution_code(code),
		"public_result": public_result.duplicate(true),
		"unsupported": false,
	}


static func _unsupported(reason: String) -> Dictionary:
	return {
		"accepted": false,
		"code": "unsupported_operation",
		"public_result": {"reason": reason},
		"unsupported": true,
	}


func _receipt_from_outcome(
	intent: Dictionary,
	outcome: Dictionary,
	context: DuelIntentResolutionContext
) -> Dictionary:
	var status := "applied" if bool(outcome["accepted"]) else "rejected"
	return _receipt(
		intent, status, null if bool(outcome["accepted"]) else str(outcome["code"]),
		outcome["public_result"], context
	)


func _receipt(
	intent: Dictionary,
	status: String,
	code: Variant,
	public_result: Dictionary,
	context: DuelIntentResolutionContext
) -> Dictionary:
	var public_subject: Variant = {"kind": "controller", "seat": int(intent.get("owner_seat", -1))}
	if typeof(intent.get("subject", null)) == TYPE_DICTIONARY \
		and str((intent["subject"] as Dictionary).get("kind", "")) == "entity":
		var resolved := context.resolve_entity(intent["subject"])
		public_subject = {"kind": "entity", "public_id": str(resolved.get("public_id", "unknown"))}
	return {
		"apply_tick": int(intent.get("apply_tick", 0)),
		"code": null if code == null else _stable_execution_code(str(code)),
		"command_id": str((intent.get("source", {}) as Dictionary).get("command_id", "invalid")),
		"expansion_index": int((intent.get("source", {}) as Dictionary).get("expansion_index", 0)),
		"intent_ref": _public_intent_ref(intent),
		"operation": str(intent.get("operation", "invalid")),
		"result": public_result.duplicate(true),
		"status": status,
		"subject": public_subject,
	}


static func _stable_execution_code(code: String) -> String:
	if code in [
		"ability_unavailable", "actor_unavailable", "conflicting_order", "cooldown_active",
		"execution_failed", "food_cap_blocked", "insufficient_resources", "invalid_placement",
		"invalid_target_type", "not_owner", "out_of_bounds", "queue_full",
		"requirement_not_met", "target_unavailable", "unknown_entity",
		"unexplored_location", "unsupported_operation",
	]:
		return code
	match code:
		"not_owned":
			return "not_owner"
		"cooldown":
			return "cooldown_active"
		"insufficient_resource":
			return "insufficient_resources"
		"placement_blocked":
			return "invalid_placement"
		"inventory_full", "capacity_blocked", "invalid_actor", "invalid_producer", \
		"invalid_state", "already_completed", "already_exists", "already_queued", \
		"attack_disabled", "authority_unavailable", "combat_not_configured", \
		"ground_attack_unsupported", \
		"prerequisite_missing", "unknown_catalog_id":
			return "requirement_not_met"
		"attacker_dead", "attacker_missing", "attacker_unavailable":
			return "actor_unavailable"
		"invalid_target", "out_of_range":
			return "target_unavailable"
	return "execution_failed"


static func _public_runtime_ref(kind: String, intent: Dictionary) -> String:
	return "%s.%s" % [kind, _public_intent_ref(intent).trim_prefix("intent.")]


static func _public_intent_ref(intent: Dictionary) -> String:
	var source: Dictionary = intent.get("source", {})
	var seed := {
		"batch_id": str(source.get("batch_id", "invalid")),
		"command_id": str(source.get("command_id", "invalid")),
		"expansion_index": int(source.get("expansion_index", 0)),
		"operation": str(intent.get("operation", "invalid")),
	}
	return "intent.%s" % Codec.sha256_canonical(seed).substr(0, 20)


static func _cancel_open_orders(simulation: Variant, actor_id: int) -> void:
	for order_id: int in simulation.state.sorted_order_ids():
		var order: OrderRecord = simulation.state.orders[order_id]
		if order.actor_id == actor_id and order.status <= OrderRecord.Status.ACTIVE:
			order.status = OrderRecord.Status.CANCELLED
	if simulation.state.entities.has(actor_id):
		simulation.state.entities[actor_id].active_order_id = 0
	if simulation.state.combat.attack_orders.has(actor_id):
		simulation.combat.cancel_attack(simulation.state, actor_id)


static func _entities_within_range(simulation: Variant, left_id: int, right_id: int, range_mt: int) -> bool:
	if range_mt < 0 or not simulation.state.entities.has(left_id) \
		or not simulation.state.entities.has(right_id):
		return false
	var left: Variant = simulation.state.entities[left_id]
	var right: Variant = simulation.state.entities[right_id]
	var dx := int(left.position_x_mt) - int(right.position_x_mt)
	var dy := int(left.position_y_mt) - int(right.position_y_mt)
	return dx * dx + dy * dy <= range_mt * range_mt


static func _intent_less(left: Dictionary, right: Dictionary) -> bool:
	var left_source: Dictionary = left.get("source", {})
	var right_source: Dictionary = right.get("source", {})
	var left_key := "%012d|%s|%08d|%08d|%s" % [
		int(left.get("apply_tick", 0)), str(left_source.get("batch_id", "")),
		int(left_source.get("command_index", 0)), int(left_source.get("expansion_index", 0)),
		str(left.get("intent_id", "")),
	]
	var right_key := "%012d|%s|%08d|%08d|%s" % [
		int(right.get("apply_tick", 0)), str(right_source.get("batch_id", "")),
		int(right_source.get("command_index", 0)), int(right_source.get("expansion_index", 0)),
		str(right.get("intent_id", "")),
	]
	return left_key < right_key


static func _has_exact_fields(value_variant: Variant, fields: Array[String]) -> bool:
	if typeof(value_variant) != TYPE_DICTIONARY:
		return false
	var value: Dictionary = value_variant
	if value.size() != fields.size():
		return false
	for field: String in fields:
		if not value.has(field):
			return false
	return true


static func _sorted_nested_dictionary(value: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var keys: Array = value.keys()
	keys.sort()
	for key_variant: Variant in keys:
		var child: Variant = value[key_variant]
		result[str(key_variant)] = child.duplicate(true) if typeof(child) in [TYPE_DICTIONARY, TYPE_ARRAY] else child
	return result


func _canonical_pending_appends() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var actor_ids: Array = pending_append_order_ids.keys()
	actor_ids.sort()
	for actor_variant: Variant in actor_ids:
		var actor_id := int(actor_variant)
		var public_id := str(_actor_public_aliases.get(actor_id, "unknown"))
		## Internal order IDs remain authority-only; this public controller snapshot
		## reports only queue depth. The state snapshot owns the actual order records.
		result.append({"pending_count": (pending_append_order_ids[actor_id] as Array).size(), "public_id": public_id})
	return result


func _canonical_transport_manifests() -> Dictionary:
	var result: Dictionary = {}
	var keys: Array = transport_manifests.keys()
	keys.sort()
	for key_variant: Variant in keys:
		var passengers: Array = (transport_manifests[key_variant] as Array).duplicate()
		passengers.sort()
		result[str(key_variant)] = passengers
	return result
