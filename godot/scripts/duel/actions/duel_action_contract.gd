class_name DuelActionContract
extends RefCounted

## Frozen structural contract for actions.hybrid-v1.
##
## This is intentionally explicit rather than a permissive JSON-to-GDScript
## adapter.  Python performs the first schema check, but Godot repeats the
## authoritative subset before an action may become a simulation intent.

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const PROTOCOL_VERSION := "worldeval-rts/1.0.0"
const MAX_COMMAND_OBJECTS := 16
const MAX_ATOMIC_ORDER_COST := 64
const MAX_ACTORS := 24
const MAX_QUEUE_ENTRIES := 8
const MAX_OUTPUT_BYTES := 16_384
const MAX_WORKING_MEMORY_BYTES := 4_096
const MAX_INTENT_SUMMARY_CODEPOINTS := 240
const MAX_JSON_DEPTH := 16

const ENVELOPE_REQUIRED: Array[String] = [
	"message_type",
	"protocol_version",
	"match_id",
	"observation_seq",
	"based_on_observation_hash",
	"client_batch_id",
	"valid_until_tick",
	"commands",
]
const ENVELOPE_OPTIONAL: Array[String] = ["intent_summary", "working_memory"]

## Sorted exactly like actions.hybrid-v1.json and DuelCatalogLoader.
const OPERATIONS: Array[String] = [
	"attack_entity",
	"attack_ground",
	"attack_move",
	"build",
	"cancel_construction",
	"cancel_queue",
	"cast",
	"define_squad",
	"disband_squad",
	"drop_item",
	"follow",
	"gather",
	"hold_position",
	"learn_ability",
	"load_transport",
	"move",
	"order_squad",
	"patrol",
	"pick_up_item",
	"produce",
	"purchase_offer",
	"repair",
	"research",
	"retreat",
	"return_cargo",
	"revive_hero",
	"sell_item",
	"set_autocast",
	"set_rally",
	"set_stance",
	"set_tactics",
	"stop",
	"transfer_item",
	"unload_transport",
	"update_squad",
	"upgrade_tier",
	"use_item",
]

const REQUIRED_FIELDS := {
	"attack_entity": ["actor_ids", "target", "queue"],
	"attack_ground": ["actor_ids", "target", "queue"],
	"attack_move": ["actor_ids", "target", "queue"],
	"build": ["builder_ids", "building_type_id", "build_site_id"],
	"cancel_construction": ["building_id"],
	"cancel_queue": ["producer_id", "queue_entry_id"],
	"cast": ["actor_id", "ability_id", "queue"],
	"define_squad": ["squad_id", "member_ids"],
	"disband_squad": ["squad_id"],
	"drop_item": ["hero_id", "item_instance_id", "target"],
	"follow": ["actor_ids", "target", "distance_mt", "queue"],
	"gather": ["worker_ids", "resource_target", "queue"],
	"hold_position": ["actor_ids"],
	"learn_ability": ["hero_id", "ability_id"],
	"load_transport": ["transport_id", "passenger_ids", "queue"],
	"move": ["actor_ids", "target", "queue"],
	"order_squad": [
		"squad_id", "objective", "target", "formation", "engagement", "queue",
	],
	"patrol": ["actor_ids", "targets", "queue"],
	"pick_up_item": ["hero_id", "item_entity_id", "queue"],
	"produce": ["producer_id", "unit_type_id", "quantity"],
	"purchase_offer": ["buyer_id", "shop_id", "offer_id", "quantity"],
	"repair": ["worker_ids", "target", "queue"],
	"research": ["producer_id", "upgrade_id"],
	"retreat": ["actor_ids", "target", "queue"],
	"return_cargo": ["worker_ids", "queue"],
	"revive_hero": ["reviver_id", "hero_id", "revival_method"],
	"sell_item": ["hero_id", "shop_id", "item_instance_id"],
	"set_autocast": ["actor_ids", "ability_id", "enabled"],
	"set_rally": ["producer_id", "target"],
	"set_stance": ["actor_ids", "stance"],
	"set_tactics": [
		"subject", "formation", "stance", "focus_tag", "retreat_hp_threshold_bp",
	],
	"stop": ["actor_ids"],
	"transfer_item": ["from_hero_id", "to_hero_id", "item_instance_id"],
	"unload_transport": ["transport_id", "passengers", "target"],
	"update_squad": ["squad_id", "member_ids"],
	"upgrade_tier": ["stronghold_id", "target_tier"],
	"use_item": ["hero_id", "item_instance_id", "queue"],
}

