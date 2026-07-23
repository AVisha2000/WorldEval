class_name DuelActionValidator
extends RefCounted

## Authoritative Godot-side validation boundary for a parsed hybrid-v1 batch.
##
## `validate_and_compile()` treats both inputs as immutable.  The legal context
## is a frozen application-tick projection supplied by DuelSimulation.  It
## contains opaque protocol aliases mapped to authoritative internal IDs; this
## class never guesses an alias or queries hidden world state on its own.

const Contract := preload("res://scripts/duel/actions/duel_action_contract.gd")
const Compiler := preload("res://scripts/duel/actions/duel_order_compiler.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const STABLE_COMMAND_CODES: Array[String] = [
	"ability_unavailable",
	"actor_unavailable",
	"conflicting_order",
	"cooldown_active",
	"execution_failed",
	"food_cap_blocked",
	"insufficient_resources",
	"invalid_placement",
	"invalid_target_type",
	"not_owner",
	"out_of_bounds",
	"queue_full",
	"requirement_not_met",
	"target_unavailable",
	"too_many_actors",
	"unknown_entity",
	"unexplored_location",
	"unsupported_operation",
]


func validate_and_compile(batch_input: Variant, legal_context_input: Dictionary) -> Dictionary:
	var batch: Variant = batch_input.duplicate(true) if typeof(batch_input) in [TYPE_DICTIONARY, TYPE_ARRAY] \
		else batch_input
	var context: Dictionary = legal_context_input.duplicate(true)
	var context_code := _context_code(context)
	if not context_code.is_empty():
		return _envelope_failure(batch, context, "execution_failed")

	var structural_code := Contract.envelope_structural_code(batch)
	if not structural_code.is_empty():
		return _envelope_failure(batch, context, structural_code)
	var action_batch: Dictionary = batch
	var boundary_code := _boundary_code(action_batch, context)
	if not boundary_code.is_empty():
		return _envelope_failure(action_batch, context, boundary_code)

	var frozen_squads: Dictionary = _canonical_squads(context.get("squads", {}))
	var squad_sizes: Dictionary = context.get("squad_sizes", {})
	var transport_counts: Dictionary = context.get("transport_passenger_counts", {})
	var atomic_cost := Contract.total_atomic_cost(
		action_batch["commands"], squad_sizes, transport_counts
	)
	if atomic_cost < 0 or atomic_cost > Contract.MAX_ATOMIC_ORDER_COST:
		return _envelope_failure(action_batch, context, "atomic_budget_exceeded")

	var projected := {
		"queue_sizes": _initial_queue_sizes(context),
		"replace_claims": {},
		"squads": frozen_squads.duplicate(true),
	}
	var intents: Array[Dictionary] = []
	var command_receipts: Array[Dictionary] = []
	var compiler := Compiler.new()
	var commands: Array = action_batch["commands"]
	for command_index: int in commands.size():
		var command: Dictionary = commands[command_index]
		var command_cost := Contract.command_atomic_cost(command, squad_sizes, transport_counts)
		var validation := _dispatch_validate(
			command, context, projected, frozen_squads
		)
		if not bool(validation.get("ok", false)):
			command_receipts.append(_rejected_command_receipt(
				str(command["command_id"]),
				str(validation.get("code", "execution_failed")),
				command_cost
			))
			continue
		var plan: Dictionary = validation["plan"]
		var queue_result := _validate_and_project_queue(command, plan, context, projected)
		if not bool(queue_result["ok"]):
			command_receipts.append(_rejected_command_receipt(
				str(command["command_id"]), str(queue_result["code"]), command_cost
			))
			continue

		var compiled := compiler.compile_command(
			command, command_index, action_batch, context, plan
		)
		if compiled.size() != command_cost:
			command_receipts.append(_rejected_command_receipt(
				str(command["command_id"]), "execution_failed", command_cost
			))
			continue
		_apply_projected_mutation(validation, projected)
		projected["queue_sizes"] = queue_result["queue_sizes"]
		projected["replace_claims"] = queue_result["replace_claims"]
		intents.append_array(compiled)
		var compiled_ids: Array[String] = []
		for intent: Dictionary in compiled:
			compiled_ids.append(str(intent["intent_id"]))
		compiled_ids.sort()
		command_receipts.append({
			"atomic_cost": command_cost,
			"code": null,
			"command_id": str(command["command_id"]),
			"compiled_order_ids": compiled_ids,
			"status": "applied",
		})

	var batch_status := _batch_status(command_receipts)
	var receipt := {
		"apply_tick": int(context["application_tick"]),
		"batch_id": str(action_batch["client_batch_id"]),
		"batch_status": batch_status,
		"code": null,
		"commands": command_receipts,
		"observation_seq": int(action_batch["observation_seq"]),
		"received_tick": int(context["received_tick"]),
	}
	return {
		"atomic_cost": atomic_cost,
		"batch_digest": Codec.sha256_canonical(action_batch),
		"code": null,
		"intents": intents,
		"ok": true,
		"projected_order_queue_sizes": _sorted_dictionary(projected["queue_sizes"]),
		"receipt": receipt,
		"squads": _canonical_squads(projected["squads"]),
	}


func _dispatch_validate(
	command: Dictionary,
	context: Dictionary,
	projected: Dictionary,
	frozen_squads: Dictionary
) -> Dictionary:
	## Every operation is named explicitly.  Never replace this with runtime
	## method-name concatenation or any other reflective dispatch.
	match str(command["op"]):
		"attack_entity":
			return _validate_attack_entity(command, context)
		"attack_ground":
			return _validate_attack_ground(command, context)
		"attack_move":
			return _validate_attack_move(command, context)
		"build":
			return _validate_build(command, context)
		"cancel_construction":
			return _validate_cancel_construction(command, context)
		"cancel_queue":
			return _validate_cancel_queue(command, context)
		"cast":
			return _validate_cast(command, context)
		"define_squad":
			return _validate_define_squad(command, context, projected)
		"disband_squad":
			return _validate_disband_squad(command, projected)
		"drop_item":
			return _validate_drop_item(command, context)
		"follow":
			return _validate_follow(command, context)
		"gather":
			return _validate_gather(command, context)
		"hold_position":
			return _validate_hold_position(command, context)
		"learn_ability":
			return _validate_learn_ability(command, context)
		"load_transport":
			return _validate_load_transport(command, context)
		"move":
			return _validate_move(command, context)
		"order_squad":
			return _validate_order_squad(command, context, projected, frozen_squads)
		"patrol":
			return _validate_patrol(command, context)
		"pick_up_item":
			return _validate_pick_up_item(command, context)
		"produce":
			return _validate_produce(command, context)
		"purchase_offer":
			return _validate_purchase_offer(command, context)
		"repair":
			return _validate_repair(command, context)
		"research":
			return _validate_research(command, context)
		"retreat":
			return _validate_retreat(command, context)
		"return_cargo":
			return _validate_return_cargo(command, context)
		"revive_hero":
			return _validate_revive_hero(command, context)
		"sell_item":
			return _validate_sell_item(command, context)
		"set_autocast":
			return _validate_set_autocast(command, context)
		"set_rally":
			return _validate_set_rally(command, context)
		"set_stance":
			return _validate_set_stance(command, context)
		"set_tactics":
			return _validate_set_tactics(command, context, projected, frozen_squads)
		"stop":
			return _validate_stop(command, context)
		"transfer_item":
			return _validate_transfer_item(command, context)
		"unload_transport":
			return _validate_unload_transport(command, context)
		"update_squad":
			return _validate_update_squad(command, context, projected)
		"upgrade_tier":
			return _validate_upgrade_tier(command, context)
		"use_item":
			return _validate_use_item(command, context)
	return _failure("unsupported_operation")


