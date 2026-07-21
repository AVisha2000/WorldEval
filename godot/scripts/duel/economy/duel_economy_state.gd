class_name DuelEconomyState
extends RefCounted

## Explicit, integer-only authority owned by DuelEconomy. Runtime dictionaries
## use integer entity IDs for efficient lookup; to_canonical_dict() converts
## every map to an ID-sorted array before it enters a checkpoint.

var enabled: bool = false
var catalog_hash: String = ""
var next_entry_id: int = 1
var next_receipt_id: int = 1

var players: Dictionary = {}
var entity_records: Dictionary = {}
var resource_nodes: Dictionary = {}
var worker_tasks: Dictionary = {}
var construction_sites: Dictionary = {}
var production_queues: Dictionary = {}
var tier_queues: Dictionary = {}
var repair_ledgers: Dictionary = {}
var claimed_site_ids: Dictionary = {}
var receipts: Array[Dictionary] = []


func reset() -> void:
	enabled = false
	catalog_hash = ""
	next_entry_id = 1
	next_receipt_id = 1
	players.clear()
	entity_records.clear()
	resource_nodes.clear()
	worker_tasks.clear()
	construction_sites.clear()
	production_queues.clear()
	tier_queues.clear()
	repair_ledgers.clear()
	claimed_site_ids.clear()
	receipts.clear()


func allocate_entry_id() -> int:
	var result := next_entry_id
	next_entry_id += 1
	return result


func append_receipt(receipt: Dictionary) -> Dictionary:
	var stored := receipt.duplicate(true)
	stored["receipt_id"] = next_receipt_id
	next_receipt_id += 1
	receipts.append(stored)
	return stored.duplicate(true)


func sorted_player_seats() -> Array[int]:
	return _sorted_int_keys(players)


func sorted_entity_record_ids() -> Array[int]:
	return _sorted_int_keys(entity_records)


func sorted_resource_node_ids() -> Array[int]:
	return _sorted_int_keys(resource_nodes)


func sorted_worker_ids() -> Array[int]:
	return _sorted_int_keys(worker_tasks)


func sorted_construction_ids() -> Array[int]:
	return _sorted_int_keys(construction_sites)


func sorted_producer_ids() -> Array[int]:
	return _sorted_int_keys(production_queues)


func sorted_tier_queue_seats() -> Array[int]:
	return _sorted_int_keys(tier_queues)


func sorted_repair_building_ids() -> Array[int]:
	return _sorted_int_keys(repair_ledgers)