const OPTIONAL_FIELDS := {
	"cast": ["target"],
	"purchase_offer": ["service_target"],
	"return_cargo": ["deposit_target"],
	"set_tactics": ["retreat_target"],
	"use_item": ["target"],
}

const ACTOR_ARRAY_FIELDS: Array[String] = [
	"actor_ids", "worker_ids", "builder_ids", "passenger_ids", "member_ids",
]
const QUEUES: Array[String] = ["replace", "append", "front"]
const FRONT_ALLOWED: Array[String] = ["cast", "retreat", "stop", "use_item"]
const STANCES: Array[String] = ["aggressive", "defensive", "hold_fire", "hold_position"]
const FORMATIONS: Array[String] = ["compact", "line", "none", "spread", "wedge"]
const ENGAGEMENTS: Array[String] = [
	"avoid", "defend_if_attacked", "engage_visible", "focus_target",
]
const SQUAD_OBJECTIVES: Array[String] = [
	"attack_move_to",
	"focus_visible_entity",
	"hold_area",
	"move_to",
	"patrol_points",
	"retreat_to",
]
const FOCUS_TAGS: Array[String] = [
	"air", "anti_air", "caster", "ground", "healer", "hero", "none", "siege",
	"structure", "worker",
]


static func envelope_structural_code(batch: Variant) -> String:
	if typeof(batch) != TYPE_DICTIONARY:
		return "schema_mismatch"
	var value: Dictionary = batch
	if not _has_exact_fields(value, ENVELOPE_REQUIRED, ENVELOPE_OPTIONAL):
		return "schema_mismatch"
	if typeof(value["protocol_version"]) == TYPE_STRING \
		and str(value["protocol_version"]) != PROTOCOL_VERSION:
		return "unsupported_version"
	if typeof(value["message_type"]) != TYPE_STRING \
		or str(value["message_type"]) != "action_batch":
		return "schema_mismatch"
	if not is_match_id(value["match_id"]):
		return "schema_mismatch"
	if typeof(value["observation_seq"]) != TYPE_INT or int(value["observation_seq"]) < 0:
		return "schema_mismatch"
	if not is_sha256(value["based_on_observation_hash"]):
		return "schema_mismatch"
	if not is_batch_id(value["client_batch_id"]):
		return "schema_mismatch"
	if typeof(value["valid_until_tick"]) != TYPE_INT or int(value["valid_until_tick"]) < 1:
		return "schema_mismatch"
	if value.has("intent_summary"):
		if typeof(value["intent_summary"]) != TYPE_STRING \
			or str(value["intent_summary"]).length() > MAX_INTENT_SUMMARY_CODEPOINTS:
			return "schema_mismatch"
	if value.has("working_memory"):
		if typeof(value["working_memory"]) != TYPE_STRING \
			or str(value["working_memory"]).length() > MAX_WORKING_MEMORY_BYTES \
			or str(value["working_memory"]).to_utf8_buffer().size() > MAX_WORKING_MEMORY_BYTES:
			return "schema_mismatch"
	if typeof(value["commands"]) != TYPE_ARRAY:
		return "schema_mismatch"
	var commands: Array = value["commands"]
	if commands.size() > MAX_COMMAND_OBJECTS:
		return "too_many_commands"

	var command_ids: Dictionary = {}
	for command_variant: Variant in commands:
		if typeof(command_variant) != TYPE_DICTIONARY:
			return "schema_mismatch"
		var command: Dictionary = command_variant
		if typeof(command.get("command_id", null)) == TYPE_STRING:
			var command_id := str(command["command_id"])
			if command_ids.has(command_id):
				return "duplicate_command_id"
			command_ids[command_id] = true
		for field: String in ACTOR_ARRAY_FIELDS:
			if typeof(command.get(field, null)) == TYPE_ARRAY \
				and (command[field] as Array).size() > MAX_ACTORS:
				return "too_many_actors"
		var subject: Variant = command.get("subject", null)
		if typeof(subject) == TYPE_DICTIONARY \
			and typeof((subject as Dictionary).get("actor_ids", null)) == TYPE_ARRAY \
			and ((subject as Dictionary)["actor_ids"] as Array).size() > MAX_ACTORS:
			return "too_many_actors"

	for command_variant: Variant in commands:
		var command_code := command_structural_code(command_variant)
		if not command_code.is_empty():
			return command_code
	if _json_depth(value) > MAX_JSON_DEPTH:
		return "schema_mismatch"
	if not Codec.validate_canonical_value(value).is_empty():
		return "schema_mismatch"
	if Codec.canonical_bytes(value).size() > MAX_OUTPUT_BYTES:
		return "schema_mismatch"
	return ""