func _validate_move(command: Dictionary, context: Dictionary) -> Dictionary:
	return _actor_target_plan(command, context, "actor_ids", "target", "move", "visible_or_owned")


func _validate_attack_move(command: Dictionary, context: Dictionary) -> Dictionary:
	return _actor_target_plan(command, context, "actor_ids", "target", "attack_move", "visible_or_owned")


func _validate_attack_entity(command: Dictionary, context: Dictionary) -> Dictionary:
	return _actor_target_plan(command, context, "actor_ids", "target", "attack_entity", "visible")


func _validate_attack_ground(command: Dictionary, context: Dictionary) -> Dictionary:
	return _actor_target_plan(command, context, "actor_ids", "target", "attack_ground", "visible_or_owned")


func _validate_stop(command: Dictionary, context: Dictionary) -> Dictionary:
	var actors := _owned_actors(command["actor_ids"], context, "stop", [])
	if not bool(actors["ok"]):
		return actors
	return _success(_plan(actors["actor_ids"], {}, "replace", {}))


func _validate_hold_position(command: Dictionary, context: Dictionary) -> Dictionary:
	var actors := _owned_actors(command["actor_ids"], context, "hold_position", [])
	if not bool(actors["ok"]):
		return actors
	return _success(_plan(actors["actor_ids"], {}, "replace", {}))


func _validate_patrol(command: Dictionary, context: Dictionary) -> Dictionary:
	var actors := _owned_actors(command["actor_ids"], context, "patrol", [])
	if not bool(actors["ok"]):
		return actors
	var targets: Array[Dictionary] = []
	for target_variant: Variant in (command["targets"] as Array):
		var normalized := _normalize_target(target_variant, context, "visible_or_owned", false)
		if not bool(normalized["ok"]):
			return normalized
		targets.append(normalized["target"])
	return _success(_plan(
		actors["actor_ids"],
		{},
		str(command["queue"]),
		{"targets": targets}
	))


func _validate_follow(command: Dictionary, context: Dictionary) -> Dictionary:
	var result := _actor_target_plan(
		command, context, "actor_ids", "target", "follow", "visible_or_owned"
	)
	if bool(result["ok"]):
		(result["plan"] as Dictionary)["parameters"] = {
			"distance_mt": int(command["distance_mt"]),
		}
	return result


func _validate_retreat(command: Dictionary, context: Dictionary) -> Dictionary:
	var result := _actor_target_plan(command, context, "actor_ids", "target", "retreat", "owned")
	if not bool(result["ok"]):
		return result
	var target_record: Dictionary = (result["plan"] as Dictionary).get("target_record", {})
	if not target_record.is_empty() and not _record_has_any_tag(target_record, ["hall", "stronghold", "deposit"]):
		return _failure("invalid_target_type")
	(result["plan"] as Dictionary).erase("target_record")
	return result


func _validate_set_stance(command: Dictionary, context: Dictionary) -> Dictionary:
	var actors := _owned_actors(command["actor_ids"], context, "set_stance", [])
	if not bool(actors["ok"]):
		return actors
	return _success(_plan(
		actors["actor_ids"], {}, "none", {"stance": str(command["stance"])}
	))


func _validate_gather(command: Dictionary, context: Dictionary) -> Dictionary:
	var actors := _owned_actors(command["worker_ids"], context, "gather", ["worker"])
	if not bool(actors["ok"]):
		return actors
	var target := _normalize_target(command["resource_target"], context, "visible_or_owned", false)
	if not bool(target["ok"]):
		return target
	var target_record: Dictionary = target.get("record", {})
	if not target_record.is_empty() and not _record_has_any_tag(target_record, ["resource", "gold", "lumber", "tree"]):
		return _failure("invalid_target_type")
	return _success(_plan(
		actors["actor_ids"], target["target"], str(command["queue"]), {}
	))


func _validate_return_cargo(command: Dictionary, context: Dictionary) -> Dictionary:
	var actors := _owned_actors(command["worker_ids"], context, "return_cargo", ["worker"])
	if not bool(actors["ok"]):
		return actors
	var target: Dictionary = {}
	if command.has("deposit_target"):
		var normalized := _normalize_target(command["deposit_target"], context, "owned", false)
		if not bool(normalized["ok"]):
			return normalized
		var record: Dictionary = normalized.get("record", {})
		if not _record_has_any_tag(record, ["deposit", "hall", "stronghold"]):
			return _failure("invalid_target_type")
		target = normalized["target"]
	return _success(_plan(
		actors["actor_ids"], target, str(command["queue"]), {}
	))


func _validate_repair(command: Dictionary, context: Dictionary) -> Dictionary:
	var actors := _owned_actors(command["worker_ids"], context, "repair", ["worker"])
	if not bool(actors["ok"]):
		return actors
	var target := _normalize_target(command["target"], context, "owned", false)
	if not bool(target["ok"]):
		return target
	if not bool((target.get("record", {}) as Dictionary).get("repairable", true)):
		return _failure("invalid_target_type")
	return _success(_plan(
		actors["actor_ids"], target["target"], str(command["queue"]), {}
	))


func _validate_build(command: Dictionary, context: Dictionary) -> Dictionary:
	var actors := _owned_actors(command["builder_ids"], context, "build", ["worker"])
	if not bool(actors["ok"]):
		return actors
	var catalog_code := _catalog_code(context, "building_type_ids", str(command["building_type_id"]), "requirement_not_met")
	if not catalog_code.is_empty():
		return _failure(catalog_code)
	var site_result := _normalize_target(
		{"kind": "site", "site_id": str(command["build_site_id"])}, context, "known", true
	)
	if not bool(site_result["ok"]):
		return site_result
	var site_record: Dictionary = site_result.get("record", {})
	if not bool(site_record.get("buildable", true)):
		return _failure("invalid_placement")
	var blocked := _first_record_block(actors["records"], "build", str(command["building_type_id"]))
	if not blocked.is_empty():
		return _failure(blocked)
	return _success(_plan(
		actors["actor_ids"],
		site_result["target"],
		"replace",
		{"building_type_id": str(command["building_type_id"])}
	))


func _validate_cancel_construction(command: Dictionary, context: Dictionary) -> Dictionary:
	var entity := _owned_actor(str(command["building_id"]), context, "cancel_construction", [])
	if not bool(entity["ok"]):
		return entity
	if bool((entity["record"] as Dictionary).get("construction_complete", false)):
		return _failure("requirement_not_met")
	return _success(_plan([], {}, "none", {}))