func to_canonical_dict() -> Dictionary:
	var canonical_players: Array = []
	for seat: int in sorted_player_seats():
		var player: Dictionary = players[seat]
		var upgrades: Array = []
		var upgrade_ids: Array = player.get("completed_upgrades", {}).keys()
		upgrade_ids.sort()
		for upgrade_id_variant: Variant in upgrade_ids:
			var upgrade_id := str(upgrade_id_variant)
			upgrades.append({
				"level": int(player["completed_upgrades"][upgrade_id]),
				"upgrade_id": upgrade_id,
			})
		canonical_players.append({
			"completed_upgrades": upgrades,
			"food_capacity": int(player["food_capacity"]),
			"food_used": int(player["food_used"]),
			"gold": int(player["gold"]),
			"gold_delivery_bp": int(player["gold_delivery_bp"]),
			"hero_slots": int(player["hero_slots"]),
			"lumber": int(player["lumber"]),
			"reserved_food": int(player["reserved_food"]),
			"seat": seat,
			"technology_tier": int(player["technology_tier"]),
			"upkeep_tier": str(player["upkeep_tier"]),
		})

	var canonical_entity_records: Array = []
	for entity_id: int in sorted_entity_record_ids():
		canonical_entity_records.append(entity_records[entity_id].duplicate(true))

	var canonical_nodes: Array = []
	for entity_id: int in sorted_resource_node_ids():
		var node: Dictionary = resource_nodes[entity_id]
		var assigned: Array = node["assigned_worker_ids"].duplicate()
		assigned.sort()
		var canonical_node := node.duplicate(true)
		canonical_node["assigned_worker_ids"] = assigned
		canonical_nodes.append(canonical_node)

	var canonical_worker_tasks: Array = []
	for worker_id: int in sorted_worker_ids():
		canonical_worker_tasks.append(worker_tasks[worker_id].duplicate(true))

	var canonical_construction: Array = []
	for building_id: int in sorted_construction_ids():
		var site: Dictionary = construction_sites[building_id]
		var workers: Array = site["worker_ids"].duplicate()
		workers.sort()
		var canonical_site := site.duplicate(true)
		canonical_site["worker_ids"] = workers
		canonical_construction.append(canonical_site)

	var canonical_production: Array = []
	for producer_id: int in sorted_producer_ids():
		var entries: Array = []
		for entry_variant: Variant in production_queues[producer_id]:
			entries.append((entry_variant as Dictionary).duplicate(true))
		canonical_production.append({"entries": entries, "producer_id": producer_id})

	var canonical_tiers: Array = []
	for seat: int in sorted_tier_queue_seats():
		canonical_tiers.append(tier_queues[seat].duplicate(true))

	var canonical_repairs: Array = []
	for building_id: int in sorted_repair_building_ids():
		var ledger: Dictionary = repair_ledgers[building_id]
		var workers: Array = ledger["worker_ids"].duplicate()
		workers.sort()
		var canonical_ledger := ledger.duplicate(true)
		canonical_ledger["worker_ids"] = workers
		canonical_repairs.append(canonical_ledger)

	var canonical_claims: Array = []
	var site_ids: Array = claimed_site_ids.keys()
	site_ids.sort()
	for site_id_variant: Variant in site_ids:
		canonical_claims.append({
			"building_id": int(claimed_site_ids[site_id_variant]),
			"site_id": str(site_id_variant),
		})

	var canonical_receipts: Array = []
	for receipt: Dictionary in receipts:
		canonical_receipts.append(receipt.duplicate(true))

	return {
		"catalog_hash": catalog_hash,
		"claimed_sites": canonical_claims,
		"construction_sites": canonical_construction,
		"enabled": enabled,
		"entity_records": canonical_entity_records,
		"next_entry_id": next_entry_id,
		"next_receipt_id": next_receipt_id,
		"players": canonical_players,
		"production_queues": canonical_production,
		"receipts": canonical_receipts,
		"repair_ledgers": canonical_repairs,
		"resource_nodes": canonical_nodes,
		"tier_queues": canonical_tiers,
		"worker_tasks": canonical_worker_tasks,
	}


