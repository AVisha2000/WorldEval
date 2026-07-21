class_name DuelOrderCompiler
extends RefCounted

## Converts an individually legal hybrid-v1 command into canonical, typed
## intents.  These dictionaries are the only action output consumed by later
## simulation/economy/combat integration.  This compiler never mutates world
## state and never dispatches by reflection.

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")


func compile_command(
	command: Dictionary,
	command_index: int,
	batch: Dictionary,
	legal_context: Dictionary,
	plan: Dictionary
) -> Array[Dictionary]:
	var operation := str(command["op"])
	match operation:
		"move":
			return _compile_actor_orders(command, command_index, batch, legal_context, plan, "order", "move")
		"attack_move":
			return _compile_actor_orders(command, command_index, batch, legal_context, plan, "order", "attack_move")
		"attack_entity":
			return _compile_actor_orders(command, command_index, batch, legal_context, plan, "order", "attack_entity")
		"attack_ground":
			return _compile_actor_orders(command, command_index, batch, legal_context, plan, "order", "attack_ground")
		"stop":
			return _compile_actor_orders(command, command_index, batch, legal_context, plan, "order", "stop")
		"hold_position":
			return _compile_actor_orders(command, command_index, batch, legal_context, plan, "order", "hold_position")
		"patrol":
			return _compile_actor_orders(command, command_index, batch, legal_context, plan, "order", "patrol")
		"follow":
			return _compile_actor_orders(command, command_index, batch, legal_context, plan, "order", "follow")
		"retreat":
			return _compile_actor_orders(command, command_index, batch, legal_context, plan, "order", "retreat")
		"set_stance":
			return _compile_actor_orders(command, command_index, batch, legal_context, plan, "tactics", "set_stance")
		"gather":
			return _compile_actor_orders(command, command_index, batch, legal_context, plan, "economy", "gather")
		"return_cargo":
			return _compile_actor_orders(command, command_index, batch, legal_context, plan, "economy", "return_cargo")
		"repair":
			return _compile_actor_orders(command, command_index, batch, legal_context, plan, "economy", "repair")
		"build":
			return _compile_build(command, command_index, batch, legal_context, plan)
		"cancel_construction":
			return _compile_single(command, command_index, batch, legal_context, plan, "economy", "cancel_construction", str(command["building_id"]))
		"produce":
			return _compile_quantity(command, command_index, batch, legal_context, plan, "economy", "produce", str(command["producer_id"]), int(command["quantity"]))
		"research":
			return _compile_single(command, command_index, batch, legal_context, plan, "economy", "research", str(command["producer_id"]))
		"upgrade_tier":
			return _compile_single(command, command_index, batch, legal_context, plan, "economy", "upgrade_tier", str(command["stronghold_id"]))
		"cancel_queue":
			return _compile_single(command, command_index, batch, legal_context, plan, "economy", "cancel_queue", str(command["producer_id"]))
		"set_rally":
			return _compile_single(command, command_index, batch, legal_context, plan, "economy", "set_rally", str(command["producer_id"]))
		"revive_hero":
			return _compile_single(command, command_index, batch, legal_context, plan, "economy", "revive_hero", str(command["reviver_id"]))
		"cast":
			return _compile_single(command, command_index, batch, legal_context, plan, "ability", "cast", str(command["actor_id"]))
		"set_autocast":
			return _compile_actor_orders(command, command_index, batch, legal_context, plan, "ability", "set_autocast")
		"learn_ability":
			return _compile_single(command, command_index, batch, legal_context, plan, "ability", "learn_ability", str(command["hero_id"]))
		"use_item":
			return _compile_single(command, command_index, batch, legal_context, plan, "item", "use_item", str(command["hero_id"]))
		"pick_up_item":
			return _compile_single(command, command_index, batch, legal_context, plan, "item", "pick_up_item", str(command["hero_id"]))
		"drop_item":
			return _compile_single(command, command_index, batch, legal_context, plan, "item", "drop_item", str(command["hero_id"]))
		"transfer_item":
			return _compile_single(command, command_index, batch, legal_context, plan, "item", "transfer_item", str(command["from_hero_id"]))
		"sell_item":
			return _compile_single(command, command_index, batch, legal_context, plan, "item", "sell_item", str(command["hero_id"]))
		"purchase_offer":
			return _compile_quantity(command, command_index, batch, legal_context, plan, "item", "purchase_offer", str(command["buyer_id"]), int(command["quantity"]))
		"load_transport":
			return _compile_transport(command, command_index, batch, legal_context, plan, "load_transport")
		"unload_transport":
			return _compile_transport(command, command_index, batch, legal_context, plan, "unload_transport")
		"define_squad":
			return _compile_controller_intent(command, command_index, batch, legal_context, plan, "define_squad")
		"update_squad":
			return _compile_controller_intent(command, command_index, batch, legal_context, plan, "update_squad")
		"disband_squad":
			return _compile_controller_intent(command, command_index, batch, legal_context, plan, "disband_squad")
		"order_squad":
			return _compile_actor_orders(
				command,
				command_index,
				batch,
				legal_context,
				plan,
				"order",
				str(plan["compiled_operation"])
			)
		"set_tactics":
			return _compile_actor_orders(command, command_index, batch, legal_context, plan, "tactics", "set_tactics")
	return []