func _validate_produce(command: Dictionary, context: Dictionary) -> Dictionary:
	var producer := _owned_actor(str(command["producer_id"]), context, "produce", ["producer"])
	if not bool(producer["ok"]):
		return producer
	var type_id := str(command["unit_type_id"])
	var catalog_code := _catalog_code(context, "unit_type_ids", type_id, "requirement_not_met")
	if not catalog_code.is_empty():
		return _failure(catalog_code)
	var record: Dictionary = producer["record"]
	if not _record_allows_id(record, "producible_unit_ids", type_id):
		return _failure("requirement_not_met")
	var blocked := _record_block(record, "produce", type_id)
	if not blocked.is_empty():
		return _failure(blocked)
	var queue_size := int(record.get("production_queue_size", 0))
	var queue_limit := int(record.get("production_queue_limit", 5))
	if queue_size + int(command["quantity"]) > queue_limit:
		return _failure("queue_full")
	return _success(_plan([], {}, "none", {"unit_type_id": type_id}))


func _validate_research(command: Dictionary, context: Dictionary) -> Dictionary:
	var producer := _owned_actor(str(command["producer_id"]), context, "research", ["producer"])
	if not bool(producer["ok"]):
		return producer
	var upgrade_id := str(command["upgrade_id"])
	var catalog_code := _catalog_code(context, "upgrade_ids", upgrade_id, "requirement_not_met")
	if not catalog_code.is_empty():
		return _failure(catalog_code)
	var record: Dictionary = producer["record"]
	if not _record_allows_id(record, "researchable_upgrade_ids", upgrade_id):
		return _failure("requirement_not_met")
	var blocked := _record_block(record, "research", upgrade_id)
	if not blocked.is_empty():
		return _failure(blocked)
	return _success(_plan([], {}, "none", {"upgrade_id": upgrade_id}))


func _validate_upgrade_tier(command: Dictionary, context: Dictionary) -> Dictionary:
	var stronghold := _owned_actor(str(command["stronghold_id"]), context, "upgrade_tier", ["stronghold"])
	if not bool(stronghold["ok"]):
		return stronghold
	var target_tier := int(command["target_tier"])
	var record: Dictionary = stronghold["record"]
	if int(record.get("tier", target_tier - 1)) + 1 != target_tier:
		return _failure("requirement_not_met")
	var blocked := _record_block(record, "upgrade_tier", str(target_tier))
	if not blocked.is_empty():
		return _failure(blocked)
	return _success(_plan([], {}, "none", {"target_tier": target_tier}))


func _validate_cancel_queue(command: Dictionary, context: Dictionary) -> Dictionary:
	var producer := _owned_actor(str(command["producer_id"]), context, "cancel_queue", ["producer"])
	if not bool(producer["ok"]):
		return producer
	var queue_id := str(command["queue_entry_id"])
	if not _record_allows_id(producer["record"], "queue_entry_ids", queue_id):
		return _failure("target_unavailable")
	return _success(_plan([], {}, "none", {"queue_entry_id": queue_id}))


func _validate_set_rally(command: Dictionary, context: Dictionary) -> Dictionary:
	var producer := _owned_actor(str(command["producer_id"]), context, "set_rally", ["producer"])
	if not bool(producer["ok"]):
		return producer
	var target := _normalize_target(command["target"], context, "visible_or_owned", false)
	if not bool(target["ok"]):
		return target
	return _success(_plan([], target["target"], "none", {}))


func _validate_revive_hero(command: Dictionary, context: Dictionary) -> Dictionary:
	var reviver := _owned_actor(str(command["reviver_id"]), context, "revive_hero", [])
	if not bool(reviver["ok"]):
		return reviver
	var hero := _owned_entity_record(str(command["hero_id"]), context, false)
	if not bool(hero["ok"]):
		return hero
	if not _record_has_any_tag(hero["record"], ["hero"]) or bool((hero["record"] as Dictionary).get("alive", true)):
		return _failure("requirement_not_met")
	var blocked := _record_block(reviver["record"], "revive_hero", str(command["revival_method"]))
	if not blocked.is_empty():
		return _failure(blocked)
	return _success(_plan([], {}, "none", {
		"hero": _entity_reference(str(command["hero_id"]), context),
		"revival_method": str(command["revival_method"]),
	}))


func _validate_cast(command: Dictionary, context: Dictionary) -> Dictionary:
	var actor := _owned_actor(str(command["actor_id"]), context, "cast", [])
	if not bool(actor["ok"]):
		return actor
	var ability_id := str(command["ability_id"])
	var catalog_code := _catalog_code(context, "ability_ids", ability_id, "ability_unavailable")
	if not catalog_code.is_empty() or not _record_allows_id(actor["record"], "ability_ids", ability_id):
		return _failure("ability_unavailable")
	var ready_code := _ability_ready_code(actor["record"], ability_id, context)
	if not ready_code.is_empty():
		return _failure(ready_code)
	var target: Dictionary = {}
	if command.has("target"):
		var normalized := _normalize_target(command["target"], context, "visible_or_owned", false)
		if not bool(normalized["ok"]):
			return normalized
		target = normalized["target"]
	var blocked := _record_block(actor["record"], "cast", ability_id)
	if not blocked.is_empty():
		return _failure(blocked)
	var plan := _plan([], target, str(command["queue"]), {"ability_id": ability_id})
	plan["queue_actor_ids"] = [str(command["actor_id"])]
	return _success(plan)


func _validate_set_autocast(command: Dictionary, context: Dictionary) -> Dictionary:
	var actors := _owned_actors(command["actor_ids"], context, "set_autocast", [])
	if not bool(actors["ok"]):
		return actors
	var ability_id := str(command["ability_id"])
	if not _catalog_code(context, "ability_ids", ability_id, "ability_unavailable").is_empty():
		return _failure("ability_unavailable")
	for record_variant: Variant in actors["records"]:
		if not _record_allows_id(record_variant, "ability_ids", ability_id):
			return _failure("ability_unavailable")
	return _success(_plan(actors["actor_ids"], {}, "none", {
		"ability_id": ability_id,
		"enabled": bool(command["enabled"]),
	}))


func _validate_learn_ability(command: Dictionary, context: Dictionary) -> Dictionary:
	var hero := _owned_actor(str(command["hero_id"]), context, "learn_ability", ["hero"])
	if not bool(hero["ok"]):
		return hero
	var ability_id := str(command["ability_id"])
	if not _catalog_code(context, "ability_ids", ability_id, "ability_unavailable").is_empty() \
		or not _record_allows_id(hero["record"], "learnable_ability_ids", ability_id):
		return _failure("ability_unavailable")
	var blocked := _record_block(hero["record"], "learn_ability", ability_id)
	if not blocked.is_empty():
		return _failure(blocked)
	return _success(_plan([], {}, "none", {"ability_id": ability_id}))