static func command_structural_code(command_variant: Variant) -> String:
	if typeof(command_variant) != TYPE_DICTIONARY:
		return "schema_mismatch"
	var command: Dictionary = command_variant
	if not is_command_id(command.get("command_id", null)) or typeof(command.get("op", null)) != TYPE_STRING:
		return "schema_mismatch"
	var operation := str(command["op"])
	if not OPERATIONS.has(operation):
		return "schema_mismatch"
	var required: Array = REQUIRED_FIELDS[operation]
	var optional: Array = OPTIONAL_FIELDS.get(operation, [])
	if not _has_exact_fields(command, ["command_id", "op"] + required, optional):
		return "schema_mismatch"

	match operation:
		"move", "attack_move":
			return _actors_target_queue_code(command, "actor_ids", ["point", "region_slot"])
		"attack_entity":
			return _actors_target_queue_code(command, "actor_ids", ["entity"])
		"attack_ground":
			return _actors_target_queue_code(command, "actor_ids", ["point"])
		"stop", "hold_position":
			return _entity_ids_code(command["actor_ids"])
		"patrol":
			var actor_code := _entity_ids_code(command["actor_ids"])
			if not actor_code.is_empty():
				return actor_code
			if typeof(command["targets"]) != TYPE_ARRAY:
				return "schema_mismatch"
			var targets: Array = command["targets"]
			if targets.size() < 2 or targets.size() > 8:
				return "schema_mismatch"
			for target: Variant in targets:
				if not _target_code(target, ["point", "region_slot"]).is_empty():
					return "schema_mismatch"
			return _queue_code(command["queue"])
		"follow":
			var code := _actors_target_queue_code(command, "actor_ids", ["entity"])
			if not code.is_empty():
				return code
			return _integer_range_code(command["distance_mt"], 0, 50_000)
		"retreat":
			return _actors_target_queue_code(command, "actor_ids", ["entity", "site"])
		"set_stance":
			var code := _entity_ids_code(command["actor_ids"])
			if not code.is_empty():
				return code
			return "" if typeof(command["stance"]) == TYPE_STRING \
				and STANCES.has(str(command["stance"])) else "schema_mismatch"
		"gather":
			var code := _entity_ids_code(command["worker_ids"])
			if not code.is_empty():
				return code
			code = _target_code(command["resource_target"], ["entity", "site"])
			return code if not code.is_empty() else _queue_code(command["queue"])
		"return_cargo":
			var code := _entity_ids_code(command["worker_ids"])
			if not code.is_empty():
				return code
			if command.has("deposit_target"):
				code = _target_code(command["deposit_target"], ["entity"])
				if not code.is_empty():
					return code
			return _queue_code(command["queue"])
		"repair":
			return _actors_target_queue_code(command, "worker_ids", ["entity"])
		"build":
			var code := _entity_ids_code(command["builder_ids"])
			if not code.is_empty():
				return code
			return "" if is_catalog_id(command["building_type_id"]) \
				and is_public_id(command["build_site_id"]) else "schema_mismatch"
		"cancel_construction":
			return "" if is_entity_id(command["building_id"]) else "schema_mismatch"
		"produce":
			if not is_entity_id(command["producer_id"]) or not is_catalog_id(command["unit_type_id"]):
				return "schema_mismatch"
			return _integer_range_code(command["quantity"], 1, 5)
		"research":
			return "" if is_entity_id(command["producer_id"]) \
				and is_catalog_id(command["upgrade_id"]) else "schema_mismatch"
		"upgrade_tier":
			if not is_entity_id(command["stronghold_id"]):
				return "schema_mismatch"
			return _integer_range_code(command["target_tier"], 2, 3)
		"cancel_queue":
			return "" if is_entity_id(command["producer_id"]) \
				and is_public_id(command["queue_entry_id"]) else "schema_mismatch"
		"set_rally":
			if not is_entity_id(command["producer_id"]):
				return "schema_mismatch"
			return _target_code(command["target"], ["entity", "point", "region_slot", "site"])
		"revive_hero":
			return "" if is_entity_id(command["reviver_id"]) \
				and is_entity_id(command["hero_id"]) \
				and typeof(command["revival_method"]) == TYPE_STRING \
				and ["altar", "tavern"].has(str(command["revival_method"])) \
				else "schema_mismatch"
		"cast":
			if not is_entity_id(command["actor_id"]) or not is_catalog_id(command["ability_id"]):
				return "schema_mismatch"
			if command.has("target"):
				var code := _target_code(command["target"], ["entity", "point", "region_slot", "site"])
				if not code.is_empty():
					return code
			return _queue_code(command["queue"])
		"set_autocast":
			var code := _entity_ids_code(command["actor_ids"])
			if not code.is_empty() or not is_catalog_id(command["ability_id"]):
				return "schema_mismatch"
			return "" if typeof(command["enabled"]) == TYPE_BOOL else "schema_mismatch"
		"learn_ability":
			return "" if is_entity_id(command["hero_id"]) \
				and is_catalog_id(command["ability_id"]) else "schema_mismatch"
		"use_item":
			if not is_entity_id(command["hero_id"]) or not is_public_id(command["item_instance_id"]):
				return "schema_mismatch"
			if command.has("target"):
				var code := _target_code(command["target"], ["entity", "point", "region_slot", "site"])
				if not code.is_empty():
					return code
			return _queue_code(command["queue"])
		"pick_up_item":
			if not is_entity_id(command["hero_id"]) or not is_entity_id(command["item_entity_id"]):
				return "schema_mismatch"
			return _queue_code(command["queue"])
		"drop_item":
			if not is_entity_id(command["hero_id"]) or not is_public_id(command["item_instance_id"]):
				return "schema_mismatch"
			return _target_code(command["target"], ["point"])
		"transfer_item":
			return "" if is_entity_id(command["from_hero_id"]) \
				and is_entity_id(command["to_hero_id"]) \
				and is_public_id(command["item_instance_id"]) else "schema_mismatch"
		"sell_item":
			return "" if is_entity_id(command["hero_id"]) \
				and is_entity_id(command["shop_id"]) \
				and is_public_id(command["item_instance_id"]) else "schema_mismatch"
		"purchase_offer":
			if not is_entity_id(command["buyer_id"]) or not is_entity_id(command["shop_id"]) \
				or not is_catalog_id(command["offer_id"]):
				return "schema_mismatch"
			var code := _integer_range_code(command["quantity"], 1, 5)
			if not code.is_empty():
				return code
			if command.has("service_target"):
				return _target_code(command["service_target"], ["point", "region_slot"])
			return ""
		"load_transport":
			if not is_entity_id(command["transport_id"]):
				return "schema_mismatch"
			var code := _entity_ids_code(command["passenger_ids"])
			return code if not code.is_empty() else _queue_code(command["queue"])
		"unload_transport":
			if not is_entity_id(command["transport_id"]):
				return "schema_mismatch"
			if typeof(command["passengers"]) == TYPE_STRING:
				if str(command["passengers"]) != "all":
					return "schema_mismatch"
			else:
				var code := _entity_ids_code(command["passengers"])
				if not code.is_empty():
					return code
			return _target_code(command["target"], ["point"])
		"define_squad", "update_squad":
			if not is_squad_id(command["squad_id"]):
				return "schema_mismatch"
			return _entity_ids_code(command["member_ids"])
		"disband_squad":
			return "" if is_squad_id(command["squad_id"]) else "schema_mismatch"
		"order_squad":
			if not is_squad_id(command["squad_id"]) \
				or typeof(command["objective"]) != TYPE_STRING \
				or not SQUAD_OBJECTIVES.has(str(command["objective"])) \
				or typeof(command["formation"]) != TYPE_STRING \
				or not FORMATIONS.has(str(command["formation"])) \
				or typeof(command["engagement"]) != TYPE_STRING \
				or not ENGAGEMENTS.has(str(command["engagement"])):
				return "schema_mismatch"
			var code := _target_code(command["target"], ["entity", "point", "region_slot", "site"])
			return code if not code.is_empty() else _queue_code(command["queue"])
		"set_tactics":
			var code := _subject_code(command["subject"])
			if not code.is_empty():
				return code
			if typeof(command["formation"]) != TYPE_STRING \
				or not FORMATIONS.has(str(command["formation"])) \
				or typeof(command["stance"]) != TYPE_STRING \
				or not STANCES.has(str(command["stance"])) \
				or typeof(command["focus_tag"]) != TYPE_STRING \
				or not FOCUS_TAGS.has(str(command["focus_tag"])):
				return "schema_mismatch"
			code = _integer_range_code(command["retreat_hp_threshold_bp"], 0, 10_000)
			if not code.is_empty():
				return code
			if int(command["retreat_hp_threshold_bp"]) > 0 and not command.has("retreat_target"):
				return "schema_mismatch"
			if command.has("retreat_target"):
				return _target_code(command["retreat_target"], ["entity", "site"])
			return ""
	return "schema_mismatch"


