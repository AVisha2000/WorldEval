class_name DuelHeroState
extends RefCounted

var enabled: bool = false
var rules_catalog_id: String = ""
var faction_catalog_id: String = ""
var item_catalog_id: String = ""
var next_item_instance_id: int = 1
var next_effect_id: int = 1
var heroes: Dictionary = {}
var ground_items: Dictionary = {}
var revivals: Dictionary = {}
var periodic_effects: Dictionary = {}


func reset() -> void:
	enabled = false
	rules_catalog_id = ""
	faction_catalog_id = ""
	item_catalog_id = ""
	next_item_instance_id = 1
	next_effect_id = 1
	heroes.clear()
	ground_items.clear()
	revivals.clear()
	periodic_effects.clear()


func allocate_item_instance_id() -> String:
	var value := "item_%08d" % next_item_instance_id
	next_item_instance_id += 1
	return value


func allocate_effect_id() -> int:
	var value := next_effect_id
	next_effect_id += 1
	return value


func sorted_hero_ids() -> Array[int]:
	return _sorted_int_keys(heroes)


func sorted_ground_item_ids() -> Array[int]:
	return _sorted_int_keys(ground_items)


func to_canonical_dict() -> Dictionary:
	var canonical_heroes: Array = []
	for hero_id: int in sorted_hero_ids():
		var hero: Dictionary = heroes[hero_id].duplicate(true)
		hero["learned_abilities"] = _sorted_dictionary(hero["learned_abilities"])
		var inventory: Array = hero["inventory"].duplicate(true)
		inventory.sort_custom(_inventory_less)
		hero["inventory"] = inventory
		canonical_heroes.append(hero)
	var canonical_ground_items: Array = []
	for entity_id: int in sorted_ground_item_ids():
		canonical_ground_items.append(ground_items[entity_id].duplicate(true))
	var canonical_revivals: Array = []
	for hero_id: int in _sorted_int_keys(revivals):
		canonical_revivals.append(revivals[hero_id].duplicate(true))
	var canonical_effects: Array = []
	for effect_id: int in _sorted_int_keys(periodic_effects):
		canonical_effects.append(periodic_effects[effect_id].duplicate(true))
	return {
		"enabled": enabled,
		"faction_catalog_id": faction_catalog_id,
		"ground_items": canonical_ground_items,
		"heroes": canonical_heroes,
		"item_catalog_id": item_catalog_id,
		"next_effect_id": next_effect_id,
		"next_item_instance_id": next_item_instance_id,
		"periodic_effects": canonical_effects,
		"revivals": canonical_revivals,
		"rules_catalog_id": rules_catalog_id,
	}


func validate(entities: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if not enabled:
		return errors
	if next_item_instance_id <= 0 or next_effect_id <= 0:
		errors.append("Hero state next IDs must be positive")
	for hero_id: int in sorted_hero_ids():
		if not entities.has(hero_id):
			errors.append("Hero state references missing entity %d" % hero_id)
			continue
		var hero: Dictionary = heroes[hero_id]
		if int(hero.get("entity_id", 0)) != hero_id:
			errors.append("Hero state entity key mismatch for %d" % hero_id)
		if int(hero.get("level", 0)) < 1 or int(hero.get("level", 0)) > 10:
			errors.append("Hero %d level is outside [1,10]" % hero_id)
		if int(hero.get("xp", -1)) < 0 or int(hero.get("skill_points", -1)) < 0:
			errors.append("Hero %d XP/skill points must be non-negative" % hero_id)
		if int(hero.get("hp_regen_numerator", -1)) < 0 \
			or int(hero.get("hp_regen_numerator", -1)) >= 100:
			errors.append("Hero %d HP regeneration remainder is outside [0,100)" % hero_id)
		if int(hero.get("mana_regen_numerator", -1)) < 0 \
			or int(hero.get("mana_regen_numerator", -1)) >= 200:
			errors.append("Hero %d mana regeneration remainder is outside [0,200)" % hero_id)
		var inventory: Array = hero.get("inventory", [])
		if inventory.size() > 6:
			errors.append("Hero %d inventory exceeds six slots" % hero_id)
		var slots: Dictionary = {}
		var instances: Dictionary = {}
		for item_variant: Variant in inventory:
			if typeof(item_variant) != TYPE_DICTIONARY:
				errors.append("Hero %d inventory entry must be an object" % hero_id)
				continue
			var item: Dictionary = item_variant
			var slot := int(item.get("slot", -1))
			var instance_id := str(item.get("item_instance_id", ""))
			if slot < 0 or slot >= 6 or slots.has(slot):
				errors.append("Hero %d has invalid/duplicate inventory slot" % hero_id)
			if instance_id.is_empty() or instances.has(instance_id):
				errors.append("Hero %d has invalid/duplicate item instance" % hero_id)
			slots[slot] = true
			instances[instance_id] = true
	for entity_id: int in sorted_ground_item_ids():
		if not entities.has(entity_id):
			errors.append("ground item references missing entity %d" % entity_id)
	return errors


static func _sorted_int_keys(value: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for key_variant: Variant in value.keys():
		result.append(int(key_variant))
	result.sort()
	return result


static func _sorted_dictionary(value: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var keys: Array = value.keys()
	keys.sort()
	for key_variant: Variant in keys:
		result[str(key_variant)] = value[key_variant]
	return result


static func _inventory_less(left: Dictionary, right: Dictionary) -> bool:
	var left_slot := int(left["slot"])
	var right_slot := int(right["slot"])
	if left_slot != right_slot:
		return left_slot < right_slot
	return str(left["item_instance_id"]) < str(right["item_instance_id"])