func _validate_use_item(command: Dictionary, context: Dictionary) -> Dictionary:
	var hero := _owned_actor(str(command["hero_id"]), context, "use_item", ["hero"])
	if not bool(hero["ok"]):
		return hero
	var item_id := str(command["item_instance_id"])
	if not _record_allows_id(hero["record"], "item_instance_ids", item_id):
		return _failure("requirement_not_met")
	if str(command["queue"]) == "front" and not _record_allows_id(hero["record"], "defensive_item_instance_ids", item_id):
		return _failure("conflicting_order")
	var target: Dictionary = {}
	if command.has("target"):
		var normalized := _normalize_target(command["target"], context, "visible_or_owned", false)
		if not bool(normalized["ok"]):
			return normalized
		target = normalized["target"]
	var blocked := _record_block(hero["record"], "use_item", item_id)
	if not blocked.is_empty():
		return _failure(blocked)
	var plan := _plan([], target, str(command["queue"]), {"item_instance_id": item_id})
	plan["queue_actor_ids"] = [str(command["hero_id"])]
	return _success(plan)


func _validate_pick_up_item(command: Dictionary, context: Dictionary) -> Dictionary:
	var hero := _owned_actor(str(command["hero_id"]), context, "pick_up_item", ["hero"])
	if not bool(hero["ok"]):
		return hero
	var target := _normalize_target(
		{"kind": "entity", "entity_id": str(command["item_entity_id"])}, context, "visible", false
	)
	if not bool(target["ok"]):
		return target
	if not _record_has_any_tag(target.get("record", {}), ["item"]):
		return _failure("invalid_target_type")
	var plan := _plan([], target["target"], str(command["queue"]), {})
	plan["queue_actor_ids"] = [str(command["hero_id"])]
	return _success(plan)


func _validate_drop_item(command: Dictionary, context: Dictionary) -> Dictionary:
	var hero := _owned_actor(str(command["hero_id"]), context, "drop_item", ["hero"])
	if not bool(hero["ok"]):
		return hero
	var item_id := str(command["item_instance_id"])
	if not _record_allows_id(hero["record"], "item_instance_ids", item_id):
		return _failure("requirement_not_met")
	var target := _normalize_target(command["target"], context, "known", false)
	if not bool(target["ok"]):
		return target
	return _success(_plan([], target["target"], "none", {"item_instance_id": item_id}))


func _validate_transfer_item(command: Dictionary, context: Dictionary) -> Dictionary:
	var source := _owned_actor(str(command["from_hero_id"]), context, "transfer_item", ["hero"])
	if not bool(source["ok"]):
		return source
	var destination := _owned_actor(str(command["to_hero_id"]), context, "transfer_item", ["hero"])
	if not bool(destination["ok"]):
		return destination
	var item_id := str(command["item_instance_id"])
	if not _record_allows_id(source["record"], "item_instance_ids", item_id):
		return _failure("requirement_not_met")
	return _success(_plan([], {}, "none", {
		"item_instance_id": item_id,
		"to_hero": _entity_reference(str(command["to_hero_id"]), context),
	}))


func _validate_sell_item(command: Dictionary, context: Dictionary) -> Dictionary:
	var hero := _owned_actor(str(command["hero_id"]), context, "sell_item", ["hero"])
	if not bool(hero["ok"]):
		return hero
	var item_id := str(command["item_instance_id"])
	if not _record_allows_id(hero["record"], "item_instance_ids", item_id):
		return _failure("requirement_not_met")
	var shop := _normalize_target(
		{"kind": "entity", "entity_id": str(command["shop_id"])}, context, "visible_or_owned", false
	)
	if not bool(shop["ok"]):
		return shop
	if not _record_has_any_tag(shop.get("record", {}), ["shop"]):
		return _failure("invalid_target_type")
	return _success(_plan([], shop["target"], "none", {"item_instance_id": item_id}))


func _validate_purchase_offer(command: Dictionary, context: Dictionary) -> Dictionary:
	var buyer := _owned_actor(str(command["buyer_id"]), context, "purchase_offer", [])
	if not bool(buyer["ok"]):
		return buyer
	var shop := _normalize_target(
		{"kind": "entity", "entity_id": str(command["shop_id"])}, context, "visible_or_owned", false
	)
	if not bool(shop["ok"]):
		return shop
	if not _record_has_any_tag(shop.get("record", {}), ["shop"]):
		return _failure("invalid_target_type")
	var offer_id := str(command["offer_id"])
	if not _record_allows_id(shop.get("record", {}), "visible_offer_ids", offer_id):
		return _failure("target_unavailable")
	var target: Dictionary = shop["target"]
	var parameters := {"offer_id": offer_id}
	if command.has("service_target"):
		var service := _normalize_target(command["service_target"], context, "known", false)
		if not bool(service["ok"]):
			return service
		parameters["service_target"] = service["target"]
	var blocked := _record_block(buyer["record"], "purchase_offer", offer_id)
	if not blocked.is_empty():
		return _failure(blocked)
	return _success(_plan([], target, "none", parameters))


func _validate_load_transport(command: Dictionary, context: Dictionary) -> Dictionary:
	var transport := _owned_actor(str(command["transport_id"]), context, "load_transport", ["transport"])
	if not bool(transport["ok"]):
		return transport
	var passengers := _owned_actors(command["passenger_ids"], context, "load_transport", [])
	if not bool(passengers["ok"]):
		return passengers
	return _success({
		"actor_ids": [],
		"parameters": {},
		"passenger_ids": passengers["actor_ids"],
		"queue_actor_ids": [str(command["transport_id"])],
		"queue_policy": str(command["queue"]),
		"target": {},
	})


func _validate_unload_transport(command: Dictionary, context: Dictionary) -> Dictionary:
	var transport := _owned_actor(str(command["transport_id"]), context, "unload_transport", ["transport"])
	if not bool(transport["ok"]):
		return transport
	var record: Dictionary = transport["record"]
	var passenger_ids: Array = []
	if typeof(command["passengers"]) == TYPE_STRING:
		passenger_ids = (record.get("passenger_ids", []) as Array).duplicate()
	else:
		passenger_ids = (command["passengers"] as Array).duplicate()
	for passenger_id_variant: Variant in passenger_ids:
		if not _record_allows_id(record, "passenger_ids", str(passenger_id_variant)):
			return _failure("target_unavailable")
	var target := _normalize_target(command["target"], context, "known", true)
	if not bool(target["ok"]):
		return target
	return _success({
		"actor_ids": [],
		"parameters": {},
		"passenger_ids": passenger_ids,
		"queue_actor_ids": [],
		"queue_policy": "none",
		"target": target["target"],
	})


func _validate_define_squad(
	command: Dictionary,
	context: Dictionary,
	projected: Dictionary
) -> Dictionary:
	var squad_id := str(command["squad_id"])
	var squads: Dictionary = projected["squads"]
	if squads.has(squad_id):
		return _failure("conflicting_order")
	var members := _owned_actors(command["member_ids"], context, "define_squad", [])
	if not bool(members["ok"]):
		return members
	return _success_with_mutation(
		_plan([], {}, "none", {"member_ids": members["actor_ids"], "squad_id": squad_id}),
		{"kind": "set_squad", "member_ids": members["actor_ids"], "squad_id": squad_id}
	)