func _compile_actor_orders(
	command: Dictionary,
	command_index: int,
	batch: Dictionary,
	context: Dictionary,
	plan: Dictionary,
	intent_type: String,
	operation: String
) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var actor_ids: Array = plan.get("actor_ids", [])
	for expansion_index: int in actor_ids.size():
		results.append(_make_intent(
			command,
			command_index,
			expansion_index,
			batch,
			context,
			intent_type,
			operation,
			_entity_subject(str(actor_ids[expansion_index]), context),
			str(plan.get("queue_policy", "none")),
			(plan.get("target", {}) as Dictionary).duplicate(true),
			(plan.get("parameters", {}) as Dictionary).duplicate(true)
		))
	return results


func _compile_build(
	command: Dictionary,
	command_index: int,
	batch: Dictionary,
	context: Dictionary,
	plan: Dictionary
) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var actor_ids: Array = plan.get("actor_ids", [])
	var group_seed := {
		"batch_id": str(batch["client_batch_id"]),
		"command_id": str(command["command_id"]),
		"match_id": str(batch["match_id"]),
	}
	var construction_group_id := "cg_" + Codec.sha256_canonical(group_seed)
	for expansion_index: int in actor_ids.size():
		var parameters: Dictionary = (plan.get("parameters", {}) as Dictionary).duplicate(true)
		parameters["construction_group_id"] = construction_group_id
		parameters["builder_index"] = expansion_index
		parameters["builder_count"] = actor_ids.size()
		parameters["is_primary_builder"] = expansion_index == 0
		results.append(_make_intent(
			command,
			command_index,
			expansion_index,
			batch,
			context,
			"economy",
			"build",
			_entity_subject(str(actor_ids[expansion_index]), context),
			"replace",
			(plan.get("target", {}) as Dictionary).duplicate(true),
			parameters
		))
	return results


func _compile_single(
	command: Dictionary,
	command_index: int,
	batch: Dictionary,
	context: Dictionary,
	plan: Dictionary,
	intent_type: String,
	operation: String,
	actor_id: String
) -> Array[Dictionary]:
	return [_make_intent(
		command,
		command_index,
		0,
		batch,
		context,
		intent_type,
		operation,
		_entity_subject(actor_id, context),
		str(plan.get("queue_policy", "none")),
		(plan.get("target", {}) as Dictionary).duplicate(true),
		(plan.get("parameters", {}) as Dictionary).duplicate(true)
	)]


func _compile_quantity(
	command: Dictionary,
	command_index: int,
	batch: Dictionary,
	context: Dictionary,
	plan: Dictionary,
	intent_type: String,
	operation: String,
	actor_id: String,
	quantity: int
) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	for expansion_index: int in quantity:
		var parameters: Dictionary = (plan.get("parameters", {}) as Dictionary).duplicate(true)
		parameters["quantity_index"] = expansion_index
		parameters["requested_quantity"] = quantity
		results.append(_make_intent(
			command,
			command_index,
			expansion_index,
			batch,
			context,
			intent_type,
			operation,
			_entity_subject(actor_id, context),
			str(plan.get("queue_policy", "none")),
			(plan.get("target", {}) as Dictionary).duplicate(true),
			parameters
		))
	return results


func _compile_transport(
	command: Dictionary,
	command_index: int,
	batch: Dictionary,
	context: Dictionary,
	plan: Dictionary,
	operation: String
) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var passenger_ids: Array = plan.get("passenger_ids", [])
	for expansion_index: int in passenger_ids.size():
		var passenger_id := str(passenger_ids[expansion_index])
		var parameters: Dictionary = (plan.get("parameters", {}) as Dictionary).duplicate(true)
		parameters["passenger"] = _entity_subject(passenger_id, context)
		results.append(_make_intent(
			command,
			command_index,
			expansion_index,
			batch,
			context,
			"transport",
			operation,
			_entity_subject(str(command["transport_id"]), context),
			str(plan.get("queue_policy", "none")),
			(plan.get("target", {}) as Dictionary).duplicate(true),
			parameters
		))
	return results


func _compile_controller_intent(
	command: Dictionary,
	command_index: int,
	batch: Dictionary,
	context: Dictionary,
	plan: Dictionary,
	operation: String
) -> Array[Dictionary]:
	return [_make_intent(
		command,
		command_index,
		0,
		batch,
		context,
		"squad_state",
		operation,
		{"kind": "controller", "seat": int(context["player_seat"])},
		"none",
		{},
		(plan.get("parameters", {}) as Dictionary).duplicate(true)
	)]


func _make_intent(
	command: Dictionary,
	command_index: int,
	expansion_index: int,
	batch: Dictionary,
	context: Dictionary,
	intent_type: String,
	operation: String,
	subject: Dictionary,
	queue_policy: String,
	target: Dictionary,
	parameters: Dictionary
) -> Dictionary:
	var command_digest := Codec.sha256_canonical(command)
	var body := {
		"apply_tick": int(context["application_tick"]),
		"intent_type": intent_type,
		"operation": operation,
		"owner_seat": int(context["player_seat"]),
		"parameters": parameters,
		"queue_policy": queue_policy,
		"source": {
			"batch_id": str(batch["client_batch_id"]),
			"command_digest": command_digest,
			"command_id": str(command["command_id"]),
			"command_index": command_index,
			"expansion_index": expansion_index,
			"match_id": str(batch["match_id"]),
			"observation_seq": int(batch["observation_seq"]),
		},
		"subject": subject,
		"target": target,
	}
	var digest := Codec.sha256_canonical(body)
	var result := body.duplicate(true)
	result["intent_digest"] = digest
	result["intent_id"] = "ci_" + digest
	return result


func _entity_subject(public_id: String, context: Dictionary) -> Dictionary:
	var entities: Dictionary = context.get("entities", {})
	var record: Dictionary = entities.get(public_id, {})
	return {
		"internal_id": record.get("internal_id", public_id),
		"kind": "entity",
		"public_id": public_id,
	}