static func command_atomic_cost(
	command: Dictionary,
	squad_sizes: Dictionary,
	transport_passenger_counts: Dictionary
) -> int:
	var operation := str(command.get("op", ""))
	if ["gather", "return_cargo", "repair"].has(operation):
		return (command.get("worker_ids", []) as Array).size()
	if operation == "build":
		return (command.get("builder_ids", []) as Array).size()
	if operation == "produce" or operation == "purchase_offer":
		return int(command.get("quantity", 0))
	if operation == "load_transport":
		return (command.get("passenger_ids", []) as Array).size()
	if operation == "unload_transport":
		if typeof(command.get("passengers", null)) == TYPE_STRING:
			var transport_id := str(command.get("transport_id", ""))
			return int(transport_passenger_counts.get(transport_id, -1))
		return (command.get("passengers", []) as Array).size()
	if operation == "order_squad":
		return int(squad_sizes.get(str(command.get("squad_id", "")), -1))
	if operation == "set_tactics":
		var subject: Dictionary = command.get("subject", {})
		if str(subject.get("kind", "")) == "actors":
			return (subject.get("actor_ids", []) as Array).size()
		return int(squad_sizes.get(str(subject.get("squad_id", "")), -1))
	if command.has("actor_ids"):
		return (command["actor_ids"] as Array).size()
	return 1