func _validate_update_squad(
	command: Dictionary,
	context: Dictionary,
	projected: Dictionary
) -> Dictionary:
	var squad_id := str(command["squad_id"])
	var squads: Dictionary = projected["squads"]
	if not squads.has(squad_id):
		return _failure("requirement_not_met")
	var members := _owned_actors(command["member_ids"], context, "update_squad", [])
	if not bool(members["ok"]):
		return members
	return _success_with_mutation(
		_plan([], {}, "none", {"member_ids": members["actor_ids"], "squad_id": squad_id}),
		{"kind": "set_squad", "member_ids": members["actor_ids"], "squad_id": squad_id}
	)


func _validate_disband_squad(command: Dictionary, projected: Dictionary) -> Dictionary:
	var squad_id := str(command["squad_id"])
	if not (projected["squads"] as Dictionary).has(squad_id):
		return _failure("requirement_not_met")
	return _success_with_mutation(
		_plan([], {}, "none", {"squad_id": squad_id}),
		{"kind": "erase_squad", "squad_id": squad_id}
	)


func _validate_order_squad(
	command: Dictionary,
	context: Dictionary,
	projected: Dictionary,
	frozen_squads: Dictionary
) -> Dictionary:
	var squad_id := str(command["squad_id"])
	if not (projected["squads"] as Dictionary).has(squad_id) or not frozen_squads.has(squad_id):
		return _failure("requirement_not_met")
	var projected_members: Array = ((projected["squads"] as Dictionary)[squad_id] as Dictionary).get("member_ids", [])
	var frozen_members: Array = (frozen_squads[squad_id] as Dictionary).get("member_ids", [])
	if projected_members != frozen_members:
		## Prevent update-then-order from evading Python's frozen squad-size budget.
		return _failure("conflicting_order")
	var members := _owned_actors(frozen_members, context, "order_squad", [])
	if not bool(members["ok"]):
		return members
	var objective := str(command["objective"])
	var target_kind := Contract.target_kind(command["target"])
	if objective == "focus_visible_entity" and target_kind != "entity":
		return _failure("invalid_target_type")
	if objective == "retreat_to" and not ["entity", "site"].has(target_kind):
		return _failure("invalid_target_type")
	if objective == "patrol_points" and not ["point", "region_slot"].has(target_kind):
		return _failure("invalid_target_type")
	var target_policy := "visible" if objective == "focus_visible_entity" else (
		"owned" if objective == "retreat_to" else "visible_or_owned"
	)
	var target := _normalize_target(command["target"], context, target_policy, false)
	if not bool(target["ok"]):
		return target
	var compiled_operations := {
		"attack_move_to": "attack_move",
		"focus_visible_entity": "attack_entity",
		"hold_area": "hold_area",
		"move_to": "move",
		"patrol_points": "patrol_points",
		"retreat_to": "retreat",
	}
	var plan := _plan(
		members["actor_ids"],
		target["target"],
		str(command["queue"]),
		{
			"engagement": str(command["engagement"]),
			"formation": str(command["formation"]),
			"objective": objective,
			"squad_id": squad_id,
		}
	)
	plan["compiled_operation"] = str(compiled_operations[objective])
	return _success(plan)


func _validate_set_tactics(
	command: Dictionary,
	context: Dictionary,
	projected: Dictionary,
	frozen_squads: Dictionary
) -> Dictionary:
	var subject: Dictionary = command["subject"]
	var actor_ids: Array = []
	var subject_parameters: Dictionary = subject.duplicate(true)
	if str(subject["kind"]) == "actors":
		actor_ids = (subject["actor_ids"] as Array).duplicate()
	else:
		var squad_id := str(subject["squad_id"])
		if not (projected["squads"] as Dictionary).has(squad_id) or not frozen_squads.has(squad_id):
			return _failure("requirement_not_met")
		var current_members: Array = ((projected["squads"] as Dictionary)[squad_id] as Dictionary).get("member_ids", [])
		actor_ids = (frozen_squads[squad_id] as Dictionary).get("member_ids", [])
		if current_members != actor_ids:
			return _failure("conflicting_order")
	var actors := _owned_actors(actor_ids, context, "set_tactics", [])
	if not bool(actors["ok"]):
		return actors
	var target: Dictionary = {}
	if command.has("retreat_target"):
		var normalized := _normalize_target(command["retreat_target"], context, "owned", false)
		if not bool(normalized["ok"]):
			return normalized
		target = normalized["target"]
	var parameters := {
		"focus_tag": str(command["focus_tag"]),
		"formation": str(command["formation"]),
		"retreat_hp_threshold_bp": int(command["retreat_hp_threshold_bp"]),
		"stance": str(command["stance"]),
		"subject": subject_parameters,
	}
	var plan := _plan(actors["actor_ids"], target, "none", parameters)
	if str(subject["kind"]) == "squad":
		return _success_with_mutation(plan, {
			"kind": "set_squad_tactics",
			"squad_id": str(subject["squad_id"]),
			"tactics": {
				"focus_tag": str(command["focus_tag"]),
				"formation": str(command["formation"]),
				"retreat_hp_threshold_bp": int(command["retreat_hp_threshold_bp"]),
				"retreat_target": target.duplicate(true),
				"stance": str(command["stance"]),
			},
		})
	return _success(plan)


func _actor_target_plan(
	command: Dictionary,
	context: Dictionary,
	actor_field: String,
	target_field: String,
	operation: String,
	target_policy: String
) -> Dictionary:
	var actors := _owned_actors(command[actor_field], context, operation, [])
	if not bool(actors["ok"]):
		return actors
	var target := _normalize_target(command[target_field], context, target_policy, false)
	if not bool(target["ok"]):
		return target
	var plan := _plan(
		actors["actor_ids"], target["target"], str(command["queue"]), {}
	)
	if target.has("record"):
		plan["target_record"] = target["record"]
	return _success(plan)


func _owned_actors(
	actor_ids_variant: Variant,
	context: Dictionary,
	operation: String,
	required_tags: Array[String]
) -> Dictionary:
	if typeof(actor_ids_variant) != TYPE_ARRAY:
		return _failure("too_many_actors")
	var actor_ids: Array = actor_ids_variant
	var records: Array[Dictionary] = []
	for actor_id_variant: Variant in actor_ids:
		var actor := _owned_actor(str(actor_id_variant), context, operation, required_tags)
		if not bool(actor["ok"]):
			return actor
		records.append(actor["record"])
	return {"actor_ids": actor_ids.duplicate(), "ok": true, "records": records}


func _owned_actor(
	actor_id: String,
	context: Dictionary,
	operation: String,
	required_tags: Array[String]
) -> Dictionary:
	var result := _owned_entity_record(actor_id, context, true)
	if not bool(result["ok"]):
		return result
	var record: Dictionary = result["record"]
	if not required_tags.is_empty() and not _record_has_any_tag(record, required_tags):
		return _failure("requirement_not_met")
	if record.has("legal_ops") and not _variant_collection_has(record["legal_ops"], operation):
		return _failure("requirement_not_met")
	var blocked := _record_block(record, operation, "")
	if not blocked.is_empty():
		return _failure(blocked)
	return result