func validate(entities: Dictionary = {}) -> PackedStringArray:
	var errors := PackedStringArray()
	var expected_food_used := {0: 0, 1: 0}
	var expected_food_capacity := {0: 0, 1: 0}
	var expected_reserved_food := {0: 0, 1: 0}
	if next_entry_id <= 0 or next_receipt_id <= 0:
		errors.append("economy next IDs must be positive")
	for seat: int in sorted_player_seats():
		if seat < 0 or seat > 1:
			errors.append("economy player seat must be 0 or 1")
		var player: Dictionary = players[seat]
		for field: String in [
			"gold", "lumber", "food_used", "food_capacity", "reserved_food",
			"technology_tier", "hero_slots", "gold_delivery_bp",
		]:
			if not player.has(field) or typeof(player[field]) != TYPE_INT:
				errors.append("player[%d].%s must be an integer" % [seat, field])
			elif int(player[field]) < 0:
				errors.append("player[%d].%s must be non-negative" % [seat, field])
		if int(player.get("food_capacity", 0)) > 100:
			errors.append("player[%d] food capacity exceeds 100" % seat)
		if int(player.get("technology_tier", 0)) < 1 \
			or int(player.get("technology_tier", 0)) > 3:
			errors.append("player[%d] technology tier must be in [1, 3]" % seat)
		if not str(player.get("upkeep_tier", "")) in ["none", "low", "high"]:
			errors.append("player[%d] upkeep tier is invalid" % seat)

	for entity_id: int in sorted_entity_record_ids():
		var record: Dictionary = entity_records[entity_id]
		if int(record.get("entity_id", 0)) != entity_id:
			errors.append("economy entity record key mismatch for %d" % entity_id)
		if not entities.is_empty() and not entities.has(entity_id):
			errors.append("economy entity record %d has no entity" % entity_id)
		var owner_seat := int(record.get("owner_seat", -1))
		if owner_seat in [0, 1]:
			expected_food_used[owner_seat] += int(record.get("food_cost", 0))
			expected_food_capacity[owner_seat] += int(record.get("food_provided", 0))
	for entity_id: int in sorted_resource_node_ids():
		var node: Dictionary = resource_nodes[entity_id]
		if int(node.get("entity_id", 0)) != entity_id:
			errors.append("resource node key mismatch for %d" % entity_id)
		if int(node.get("stock", -1)) < 0 or int(node.get("maximum_stock", -1)) < 0:
			errors.append("resource node %d stock must be non-negative" % entity_id)
		if int(node.get("stock", 0)) > int(node.get("maximum_stock", 0)):
			errors.append("resource node %d stock exceeds its maximum" % entity_id)
		if int(node.get("slots", 0)) <= 0:
			errors.append("resource node %d slots must be positive" % entity_id)
		if (node.get("assigned_worker_ids", []) as Array).size() > int(node.get("slots", 0)):
			errors.append("resource node %d exceeds its extraction slots" % entity_id)
	for worker_id: int in sorted_worker_ids():
		var task: Dictionary = worker_tasks[worker_id]
		if int(task.get("worker_id", 0)) != worker_id:
			errors.append("worker task key mismatch for %d" % worker_id)
		if not entities.is_empty() and not entities.has(worker_id):
			errors.append("worker task %d has no entity" % worker_id)
		if not str(task.get("phase", "")) in [
			"to_resource", "waiting_slot", "working", "to_deposit",
		]:
			errors.append("worker task %d phase is invalid" % worker_id)
	for building_id: int in sorted_construction_ids():
		var site: Dictionary = construction_sites[building_id]
		if int(site.get("building_id", 0)) != building_id:
			errors.append("construction site key mismatch for %d" % building_id)
		if int(site.get("work_done_bp", -1)) < 0 \
			or int(site.get("work_done_bp", 0)) > int(site.get("work_required_bp", 0)):
			errors.append("construction site %d progress is invalid" % building_id)
	for producer_id: int in sorted_producer_ids():
		var queue: Array = production_queues[producer_id]
		if queue.size() > 5:
			errors.append("producer %d queue exceeds capacity" % producer_id)
		var prior_entry_id := 0
		for entry_variant: Variant in queue:
			var entry: Dictionary = entry_variant
			if int(entry.get("entry_id", 0)) <= prior_entry_id:
				errors.append("producer %d queue is not FIFO by entry ID" % producer_id)
			prior_entry_id = int(entry.get("entry_id", 0))
			var owner_seat := int(entry.get("owner_seat", -1))
			if owner_seat in [0, 1]:
				if bool(entry.get("food_committed", false)):
					expected_food_used[owner_seat] += int(entry.get("food_cost", 0))
				else:
					expected_reserved_food[owner_seat] += int(entry.get("food_cost", 0))
	for seat: int in sorted_player_seats():
		var player: Dictionary = players[seat]
		if int(player.get("food_used", 0)) != int(expected_food_used[seat]):
			errors.append("player[%d] food_used does not match entities/queues" % seat)
		if int(player.get("food_capacity", 0)) != mini(
			100, int(expected_food_capacity[seat])
		):
			errors.append("player[%d] food_capacity does not match completed structures" % seat)
		if int(player.get("reserved_food", 0)) != int(expected_reserved_food[seat]):
			errors.append("player[%d] reserved_food does not match queues" % seat)
	for receipt_index: int in receipts.size():
		if int(receipts[receipt_index].get("receipt_id", 0)) != receipt_index + 1:
			errors.append("economy receipt sequence is not contiguous")
	return errors


static func _sorted_int_keys(source: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for key_variant: Variant in source.keys():
		result.append(int(key_variant))
	result.sort()
	return result
