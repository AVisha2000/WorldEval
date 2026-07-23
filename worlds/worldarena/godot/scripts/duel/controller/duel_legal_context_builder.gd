class_name DuelLegalContextBuilder
extends RefCounted

const ActionContract := preload("res://scripts/duel/actions/duel_action_contract.gd")
const ObservationBuilder := preload("res://scripts/duel/observations/duel_observation_builder.gd")
const ObservationContract := preload("res://scripts/duel/observations/duel_observation_contract.gd")
const ResolutionContext := preload("res://scripts/duel/controller/duel_intent_resolution_context.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const KeyedRandom := preload("res://scripts/duel/simulation/duel_keyed_random.gd")

## Protected observation -> action-authority adapter.
##
## The model-visible observation is the source of every legal fact. The
## simulation, map, runtime catalog, and observer-scoped alias table are used
## only to prove those facts and attach the internal references required by the
## execution bridge. Remembered, destroyed, hidden, or merely pre-allocated
## aliases never enter either returned context.

const BOUNDARY_REQUIRED: Array[String] = ["accepted_batch_ids", "received_tick"]
const BOUNDARY_OPTIONAL: Array[String] = [
	"application_tick",
	"gather_travel_ticks",
	"neutral_building_bindings",
	"transport_range_mt",
]
const WORLD_MAX_INCLUSIVE_MT: Array = [191_999, 127_999]
const CONTINUOUS_VALIDITY_TICKS := 100
const DEFAULT_GATHER_TRAVEL_TICKS := {"return": 0, "to_resource": 0}


class MultiObserverResolutionContext:
	extends DuelIntentResolutionContext

	var _ambiguous_internal_ids: Dictionary = {}


	func configure_combined(value_input: Dictionary, protected_key: PackedByteArray) -> PackedStringArray:
		## Both source contexts were already validated by the ordinary closed
		## resolver. This alternate freezer changes exactly one invariant: several
		## observer-scoped public aliases may name the same internal entity.
		_configured = false
		_frozen.clear()
		_reverse_entity_aliases.clear()
		_ambiguous_internal_ids.clear()
		_protected_tie_key.clear()
		var errors := PackedStringArray()
		if protected_key.is_empty():
			errors.append("combined resolution context requires a protected tie key")
		for message: String in Codec.validate_canonical_value(
			value_input, "$.combined_resolution_context"
		):
			errors.append(message)
		if typeof(value_input.get("entities")) != TYPE_DICTIONARY \
			or value_input.get("world_max_inclusive_mt", []) != WORLD_MAX_INCLUSIVE_MT:
			errors.append("combined resolution context has invalid entities/world bounds")
		if not errors.is_empty():
			return errors
		var reverse: Dictionary = {}
		for alias_variant: Variant in (value_input["entities"] as Dictionary).keys():
			var alias := str(alias_variant)
			var record_variant: Variant = value_input["entities"][alias_variant]
			if not ActionContract.is_entity_id(alias) \
				or typeof(record_variant) != TYPE_DICTIONARY:
				errors.append("combined resolution context has an invalid entity alias")
				continue
			var record: Dictionary = record_variant
			if typeof(record.get("internal_id")) != TYPE_INT \
				or int(record["internal_id"]) <= 0 \
				or typeof(record.get("owner_seat")) != TYPE_INT \
				or int(record["owner_seat"]) not in [-1, 0, 1]:
				errors.append("combined resolution context has an invalid entity record")
				continue
			var internal_id := int(record["internal_id"])
			if reverse.has(internal_id):
				_ambiguous_internal_ids[internal_id] = true
				reverse.erase(internal_id)
			elif not _ambiguous_internal_ids.has(internal_id):
				reverse[internal_id] = alias
		if not errors.is_empty():
			return errors
		_frozen = value_input.duplicate(true)
		_reverse_entity_aliases = reverse
		_protected_tie_key = protected_key.duplicate()
		_configured = true
		return errors


	func alias_for_internal_entity(internal_id: int) -> String:
		## Reverse lookup is not observer-safe when two aliases are valid. The
		## intent bridge never needs this method; callers must retain seat scope.
		if _ambiguous_internal_ids.has(internal_id):
			return ""
		return super.alias_for_internal_entity(internal_id)


func build(
	perception_runtime: RefCounted,
	observer_seat: int,
	observation_input: Dictionary,
	simulation: Variant,
	map_manifest: Dictionary,
	runtime_catalog: Dictionary,
	boundary_input: Dictionary,
	protected_tie_key: PackedByteArray
) -> Dictionary:
	var errors := PackedStringArray()
	if observer_seat not in [0, 1]:
		errors.append("observer_seat must be 0 or 1")
	if perception_runtime == null or not perception_runtime.is_configured():
		errors.append("legal context builder requires a configured DuelPerceptionRuntime")
	if simulation == null or not bool(simulation.is_ready):
		errors.append("legal context builder requires a ready DuelSimulation")
	if protected_tie_key.is_empty():
		errors.append("legal context builder requires a protected tie key")
	errors.append_array(ObservationContract.validate_observation(observation_input, true))
	_validate_boundary(boundary_input, errors)
	_validate_authority_artifacts(simulation, map_manifest, runtime_catalog, errors)
	if not errors.is_empty():
		return _failure(errors)

	var observation := observation_input.duplicate(true)
	var boundary := boundary_input.duplicate(true)
	var knowledge: Variant = perception_runtime.knowledge_state_for_checkpoint(observer_seat)
	if knowledge == null or not knowledge.is_configured():
		errors.append("observer knowledge state is unavailable")
		return _failure(errors)
	if int(knowledge.observer_seat) != observer_seat:
		errors.append("observer knowledge state belongs to a different seat")
	if str(perception_runtime.match_id) != str(observation["match_id"]):
		errors.append("observation match_id does not match perception runtime")
	if int(knowledge.current_tick) != int(observation["tick"]):
		errors.append("observation tick does not match observer knowledge")
	if int(simulation.state.tick) != int(observation["tick"]):
		errors.append("observation tick does not match frozen simulation authority")
	if int(boundary["received_tick"]) < int(observation["tick"]):
		errors.append("received_tick cannot precede the observation tick")
	var decision: Dictionary = observation["decision"]
	var application_tick := _resolve_application_tick(
		decision, boundary, int(observation["tick"]), errors
	)
	if not errors.is_empty():
		return _failure(errors)

	var protected_knowledge: Dictionary = knowledge.to_protected_canonical_dict()
	var alias_index := _alias_index(protected_knowledge, errors)
	_verify_observation_against_knowledge_and_authority(
		observation, observer_seat, knowledge, protected_knowledge, alias_index,
		simulation, map_manifest, runtime_catalog, boundary, errors
	)
	if not errors.is_empty():
		return _failure(errors)

	var entity_build := _build_entity_contexts(
		observation, observer_seat, knowledge, alias_index, simulation, runtime_catalog,
		boundary, application_tick, errors
	)
	if _sorted_keys(entity_build["legal_entities"]) \
		!= _sorted_keys(entity_build["resolution_entities"]):
		errors.append("validator and resolver actionable alias sets disagree")
	var spatial_build := _build_spatial_contexts(
		observation, observer_seat, knowledge, simulation, map_manifest, errors
	)
	var queue_build := _build_queue_context(
		observation, observer_seat, entity_build["legal_entities"], simulation, errors
	)
	if not errors.is_empty():
		return _failure(errors)

	var squads := _build_squads(observation, entity_build["legal_entities"], observer_seat, errors)
	if not errors.is_empty():
		return _failure(errors)
	var squad_sizes: Dictionary = {}
	for squad_id_variant: Variant in squads.keys():
		var squad_id := str(squad_id_variant)
		squad_sizes[squad_id] = int((squads[squad_id] as Dictionary)["member_ids"].size())

	var transport_counts: Dictionary = {}
	for alias_variant: Variant in (entity_build["legal_entities"] as Dictionary).keys():
		var alias := str(alias_variant)
		var record: Dictionary = entity_build["legal_entities"][alias]
		if record.has("passenger_ids"):
			transport_counts[alias] = int((record["passenger_ids"] as Array).size())

	var accepted_batch_ids: Array = boundary["accepted_batch_ids"].duplicate()
	accepted_batch_ids.sort()
	var legal_context := {
		"accepted_batch_ids": accepted_batch_ids,
		"all_points_explored": bool(spatial_build["all_points_explored"]),
		"application_tick": application_tick,
		"catalog_ids": _catalog_ids(runtime_catalog, int(observation["technology"]["tier"])),
		"controller_valid_until_tick": int(decision["valid_until_tick"]),
		"entities": entity_build["legal_entities"],
		"explored_points": spatial_build["explored_points"],
		"known_regions": spatial_build["known_regions"],
		"known_sites": spatial_build["known_sites"],
		"match_id": str(observation["match_id"]),
		"observation_hash": str(observation["observation_hash"]),
		"observation_seq": int(observation["observation_seq"]),
		"player_seat": observer_seat,
		"received_tick": int(boundary["received_tick"]),
		"self_rotates_to_world": observer_seat == 1,
		"self_to_world_public_ids": spatial_build["self_to_world_public_ids"],
		"squad_sizes": squad_sizes,
		"squads": squads,
		"transport_passenger_counts": transport_counts,
		"world_max_inclusive_mt": WORLD_MAX_INCLUSIVE_MT.duplicate(),
	}
	for alias_variant: Variant in queue_build["queue_ids_by_producer"].keys():
		var alias := str(alias_variant)
		if legal_context["entities"].has(alias):
			legal_context["entities"][alias]["queue_entry_ids"] = (
				queue_build["queue_ids_by_producer"][alias] as Array
			).duplicate()
	var legal_errors := Codec.validate_canonical_value(legal_context, "$.legal_context")
	for message: String in legal_errors:
		errors.append(message)
	if not errors.is_empty():
		return _failure(errors)

	var resolution_data := {
		"default_deposit_by_seat": _default_deposits(
			entity_build["legal_entities"], observer_seat
		),
		"entities": entity_build["resolution_entities"],
		"gather_travel_ticks": boundary.get(
			"gather_travel_ticks", DEFAULT_GATHER_TRAVEL_TICKS
		).duplicate(true),
		"queue_entries": queue_build["resolution_queue_entries"],
		"region_slots": spatial_build["resolution_region_slots"],
		"sites": spatial_build["resolution_sites"],
		"transport_capacities": entity_build["transport_capacities"],
		"transport_range_mt": int(boundary.get("transport_range_mt", 0)),
		"world_max_inclusive_mt": WORLD_MAX_INCLUSIVE_MT.duplicate(),
	}
	var tavern_by_seat: Dictionary = _visible_tavern_by_seat(
		entity_build["shop_alias_by_world_site"], map_manifest, observer_seat
	)
	if not tavern_by_seat.is_empty():
		resolution_data["field_revival_tavern_by_seat"] = tavern_by_seat
	var resolution_context := ResolutionContext.new()
	errors.append_array(resolution_context.configure(resolution_data, protected_tie_key))
	if not errors.is_empty():
		return _failure(errors)

	var public_resolution_snapshot: Dictionary = resolution_context.public_snapshot()
	var protected_document := {
		"legal_context": legal_context,
		"resolution_context": resolution_data,
	}
	return {
		"errors": errors,
		"legal_context": legal_context.duplicate(true),
		"ok": true,
		"observer_seat": observer_seat,
		"protected_context_hash": Codec.sha256_canonical(protected_document),
		"protected_context_mac": _protected_mac(protected_document, protected_tie_key),
		"protected_resolution_data": resolution_data.duplicate(true),
		"public_resolution_snapshot": public_resolution_snapshot,
		"resolution_context": resolution_context,
		"visible_shop_aliases": entity_build["shop_alias_by_self_site"],
	}


func build_combined_resolution_context(
	seat_zero_result: Dictionary,
	seat_one_result: Dictionary,
	protected_tie_key: PackedByteArray
) -> Dictionary:
	var errors := PackedStringArray()
	for pair: Array in [[0, seat_zero_result], [1, seat_one_result]]:
		var expected_seat := int(pair[0])
		var result: Dictionary = pair[1]
		if not bool(result.get("ok", false)) \
			or int(result.get("observer_seat", -1)) != expected_seat \
			or typeof(result.get("legal_context")) != TYPE_DICTIONARY \
			or typeof(result.get("protected_resolution_data")) != TYPE_DICTIONARY:
			errors.append("combined resolver requires successful seat %d context" % expected_seat)
			continue
		var protected_document := {
			"legal_context": result["legal_context"],
			"resolution_context": result["protected_resolution_data"],
		}
		if str(result.get("protected_context_hash", "")) \
			!= Codec.sha256_canonical(protected_document) \
			or str(result.get("protected_context_mac", "")) \
			!= _protected_mac(protected_document, protected_tie_key):
			errors.append("seat %d protected context failed integrity verification" % expected_seat)
		var public_snapshot: Variant = result.get("public_resolution_snapshot", {})
		if typeof(public_snapshot) != TYPE_DICTIONARY \
			or str((public_snapshot as Dictionary).get("protected_tie_key_sha256", "")) \
			!= Codec.sha256_bytes(protected_tie_key):
			errors.append("seat %d context was configured with a different tie key" % expected_seat)
	if not errors.is_empty():
		return _combined_failure(errors)
	var left: Dictionary = seat_zero_result["protected_resolution_data"]
	var right: Dictionary = seat_one_result["protected_resolution_data"]
	var combined := _merge_resolution_data(left, right, errors)
	if not errors.is_empty():
		return _combined_failure(errors)
	var context := MultiObserverResolutionContext.new()
	errors.append_array(context.configure_combined(combined, protected_tie_key))
	if not errors.is_empty():
		return _combined_failure(errors)
	return {
		"errors": errors,
		"ok": true,
		"protected_context_hash": Codec.sha256_canonical(combined),
		"protected_context_mac": _protected_mac(combined, protected_tie_key),
		"public_resolution_snapshot": context.public_snapshot(),
		"resolution_context": context,
	}


static func operation_coverage() -> Dictionary:
	var result: Dictionary = {}
	for operation: String in ActionContract.OPERATIONS:
		result[operation] = "context_supported"
	return result


static func _validate_boundary(value: Dictionary, errors: PackedStringArray) -> void:
	if not _has_exact_fields(value, BOUNDARY_REQUIRED, BOUNDARY_OPTIONAL):
		errors.append("legal context boundary has missing or unknown fields")
		return
	for message: String in Codec.validate_canonical_value(value, "$.legal_context_boundary"):
		errors.append(message)
	if typeof(value.get("received_tick")) != TYPE_INT or int(value.get("received_tick", -1)) < 0:
		errors.append("legal context received_tick must be non-negative")
	if value.has("application_tick") \
		and (typeof(value["application_tick"]) != TYPE_INT \
		or int(value["application_tick"]) < 1):
		errors.append("legal context application_tick must be a positive integer")
	if typeof(value.get("accepted_batch_ids")) != TYPE_ARRAY:
		errors.append("accepted_batch_ids must be an array")
	else:
		var seen: Dictionary = {}
		for id_variant: Variant in value["accepted_batch_ids"]:
			var batch_id := str(id_variant)
			if typeof(id_variant) != TYPE_STRING or not ActionContract.is_batch_id(batch_id) \
				or seen.has(batch_id):
				errors.append("accepted_batch_ids contains an invalid or duplicate ID")
			else:
				seen[batch_id] = true
	if value.has("gather_travel_ticks"):
		var travel: Variant = value["gather_travel_ticks"]
		if typeof(travel) != TYPE_DICTIONARY \
			or not _has_exact_fields(travel, ["return", "to_resource"], []) \
			or typeof(travel["return"]) != TYPE_INT or int(travel["return"]) < 0 \
			or typeof(travel["to_resource"]) != TYPE_INT or int(travel["to_resource"]) < 0:
			errors.append("gather_travel_ticks is invalid")
	if value.has("transport_range_mt") \
		and (typeof(value["transport_range_mt"]) != TYPE_INT \
		or int(value["transport_range_mt"]) < 0):
		errors.append("transport_range_mt is invalid")
	if value.has("neutral_building_bindings"):
		if typeof(value["neutral_building_bindings"]) != TYPE_DICTIONARY:
			errors.append("neutral_building_bindings must be an object")
		else:
			var seen_ids: Dictionary = {}
			for site_variant: Variant in (value["neutral_building_bindings"] as Dictionary).keys():
				var site_id := str(site_variant)
				var internal: Variant = value["neutral_building_bindings"][site_variant]
				if typeof(site_variant) != TYPE_STRING \
					or not ObservationContract.is_public_id(site_id) \
					or typeof(internal) != TYPE_INT or int(internal) <= 0 \
					or seen_ids.has(int(internal)):
					errors.append("neutral_building_bindings contains an invalid row")
				else:
					seen_ids[int(internal)] = true


static func _resolve_application_tick(
	decision: Dictionary,
	boundary: Dictionary,
	observation_tick: int,
	errors: PackedStringArray
) -> int:
	if int(decision.get("observation_tick", -1)) != observation_tick:
		errors.append("decision observation_tick does not match the frozen observation")
	var valid_until_tick := int(decision.get("valid_until_tick", -1))
	match str(decision.get("mode", "")):
		"fixed_simultaneous":
			if boundary.has("application_tick"):
				errors.append("fixed mode forbids a boundary application_tick override")
			var advertised: Variant = decision.get("commands_apply_tick", null)
			if typeof(advertised) != TYPE_INT \
				or int(advertised) != observation_tick + 1:
				errors.append("fixed mode commands_apply_tick must equal observation_tick + 1")
				return -1
			if valid_until_tick < int(advertised):
				errors.append("decision validity ends before commands apply")
			if valid_until_tick != observation_tick + 1:
				errors.append("fixed mode valid_until_tick must equal observation_tick + 1")
			return int(advertised)
		"continuous_realtime":
			if decision.get("commands_apply_tick", null) != null:
				errors.append("continuous mode must not advertise a model-visible application tick")
			if not boundary.has("application_tick"):
				errors.append("continuous mode requires the protected ready-time application_tick")
				return -1
			var selected_tick := int(boundary["application_tick"])
			if valid_until_tick != observation_tick + CONTINUOUS_VALIDITY_TICKS:
				errors.append("continuous mode validity window must be exactly 100 ticks")
			if selected_tick < observation_tick + 1:
				errors.append("continuous application_tick must be after the observation tick")
			if selected_tick > valid_until_tick:
				errors.append("continuous application_tick exceeds decision validity")
			return selected_tick
		_:
			errors.append("decision mode is invalid")
	return -1


static func _validate_authority_artifacts(
	simulation: Variant,
	map_manifest: Dictionary,
	runtime_catalog: Dictionary,
	errors: PackedStringArray
) -> void:
	if simulation == null or not bool(simulation.is_ready):
		return
	for message: String in simulation.validate():
		errors.append("simulation: " + message)
	if typeof(map_manifest) != TYPE_DICTIONARY \
		or typeof(map_manifest.get("rotation_transform")) != TYPE_DICTIONARY:
		errors.append("locked map manifest is invalid")
	elif map_manifest["rotation_transform"].get("world_max_inclusive_mt", []) \
		!= WORLD_MAX_INCLUSIVE_MT:
		errors.append("locked map world bounds drifted")
	if typeof(simulation.config.get("map_manifest")) != TYPE_DICTIONARY \
		or Codec.sha256_canonical(simulation.config["map_manifest"]) \
		!= Codec.sha256_canonical(map_manifest):
		errors.append("map manifest does not match simulation authority")
	var runtime_required := [
		"abilities", "economy", "faction_id", "heroes", "protocol_version", "units",
	]
	for field: String in runtime_required:
		if not runtime_catalog.has(field):
			errors.append("runtime catalog is missing %s" % field)
	if not errors.is_empty():
		return
	if str(runtime_catalog["protocol_version"]) != ObservationContract.PROTOCOL_VERSION:
		errors.append("runtime catalog protocol version drifted")
	if str(simulation.economy.catalog.get("catalog_id", "")) \
		!= str(runtime_catalog["economy"].get("catalog_id", "")):
		errors.append("runtime economy catalog does not match simulation authority")


static func _alias_index(protected_knowledge: Dictionary, errors: PackedStringArray) -> Dictionary:
	var result: Dictionary = {}
	var aliases: Variant = protected_knowledge.get("aliases", {})
	if typeof(aliases) != TYPE_DICTIONARY or typeof(aliases.get("entries")) != TYPE_ARRAY:
		errors.append("observer protected alias table is invalid")
		return result
	for entry_variant: Variant in aliases["entries"]:
		if typeof(entry_variant) != TYPE_DICTIONARY:
			errors.append("observer protected alias row is invalid")
			continue
		var entry: Dictionary = entry_variant
		var alias := str(entry.get("alias", ""))
		var internal_id := int(entry.get("internal_id", 0))
		if not ObservationContract.is_entity_id(alias) or internal_id <= 0 \
			or result.has(alias):
			errors.append("observer protected alias row is invalid or duplicated")
			continue
		result[alias] = {
			"internal_id": internal_id,
			"tombstoned": bool(entry.get("tombstoned", false)),
		}
	return result


static func _verify_observation_against_knowledge_and_authority(
	observation: Dictionary,
	observer_seat: int,
	knowledge: Variant,
	protected_knowledge: Dictionary,
	alias_index: Dictionary,
	simulation: Variant,
	map_manifest: Dictionary,
	runtime_catalog: Dictionary,
	boundary: Dictionary,
	errors: PackedStringArray
) -> void:
	_verify_exact_knowledge_projection(
		observation, knowledge, runtime_catalog, errors
	)
	_verify_technology_authority(observation, observer_seat, simulation, errors)
	var emitted_owned := _entity_ids_from_fields(
		observation, ["heroes", "owned_entities", "owned_structures"], errors
	)
	var emitted_visible := _entity_ids_from_fields(
		observation, ["visible_contacts", "visible_neutrals"], errors
	)
	var expected_owned: Dictionary = {}
	for row_variant: Variant in protected_knowledge.get("owned", []):
		if typeof(row_variant) != TYPE_DICTIONARY \
			or typeof((row_variant as Dictionary).get("record")) != TYPE_DICTIONARY:
			continue
		var record: Dictionary = row_variant["record"]
		expected_owned[str(record.get("entity_id", ""))] = true
	var expected_visible: Dictionary = {}
	var protected_contact_state: Dictionary = {}
	for row_variant: Variant in protected_knowledge.get("contacts", []):
		if typeof(row_variant) != TYPE_DICTIONARY \
			or typeof((row_variant as Dictionary).get("record")) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = row_variant
		var record: Dictionary = row["record"]
		var alias := str(record.get("entity_id", ""))
		protected_contact_state[alias] = str(record.get("knowledge_state", ""))
		if str(record.get("knowledge_state", "")) == "visible":
			expected_visible[alias] = true
	if not bool(observation["observation_truncated"]):
		if _sorted_keys(emitted_owned) != _sorted_keys(expected_owned):
			errors.append("emitted owned entity set disagrees with observer knowledge")
		if _sorted_keys(emitted_visible) != _sorted_keys(expected_visible):
			errors.append("emitted visible entity set disagrees with observer knowledge")
	else:
		_require_subset(emitted_owned, expected_owned, "owned entity", errors)
		_require_subset(emitted_visible, expected_visible, "visible entity", errors)

	var emitted_actionable: Dictionary = {}
	for alias_variant: Variant in emitted_owned.keys() + emitted_visible.keys():
		var alias := str(alias_variant)
		if emitted_actionable.has(alias):
			errors.append("observation repeats an actionable entity alias")
		emitted_actionable[alias] = true
		if not alias_index.has(alias) or bool(alias_index[alias]["tombstoned"]):
			errors.append("observation entity is absent or tombstoned in its observer alias table")
	for remembered_variant: Variant in observation["remembered_contacts"]:
		var remembered: Dictionary = remembered_variant
		var alias := str(remembered["entity_id"])
		if emitted_actionable.has(alias):
			errors.append("remembered entity is also emitted as actionable")
		if not alias_index.has(alias) \
			or str(protected_contact_state.get(alias, "")) not in ["remembered", "unlocated"]:
			errors.append("remembered entity disagrees with observer knowledge")

	for field: String in ["heroes", "owned_entities", "owned_structures"]:
		for record_variant: Variant in observation[field]:
			_verify_entity_record(
				record_variant, observer_seat, true, alias_index, knowledge, simulation, errors
			)
	for field: String in ["visible_contacts", "visible_neutrals"]:
		for record_variant: Variant in observation[field]:
			_verify_entity_record(
				record_variant, observer_seat, false, alias_index, knowledge, simulation, errors
			)
	_verify_visible_items(observation, alias_index, knowledge, simulation, errors)
	_verify_visible_shops(
		observation, observer_seat, alias_index, knowledge, simulation,
		map_manifest, boundary, errors
	)
	_verify_map_knowledge(observation, knowledge, map_manifest, errors)


static func _verify_exact_knowledge_projection(
	observation: Dictionary,
	knowledge: Variant,
	runtime_catalog: Dictionary,
	errors: PackedStringArray
) -> void:
	## Re-run the public observation serializer's normalization over the exact
	## observer projection. This closes re-hash attacks against abilities,
	## inventory, queues, movement state, transport state, and other legal facts.
	var projection_variant: Variant = knowledge.public_projection()
	if typeof(projection_variant) != TYPE_DICTIONARY:
		errors.append("observer public projection is unavailable")
		return
	var projection: Dictionary = projection_variant
	var structure_type_ids: Dictionary = {}
	for id_variant: Variant in runtime_catalog["economy"].get("structures", {}).keys():
		structure_type_ids[str(id_variant)] = true
	var expected_heroes: Array = []
	var expected_entities: Array = []
	var expected_structures: Array = []
	for source_variant: Variant in projection["owned_entities"]:
		var source: Dictionary = source_variant
		var tags: Array = source.get("tags", [])
		var is_hero := tags.has("hero") or str(source.get("class", "")) == "hero" \
			or source.has("hero_type_id") or source.has("hero_level") or source.has("level")
		var is_structure := tags.has("structure") \
			or str(source.get("class", "")) == "structure" \
			or source.has("structure_role") \
			or structure_type_ids.has(str(source.get("type_id", "")))
		if is_hero:
			expected_heroes.append(ObservationBuilder._normalize_hero(source))
		elif is_structure:
			expected_structures.append(ObservationBuilder._normalize_structure(source))
		else:
			expected_entities.append(ObservationBuilder._normalize_owned_base(source))
	expected_heroes.sort_custom(_public_entity_less)
	expected_entities.sort_custom(_public_entity_less)
	expected_structures.sort_custom(_public_entity_less)
	if observation["heroes"] != expected_heroes:
		errors.append("emitted Hero records disagree with the exact observer projection")
	if observation["owned_entities"] != expected_entities:
		errors.append("emitted owned-unit records disagree with the exact observer projection")
	if observation["owned_structures"] != expected_structures:
		errors.append("emitted owned-structure records disagree with the exact observer projection")

	var expected_contacts: Array = []
	var expected_neutrals: Array = []
	for source_variant: Variant in projection["visible_contacts"]:
		var normalized: Dictionary = ObservationBuilder._normalize_visible_contact(source_variant)
		if str(normalized["owner_category"]) == "neutral":
			expected_neutrals.append(normalized)
		else:
			expected_contacts.append(normalized)
	expected_contacts.sort_custom(_public_entity_less)
	expected_neutrals.sort_custom(_public_entity_less)
	if observation["visible_contacts"] != expected_contacts:
		errors.append("emitted visible contacts disagree with the exact observer projection")
	if observation["visible_neutrals"] != expected_neutrals:
		errors.append("emitted visible neutrals disagree with the exact observer projection")

	var expected_remembered: Array = []
	for source_variant: Variant in projection["remembered_contacts"]:
		expected_remembered.append(ObservationBuilder._normalize_remembered_contact(source_variant))
	expected_remembered.sort_custom(_public_entity_less)
	if not bool(observation["observation_truncated"]):
		if observation["remembered_contacts"] != expected_remembered:
			errors.append("emitted remembered contacts disagree with the exact observer projection")
	else:
		var expected_by_alias: Dictionary = {}
		for row_variant: Variant in expected_remembered:
			expected_by_alias[str((row_variant as Dictionary)["entity_id"])] = row_variant
		for row_variant: Variant in observation["remembered_contacts"]:
			var row: Dictionary = row_variant
			var alias := str(row["entity_id"])
			if not expected_by_alias.has(alias) or expected_by_alias[alias] != row:
				errors.append("truncated remembered contact disagrees with observer projection")

	var expected_map: Dictionary = ObservationBuilder._normalize_map_state(projection["map_state"])
	var actual_map: Dictionary = observation["map_state"]
	for field: String in ["explored_region_ids", "visible_region_ids", "terrain_changes"]:
		if actual_map[field] != expected_map[field]:
			errors.append("emitted map %s disagrees with the exact observer projection" % field)
	if not bool(observation["observation_truncated"]) \
		and actual_map["local_context"] != expected_map["local_context"]:
		errors.append("emitted local map context disagrees with the exact observer projection")


static func _verify_technology_authority(
	observation: Dictionary,
	observer_seat: int,
	simulation: Variant,
	errors: PackedStringArray
) -> void:
	var player: Dictionary = simulation.state.economy.players[observer_seat]
	var technology: Dictionary = observation["technology"]
	if int(technology["tier"]) != int(player["technology_tier"]):
		errors.append("observation technology tier disagrees with economy authority")
	var completed: Array[String] = []
	var upgrade_ids: Array = (player["completed_upgrades"] as Dictionary).keys()
	upgrade_ids.sort()
	for upgrade_variant: Variant in upgrade_ids:
		var upgrade_id := str(upgrade_variant)
		var level := int(player["completed_upgrades"][upgrade_variant])
		if level > 0:
			completed.append("%s_%d" % [upgrade_id, level])
	if _sorted_unique_strings(technology["completed_upgrades"]) != completed:
		errors.append("observation completed upgrades disagree with economy authority")


static func _verify_entity_record(
	record_variant: Variant,
	observer_seat: int,
	is_owned: bool,
	alias_index: Dictionary,
	knowledge: Variant,
	simulation: Variant,
	errors: PackedStringArray
) -> void:
	if typeof(record_variant) != TYPE_DICTIONARY:
		return
	var record: Dictionary = record_variant
	var alias := str(record.get("entity_id", ""))
	if not alias_index.has(alias):
		return
	var internal_id := int(alias_index[alias]["internal_id"])
	if not simulation.state.entities.has(internal_id):
		errors.append("observation alias resolves to a missing simulation entity")
		return
	var entity: Variant = simulation.state.entities[internal_id]
	if is_owned:
		if int(entity.owner_seat) != observer_seat or not knowledge.is_owned_internal_id(internal_id):
			errors.append("owned observation entity is not owned by its observer")
	else:
		if int(entity.owner_seat) == observer_seat \
			or not knowledge.is_currently_visible_internal_id(internal_id):
			errors.append("visible observation entity is not a current contact")
	var world_point: Array = knowledge.coordinate_frame.self_point_to_world(record["position_mt"])
	if world_point != [int(entity.position_x_mt), int(entity.position_y_mt)]:
		errors.append("observation entity position disagrees with authority: %s" % alias)
	if str(record.get("type_id", "")) != str(entity.catalog_id):
		errors.append("observation entity type disagrees with authority: %s" % alias)
	if int(record.get("hp", -1)) != int(entity.hp) \
		or int(record.get("max_hp", -1)) != int(entity.max_hp):
		errors.append("observation entity hit points disagree with authority: %s" % alias)
	var record_tags := _sorted_unique_strings(record.get("tags", []))
	var authority_tags := _sorted_unique_strings(entity.tags)
	if record_tags != authority_tags:
		errors.append("observation entity tags disagree with authority: %s" % alias)
	if is_owned:
		if int(record.get("mana", -1)) != int(entity.mana) \
			or int(record.get("max_mana", -1)) != int(entity.max_mana):
			errors.append("owned observation mana disagrees with authority: %s" % alias)
	else:
		var expected_category := "opponent" if int(entity.owner_seat) in [0, 1] else "neutral"
		if str(record.get("owner_category", "")) != expected_category:
			errors.append("visible contact owner category disagrees with authority: %s" % alias)
		if record.get("visible_mana", null) != null \
			and int(record["visible_mana"]) != int(entity.mana):
			errors.append("visible contact mana disagrees with authority: %s" % alias)


static func _verify_visible_items(
	observation: Dictionary,
	alias_index: Dictionary,
	knowledge: Variant,
	simulation: Variant,
	errors: PackedStringArray
) -> void:
	var emitted: Dictionary = {}
	for item_variant: Variant in observation["visible_items"]:
		var item: Dictionary = item_variant
		var alias := str(item["item_entity_id"])
		emitted[alias] = true
		if not alias_index.has(alias) or bool(alias_index[alias]["tombstoned"]):
			errors.append("visible item has no live observer alias")
			continue
		var internal_id := int(alias_index[alias]["internal_id"])
		if not simulation.state.heroes.ground_items.has(internal_id) \
			or not simulation.state.entities.has(internal_id):
			errors.append("visible item does not exist in Hero authority")
			continue
		var ground: Dictionary = simulation.state.heroes.ground_items[internal_id]
		var entity: Variant = simulation.state.entities[internal_id]
		var world_point: Array = knowledge.coordinate_frame.self_point_to_world(item["position_mt"])
		if world_point != [int(entity.position_x_mt), int(entity.position_y_mt)] \
			or str(item["item_type_id"]) != str(ground["item"]["item_type_id"]) \
			or int(item["charges"]) != int(ground["item"]["charges"]):
			errors.append("visible item disagrees with authoritative item state")
	var expected: Dictionary = {}
	for internal_id: int in simulation.state.heroes.sorted_ground_item_ids():
		if not simulation.state.entities.has(internal_id):
			continue
		var entity: Variant = simulation.state.entities[internal_id]
		if not _world_position_is_visible(knowledge, simulation, [
			int(entity.position_x_mt), int(entity.position_y_mt),
		]):
			continue
		var alias := str(knowledge.alias_if_known(internal_id))
		if not alias.is_empty():
			expected[alias] = true
	if not bool(observation["observation_truncated"]) \
		and _sorted_keys(emitted) != _sorted_keys(expected):
		errors.append("visible item set disagrees with observer visibility")
	elif bool(observation["observation_truncated"]):
		_require_subset(emitted, expected, "visible item", errors)


static func _verify_visible_shops(
	observation: Dictionary,
	observer_seat: int,
	alias_index: Dictionary,
	knowledge: Variant,
	simulation: Variant,
	map_manifest: Dictionary,
	boundary: Dictionary,
	errors: PackedStringArray
) -> void:
	var authoritative: Dictionary = {}
	if bool(simulation.state.neutrals.enabled):
		for site_id_variant: Variant in simulation.state.neutrals.buildings.keys():
			var site_id := str(site_id_variant)
			authoritative[site_id] = simulation.state.neutrals.buildings[site_id]
	var map_shops := _records_by_id(map_manifest.get("neutral_buildings", []))
	var bindings: Dictionary = boundary.get("neutral_building_bindings", {})
	var emitted_world: Dictionary = {}
	var emitted_aliases: Dictionary = {}
	for shop_variant: Variant in observation["visible_shops"]:
		var shop: Dictionary = shop_variant
		var shop_alias := str(shop["shop_id"])
		var world_site: String = str(
			knowledge.coordinate_frame.self_public_id_to_world(str(shop["site_id"]))
		)
		if emitted_world.has(world_site):
			errors.append("visible shop repeats a site")
		if emitted_aliases.has(shop_alias):
			errors.append("visible shop repeats an observer alias")
		emitted_world[world_site] = true
		emitted_aliases[shop_alias] = true
		if not authoritative.has(world_site) or not map_shops.has(world_site):
			errors.append("visible shop is absent from neutral/map authority")
			continue
		if not bindings.has(world_site):
			errors.append("visible shop has no protected neutral building binding")
			continue
		if not alias_index.has(shop_alias) or bool(alias_index[shop_alias]["tombstoned"]):
			errors.append("visible shop has no live observer alias")
			continue
		if int(alias_index[shop_alias]["internal_id"]) != int(bindings[world_site]):
			errors.append("visible shop alias disagrees with its protected neutral binding")
			continue
		var source: Dictionary = authoritative[world_site]
		var world_point: Array = knowledge.coordinate_frame.self_point_to_world(shop["position_mt"])
		var world_region: String = str(
			knowledge.coordinate_frame.self_public_id_to_world(str(shop["region_id"]))
		)
		if world_point != source["position_mt"] \
			or world_region != str(source["region_id"]) \
			or str(shop["shop_type"]) != str(source["building_type"]):
			errors.append("visible shop position/region/type disagrees with authority")
		var offer_index: Dictionary = source.get("offers", {})
		var emitted_offer_ids: Dictionary = {}
		for offer_variant: Variant in shop["offers"]:
			var offer: Dictionary = offer_variant
			var offer_id := str(offer["offer_id"])
			if emitted_offer_ids.has(offer_id):
				errors.append("visible shop repeats an offer")
			emitted_offer_ids[offer_id] = true
			if not offer_index.has(offer_id):
				errors.append("visible shop exposes a non-authoritative offer")
				continue
			var authority_offer: Dictionary = offer_index[offer_id]
			var expected_stock: Variant = (
				null if int(authority_offer["maximum_stock"]) < 0
				else int(authority_offer["current_stock"])
			)
			var expected_restock: Variant = (
				null if int(authority_offer["next_restock_tick"]) < 0
				else int(authority_offer["next_restock_tick"])
			)
			if int(offer["cost_gold"]) != int(authority_offer["cost_gold"]) \
				or int(offer["cost_lumber"]) != int(authority_offer["cost_lumber"]) \
				or str(offer["kind"]) != str(authority_offer["kind"]) \
				or offer["stock"] != expected_stock \
				or offer["next_restock_tick"] != expected_restock \
				or bool(offer.get("requires_service_target", false)) \
				!= bool(authority_offer["requires_service_target"]) \
				or bool(offer["available"]) != (
					bool(authority_offer["activated"]) and int(authority_offer["current_stock"]) != 0
				):
				errors.append("visible shop offer disagrees with neutral authority")
		if _sorted_keys(emitted_offer_ids) != _sorted_keys(offer_index):
			errors.append("visible shop offer set disagrees with neutral authority")
	var expected_world: Dictionary = {}
	for site_id_variant: Variant in authoritative.keys():
		var site_id := str(site_id_variant)
		var source: Dictionary = authoritative[site_id]
		if _world_position_is_visible(knowledge, simulation, source["position_mt"]):
			expected_world[site_id] = true
	if not bool(observation["observation_truncated"]) \
		and _sorted_keys(emitted_world) != _sorted_keys(expected_world):
		errors.append("visible shop set disagrees with observer visibility")
	elif bool(observation["observation_truncated"]):
		_require_subset(emitted_world, expected_world, "visible shop", errors)
	if observer_seat not in [0, 1]:
		errors.append("visible shop observer seat is invalid")


static func _verify_map_knowledge(
	observation: Dictionary,
	knowledge: Variant,
	map_manifest: Dictionary,
	errors: PackedStringArray
) -> void:
	var map_regions := _records_by_id(map_manifest.get("regions", []))
	var explored: Dictionary = {}
	for self_variant: Variant in observation["map_state"]["explored_region_ids"]:
		var self_id := str(self_variant)
		var world_id: String = str(knowledge.coordinate_frame.self_public_id_to_world(self_id))
		if not map_regions.has(world_id):
			errors.append("observation exposes an unknown explored region")
		explored[self_id] = true
	for self_variant: Variant in observation["map_state"]["visible_region_ids"]:
		if not explored.has(str(self_variant)):
			errors.append("visible region is not explored")


static func _build_entity_contexts(
	observation: Dictionary,
	observer_seat: int,
	knowledge: Variant,
	alias_index: Dictionary,
	simulation: Variant,
	runtime_catalog: Dictionary,
	boundary: Dictionary,
	application_tick: int,
	errors: PackedStringArray
) -> Dictionary:
	var legal: Dictionary = {}
	var resolution: Dictionary = {}
	var capacities: Dictionary = {}
	var technology_tier := int(observation["technology"]["tier"])
	for field: String in ["heroes", "owned_entities", "owned_structures"]:
		for row_variant: Variant in observation[field]:
			var row: Dictionary = row_variant
			var alias := str(row["entity_id"])
			var internal_id := int(alias_index[alias]["internal_id"])
			var record := _owned_legal_record(
				row, field, internal_id, observer_seat, observation, simulation,
				runtime_catalog, technology_tier, application_tick
			)
			legal[alias] = record
			resolution[alias] = {"internal_id": internal_id, "owner_seat": observer_seat}
			if record.has("cargo_capacity_food"):
				capacities[alias] = int(record["cargo_capacity_food"])
	for field: String in ["visible_contacts", "visible_neutrals"]:
		for row_variant: Variant in observation[field]:
			var row: Dictionary = row_variant
			var alias := str(row["entity_id"])
			var internal_id := int(alias_index[alias]["internal_id"])
			var entity: Variant = simulation.state.entities[internal_id]
			legal[alias] = {
				"alive": bool(entity.alive),
				"available": bool(entity.alive),
				"internal_id": internal_id,
				"known": true,
				"order_queue_size": 0,
				"owner_seat": int(entity.owner_seat),
				"tags": _sorted_unique_strings(row["tags"]),
				"visible": true,
			}
			resolution[alias] = {
				"internal_id": internal_id,
				"owner_seat": int(entity.owner_seat),
			}
	for row_variant: Variant in observation["visible_items"]:
		var row: Dictionary = row_variant
		var alias := str(row["item_entity_id"])
		var internal_id := int(alias_index[alias]["internal_id"])
		legal[alias] = {
			"alive": true, "available": true, "internal_id": internal_id,
			"known": true, "order_queue_size": 0, "owner_seat": -1,
			"tags": ["item"], "visible": true,
		}
		resolution[alias] = {"internal_id": internal_id, "owner_seat": -1}

	var shop_alias_by_world_site: Dictionary = {}
	var shop_alias_by_self_site: Dictionary = {}
	var bindings: Dictionary = boundary.get("neutral_building_bindings", {})
	for row_variant: Variant in observation["visible_shops"]:
		var row: Dictionary = row_variant
		var self_site := str(row["site_id"])
		var world_site: String = str(
			knowledge.coordinate_frame.self_public_id_to_world(self_site)
		)
		if not bindings.has(world_site):
			errors.append("visible shop is missing its protected binding")
			continue
		var virtual_id := int(bindings[world_site])
		var alias := str(row["shop_id"])
		if not alias_index.has(alias) \
			or bool(alias_index[alias]["tombstoned"]) \
			or int(alias_index[alias]["internal_id"]) != virtual_id:
			errors.append("visible shop identifier is not its protected observer alias")
			continue
		if legal.has(alias) or resolution.has(alias):
			errors.append("visible shop alias collides with another actionable record")
			continue
		var offers: Array[String] = []
		for offer_variant: Variant in row["offers"]:
			if bool((offer_variant as Dictionary)["available"]):
				offers.append(str((offer_variant as Dictionary)["offer_id"]))
		offers.sort()
		legal[alias] = {
			"alive": true, "available": true, "internal_id": virtual_id,
			"known": true, "order_queue_size": 0, "owner_seat": -1,
			"tags": ["shop", "structure"], "visible": true,
			"visible_offer_ids": offers,
		}
		resolution[alias] = {
			"internal_id": virtual_id,
			"neutral_building_id": world_site,
			"owner_seat": -1,
		}
		shop_alias_by_world_site[world_site] = alias
		shop_alias_by_self_site[self_site] = alias
	return {
		"legal_entities": _sorted_dictionary(legal),
		"resolution_entities": _sorted_dictionary(resolution),
		"shop_alias_by_self_site": _sorted_dictionary(shop_alias_by_self_site),
		"shop_alias_by_world_site": _sorted_dictionary(shop_alias_by_world_site),
		"transport_capacities": _sorted_dictionary(capacities),
	}


static func _owned_legal_record(
	row: Dictionary,
	field: String,
	internal_id: int,
	observer_seat: int,
	observation: Dictionary,
	simulation: Variant,
	runtime_catalog: Dictionary,
	technology_tier: int,
	application_tick: int
) -> Dictionary:
	var tags := _sorted_unique_strings(row["tags"])
	var alive := bool(simulation.state.entities[internal_id].alive)
	var movement_state := str(row.get("movement_state", "idle"))
	var record := {
		"alive": alive,
		"available": alive and movement_state not in ["stunned", "transported"],
		"current_order_interruptible": movement_state != "stunned",
		"internal_id": internal_id,
		"known": true,
		"order_queue_size": int((row.get("queued_orders", []) as Array).size()),
		"owner_seat": observer_seat,
		"tags": tags,
		"visible": true,
	}
	var ability_ids: Array[String] = []
	var ready_ticks: Dictionary = {}
	var ability_ranks: Dictionary = {}
	for ability_variant: Variant in row.get("abilities", []):
		var ability: Dictionary = ability_variant
		var ability_id := str(ability["ability_id"])
		var rank := int(ability["rank"])
		if field != "heroes" or rank > 0:
			ability_ids.append(ability_id)
			ability_ranks[ability_id] = rank
			ready_ticks[ability_id] = int(observation["tick"]) + int(
				ability["cooldown_remaining_ticks"]
			)
	ability_ids.sort()
	record["ability_ids"] = ability_ids
	record["ability_ready_ticks"] = _sorted_dictionary(ready_ticks)
	var rejection_codes: Dictionary = {}
	if field == "heroes":
		var item_ids: Array[String] = []
		var defensive_ids: Array[String] = []
		for item_variant: Variant in row["inventory"]:
			var item: Dictionary = item_variant
			var item_id := str(item["item_instance_id"])
			item_ids.append(item_id)
			if int(item["cooldown_remaining_ticks"]) > 0:
				rejection_codes["use_item:%s" % item_id] = "cooldown_active"
			var item_definition: Dictionary = simulation.heroes.catalog.get(
				"items", {}
			).get("items", {}).get(str(item["item_type_id"]), {})
			if str(item_definition.get("activation_kind", "")) in ["active", "active_channel"] \
				and str(item_definition.get("target_kind", "")) in ["self", "self_area"]:
				defensive_ids.append(item_id)
		item_ids.sort()
		defensive_ids.sort()
		record["item_instance_ids"] = item_ids
		record["defensive_item_instance_ids"] = defensive_ids
		var hero_type := str(row.get("hero_type_id", row["type_id"]))
		var hero_definition: Dictionary = runtime_catalog.get("heroes", {}).get(hero_type, {})
		record["learnable_ability_ids"] = _sorted_unique_strings(
			hero_definition.get("abilities", [])
		)
		if int(row.get("unspent_skill_points", 0)) <= 0:
			for ability_id: String in record["learnable_ability_ids"]:
				rejection_codes["learn_ability:%s" % ability_id] = "requirement_not_met"
	for ability_id: String in ability_ids:
		var definition: Dictionary = runtime_catalog.get("abilities", {}).get(ability_id, {})
		var rank := maxi(1, int(ability_ranks.get(ability_id, 1)))
		var mana_costs: Array = definition.get("mana_cost_by_rank", [])
		if rank <= mana_costs.size() and int(row.get("mana", 0)) < int(mana_costs[rank - 1]):
			rejection_codes["cast:%s" % ability_id] = "insufficient_resources"
	if field == "owned_structures":
		var type_id := str(row["type_id"])
		var structure: Dictionary = runtime_catalog["economy"].get("structures", {}).get(type_id, {})
		var role := str(row.get("structure_role", structure.get("semantic_role", "")))
		_add_tag(tags, role)
		if role == "stronghold":
			_add_tag(tags, "stronghold")
			_add_tag(tags, "hall")
		if role == "expansion_hall":
			_add_tag(tags, "hall")
		if bool(structure.get("is_deposit", false)):
			_add_tag(tags, "deposit")
		var producible: Array[String] = []
		for unit_variant: Variant in structure.get("producer_type_ids", []):
			var unit_id := str(unit_variant)
			if runtime_catalog["economy"].get("units", {}).has(unit_id) \
				and int(runtime_catalog["economy"]["units"][unit_id]["required_tier"]) \
				<= technology_tier:
				producible.append(unit_id)
		producible.sort()
		var researchable := _researchable_upgrades_for_role(
			role, runtime_catalog, observation["technology"], technology_tier
		)
		if not producible.is_empty() or not researchable.is_empty() \
			or not (row.get("production_queue", []) as Array).is_empty():
			_add_tag(tags, "producer")
		record["producible_unit_ids"] = producible
		record["researchable_upgrade_ids"] = researchable
		record["production_queue_size"] = int((row.get("production_queue", []) as Array).size())
		record["production_queue_limit"] = 5
		record["construction_complete"] = bool(row.get("complete", true))
		record["repairable"] = alive
		record["tier"] = technology_tier
	if row.has("passenger_ids"):
		record["passenger_ids"] = _sorted_unique_strings(row["passenger_ids"])
	if row.has("cargo_capacity_food"):
		record["cargo_capacity_food"] = int(row["cargo_capacity_food"])
	if not rejection_codes.is_empty():
		record["rejection_codes"] = _sorted_dictionary(rejection_codes)
	record["tags"] = _sorted_unique_strings(tags)
	## A remaining cooldown of one at observation tick is ready at tick+1. The
	## validator compares the absolute ready tick to the declared application.
	for ability_id: String in record["ability_ids"]:
		if int(record["ability_ready_ticks"].get(ability_id, 0)) <= application_tick:
			continue
	return record


static func _researchable_upgrades_for_role(
	role: String,
	runtime_catalog: Dictionary,
	technology: Dictionary,
	technology_tier: int
) -> Array[String]:
	var completed: Array = technology.get("completed_upgrades", [])
	var result: Array[String] = []
	var upgrades: Dictionary = runtime_catalog["economy"].get("upgrades", {})
	var ids: Array = upgrades.keys()
	ids.sort()
	for id_variant: Variant in ids:
		var upgrade_id := str(id_variant)
		var definition: Dictionary = upgrades[id_variant]
		if role not in definition.get("producer_roles", []):
			continue
		var completed_level := 0
		for completed_variant: Variant in completed:
			var completed_id := str(completed_variant)
			if completed_id.begins_with(upgrade_id + "_"):
				completed_level = maxi(completed_level, int(completed_id.trim_prefix(upgrade_id + "_")))
		var levels: Array = definition.get("levels", [])
		if completed_level >= levels.size():
			continue
		if int((levels[completed_level] as Dictionary).get("required_tier", 1)) <= technology_tier:
			result.append(upgrade_id)
	return result


static func _build_spatial_contexts(
	observation: Dictionary,
	observer_seat: int,
	knowledge: Variant,
	simulation: Variant,
	map_manifest: Dictionary,
	errors: PackedStringArray
) -> Dictionary:
	var explored_self: Dictionary = {}
	for id_variant: Variant in observation["map_state"]["explored_region_ids"]:
		explored_self[str(id_variant)] = true
	var regions_by_world := _records_by_id(map_manifest.get("regions", []))
	var known_regions: Dictionary = {}
	var self_to_world: Dictionary = {}
	for self_variant: Variant in explored_self.keys():
		var self_id := str(self_variant)
		var world_id: String = str(knowledge.coordinate_frame.self_public_id_to_world(self_id))
		if not regions_by_world.has(world_id):
			continue
		known_regions[self_id] = {
			"slots": {},
			"world_region_id": world_id,
		}
		self_to_world[self_id] = world_id

	var resolution_slots: Dictionary = {}
	var slots: Array = map_manifest.get("tactical_slots", []).duplicate(true)
	slots.sort_custom(_record_id_less)
	for slot_variant: Variant in slots:
		var slot: Dictionary = slot_variant
		var world_region := str(slot["region_id"])
		var self_region: String = str(
			knowledge.coordinate_frame.world_public_id_to_self(world_region)
		)
		if not known_regions.has(self_region):
			continue
		var world_slot := str(slot["slot_id"])
		var self_slot: String = str(knowledge.coordinate_frame.world_public_id_to_self(world_slot))
		var region_slots: Dictionary = known_regions[self_region]["slots"]
		if region_slots.has(self_slot):
			continue
		var self_point: Array = knowledge.coordinate_frame.world_point_to_self(slot["position_mt"])
		region_slots[self_slot] = {
			"world_slot_id": world_slot,
			"xy_mt": self_point,
		}
		known_regions[self_region]["slots"] = region_slots
		resolution_slots["%s|%s" % [world_region, world_slot]] = {
			"xy_mt": (slot["position_mt"] as Array).duplicate(),
		}
		self_to_world[self_slot] = world_slot

	var known_sites: Dictionary = {}
	var resolution_sites: Dictionary = {}
	var cell_size := int(map_manifest["coordinate_system"]["cell_size_mt"])
	var build_sites: Array = map_manifest.get("build_sites", []).duplicate(true)
	build_sites.sort_custom(_record_id_less)
	for site_variant: Variant in build_sites:
		var site: Dictionary = site_variant
		var world_region := str(site["region_id"])
		var self_region: String = str(
			knowledge.coordinate_frame.world_public_id_to_self(world_region)
		)
		if not explored_self.has(self_region):
			continue
		var world_site := str(site["id"])
		var self_site: String = str(knowledge.coordinate_frame.world_public_id_to_self(world_site))
		var world_point := _build_site_center(site, cell_size)
		var self_point: Array = knowledge.coordinate_frame.world_point_to_self(world_point)
		var buildable: bool = site.get("starts_occupied_by", null) == null \
			and not simulation.state.economy.claimed_site_ids.has(world_site) \
			and simulation.grid.explicit_ground_cells_fit(site["footprint_cells"])
		known_sites[self_site] = {
			"buildable": buildable,
			"explored": true,
			"owner_seat": -1,
			"tags": ["build_site"],
			"world_site_id": world_site,
			"xy_mt": self_point,
		}
		resolution_sites[world_site] = {
			"internal_object_id": world_site,
			"xy_mt": world_point,
		}
		self_to_world[self_site] = world_site

	var neutral_by_world := _records_by_id(map_manifest.get("neutral_buildings", []))
	for shop_variant: Variant in observation["visible_shops"]:
		var shop: Dictionary = shop_variant
		var self_site := str(shop["site_id"])
		var world_site: String = str(
			knowledge.coordinate_frame.self_public_id_to_world(self_site)
		)
		if not neutral_by_world.has(world_site):
			continue
		var world_point: Array = knowledge.coordinate_frame.self_point_to_world(shop["position_mt"])
		known_sites[self_site] = {
			"buildable": false,
			"explored": true,
			"owner_seat": -1,
			"tags": ["shop"],
			"world_site_id": world_site,
			"xy_mt": (shop["position_mt"] as Array).duplicate(),
		}
		resolution_sites[world_site] = {
			"internal_object_id": world_site,
			"xy_mt": world_point,
		}
		self_to_world[self_site] = world_site

	var explored_points: Dictionary = {}
	var grid: Dictionary = simulation.grid.to_canonical_dict()
	var width := int(grid["width"])
	var height := int(grid["height"])
	var grid_cell_size := int(grid["cell_size_mt"])
	var region_ids: Array = grid["region_ids"]
	for node_id: int in width * height:
		var world_region := str(region_ids[node_id])
		var self_region: String = str(
			knowledge.coordinate_frame.world_public_id_to_self(world_region)
		)
		if not explored_self.has(self_region):
			continue
		var x := node_id % width
		@warning_ignore("integer_division")
		var y := node_id / width
		var world_point := [x * grid_cell_size + grid_cell_size / 2, y * grid_cell_size + grid_cell_size / 2]
		_add_explored_point(explored_points, knowledge.coordinate_frame.world_point_to_self(world_point))
	for field: String in [
		"heroes", "owned_entities", "owned_structures", "visible_contacts", "visible_neutrals",
	]:
		for row_variant: Variant in observation[field]:
			_add_explored_point(explored_points, (row_variant as Dictionary)["position_mt"])
	for row_variant: Variant in observation["remembered_contacts"]:
		_add_explored_point(
			explored_points, (row_variant as Dictionary)["last_observed"]["position_mt"]
		)
	for site_variant: Variant in known_sites.values():
		_add_explored_point(explored_points, (site_variant as Dictionary)["xy_mt"])
	for region_variant: Variant in known_regions.values():
		for slot_variant: Variant in (region_variant as Dictionary)["slots"].values():
			_add_explored_point(explored_points, (slot_variant as Dictionary)["xy_mt"])
	var point_keys: Array = explored_points.keys()
	point_keys.sort()
	var explored_point_list: Array = []
	for key_variant: Variant in point_keys:
		explored_point_list.append(str(key_variant))
	return {
		"all_points_explored": explored_self.size() == regions_by_world.size(),
		"explored_points": explored_point_list,
		"known_regions": _sorted_dictionary(known_regions),
		"known_sites": _sorted_dictionary(known_sites),
		"resolution_region_slots": _sorted_dictionary(resolution_slots),
		"resolution_sites": _sorted_dictionary(resolution_sites),
		"self_to_world_public_ids": _sorted_dictionary(self_to_world),
	}


static func _build_queue_context(
	observation: Dictionary,
	observer_seat: int,
	legal_entities: Dictionary,
	simulation: Variant,
	errors: PackedStringArray
) -> Dictionary:
	var authority: Dictionary = {}
	for producer_id: int in simulation.state.economy.sorted_producer_ids():
		for entry_variant: Variant in simulation.state.economy.production_queues[producer_id]:
			var entry: Dictionary = entry_variant
			if int(entry["owner_seat"]) != observer_seat:
				continue
			var public_id := _opaque_public_ref("queue", [
				int(entry["entry_id"]), producer_id,
			])
			authority[public_id] = {
				"internal_entry_id": int(entry["entry_id"]),
				"producer_id": producer_id,
			}
	if simulation.state.economy.tier_queues.has(observer_seat):
		var entry: Dictionary = simulation.state.economy.tier_queues[observer_seat]
		var producer_id := int(entry["stronghold_id"])
		var public_id := _opaque_public_ref("queue", [
			int(entry["entry_id"]), producer_id,
		])
		authority[public_id] = {
			"internal_entry_id": int(entry["entry_id"]),
			"producer_id": producer_id,
		}
	var alias_by_internal: Dictionary = {}
	for alias_variant: Variant in legal_entities.keys():
		var alias := str(alias_variant)
		var record: Dictionary = legal_entities[alias]
		if int(record["owner_seat"]) == observer_seat:
			alias_by_internal[int(record["internal_id"])] = alias
	var resolution: Dictionary = {}
	var ids_by_producer: Dictionary = {}
	var observed_ids: Dictionary = {}
	for structure_variant: Variant in observation["owned_structures"]:
		var structure: Dictionary = structure_variant
		var producer_alias := str(structure["entity_id"])
		for queue_variant: Variant in structure["production_queue"]:
			var queue: Dictionary = queue_variant
			var public_id := str(queue["queue_entry_id"])
			observed_ids[public_id] = true
			if str(queue["kind"]) == "revival":
				continue
			if not authority.has(public_id):
				errors.append("observed queue entry disagrees with economy authority")
				continue
			var authority_entry: Dictionary = authority[public_id]
			if str(alias_by_internal.get(int(authority_entry["producer_id"]), "")) != producer_alias:
				errors.append("observed queue entry belongs to a different producer")
				continue
			resolution[public_id] = {
				"internal_entry_id": int(authority_entry["internal_entry_id"]),
				"producer_alias": producer_alias,
			}
			var producer_ids: Array = ids_by_producer.get(producer_alias, [])
			producer_ids.append(public_id)
			producer_ids.sort()
			ids_by_producer[producer_alias] = producer_ids
	for research_variant: Variant in observation["technology"]["researching"]:
		var research: Dictionary = research_variant
		var public_id := str(research["entry"]["queue_entry_id"])
		if not observed_ids.has(public_id) and not authority.has(public_id):
			errors.append("technology queue entry disagrees with economy authority")
	return {
		"queue_ids_by_producer": _sorted_dictionary(ids_by_producer),
		"resolution_queue_entries": _sorted_dictionary(resolution),
	}


static func _build_squads(
	observation: Dictionary,
	legal_entities: Dictionary,
	observer_seat: int,
	errors: PackedStringArray
) -> Dictionary:
	var result: Dictionary = {}
	for squad_variant: Variant in observation["squads"]:
		var squad: Dictionary = squad_variant
		var members: Array = squad["member_ids"].duplicate()
		for member_variant: Variant in members:
			var member := str(member_variant)
			if not legal_entities.has(member) \
				or int(legal_entities[member]["owner_seat"]) != observer_seat:
				errors.append("observation squad contains a non-owned member")
		var tactics := {
			"formation": str(squad["formation"]),
			"stance": str(squad["stance"]),
		}
		if squad.has("retreat_hp_threshold_bp"):
			tactics["retreat_hp_threshold_bp"] = int(squad["retreat_hp_threshold_bp"])
		result[str(squad["squad_id"])] = {
			"member_ids": members,
			"tactics": tactics,
		}
	return _sorted_dictionary(result)


static func _catalog_ids(runtime_catalog: Dictionary, technology_tier: int) -> Dictionary:
	var abilities: Array = runtime_catalog.get("abilities", {}).keys()
	abilities.sort()
	var buildings: Array[String] = []
	for id_variant: Variant in runtime_catalog["economy"].get("structures", {}).keys():
		var id := str(id_variant)
		if int(runtime_catalog["economy"]["structures"][id]["required_tier"]) <= technology_tier:
			buildings.append(id)
	buildings.sort()
	var units: Array[String] = []
	for id_variant: Variant in runtime_catalog["economy"].get("units", {}).keys():
		var id := str(id_variant)
		if int(runtime_catalog["economy"]["units"][id]["required_tier"]) <= technology_tier:
			units.append(id)
	units.sort()
	var upgrades: Array = runtime_catalog["economy"].get("upgrades", {}).keys()
	upgrades.sort()
	return {
		"ability_ids": abilities,
		"building_type_ids": buildings,
		"unit_type_ids": units,
		"upgrade_ids": upgrades,
	}


static func _default_deposits(entities: Dictionary, observer_seat: int) -> Dictionary:
	var candidates: Array[String] = []
	for alias_variant: Variant in entities.keys():
		var alias := str(alias_variant)
		var record: Dictionary = entities[alias]
		if int(record["owner_seat"]) == observer_seat \
			and bool(record.get("alive", true)) \
			and _has_any_tag(record.get("tags", []), ["stronghold", "hall", "deposit"]):
			candidates.append(alias)
	candidates.sort_custom(_deposit_alias_less.bind(entities))
	return {} if candidates.is_empty() else {str(observer_seat): candidates[0]}


static func _visible_tavern_by_seat(
	shop_alias_by_world_site: Dictionary,
	map_manifest: Dictionary,
	observer_seat: int
) -> Dictionary:
	for shop_variant: Variant in map_manifest.get("neutral_buildings", []):
		var shop: Dictionary = shop_variant
		var site_id := str(shop["id"])
		if str(shop["building_type"]) == "tavern" \
			and shop_alias_by_world_site.has(site_id):
			return {str(observer_seat): str(shop_alias_by_world_site[site_id])}
	return {}


static func _entity_ids_from_fields(
	observation: Dictionary,
	fields: Array[String],
	errors: PackedStringArray
) -> Dictionary:
	var result: Dictionary = {}
	for field: String in fields:
		for row_variant: Variant in observation[field]:
			var alias := str((row_variant as Dictionary).get("entity_id", ""))
			if result.has(alias):
				errors.append("observation repeats entity alias %s" % alias)
			result[alias] = true
	return result


static func _world_position_is_visible(
	knowledge: Variant,
	simulation: Variant,
	position: Array
) -> bool:
	var grid: Dictionary = simulation.grid.to_canonical_dict()
	var cell_size := int(grid["cell_size_mt"])
	@warning_ignore("integer_division")
	var x := int(position[0]) / cell_size
	@warning_ignore("integer_division")
	var y := int(position[1]) / cell_size
	if x < 0 or y < 0 or x >= int(grid["width"]) or y >= int(grid["height"]):
		return false
	return knowledge.is_cell_currently_visible(y * int(grid["width"]) + x)


static func _build_site_center(site: Dictionary, cell_size_mt: int) -> Array:
	var min_x := 1_000_000
	var min_y := 1_000_000
	var max_x := -1
	var max_y := -1
	for cell_variant: Variant in site["footprint_cells"]:
		var cell: Array = cell_variant
		min_x = mini(min_x, int(cell[0]))
		min_y = mini(min_y, int(cell[1]))
		max_x = maxi(max_x, int(cell[0]))
		max_y = maxi(max_y, int(cell[1]))
	@warning_ignore("integer_division")
	var x_mt := ((min_x + max_x + 1) * cell_size_mt) / 2
	@warning_ignore("integer_division")
	var y_mt := ((min_y + max_y + 1) * cell_size_mt) / 2
	return [x_mt, y_mt]


static func _opaque_public_ref(prefix: String, scope: Array) -> String:
	return "%s.%s" % [prefix, Codec.sha256_canonical(scope).substr(0, 20)]


static func _records_by_id(records_variant: Variant) -> Dictionary:
	var result: Dictionary = {}
	if typeof(records_variant) != TYPE_ARRAY:
		return result
	for record_variant: Variant in records_variant:
		if typeof(record_variant) == TYPE_DICTIONARY:
			result[str((record_variant as Dictionary).get("id", ""))] = record_variant
	return result


static func _add_explored_point(points: Dictionary, point_variant: Variant) -> void:
	if typeof(point_variant) != TYPE_ARRAY or (point_variant as Array).size() != 2:
		return
	var point: Array = point_variant
	points["%d,%d" % [int(point[0]), int(point[1])]] = true


static func _add_tag(tags: Array, tag: String) -> void:
	if not tag.is_empty() and not tags.has(tag):
		tags.append(tag)


static func _has_any_tag(tags_variant: Variant, candidates: Array[String]) -> bool:
	if typeof(tags_variant) != TYPE_ARRAY:
		return false
	for candidate: String in candidates:
		if (tags_variant as Array).has(candidate):
			return true
	return false


static func _require_subset(
	actual: Dictionary,
	expected: Dictionary,
	label: String,
	errors: PackedStringArray
) -> void:
	for key_variant: Variant in actual.keys():
		if not expected.has(str(key_variant)):
			errors.append("emitted %s is absent from observer knowledge" % label)


static func _sorted_unique_strings(value_variant: Variant) -> Array[String]:
	var seen: Dictionary = {}
	if typeof(value_variant) == TYPE_ARRAY or typeof(value_variant) == TYPE_PACKED_STRING_ARRAY:
		for item_variant: Variant in value_variant:
			seen[str(item_variant)] = true
	var result: Array[String] = []
	for item_variant: Variant in seen.keys():
		result.append(str(item_variant))
	result.sort()
	return result


static func _sorted_keys(value: Dictionary) -> Array:
	var result: Array = value.keys()
	result.sort()
	return result


static func _sorted_dictionary(value: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var keys: Array = value.keys()
	keys.sort()
	for key_variant: Variant in keys:
		result[str(key_variant)] = value[key_variant]
	return result


static func _has_exact_fields(value_variant: Variant, required: Array, optional: Array) -> bool:
	if typeof(value_variant) != TYPE_DICTIONARY:
		return false
	var value: Dictionary = value_variant
	var allowed: Dictionary = {}
	for field_variant: Variant in required:
		var field := str(field_variant)
		if not value.has(field):
			return false
		allowed[field] = true
	for field_variant: Variant in optional:
		allowed[str(field_variant)] = true
	for key_variant: Variant in value.keys():
		if typeof(key_variant) != TYPE_STRING or not allowed.has(str(key_variant)):
			return false
	return true


static func _merge_resolution_data(
	left: Dictionary,
	right: Dictionary,
	errors: PackedStringArray
) -> Dictionary:
	for scalar: String in ["gather_travel_ticks", "transport_range_mt", "world_max_inclusive_mt"]:
		if left.get(scalar) != right.get(scalar):
			errors.append("seat resolution contexts disagree on %s" % scalar)
	var result := {
		"default_deposit_by_seat": {},
		"entities": {},
		"gather_travel_ticks": left.get(
			"gather_travel_ticks", DEFAULT_GATHER_TRAVEL_TICKS
		).duplicate(true),
		"queue_entries": {},
		"region_slots": {},
		"sites": {},
		"transport_capacities": {},
		"transport_range_mt": int(left.get("transport_range_mt", 0)),
		"world_max_inclusive_mt": WORLD_MAX_INCLUSIVE_MT.duplicate(),
	}
	if left.has("field_revival_tavern_by_seat") \
		or right.has("field_revival_tavern_by_seat"):
		result["field_revival_tavern_by_seat"] = {}
	for field: String in [
		"default_deposit_by_seat", "entities", "field_revival_tavern_by_seat",
		"queue_entries", "region_slots", "sites", "transport_capacities",
	]:
		if not result.has(field):
			continue
		_merge_dictionary_rows(result[field], left.get(field, {}), field, errors)
		_merge_dictionary_rows(result[field], right.get(field, {}), field, errors)
	return _canonical_top_level(result)


static func _merge_dictionary_rows(
	target: Dictionary,
	source_variant: Variant,
	field: String,
	errors: PackedStringArray
) -> void:
	if typeof(source_variant) != TYPE_DICTIONARY:
		errors.append("seat resolution context %s is not an object" % field)
		return
	var source: Dictionary = source_variant
	var keys: Array = source.keys()
	keys.sort()
	for key_variant: Variant in keys:
		var key := str(key_variant)
		if target.has(key) and target[key] != source[key_variant]:
			errors.append("seat resolution contexts conflict at %s.%s" % [field, key])
			continue
		target[key] = _deep_copy(source[key_variant])


static func _canonical_top_level(value: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var keys: Array = value.keys()
	keys.sort()
	for key_variant: Variant in keys:
		result[str(key_variant)] = _deep_copy(value[key_variant])
	return result


static func _deep_copy(value: Variant) -> Variant:
	if typeof(value) == TYPE_DICTIONARY or typeof(value) == TYPE_ARRAY:
		return value.duplicate(true)
	return value


static func _protected_mac(value: Variant, protected_key: PackedByteArray) -> String:
	return KeyedRandom.hmac_sha256_hex(protected_key, Codec.canonical_bytes(value))


static func _record_id_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left.get("id", "")) < str(right.get("id", ""))


static func _public_entity_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left.get("entity_id", "")) < str(right.get("entity_id", ""))


static func _deposit_alias_less(left: String, right: String, entities: Dictionary) -> bool:
	var left_tags: Array = entities[left].get("tags", [])
	var right_tags: Array = entities[right].get("tags", [])
	var left_rank := 0 if left_tags.has("stronghold") else (1 if left_tags.has("hall") else 2)
	var right_rank := 0 if right_tags.has("stronghold") else (1 if right_tags.has("hall") else 2)
	return left_rank < right_rank or (left_rank == right_rank and left < right)


static func _failure(errors: PackedStringArray) -> Dictionary:
	return {
		"errors": errors,
		"legal_context": {},
		"ok": false,
		"observer_seat": -1,
		"protected_context_hash": "",
		"protected_context_mac": "",
		"protected_resolution_data": {},
		"public_resolution_snapshot": {},
		"resolution_context": null,
		"visible_shop_aliases": {},
	}


static func _combined_failure(errors: PackedStringArray) -> Dictionary:
	return {
		"errors": errors,
		"ok": false,
		"protected_context_hash": "",
		"protected_context_mac": "",
		"public_resolution_snapshot": {},
		"resolution_context": null,
	}