func _owned_entity_record(actor_id: String, context: Dictionary, require_available: bool) -> Dictionary:
	var entities: Dictionary = context["entities"]
	if not entities.has(actor_id):
		return _failure("unknown_entity")
	var record_variant: Variant = entities[actor_id]
	if typeof(record_variant) != TYPE_DICTIONARY:
		return _failure("execution_failed")
	var record: Dictionary = record_variant
	if not bool(record.get("known", true)):
		return _failure("unknown_entity")
	if int(record.get("owner_seat", -1)) != int(context["player_seat"]):
		return _failure("not_owner")
	if require_available and not _record_available(record, context):
		return _failure("actor_unavailable")
	return {"ok": true, "record": record}


func _normalize_target(
	target_variant: Variant,
	context: Dictionary,
	entity_policy: String,
	require_explored: bool
) -> Dictionary:
	var target: Dictionary = target_variant
	match str(target["kind"]):
		"entity":
			var entity_id := str(target["entity_id"])
			var entities: Dictionary = context["entities"]
			if not entities.has(entity_id) or typeof(entities[entity_id]) != TYPE_DICTIONARY:
				return _failure("target_unavailable")
			var record: Dictionary = entities[entity_id]
			var owned := int(record.get("owner_seat", -1)) == int(context["player_seat"])
			var visible := bool(record.get("visible", owned))
			if entity_policy == "owned" and not owned:
				return _failure("target_unavailable")
			if entity_policy == "visible" and not visible:
				return _failure("target_unavailable")
			if entity_policy == "visible_or_owned" and not visible and not owned:
				return _failure("target_unavailable")
			if not _record_available(record, context):
				return _failure("target_unavailable")
			return {
				"ok": true,
				"record": record,
				"target": _entity_reference(entity_id, context),
			}
		"point":
			var point: Array = target["xy_mt"]
			var world_max: Array = context["world_max_inclusive_mt"]
			if int(point[0]) > int(world_max[0]) or int(point[1]) > int(world_max[1]):
				return _failure("out_of_bounds")
			if require_explored and not _point_explored(point, context):
				return _failure("unexplored_location")
			return {"ok": true, "target": {
				"kind": "point",
				"xy_mt": _self_point_to_world(point, context),
			}}
		"region_slot":
			var region_id := str(target["region_id"])
			var slot_id := str(target["slot_id"])
			var regions: Dictionary = context["known_regions"]
			if not regions.has(region_id) or typeof(regions[region_id]) != TYPE_DICTIONARY:
				return _failure("unexplored_location")
			var region: Dictionary = regions[region_id]
			var slots: Variant = region.get("slots", {})
			if not _variant_collection_has(slots, slot_id):
				return _failure("unexplored_location")
			var result_target := {
				"kind": "region_slot",
				"region_id": str(region.get("world_region_id", _self_public_id_to_world(region_id, context))),
				"slot_id": _world_slot_id(slot_id, slots, context),
			}
			var slot_record: Variant = (slots as Dictionary).get(slot_id, {}) if typeof(slots) == TYPE_DICTIONARY else {}
			if typeof(slot_record) == TYPE_DICTIONARY and (slot_record as Dictionary).has("xy_mt"):
				result_target["xy_mt"] = _self_point_to_world((slot_record as Dictionary)["xy_mt"], context)
			return {"ok": true, "record": region, "target": result_target}
		"site":
			var site_id := str(target["site_id"])
			var sites: Dictionary = context["known_sites"]
			if not sites.has(site_id) or typeof(sites[site_id]) != TYPE_DICTIONARY:
				return _failure("unexplored_location")
			var site: Dictionary = sites[site_id]
			if require_explored and not bool(site.get("explored", false)):
				return _failure("unexplored_location")
			if entity_policy == "owned" and int(site.get("owner_seat", -1)) != int(context["player_seat"]):
				return _failure("target_unavailable")
			var result_target := {
				"kind": "site",
				"site_id": str(site.get("world_site_id", _self_public_id_to_world(site_id, context))),
			}
			if site.has("xy_mt"):
				result_target["xy_mt"] = _self_point_to_world(site["xy_mt"], context)
			return {"ok": true, "record": site, "target": result_target}
	return _failure("invalid_target_type")


func _validate_and_project_queue(
	command: Dictionary,
	plan: Dictionary,
	context: Dictionary,
	projected: Dictionary
) -> Dictionary:
	var queue_policy := str(plan.get("queue_policy", "none"))
	var operation := str(command["op"])
	var queue_actor_ids: Array = plan.get("queue_actor_ids", plan.get("actor_ids", []))
	var sizes: Dictionary = (projected["queue_sizes"] as Dictionary).duplicate(true)
	var replace_claims: Dictionary = (projected["replace_claims"] as Dictionary).duplicate(true)
	if queue_policy == "none" or queue_actor_ids.is_empty():
		return {"ok": true, "queue_sizes": sizes, "replace_claims": replace_claims}
	if queue_policy == "front" and not Contract.FRONT_ALLOWED.has(operation):
		return {"code": "conflicting_order", "ok": false}
	for actor_id_variant: Variant in queue_actor_ids:
		var actor_id := str(actor_id_variant)
		var record: Dictionary = (context["entities"] as Dictionary).get(actor_id, {})
		if (queue_policy == "replace" or queue_policy == "front") \
			and not bool(record.get("current_order_interruptible", true)):
			return {"code": "conflicting_order", "ok": false}
		if queue_policy == "replace":
			if replace_claims.has(actor_id):
				return {"code": "conflicting_order", "ok": false}
			replace_claims[actor_id] = str(command["command_id"])
			sizes[actor_id] = 0
		elif queue_policy == "append":
			var current_size := int(sizes.get(actor_id, 0))
			if current_size >= Contract.MAX_QUEUE_ENTRIES:
				return {"code": "queue_full", "ok": false}
			sizes[actor_id] = current_size + 1
	return {"ok": true, "queue_sizes": sizes, "replace_claims": replace_claims}


func _apply_projected_mutation(validation: Dictionary, projected: Dictionary) -> void:
	if not validation.has("mutation"):
		return
	var mutation: Dictionary = validation["mutation"]
	var squads: Dictionary = projected["squads"]
	var squad_id := str(mutation["squad_id"])
	if str(mutation["kind"]) == "erase_squad":
		squads.erase(squad_id)
		return
	if str(mutation["kind"]) == "set_squad_tactics":
		var existing: Dictionary = squads.get(squad_id, {})
		existing["tactics"] = (mutation["tactics"] as Dictionary).duplicate(true)
		squads[squad_id] = existing
		return
	var previous: Dictionary = squads.get(squad_id, {})
	squads[squad_id] = {
		"member_ids": (mutation["member_ids"] as Array).duplicate(),
		"tactics": (previous.get("tactics", {}) as Dictionary).duplicate(true),
	}