static func total_atomic_cost(
	commands: Array,
	squad_sizes: Dictionary,
	transport_passenger_counts: Dictionary
) -> int:
	var total := 0
	for command_variant: Variant in commands:
		if typeof(command_variant) != TYPE_DICTIONARY:
			return -1
		var cost := command_atomic_cost(command_variant, squad_sizes, transport_passenger_counts)
		if cost < 0 or cost > MAX_ACTORS:
			return -1
		total += cost
		if total > MAX_ATOMIC_ORDER_COST:
			return total
	return total


static func target_kind(target: Variant) -> String:
	if typeof(target) != TYPE_DICTIONARY:
		return ""
	return str((target as Dictionary).get("kind", ""))


static func is_entity_id(value: Variant) -> bool:
	return _matches(value, "^e_[A-Za-z0-9._-]{1,80}$")


static func is_squad_id(value: Variant) -> bool:
	return _matches(value, "^squad\\.[a-z0-9][a-z0-9._-]{0,47}$")


static func is_catalog_id(value: Variant) -> bool:
	return _matches(value, "^[a-z0-9][a-z0-9._-]{0,95}$")


static func is_public_id(value: Variant) -> bool:
	return is_catalog_id(value)


static func is_command_id(value: Variant) -> bool:
	return _matches(value, "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


static func is_batch_id(value: Variant) -> bool:
	return _matches(value, "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


static func is_match_id(value: Variant) -> bool:
	return _matches(value, "^m_[A-Za-z0-9._-]{1,120}$")


static func is_sha256(value: Variant) -> bool:
	return _matches(value, "^[0-9a-f]{64}$")


static func _actors_target_queue_code(
	command: Dictionary,
	actor_field: String,
	allowed_target_kinds: Array[String]
) -> String:
	var code := _entity_ids_code(command[actor_field])
	if not code.is_empty():
		return code
	code = _target_code(command["target"], allowed_target_kinds)
	return code if not code.is_empty() else _queue_code(command["queue"])


static func _entity_ids_code(value: Variant) -> String:
	if typeof(value) != TYPE_ARRAY:
		return "schema_mismatch"
	var values: Array = value
	if values.is_empty() or values.size() > MAX_ACTORS:
		return "too_many_actors" if values.size() > MAX_ACTORS else "schema_mismatch"
	var seen: Dictionary = {}
	for entity_id: Variant in values:
		if not is_entity_id(entity_id):
			return "schema_mismatch"
		var key := str(entity_id)
		if seen.has(key):
			return "schema_mismatch"
		seen[key] = true
	return ""


static func _queue_code(value: Variant) -> String:
	return "" if typeof(value) == TYPE_STRING and QUEUES.has(str(value)) else "schema_mismatch"


static func _target_code(value: Variant, allowed_kinds: Array[String]) -> String:
	if typeof(value) != TYPE_DICTIONARY:
		return "schema_mismatch"
	var target: Dictionary = value
	if typeof(target.get("kind", null)) != TYPE_STRING:
		return "schema_mismatch"
	var kind := str(target["kind"])
	if not allowed_kinds.has(kind):
		return "schema_mismatch"
	match kind:
		"entity":
			return "" if _has_exact_fields(target, ["kind", "entity_id"], []) \
				and is_entity_id(target["entity_id"]) else "schema_mismatch"
		"point":
			if not _has_exact_fields(target, ["kind", "xy_mt"], []) \
				or typeof(target["xy_mt"]) != TYPE_ARRAY:
				return "schema_mismatch"
			var point: Array = target["xy_mt"]
			return "" if point.size() == 2 \
				and typeof(point[0]) == TYPE_INT and int(point[0]) >= 0 \
				and typeof(point[1]) == TYPE_INT and int(point[1]) >= 0 \
				else "schema_mismatch"
		"region_slot":
			return "" if _has_exact_fields(target, ["kind", "region_id", "slot_id"], []) \
				and is_public_id(target["region_id"]) and is_public_id(target["slot_id"]) \
				else "schema_mismatch"
		"site":
			return "" if _has_exact_fields(target, ["kind", "site_id"], []) \
				and is_public_id(target["site_id"]) else "schema_mismatch"
	return "schema_mismatch"


static func _subject_code(value: Variant) -> String:
	if typeof(value) != TYPE_DICTIONARY:
		return "schema_mismatch"
	var subject: Dictionary = value
	if typeof(subject.get("kind", null)) != TYPE_STRING:
		return "schema_mismatch"
	if str(subject["kind"]) == "actors":
		if not _has_exact_fields(subject, ["kind", "actor_ids"], []):
			return "schema_mismatch"
		return _entity_ids_code(subject["actor_ids"])
	if str(subject["kind"]) == "squad":
		return "" if _has_exact_fields(subject, ["kind", "squad_id"], []) \
			and is_squad_id(subject["squad_id"]) else "schema_mismatch"
	return "schema_mismatch"


static func _integer_range_code(value: Variant, minimum: int, maximum: int) -> String:
	return "" if typeof(value) == TYPE_INT and int(value) >= minimum and int(value) <= maximum \
		else "schema_mismatch"


static func _has_exact_fields(
	value: Dictionary,
	required_fields: Array,
	optional_fields: Array
) -> bool:
	for required: Variant in required_fields:
		if not value.has(str(required)):
			return false
	var allowed: Dictionary = {}
	for field: Variant in required_fields:
		allowed[str(field)] = true
	for field: Variant in optional_fields:
		allowed[str(field)] = true
	for key: Variant in value.keys():
		if typeof(key) != TYPE_STRING or not allowed.has(str(key)):
			return false
	return true


static func _matches(value: Variant, pattern: String) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
	var regex := RegEx.new()
	if regex.compile(pattern) != OK:
		return false
	var match_result := regex.search(str(value))
	return match_result != null and match_result.get_string() == str(value)


static func _json_depth(value: Variant, current: int = 1) -> int:
	if typeof(value) == TYPE_DICTIONARY:
		var maximum := current
		for child: Variant in (value as Dictionary).values():
			maximum = maxi(maximum, _json_depth(child, current + 1))
		return maximum
	if typeof(value) == TYPE_ARRAY:
		var maximum := current
		for child: Variant in (value as Array):
			maximum = maxi(maximum, _json_depth(child, current + 1))
		return maximum
	return current