func _boundary_code(batch: Dictionary, context: Dictionary) -> String:
	if str(batch["match_id"]) != str(context["match_id"]):
		return "wrong_match"
	if int(batch["observation_seq"]) != int(context["observation_seq"]):
		return "wrong_observation"
	if str(batch["based_on_observation_hash"]) != str(context["observation_hash"]):
		return "observation_hash_mismatch"
	if int(batch["valid_until_tick"]) > int(context["controller_valid_until_tick"]):
		return "schema_mismatch"
	if int(context["application_tick"]) > int(batch["valid_until_tick"]):
		return "expired_batch"
	if _variant_collection_has(context.get("accepted_batch_ids", []), str(batch["client_batch_id"])):
		return "duplicate_batch"
	return ""


func _context_code(context: Dictionary) -> String:
	var required := [
		"accepted_batch_ids",
		"application_tick",
		"controller_valid_until_tick",
		"entities",
		"known_regions",
		"known_sites",
		"match_id",
		"observation_hash",
		"observation_seq",
		"player_seat",
		"received_tick",
		"self_rotates_to_world",
		"squad_sizes",
		"squads",
		"transport_passenger_counts",
		"world_max_inclusive_mt",
	]
	for field: String in required:
		if not context.has(field):
			return "missing %s" % field
	if typeof(context["application_tick"]) != TYPE_INT or int(context["application_tick"]) < 1:
		return "invalid application_tick"
	if typeof(context["controller_valid_until_tick"]) != TYPE_INT:
		return "invalid controller_valid_until_tick"
	if typeof(context["received_tick"]) != TYPE_INT or int(context["received_tick"]) < 0:
		return "invalid received_tick"
	if typeof(context["player_seat"]) != TYPE_INT or not [0, 1].has(int(context["player_seat"])):
		return "invalid player_seat"
	if typeof(context["self_rotates_to_world"]) != TYPE_BOOL:
		return "invalid self_rotates_to_world"
	if bool(context["self_rotates_to_world"]) != (int(context["player_seat"]) == 1):
		return "coordinate transform does not match player_seat"
	if typeof(context["world_max_inclusive_mt"]) != TYPE_ARRAY \
		or (context["world_max_inclusive_mt"] as Array).size() != 2 \
		or typeof(context["world_max_inclusive_mt"][0]) != TYPE_INT \
		or typeof(context["world_max_inclusive_mt"][1]) != TYPE_INT:
		return "invalid world bounds"
	if context["world_max_inclusive_mt"] != [191999, 127999]:
		return "world bounds do not match crossroads-duel-v1"
	if not Contract.is_match_id(context["match_id"]) \
		or not Contract.is_sha256(context["observation_hash"]) \
		or typeof(context["observation_seq"]) != TYPE_INT:
		return "invalid observation boundary"
	for field: String in [
		"entities", "known_regions", "known_sites", "squad_sizes", "squads",
		"transport_passenger_counts",
	]:
		if typeof(context[field]) != TYPE_DICTIONARY:
			return "invalid %s" % field
	if typeof(context["accepted_batch_ids"]) != TYPE_ARRAY:
		return "invalid accepted_batch_ids"
	if not Codec.validate_canonical_value(context).is_empty():
		return "legal context is not canonical JSON-safe data"
	for public_id_variant: Variant in (context["entities"] as Dictionary).keys():
		if not Contract.is_entity_id(public_id_variant):
			return "invalid entity alias"
		var entity_record_variant: Variant = context["entities"][public_id_variant]
		if typeof(entity_record_variant) != TYPE_DICTIONARY:
			return "invalid entity record"
		var entity_record: Dictionary = entity_record_variant
		if not entity_record.has("internal_id") \
			or typeof(entity_record["internal_id"]) not in [TYPE_INT, TYPE_STRING]:
			return "entity alias is missing a canonical internal_id"
		if typeof(entity_record.get("owner_seat", null)) != TYPE_INT \
			or int(entity_record["owner_seat"]) < -1 or int(entity_record["owner_seat"]) > 1:
			return "invalid entity owner"
	for squad_id_variant: Variant in (context["squad_sizes"] as Dictionary).keys():
		var count: Variant = context["squad_sizes"][squad_id_variant]
		if typeof(count) != TYPE_INT or int(count) < 0 or int(count) > Contract.MAX_ACTORS:
			return "invalid squad size"
		var squad_id := str(squad_id_variant)
		if (context["squads"] as Dictionary).has(squad_id):
			var squad_record: Variant = context["squads"][squad_id]
			if typeof(squad_record) != TYPE_DICTIONARY \
				or typeof((squad_record as Dictionary).get("member_ids", null)) != TYPE_ARRAY \
				or ((squad_record as Dictionary)["member_ids"] as Array).size() != int(count):
				return "squad size does not match frozen members"
	for transport_id_variant: Variant in (context["transport_passenger_counts"] as Dictionary).keys():
		var count: Variant = context["transport_passenger_counts"][transport_id_variant]
		if typeof(count) != TYPE_INT or int(count) < 0 or int(count) > Contract.MAX_ACTORS:
			return "invalid transport count"
		var transport_id := str(transport_id_variant)
		if (context["entities"] as Dictionary).has(transport_id):
			var transport_record: Variant = context["entities"][transport_id]
			if typeof(transport_record) == TYPE_DICTIONARY \
				and (transport_record as Dictionary).has("passenger_ids") \
				and ((transport_record as Dictionary)["passenger_ids"] as Array).size() != int(count):
				return "transport count does not match frozen passengers"
	return ""


func _record_available(record: Dictionary, context: Dictionary) -> bool:
	var application_tick := int(context["application_tick"])
	if not bool(record.get("available", true)) or not bool(record.get("alive", true)):
		return false
	if int(record.get("available_from_tick", 0)) > application_tick:
		return false
	if record.has("unavailable_at_tick") and int(record["unavailable_at_tick"]) <= application_tick:
		return false
	return true


func _ability_ready_code(record: Dictionary, ability_id: String, context: Dictionary) -> String:
	var ready_ticks: Variant = record.get("ability_ready_ticks", {})
	if typeof(ready_ticks) == TYPE_DICTIONARY \
		and int((ready_ticks as Dictionary).get(ability_id, 0)) > int(context["application_tick"]):
		return "cooldown_active"
	return ""


func _record_block(record: Dictionary, operation: String, qualifier: String) -> String:
	var blocks: Variant = record.get("rejection_codes", {})
	if typeof(blocks) != TYPE_DICTIONARY:
		return ""
	var keys: Array[String] = []
	if not qualifier.is_empty():
		keys.append("%s:%s" % [operation, qualifier])
	keys.append(operation)
	for key: String in keys:
		if (blocks as Dictionary).has(key):
			var code := str((blocks as Dictionary)[key])
			return code if STABLE_COMMAND_CODES.has(code) else "execution_failed"
	return ""


func _first_record_block(records: Array, operation: String, qualifier: String) -> String:
	for record_variant: Variant in records:
		var code := _record_block(record_variant, operation, qualifier)
		if not code.is_empty():
			return code
	return ""


func _record_has_any_tag(record_variant: Variant, required_tags: Array[String]) -> bool:
	if typeof(record_variant) != TYPE_DICTIONARY:
		return false
	var record: Dictionary = record_variant
	if not record.has("tags"):
		## Some integration fixtures use explicit legal_ops without redundant tags.
		return true
	for tag: String in required_tags:
		if _variant_collection_has(record["tags"], tag):
			return true
	return false


func _record_allows_id(record_variant: Variant, field: String, value: String) -> bool:
	if typeof(record_variant) != TYPE_DICTIONARY:
		return false
	var record: Dictionary = record_variant
	return not record.has(field) or _variant_collection_has(record[field], value)


func _catalog_code(
	context: Dictionary,
	category: String,
	value: String,
	failure_code: String
) -> String:
	var catalog_ids: Variant = context.get("catalog_ids", {})
	if typeof(catalog_ids) != TYPE_DICTIONARY or not (catalog_ids as Dictionary).has(category):
		return ""
	return "" if _variant_collection_has((catalog_ids as Dictionary)[category], value) else failure_code


func _point_explored(self_point: Array, context: Dictionary) -> bool:
	if bool(context.get("all_points_explored", false)):
		return true
	var key := "%d,%d" % [int(self_point[0]), int(self_point[1])]
	return _variant_collection_has(context.get("explored_points", []), key)


func _self_point_to_world(self_point: Array, context: Dictionary) -> Array:
	if not bool(context["self_rotates_to_world"]):
		return [int(self_point[0]), int(self_point[1])]
	var world_max: Array = context["world_max_inclusive_mt"]
	return [
		int(world_max[0]) - int(self_point[0]),
		int(world_max[1]) - int(self_point[1]),
	]


func _self_public_id_to_world(public_id: String, context: Dictionary) -> String:
	var mapping: Variant = context.get("self_to_world_public_ids", {})
	if typeof(mapping) == TYPE_DICTIONARY and (mapping as Dictionary).has(public_id):
		return str((mapping as Dictionary)[public_id])
	return public_id


func _world_slot_id(slot_id: String, slots: Variant, context: Dictionary) -> String:
	if typeof(slots) == TYPE_DICTIONARY and typeof((slots as Dictionary).get(slot_id, null)) == TYPE_DICTIONARY:
		var record: Dictionary = (slots as Dictionary)[slot_id]
		if record.has("world_slot_id"):
			return str(record["world_slot_id"])
	return _self_public_id_to_world(slot_id, context)


func _entity_reference(public_id: String, context: Dictionary) -> Dictionary:
	var entities: Dictionary = context["entities"]
	var record: Dictionary = entities.get(public_id, {})
	return {
		"internal_id": record.get("internal_id", public_id),
		"kind": "entity",
		"public_id": public_id,
	}


func _initial_queue_sizes(context: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var entities: Dictionary = context["entities"]
	var ids: Array = entities.keys()
	ids.sort()
	for id_variant: Variant in ids:
		var record_variant: Variant = entities[id_variant]
		if typeof(record_variant) == TYPE_DICTIONARY:
			result[str(id_variant)] = int((record_variant as Dictionary).get("order_queue_size", 0))
	return result


func _canonical_squads(squads_variant: Variant) -> Dictionary:
	var result: Dictionary = {}
	if typeof(squads_variant) != TYPE_DICTIONARY:
		return result
	var ids: Array = (squads_variant as Dictionary).keys()
	ids.sort()
	for id_variant: Variant in ids:
		var squad_variant: Variant = (squads_variant as Dictionary)[id_variant]
		if typeof(squad_variant) != TYPE_DICTIONARY:
			continue
		var squad: Dictionary = squad_variant
		result[str(id_variant)] = {
			"member_ids": (squad.get("member_ids", []) as Array).duplicate(),
			"tactics": (squad.get("tactics", {}) as Dictionary).duplicate(true),
		}
	return result


func _sorted_dictionary(value_variant: Variant) -> Dictionary:
	var result: Dictionary = {}
	if typeof(value_variant) != TYPE_DICTIONARY:
		return result
	var keys: Array = (value_variant as Dictionary).keys()
	keys.sort()
	for key: Variant in keys:
		result[str(key)] = (value_variant as Dictionary)[key]
	return result


func _variant_collection_has(value: Variant, needle: String) -> bool:
	if typeof(value) == TYPE_ARRAY:
		return (value as Array).has(needle)
	if typeof(value) == TYPE_PACKED_STRING_ARRAY:
		return (value as PackedStringArray).has(needle)
	if typeof(value) == TYPE_DICTIONARY:
		return (value as Dictionary).has(needle)
	return false


func _plan(
	actor_ids: Array,
	target: Dictionary,
	queue_policy: String,
	parameters: Dictionary
) -> Dictionary:
	return {
		"actor_ids": actor_ids.duplicate(),
		"parameters": parameters,
		"queue_policy": queue_policy,
		"target": target,
	}


func _success(plan: Dictionary) -> Dictionary:
	return {"ok": true, "plan": plan}


func _success_with_mutation(plan: Dictionary, mutation: Dictionary) -> Dictionary:
	return {"mutation": mutation, "ok": true, "plan": plan}


func _failure(code: String) -> Dictionary:
	return {"code": code, "ok": false}


func _rejected_command_receipt(command_id: String, code: String, atomic_cost: int) -> Dictionary:
	return {
		"atomic_cost": maxi(0, atomic_cost),
		"code": code,
		"command_id": command_id,
		"compiled_order_ids": [],
		"status": "rejected",
	}


func _batch_status(receipts: Array[Dictionary]) -> String:
	if receipts.is_empty():
		return "no_op"
	var applied := 0
	for receipt: Dictionary in receipts:
		if str(receipt["status"]) == "applied" or str(receipt["status"]) == "partially_applied":
			applied += 1
	if applied == receipts.size():
		return "applied"
	if applied > 0:
		return "partially_applied"
	return "rejected"


func _envelope_failure(batch: Variant, context: Dictionary, code: String) -> Dictionary:
	var batch_id := "invalid"
	var observation_seq := maxi(0, int(context.get("observation_seq", 0)))
	var digest := ""
	if typeof(batch) == TYPE_DICTIONARY:
		var batch_dict: Dictionary = batch
		if Contract.is_batch_id(batch_dict.get("client_batch_id", null)):
			batch_id = str(batch_dict["client_batch_id"])
		if typeof(batch_dict.get("observation_seq", null)) == TYPE_INT:
			observation_seq = maxi(0, int(batch_dict["observation_seq"]))
		if Codec.validate_canonical_value(batch_dict).is_empty():
			digest = Codec.sha256_canonical(batch_dict)
	var application_tick: Variant = context.get("application_tick", null)
	var apply_tick: Variant = application_tick if typeof(application_tick) == TYPE_INT \
		and int(application_tick) >= 1 else null
	var status := "expired" if code == "expired_batch" else "rejected"
	return {
		"atomic_cost": 0,
		"batch_digest": digest,
		"code": code,
		"intents": [],
		"ok": false,
		"projected_order_queue_sizes": {},
		"receipt": {
			"apply_tick": apply_tick,
			"batch_id": batch_id,
			"batch_status": status,
			"code": code,
			"commands": [],
			"observation_seq": observation_seq,
			"received_tick": maxi(0, int(context.get("received_tick", 0))),
		},
		"squads": _canonical_squads(context.get("squads", {})),
	}
