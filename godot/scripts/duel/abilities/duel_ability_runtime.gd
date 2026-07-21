class_name DuelAbilityRuntime
extends RefCounted

const Contract := preload("res://scripts/duel/abilities/duel_ability_contract.gd")
const AbilityState := preload("res://scripts/duel/abilities/duel_ability_state.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const AuthoritativeVisibility := preload(
	"res://scripts/duel/knowledge/duel_authoritative_visibility.gd"
)

const BP_ONE := 10_000
const COMMAND_ACTIVATIONS: Array[String] = [
	"active", "active_channel", "active_resource_conversion", "active_sacrifice",
	"active_transform", "active_transform_toggle", "active_transport", "active_ultimate",
	"active_ultimate_channel", "active_ultimate_transform", "toggle",
]
const TRIGGER_ACTIVATIONS: Array[String] = [
	"active_research_transform", "passive_attack_modifier", "passive_conditional",
	"passive_threshold", "passive_trigger", "triggered",
]
const PASSIVE_ACTIVATIONS: Array[String] = [
	"passive", "passive_attack_modifier", "passive_aura", "passive_conditional",
	"passive_storage", "passive_threshold", "passive_trigger", "triggered",
]
const ADVANCE_PHASES: Array[String] = ["activation", "commit", "periodic", "all"]

var state: DuelAbilityState = AbilityState.new()
var registry: Dictionary = {}
var hero_owner_types: Dictionary = {}
var _faction_catalogs: Dictionary = {}
var _effect_intents: Array[Dictionary] = []
var _visibility_candidate_cache: Dictionary = {}
var _visibility_candidate_cache_tick: int = -1


## Loads and validates all four locked faction catalogs, then restricts casts to
## the selected mirror faction. `loaded_result` is injectable for conformance
## tests; production callers normally omit it.
func configure(selected_faction_id: String, loaded_result: Dictionary = {}) -> PackedStringArray:
	var errors := PackedStringArray()
	if selected_faction_id not in CatalogLoader.FACTION_IDS:
		errors.append("unknown official selected faction: %s" % selected_faction_id)
		return errors
	var loaded := loaded_result
	if loaded.is_empty():
		loaded = CatalogLoader.load_official_catalogs()
	var compiled := Contract.compile_official_registry(loaded)
	_append_errors(errors, compiled.get("errors", []))
	if not bool(compiled.get("ok", false)):
		return errors
	state.reset()
	registry = compiled["registry"].duplicate(true)
	_faction_catalogs.clear()
	hero_owner_types.clear()
	for faction_id: String in CatalogLoader.FACTION_IDS:
		var faction: Dictionary = loaded["catalogs"]["faction:%s" % faction_id]
		_faction_catalogs[faction_id] = faction.duplicate(true)
		for owner_variant: Variant in faction["heroes"].keys():
			hero_owner_types[str(owner_variant)] = faction_id
	state.enabled = true
	state.selected_faction_id = selected_faction_id
	state.catalog_hashes = compiled["faction_hashes"].duplicate(true)
	_effect_intents.clear()
	_visibility_candidate_cache.clear()
	_visibility_candidate_cache_tick = -1
	return errors


func is_configured() -> bool:
	return state.enabled and not registry.is_empty()


## Registers the authoritative entity/type binding. Hero ranks are copied from
## DuelHeroState when available; explicit ranks are useful for isolated tests.
## Regular unit/structure abilities are rank one by catalog definition.
func register_actor(
	simulation: Variant,
	actor_id: int,
	actor_type_id: String = "",
	explicit_ranks: Dictionary = {}
) -> PackedStringArray:
	var errors := PackedStringArray()
	if not is_configured():
		errors.append("ability runtime is not configured")
		return errors
	if not _valid_simulation(simulation) or not simulation.state.entities.has(actor_id):
		errors.append("ability actor does not exist")
		return errors
	if state.actors.has(actor_id):
		errors.append("ability actor is already registered")
		return errors
	var entity: Variant = simulation.state.entities[actor_id]
	var owner_type := actor_type_id if not actor_type_id.is_empty() else str(entity.catalog_id)
	var faction_id := state.selected_faction_id
	var ranks := _resolved_actor_ranks(simulation, actor_id, owner_type, explicit_ranks)
	if ranks.is_empty():
		errors.append("actor type has no selected-faction abilities: %s" % owner_type)
		return errors
	for ability_id: String in _sorted_string_keys(ranks):
		if not registry.has(ability_id):
			errors.append("actor references unknown ability: %s" % ability_id)
			continue
		var ability: Dictionary = registry[ability_id]
		if str(ability["faction_id"]) != faction_id or owner_type not in ability["allowed_owners"]:
			errors.append("ability is not owned by actor type: %s" % ability_id)
		elif int(ranks[ability_id]) < 0 or int(ranks[ability_id]) > int(ability["rank_count"]):
			errors.append("ability rank is outside catalog range: %s" % ability_id)
	if not errors.is_empty():
		return errors
	state.actors[actor_id] = {
		"ability_ranks": _sorted_dictionary(ranks),
		"actor_id": actor_id,
		"autocast": {},
		"cooldown_until_ticks": {},
		"faction_id": faction_id,
		"owner_seat": int(entity.owner_seat),
		"owner_type_id": owner_type,
		"toggle_states": {},
	}
	_install_passives(actor_id)
	return errors


func unregister_actor(actor_id: int) -> bool:
	if not state.actors.has(actor_id):
		return false
	interrupt_actor(actor_id, "destroyed")
	state.actors.erase(actor_id)
	for effect_id: int in _sorted_int_keys(state.persistent_effects):
		if int(state.persistent_effects[effect_id]["source_id"]) == actor_id:
			state.persistent_effects.erase(effect_id)
	return true


func refresh_actor_ranks(simulation: Variant, actor_id: int) -> PackedStringArray:
	var errors := PackedStringArray()
	if not state.actors.has(actor_id):
		errors.append("ability actor is not registered")
		return errors
	var actor: Dictionary = state.actors[actor_id]
	if hero_owner_types.has(str(actor["owner_type_id"])) \
		and not simulation.state.heroes.heroes.has(actor_id):
		## Isolated authorities may register an explicit learned-rank snapshot
		## before the Hero subsystem binds the entity. Preserve that snapshot.
		return errors
	var ranks := _resolved_actor_ranks(
		simulation, actor_id, str(actor["owner_type_id"]), {}
	)
	for ability_id: String in _sorted_string_keys(ranks):
		var previous_rank := int(actor["ability_ranks"].get(ability_id, 0))
		actor["ability_ranks"][ability_id] = int(ranks[ability_id])
		if previous_rank != int(ranks[ability_id]) \
			and str(registry[ability_id]["activation_kind"]) in PASSIVE_ACTIVATIONS:
			_remove_persistent_ability(actor_id, ability_id)
			if int(ranks[ability_id]) > 0:
				_install_passive_ability(actor_id, ability_id)
	return errors


## Validates a command at wind-up start and stores an integer-only cast. Mana
## and cooldown are deliberately committed later by advance(), after target and
## interruption legality are checked a second time.
func execute_cast(
	simulation: Variant,
	actor_id: int,
	ability_id: String,
	target: Dictionary,
	request: Dictionary = {}
) -> Dictionary:
	var registration := _ensure_actor(simulation, actor_id, request)
	if not registration.is_empty():
		return _receipt(false, str(registration[0]), {})
	var compiled := compile_cast(simulation, actor_id, ability_id, target, request)
	if not bool(compiled.get("ok", false)):
		return _receipt(false, str(compiled.get("code", "ability_unavailable")), {})
	var plan: Dictionary = compiled["plan"]
	var cast_id := state.allocate_cast_id()
	plan["cast_id"] = cast_id
	plan["status"] = "windup"
	state.casts[cast_id] = plan
	state.tick = int(simulation.state.tick)
	state.append_event("ability_windup_started", actor_id, _target_entity_id(plan["target"]), {
		"ability_id": ability_id,
		"cast_id": cast_id,
		"commit_tick": int(plan["commit_tick"]),
	})
	return _receipt(true, "accepted", {
		"ability_id": ability_id,
		"cast_id": cast_id,
		"commit_tick": int(plan["commit_tick"]),
		"rank": int(plan["rank"]),
	})


func compile_cast(
	simulation: Variant,
	actor_id: int,
	ability_id: String,
	target: Dictionary,
	request: Dictionary = {}
) -> Dictionary:
	if not is_configured() or not _valid_simulation(simulation):
		return _compile_failure("authority_unavailable")
	if not state.actors.has(actor_id) or not registry.has(ability_id):
		return _compile_failure("ability_unavailable")
	var entity: Variant = simulation.state.entities.get(actor_id)
	if entity == null or not bool(entity.alive) or int(entity.hp) <= 0:
		return _compile_failure("invalid_actor")
	var actor: Dictionary = state.actors[actor_id]
	var ability: Dictionary = registry[ability_id]
	if str(ability["faction_id"]) != state.selected_faction_id \
		or ability_id not in actor["ability_ranks"] \
		or int(actor["ability_ranks"][ability_id]) <= 0:
		return _compile_failure("ability_unavailable")
	if str(ability["activation_kind"]) not in COMMAND_ACTIVATIONS:
		return _compile_failure("ability_unavailable")
	if request.has("owner_seat") and int(request["owner_seat"]) != int(entity.owner_seat):
		return _compile_failure("invalid_actor")
	var rank := int(request.get("rank", actor["ability_ranks"][ability_id]))
	if rank <= 0 or rank > int(actor["ability_ranks"][ability_id]) \
		or rank > int(ability["rank_count"]):
		return _compile_failure("ability_unavailable")
	var blocked := _cast_block_reason(simulation, actor_id, ability_id)
	if not blocked.is_empty():
		return _compile_failure(blocked)
	var tick := int(simulation.state.tick)
	if int(actor["cooldown_until_ticks"].get(ability_id, 0)) > tick:
		return _compile_failure("cooldown_active")
	var mana_cost := int(ability["mana_cost_by_rank"][rank - 1])
	if int(entity.mana) < mana_cost:
		return _compile_failure("insufficient_mana")
	if ability.has("requires_upgrade") \
		and str(ability["requires_upgrade"]) not in _completed_upgrades(simulation, int(entity.owner_seat), request):
		return _compile_failure("prerequisite_missing")
	var target_request := request.duplicate(true)
	target_request["rank"] = rank
	var normalized_target := _normalize_target(simulation, actor_id, ability, target, target_request)
	if not bool(normalized_target.get("ok", false)):
		return _compile_failure(str(normalized_target.get("code", "invalid_target")))
	var windup := _ranked_int(ability, "windup_ticks", "windup_ticks_by_rank", rank)
	var schedule := str(ability["impact_schedule"])
	var commit_tick := tick + windup
	if schedule == "next_activation_phase":
		commit_tick = tick + 1
	var plan := {
		"ability_id": ability_id,
		"actor_id": actor_id,
		"commit_phase": "activation" if schedule == "next_activation_phase" else "commit",
		"commit_tick": commit_tick,
		"cooldown_ticks": int(ability["cooldown_ticks_by_rank"][rank - 1]),
		"issued_tick": tick,
		"mana_cost": mana_cost,
		"rank": rank,
		"target": normalized_target["target"],
	}
	if "toggle" in str(ability["activation_kind"]):
		plan["toggle_enabled"] = bool(request.get(
			"enabled", not bool(actor["toggle_states"].get(ability_id, false))
		))
	return {
		"code": "accepted",
		"ok": true,
		"plan": plan,
	}


func set_autocast(
	simulation: Variant,
	actor_id: int,
	ability_id: String,
	enabled: bool,
	request: Dictionary = {}
) -> Dictionary:
	var registration := _ensure_actor(simulation, actor_id, request)
	if not registration.is_empty():
		return _receipt(false, str(registration[0]), {})
	if not registry.has(ability_id) or not state.actors[actor_id]["ability_ranks"].has(ability_id):
		return _receipt(false, "ability_unavailable", {})
	var ability: Dictionary = registry[ability_id]
	if not bool(ability.get("autocast_eligible", false)) \
		or int(state.actors[actor_id]["ability_ranks"].get(ability_id, 0)) <= 0:
		return _receipt(false, "ability_unavailable", {})
	state.actors[actor_id]["autocast"][ability_id] = enabled
	state.tick = int(simulation.state.tick)
	state.append_event("ability_autocast_changed", actor_id, 0, {
		"ability_id": ability_id, "enabled": enabled,
	})
	return _receipt(true, "accepted", {"ability_id": ability_id, "enabled": enabled})


## Autocast never paths or reads hidden world state. The coordinator supplies
## visible candidate IDs; selection is distance, HP ratio, then opaque key.
func execute_autocast(
	simulation: Variant,
	actor_id: int,
	ability_id: String,
	candidate_entity_ids: Array,
	request: Dictionary = {}
) -> Dictionary:
	if not state.actors.has(actor_id) \
		or not bool(state.actors[actor_id]["autocast"].get(ability_id, false)):
		return _receipt(false, "ability_unavailable", {})
	var owner_seat := int(simulation.state.entities[actor_id].owner_seat) \
		if simulation.state.entities.has(actor_id) else -1
	var visible_candidates := AuthoritativeVisibility.candidate_entity_ids(
		simulation, owner_seat, candidate_entity_ids, true
	)
	var candidates := _legal_entity_candidates(
		simulation, actor_id, registry[ability_id], visible_candidates, request
	)
	if candidates.is_empty():
		return _receipt(false, "target_unavailable", {})
	var target_id := int(candidates[0]["entity_id"])
	return execute_cast(simulation, actor_id, ability_id, {
		"entity_id": target_id, "kind": "entity",
	}, request)


## Executes catalog-triggered/passive attack abilities through the same typed
## primitive boundary. The trigger name must equal the catalog schedule and
## every threshold condition is checked from explicit integer facts.
func trigger_ability(
	simulation: Variant,
	actor_id: int,
	ability_id: String,
	trigger_name: String,
	target: Dictionary,
	request: Dictionary = {}
) -> Dictionary:
	var registration := _ensure_actor(simulation, actor_id, request)
	if not registration.is_empty():
		return _receipt(false, str(registration[0]), {})
	if not registry.has(ability_id) or not state.actors[actor_id]["ability_ranks"].has(ability_id):
		return _receipt(false, "ability_unavailable", {})
	var ability: Dictionary = registry[ability_id]
	if str(ability["activation_kind"]) not in TRIGGER_ACTIVATIONS:
		return _receipt(false, "ability_unavailable", {})
	if trigger_name != str(ability["impact_schedule"]):
		return _receipt(false, "requirement_not_met", {})
	if not _trigger_gate(ability, request):
		return _receipt(false, "requirement_not_met", {})
	var actor: Dictionary = state.actors[actor_id]
	var rank := int(request.get("rank", actor["ability_ranks"].get(ability_id, 1)))
	var normalized := _normalize_target(simulation, actor_id, ability, target, request, true)
	if not bool(normalized.get("ok", false)):
		return _receipt(false, str(normalized.get("code", "invalid_target")), {})
	var tick := int(simulation.state.tick)
	if int(actor["cooldown_until_ticks"].get(ability_id, 0)) > tick:
		return _receipt(false, "cooldown_active", {})
	actor["cooldown_until_ticks"][ability_id] = tick + int(ability["cooldown_ticks_by_rank"][rank - 1])
	var cast_id := state.allocate_cast_id()
	var cast := {
		"ability_id": ability_id,
		"actor_id": actor_id,
		"cast_id": cast_id,
		"commit_phase": "trigger",
		"commit_tick": tick,
		"cooldown_ticks": int(ability["cooldown_ticks_by_rank"][rank - 1]),
		"issued_tick": tick,
		"mana_cost": 0,
		"rank": rank,
		"status": "committed",
		"target": normalized["target"],
	}
	state.casts[cast_id] = cast
	_materialize_effects(cast, ability, request)
	state.append_event("ability_triggered", actor_id, _target_entity_id(cast["target"]), {
		"ability_id": ability_id, "cast_id": cast_id, "trigger": trigger_name,
	})
	return _receipt(true, "accepted", {
		"ability_id": ability_id, "cast_id": cast_id, "rank": rank,
	})


## Phase hook. The coordinator calls `activation` in tick phase 1, `commit` in
## phase 7, and `periodic` in phase 7 after commits. `all` is an isolated-test
## convenience with the same deterministic ordering.
func advance(
	simulation: Variant,
	phase: String,
	context: Dictionary = {}
) -> Dictionary:
	var errors := PackedStringArray()
	if not is_configured() or not _valid_simulation(simulation):
		errors.append("ability runtime requires a ready DuelSimulation")
	elif phase not in ADVANCE_PHASES:
		errors.append("unsupported ability advance phase: %s" % phase)
	if not errors.is_empty():
		return {"effect_intents": [], "errors": errors, "ok": false}
	var tick := int(simulation.state.tick)
	if tick < state.tick:
		errors.append("ability runtime tick cannot move backwards")
		return {"effect_intents": [], "errors": errors, "ok": false}
	state.tick = tick
	if _visibility_candidate_cache_tick != tick:
		_visibility_candidate_cache.clear()
		_visibility_candidate_cache_tick = tick
	var start_index := _effect_intents.size()
	if phase in ["activation", "all"]:
		_commit_due_casts(simulation, tick, "activation", context)
	if phase in ["commit", "all"]:
		_commit_due_casts(simulation, tick, "commit", context)
	if phase in ["periodic", "all"]:
		_emit_due_effects(simulation, tick, context)
	var emitted: Array[Dictionary] = []
	for index: int in range(start_index, _effect_intents.size()):
		emitted.append(_effect_intents[index].duplicate(true))
	return {"effect_intents": emitted, "errors": errors, "ok": true}


func interrupt_actor(actor_id: int, reason: String) -> int:
	var cancelled := 0
	for cast_id: int in _sorted_int_keys(state.casts):
		var cast: Dictionary = state.casts[cast_id]
		if int(cast["actor_id"]) != actor_id or str(cast["status"]) not in ["windup", "channeling"]:
			continue
		var ability: Dictionary = registry.get(str(cast["ability_id"]), {})
		if reason not in ability.get("interruption_flags", []):
			continue
		cast["status"] = "interrupted"
		_cancel_cast_effects(cast_id)
		state.append_event("ability_interrupted", actor_id, _target_entity_id(cast["target"]), {
			"ability_id": str(cast["ability_id"]), "cast_id": cast_id, "reason": reason,
		})
		cancelled += 1
	return cancelled


func cancel_commanded_effect(actor_id: int, ability_id: String) -> bool:
	## Exact stop hook for `per_tick_while_commanded`; it never refunds a
	## committed cost or cooldown.
	for cast_id: int in _sorted_int_keys(state.casts):
		var cast: Dictionary = state.casts[cast_id]
		if int(cast["actor_id"]) != actor_id or str(cast["ability_id"]) != ability_id \
			or str(registry[ability_id]["impact_schedule"]) != "per_tick_while_commanded" \
			or str(cast["status"]) != "channeling":
			continue
		cast["status"] = "interrupted"
		_cancel_cast_effects(cast_id)
		state.append_event("ability_commanded_effect_stopped", actor_id, _target_entity_id(cast["target"]), {
			"ability_id": ability_id, "cast_id": cast_id,
		})
		return true
	return false


func consume_effect_intents() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for intent: Dictionary in _effect_intents:
		result.append(intent.duplicate(true))
	_effect_intents.clear()
	return result


func persistent_effect_snapshot() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for effect_id: int in _sorted_int_keys(state.persistent_effects):
		var effect: Dictionary = state.persistent_effects[effect_id]
		## A snare trap is an armed one-shot trigger, not an aura. Its target is
		## resolved by resolve_armed_triggers() against the spawned trap entity.
		## Keeping it out of the generic persistent bridge prevents the root from
		## being refreshed onto every unit around the original caster.
		if str(effect.get("effect_kind", "")) == "root_first_enemy":
			continue
		result.append(effect.duplicate(true))
	return result


## Resolves the locked `immediate_at_commit_then_first_enemy_trigger`
## semantics. The summon authority creates the trap during the commit phase;
## the next activation phase binds the matching unbound trap and roots exactly
## one nearest hostile. Distance and stable public ID form the complete tie
## order, so Dictionary/insertion order can never select a different target.
func resolve_armed_triggers(simulation: Variant) -> Dictionary:
	var errors := PackedStringArray()
	if not is_configured() or not _valid_simulation(simulation):
		errors.append("armed trigger resolution requires a ready DuelSimulation")
		return {"armed": 0, "errors": errors, "ok": false, "triggered": 0}
	var root_effect_ids: Array[int] = []
	var bound_traps: Dictionary = {}
	for effect_id: int in _sorted_int_keys(state.persistent_effects):
		var effect: Dictionary = state.persistent_effects[effect_id]
		if str(effect.get("effect_kind", "")) != "root_first_enemy":
			continue
		root_effect_ids.append(effect_id)
		var bound_id := int(effect.get("trigger_entity_id", 0))
		if bound_id > 0:
			bound_traps[bound_id] = true
	var triggered := 0
	var remove_effect_ids: Array[int] = []
	for effect_id: int in root_effect_ids:
		var effect: Dictionary = state.persistent_effects[effect_id]
		var trap_id := int(effect.get("trigger_entity_id", 0))
		if trap_id <= 0:
			trap_id = _bind_trigger_trap(simulation, effect, bound_traps)
			if trap_id > 0:
				effect["trigger_entity_id"] = trap_id
				bound_traps[trap_id] = true
		if trap_id <= 0:
			continue
		if not simulation.state.entities.has(trap_id):
			remove_effect_ids.append(effect_id)
			continue
		var trap: Variant = simulation.state.entities[trap_id]
		if not bool(trap.alive) or int(trap.hp) <= 0:
			remove_effect_ids.append(effect_id)
			continue
		var target_id := _first_trigger_enemy(simulation, trap_id, effect)
		if target_id <= 0:
			continue
		var duration := maxi(1, int(effect.get("resolved_duration_ticks", 1)))
		var stacking_key := "%s::root_first_enemy" % str(
			effect.get("status_stacking_key", effect.get("ability_id", "snare_trap"))
		)
		var receipt: Dictionary = simulation.combat.add_status(
			simulation.state, target_id, int(effect.get("source_id", 0)), "root",
			stacking_key, int(effect.get("resolved_value", 1)), duration,
			str(effect.get("dispel_class", "ordinary_magical"))
		)
		if not bool(receipt.get("accepted", false)):
			continue
		var status_id := int(receipt.get("status_id", 0))
		if simulation.state.combat.statuses.has(status_id):
			simulation.state.combat.statuses[status_id]["ability_id"] = str(
				effect.get("ability_id", "")
			)
			simulation.state.combat.statuses[status_id]["effect_kind"] = \
				"root_first_enemy"
		trap.hp = 0
		trap.integer_attributes["trap_triggered_tick"] = int(simulation.state.tick)
		remove_effect_ids.append(effect_id)
		triggered += 1
		state.append_event(
			"ability_first_enemy_triggered", int(effect.get("source_id", 0)),
			target_id, {
				"ability_id": str(effect.get("ability_id", "")),
				"cast_id": int(effect.get("cast_id", 0)),
				"duration_ticks": duration,
				"effect_kind": "root_first_enemy",
			}
		)
	remove_effect_ids.sort()
	for effect_id: int in remove_effect_ids:
		state.persistent_effects.erase(effect_id)
	return {
		"armed": root_effect_ids.size() - remove_effect_ids.size(),
		"errors": errors,
		"ok": errors.is_empty(),
		"triggered": triggered,
	}


## The generic persistent-status bridge intentionally has no observer seat.
## Remove only statuses belonging to a live persistent effect whose catalog
## explicitly requires `visible`, using the same integer LOS authority as
## phase-12 perception. Direct cast statuses (for example Mark Quarry) are not
## persistent effects and therefore correctly remain after their target hides.
func prune_illegal_persistent_visibility_statuses(simulation: Variant) -> int:
	if not is_configured() or not _valid_simulation(simulation) \
		or not simulation.state.combat.enabled:
		return 0
	var persistent_keys: Dictionary = {}
	for effect_id: int in _sorted_int_keys(state.persistent_effects):
		var effect: Dictionary = state.persistent_effects[effect_id]
		var ability: Dictionary = registry.get(str(effect.get("ability_id", "")), {})
		if "visible" not in ability.get("required_target_tags", []):
			continue
		persistent_keys[_persistent_status_key(
			int(effect.get("source_id", 0)), str(effect.get("ability_id", "")),
			str(effect.get("effect_kind", ""))
		)] = true
	var visible_by_seat: Dictionary = {}
	var removed := 0
	for status_id: int in _sorted_int_keys(simulation.state.combat.statuses):
		var status: Dictionary = simulation.state.combat.statuses[status_id]
		var key := _persistent_status_key(
			int(status.get("source_id", 0)), str(status.get("ability_id", "")),
			str(status.get("effect_kind", ""))
		)
		if not persistent_keys.has(key):
			continue
		var source_id := int(status.get("source_id", 0))
		if not simulation.state.entities.has(source_id) \
			or not bool(simulation.state.entities[source_id].alive) \
			or int(simulation.state.entities[source_id].hp) <= 0:
			simulation.state.combat.statuses.erase(status_id)
			removed += 1
			continue
		var owner_seat := int(simulation.state.entities[source_id].owner_seat)
		if owner_seat not in [0, 1]:
			simulation.state.combat.statuses.erase(status_id)
			removed += 1
			continue
		if not visible_by_seat.has(owner_seat):
			var closed: Array = AuthoritativeVisibility.candidate_entity_ids(
				simulation, owner_seat, simulation.state.sorted_entity_ids(), true
			)
			var allowed: Dictionary = {}
			for target_variant: Variant in closed:
				allowed[int(target_variant)] = true
			visible_by_seat[owner_seat] = allowed
		if not (visible_by_seat[owner_seat] as Dictionary).has(
			int(status.get("target_id", 0))
		):
			simulation.state.combat.statuses.erase(status_id)
			removed += 1
	return removed


func to_canonical_dict() -> Dictionary:
	return state.to_canonical_dict()


func checkpoint_hash() -> String:
	return Codec.sha256_canonical(to_canonical_dict())


func validate() -> PackedStringArray:
	var errors := state.validate()
	if registry.size() != 100:
		errors.append("ability registry is incomplete")
	return errors


func ability_definition(ability_id: String) -> Dictionary:
	return (registry.get(ability_id, {}) as Dictionary).duplicate(true)


static func dispatch_coverage() -> Dictionary:
	return {
		"catalog": Contract.coverage(),
		"effect_dispatch": Contract.EFFECT_DISPATCH.duplicate(true),
		"schedules": Contract.IMPACT_SCHEDULES.duplicate(),
	}


func _commit_due_casts(
	simulation: Variant,
	tick: int,
	commit_phase: String,
	context: Dictionary
) -> void:
	for cast_id: int in _sorted_int_keys(state.casts):
		var cast: Dictionary = state.casts[cast_id]
		if str(cast["status"]) != "windup" or int(cast["commit_tick"]) > tick \
			or str(cast["commit_phase"]) != commit_phase:
			continue
		var actor_id := int(cast["actor_id"])
		var ability: Dictionary = registry[str(cast["ability_id"])]
		var reason := _commit_reason(simulation, cast, ability, context)
		if not reason.is_empty():
			cast["status"] = "cancelled"
			state.append_event("ability_cancelled_before_commit", actor_id, _target_entity_id(cast["target"]), {
				"ability_id": str(cast["ability_id"]), "cast_id": cast_id, "reason": reason,
			})
			continue
		var entity: Variant = simulation.state.entities[actor_id]
		entity.mana -= int(cast["mana_cost"])
		state.actors[actor_id]["cooldown_until_ticks"][str(cast["ability_id"])] = (
			tick + int(cast["cooldown_ticks"])
		)
		cast["status"] = "channeling" \
			if int(ability["channel_ticks"]) > 0 \
			or str(ability["impact_schedule"]) == "per_tick_while_commanded" \
			else "committed"
		cast["commit_tick"] = tick
		if "toggle" in str(ability["activation_kind"]):
			var enabled := bool(cast.get("toggle_enabled", true))
			state.actors[actor_id]["toggle_states"][str(cast["ability_id"])] = enabled
			if enabled:
				cast["toggle_persistent"] = true
				_materialize_effects(cast, ability, context)
			else:
				_remove_persistent_ability(actor_id, str(cast["ability_id"]))
				_emit_toggle_removed(cast, ability)
		else:
			_materialize_effects(cast, ability, context)
		state.append_event("ability_committed", actor_id, _target_entity_id(cast["target"]), {
			"ability_id": str(cast["ability_id"]), "cast_id": cast_id,
			"cooldown_until_tick": int(state.actors[actor_id]["cooldown_until_ticks"][str(cast["ability_id"])]),
			"mana_cost": int(cast["mana_cost"]), "rank": int(cast["rank"]),
		})
	_emit_due_effects(simulation, tick, context)


func _commit_reason(
	simulation: Variant, cast: Dictionary, ability: Dictionary, context: Dictionary
) -> String:
	var actor_id := int(cast["actor_id"])
	if not simulation.state.entities.has(actor_id):
		return "invalid_actor"
	var entity: Variant = simulation.state.entities[actor_id]
	if not bool(entity.alive) or int(entity.hp) <= 0:
		return "invalid_actor"
	var blocked := _cast_block_reason(simulation, actor_id, str(cast["ability_id"]))
	if not blocked.is_empty():
		return blocked
	if int(entity.mana) < int(cast["mana_cost"]):
		return "insufficient_mana"
	var target_context := context.duplicate(true)
	target_context["rank"] = int(cast["rank"])
	var target := _normalize_target(simulation, actor_id, ability, cast["target"], target_context)
	return "" if bool(target.get("ok", false)) else str(target.get("code", "invalid_target"))


func _materialize_effects(cast: Dictionary, ability: Dictionary, context: Dictionary) -> void:
	var schedule := str(ability["impact_schedule"])
	for effect_index: int in (ability["effects"] as Array).size():
		var effect: Dictionary = ability["effects"][effect_index]
		var resolved := _resolved_effect(effect, int(cast["rank"]), int(ability["rank_count"]))
		var timing := _effect_timing(schedule, str(effect["kind"]), resolved, ability)
		if str(cast.get("commit_phase", "")) == "trigger":
			timing = {
				"first_offset_ticks": 0, "gate": schedule, "impact_count": 1,
				"interval_ticks": 0, "persistent": false,
			}
		elif bool(cast.get("toggle_persistent", false)):
			timing["persistent"] = true
		var effect_id := state.allocate_effect_id()
		var record := {
			"ability_id": str(cast["ability_id"]),
			"cast_id": int(cast["cast_id"]),
			"effect_id": effect_id,
			"effect_index": effect_index,
			"effect_kind": str(effect["kind"]),
			"execution_gate": str(timing["gate"]),
			"interval_ticks": int(timing["interval_ticks"]),
			"impact_index": 0,
			"next_tick": int(cast["commit_tick"]) + int(timing["first_offset_ticks"]),
			"primitive_kind": str(Contract.EFFECT_DISPATCH[str(effect["kind"])]),
			"rank": int(cast["rank"]),
			"remaining_impacts": int(timing["impact_count"]),
			"total_impacts": int(timing["impact_count"]),
			"resolved_duration_ticks": int(resolved["duration_ticks"]),
			"resolved_durations": resolved["durations"].duplicate(),
			"resolved_value": int(resolved["value"]),
			"resolved_values": resolved["values"].duplicate(),
			"source_id": int(cast["actor_id"]),
			"status_stacking_key": str(ability["status_stacking_key"]),
			"dispel_class": str(ability["dispel_class"]),
			"target": (cast["target"] as Dictionary).duplicate(true),
		}
		if bool(timing["persistent"]):
			state.persistent_effects[effect_id] = record
		else:
			state.scheduled_effects[effect_id] = record
	if schedule == "immediate_at_commit_then_destroy_caster":
		_emit_lifecycle_primitive(cast, "destroy_caster")
	if schedule == "immediate_at_commit_then_first_enemy_trigger":
		state.append_event("ability_trigger_armed", int(cast["actor_id"]), 0, {
			"ability_id": str(cast["ability_id"]), "cast_id": int(cast["cast_id"]),
		})


func _emit_due_effects(simulation: Variant, tick: int, context: Dictionary) -> void:
	for effect_id: int in _sorted_int_keys(state.scheduled_effects):
		var effect: Dictionary = state.scheduled_effects[effect_id]
		if int(effect["next_tick"]) > tick:
			continue
		var cast: Dictionary = state.casts.get(int(effect["cast_id"]), {})
		if cast.is_empty() or str(cast.get("status", "")) in ["cancelled", "interrupted"]:
			state.scheduled_effects.erase(effect_id)
			continue
		if str(cast["status"]) == "channeling":
			var ability: Dictionary = registry[str(cast["ability_id"])]
			var reason := _commit_reason(simulation, cast, ability, context)
			if not reason.is_empty():
				interrupt_actor(int(cast["actor_id"]), _block_to_interrupt(reason))
				continue
		_emit_effect_intent(simulation, effect, context)
		effect["impact_index"] = int(effect["impact_index"]) + 1
		var remaining := int(effect["remaining_impacts"])
		if remaining > 0:
			remaining -= 1
		effect["remaining_impacts"] = remaining
		if remaining == 0:
			state.scheduled_effects.erase(effect_id)
			if str(cast["status"]) == "channeling" and not _cast_has_scheduled_effects(int(cast["cast_id"])):
				cast["status"] = "committed"
				state.append_event("ability_channel_completed", int(cast["actor_id"]), _target_entity_id(cast["target"]), {
					"ability_id": str(cast["ability_id"]), "cast_id": int(cast["cast_id"]),
				})
		elif int(effect["interval_ticks"]) > 0:
			effect["next_tick"] = int(effect["next_tick"]) + int(effect["interval_ticks"])


func _emit_effect_intent(simulation: Variant, effect: Dictionary, context: Dictionary) -> void:
	var ability: Dictionary = registry[str(effect["ability_id"])]
	var raw_candidates: Array = context.get("candidate_entity_ids", [])
	var source_id := int(effect["source_id"])
	var owner_seat := int(simulation.state.entities[source_id].owner_seat) \
		if simulation.state.entities.has(source_id) else -1
	var effect_kind := str(effect["effect_kind"])
	var target_candidates: Array = raw_candidates.duplicate()
	if effect_kind not in ["reveal", "sight_and_detection"]:
		target_candidates = _closed_candidate_ids(
			simulation, owner_seat, raw_candidates
		)
	var selected: Array[int] = []
	var selection_context := context.duplicate(true)
	selection_context["rank"] = int(effect["rank"])
	var selection_kind := str(ability["target_kind"])
	var needs_selection := int(_ranked_int(
		ability, "area_radius_mt", "area_radius_mt_by_rank", int(effect["rank"])
	)) > 0 or selection_kind in [
		"attack_ground_area", "attack_line", "attack_target_chain", "attack_target_cone",
		"cone", "entity_chain", "line", "point",
	]
	if effect_kind in ["allied_detection_radius_mt", "visible_enemy_sight_bp"]:
		selected = _global_visibility_status_targets(
			simulation, owner_seat, effect_kind, raw_candidates
		)
	elif not target_candidates.is_empty() and needs_selection:
		for candidate: Dictionary in _legal_entity_candidates(
			simulation, int(effect["source_id"]), ability, target_candidates, selection_context,
			_target_position(simulation, effect["target"]), _selection_limit(ability, int(effect["rank"]))
		):
			selected.append(int(candidate["entity_id"]))
	elif _target_entity_id(effect["target"]) > 0:
		selected.append(_target_entity_id(effect["target"]))
	var intent := effect.duplicate(true)
	intent["impact_tick"] = state.tick
	intent["primitive_value"] = int(effect["resolved_value"])
	if str(effect["execution_gate"]) == "integer_accumulator_over_60_ticks" \
		and int(effect["total_impacts"]) > 0:
		var index := int(effect["impact_index"])
		var total := int(effect["resolved_value"])
		var count := int(effect["total_impacts"])
		@warning_ignore("integer_division")
		var cumulative_after := total * (index + 1) / count
		@warning_ignore("integer_division")
		var cumulative_before := total * index / count
		intent["primitive_value"] = cumulative_after - cumulative_before
	intent["selected_target_ids"] = selected
	_effect_intents.append(intent)
	state.append_event("ability_effect_emitted", int(effect["source_id"]), _target_entity_id(effect["target"]), {
		"ability_id": str(effect["ability_id"]),
		"cast_id": int(effect["cast_id"]),
		"effect_id": int(effect["effect_id"]),
		"effect_kind": str(effect["effect_kind"]),
		"primitive_kind": str(effect["primitive_kind"]),
	})


func _global_visibility_status_targets(
	simulation: Variant,
	owner_seat: int,
	effect_kind: String,
	raw_candidates: Array
) -> Array[int]:
	var allowed: Dictionary = {}
	if effect_kind == "allied_detection_radius_mt":
		for entity_id: int in simulation.state.sorted_entity_ids():
			var entity: Variant = simulation.state.entities[entity_id]
			if entity.alive and entity.hp > 0 and int(entity.owner_seat) == owner_seat:
				allowed[entity_id] = true
	else:
		for value: Variant in _closed_candidate_ids(
			simulation, owner_seat, raw_candidates
		):
			var entity_id := int(value)
			if simulation.state.entities.has(entity_id) \
				and int(simulation.state.entities[entity_id].owner_seat) != owner_seat:
				allowed[entity_id] = true
	var result: Array[int] = []
	for entity_id: int in _sorted_int_keys(allowed):
		result.append(entity_id)
	return result


func _closed_candidate_ids(
	simulation: Variant, owner_seat: int, raw_candidates: Array
) -> Array:
	if owner_seat not in [0, 1]:
		return []
	if _visibility_candidate_cache_tick != int(simulation.state.tick):
		_visibility_candidate_cache.clear()
		_visibility_candidate_cache_tick = int(simulation.state.tick)
	if not _visibility_candidate_cache.has(owner_seat):
		_visibility_candidate_cache[owner_seat] = \
			AuthoritativeVisibility.candidate_entity_ids(
				simulation, owner_seat, simulation.state.sorted_entity_ids(), true
			)
	var allowed: Dictionary = {}
	for value: Variant in _visibility_candidate_cache[owner_seat]:
		allowed[int(value)] = true
	var result: Array[int] = []
	for value: Variant in raw_candidates:
		var entity_id := int(value)
		if allowed.has(entity_id) and entity_id not in result:
			result.append(entity_id)
	result.sort()
	var untyped: Array = []
	untyped.assign(result)
	return untyped


func _bind_trigger_trap(
	simulation: Variant, effect: Dictionary, already_bound: Dictionary
) -> int:
	var source_id := int(effect.get("source_id", 0))
	var target_position := _target_position(simulation, effect.get("target", {}))
	if target_position.is_empty():
		return 0
	var candidates: Array[Dictionary] = []
	for entity_id: int in simulation.state.sorted_entity_ids():
		if already_bound.has(entity_id):
			continue
		var entity: Variant = simulation.state.entities[entity_id]
		if not bool(entity.alive) or int(entity.hp) <= 0 or "trap" not in entity.tags \
			or int(entity.integer_attributes.get("summon_source_id", 0)) != source_id:
			continue
		var dx := int(entity.position_x_mt) - int(target_position[0])
		var dy := int(entity.position_y_mt) - int(target_position[1])
		candidates.append({
			"distance_squared": dx * dx + dy * dy,
			"entity_id": entity_id,
			"stable_id": str(entity.public_id),
		})
	if candidates.is_empty():
		return 0
	candidates.sort_custom(_trigger_candidate_less)
	return int(candidates[0]["entity_id"])


func _first_trigger_enemy(
	simulation: Variant, trap_id: int, effect: Dictionary
) -> int:
	if not simulation.state.entities.has(trap_id):
		return 0
	var trap: Variant = simulation.state.entities[trap_id]
	var owner_seat := int(trap.owner_seat)
	if owner_seat not in [0, 1]:
		return 0
	var ability: Dictionary = registry.get(str(effect.get("ability_id", "")), {})
	if ability.is_empty():
		return 0
	var radius := _ranked_int(
		ability, "area_radius_mt", "area_radius_mt_by_rank",
		maxi(1, int(effect.get("rank", 1)))
	)
	if radius <= 0:
		return 0
	var candidates: Array[Dictionary] = []
	for entity_id: int in simulation.state.sorted_entity_ids():
		if entity_id == trap_id or not simulation.state.entities.has(entity_id) \
			or not simulation.state.combat.actors.has(entity_id):
			continue
		var entity: Variant = simulation.state.entities[entity_id]
		if not bool(entity.alive) or int(entity.hp) <= 0 \
			or int(entity.owner_seat) not in [0, 1] \
			or int(entity.owner_seat) == owner_seat:
			continue
		var layer := _entity_layer_for_trigger(simulation, entity_id)
		if layer not in ability.get("target_layers", []):
			continue
		var facts: Dictionary = {"hostile": true, layer: true}
		for tag: String in entity.tags:
			facts[tag] = true
		var legal := true
		for required_variant: Variant in ability.get("required_target_tags", []):
			if str(required_variant) not in facts:
				legal = false
				break
		if not legal:
			continue
		for forbidden_variant: Variant in ability.get("forbidden_target_tags", []):
			if str(forbidden_variant) in facts:
				legal = false
				break
		if not legal:
			continue
		var dx := int(entity.position_x_mt) - int(trap.position_x_mt)
		var dy := int(entity.position_y_mt) - int(trap.position_y_mt)
		var distance_squared := dx * dx + dy * dy
		if distance_squared > radius * radius:
			continue
		candidates.append({
			"distance_squared": distance_squared,
			"entity_id": entity_id,
			"stable_id": str(entity.public_id),
		})
	if candidates.is_empty():
		return 0
	candidates.sort_custom(_trigger_candidate_less)
	return int(candidates[0]["entity_id"])


static func _trigger_candidate_less(left: Dictionary, right: Dictionary) -> bool:
	if int(left["distance_squared"]) != int(right["distance_squared"]):
		return int(left["distance_squared"]) < int(right["distance_squared"])
	if str(left["stable_id"]) != str(right["stable_id"]):
		return str(left["stable_id"]) < str(right["stable_id"])
	return int(left["entity_id"]) < int(right["entity_id"])


static func _entity_layer_for_trigger(simulation: Variant, entity_id: int) -> String:
	if simulation.state.combat.actors.has(entity_id):
		return str(simulation.state.combat.actors[entity_id].get("layer", "ground"))
	if simulation.state.movement.enabled \
		and simulation.state.movement.actors.has(entity_id):
		return str(simulation.state.movement.actors[entity_id].get("layer", "ground"))
	return "air" if "air" in simulation.state.entities[entity_id].tags else "ground"


static func _persistent_status_key(
	source_id: int, ability_id: String, effect_kind: String
) -> String:
	return "%d|%s|%s" % [source_id, ability_id, effect_kind]


func _emit_lifecycle_primitive(cast: Dictionary, lifecycle_kind: String) -> void:
	var effect_id := state.allocate_effect_id()
	_effect_intents.append({
		"ability_id": str(cast["ability_id"]),
		"cast_id": int(cast["cast_id"]),
		"effect_id": effect_id,
		"effect_index": 2_147_483_647,
		"effect_kind": lifecycle_kind,
		"impact_tick": int(cast["commit_tick"]),
		"primitive_kind": "lifecycle",
		"primitive_value": 1,
		"rank": int(cast["rank"]),
		"resolved_duration_ticks": 0,
		"resolved_durations": [0],
		"resolved_value": 1,
		"resolved_values": [1],
		"selected_target_ids": [int(cast["actor_id"])],
		"source_id": int(cast["actor_id"]),
		"target": {"entity_id": int(cast["actor_id"]), "kind": "entity"},
	})


func _install_passives(actor_id: int) -> void:
	var actor: Dictionary = state.actors[actor_id]
	for ability_id: String in _sorted_string_keys(actor["ability_ranks"]):
		if int(actor["ability_ranks"][ability_id]) <= 0:
			continue
		var ability: Dictionary = registry[ability_id]
		if str(ability["activation_kind"]) not in PASSIVE_ACTIVATIONS:
			continue
		_install_passive_ability(actor_id, ability_id)


func _install_passive_ability(actor_id: int, ability_id: String) -> void:
	var actor: Dictionary = state.actors[actor_id]
	var ability: Dictionary = registry[ability_id]
	if int(actor["ability_ranks"].get(ability_id, 0)) <= 0:
		return
	var cast_id := state.allocate_cast_id()
	var cast := {
		"ability_id": ability_id, "actor_id": actor_id, "cast_id": cast_id,
		"commit_phase": "passive", "commit_tick": state.tick, "cooldown_ticks": 0,
		"issued_tick": state.tick, "mana_cost": 0,
		"rank": maxi(1, int(actor["ability_ranks"][ability_id])),
		"status": "persistent", "target": {"entity_id": actor_id, "kind": "entity"},
	}
	state.casts[cast_id] = cast
	_materialize_effects(cast, ability, {})


func _remove_persistent_ability(actor_id: int, ability_id: String) -> void:
	for effect_id: int in _sorted_int_keys(state.scheduled_effects):
		var scheduled: Dictionary = state.scheduled_effects[effect_id]
		if int(scheduled["source_id"]) == actor_id and str(scheduled["ability_id"]) == ability_id:
			state.scheduled_effects.erase(effect_id)
	for effect_id: int in _sorted_int_keys(state.persistent_effects):
		var effect: Dictionary = state.persistent_effects[effect_id]
		if int(effect["source_id"]) == actor_id and str(effect["ability_id"]) == ability_id:
			state.persistent_effects.erase(effect_id)
	for cast_id: int in _sorted_int_keys(state.casts):
		var cast: Dictionary = state.casts[cast_id]
		if int(cast["actor_id"]) == actor_id and str(cast["ability_id"]) == ability_id \
			and str(cast["status"]) == "persistent":
			state.casts.erase(cast_id)


func _emit_toggle_removed(cast: Dictionary, ability: Dictionary) -> void:
	var effect_id := state.allocate_effect_id()
	_effect_intents.append({
		"ability_id": str(cast["ability_id"]),
		"cast_id": int(cast["cast_id"]),
		"effect_id": effect_id,
		"effect_index": 2_147_483_646,
		"effect_kind": "remove_stacking_key",
		"impact_tick": int(cast["commit_tick"]),
		"primitive_kind": "status_remove",
		"primitive_value": 1,
		"rank": int(cast["rank"]),
		"resolved_duration_ticks": 0,
		"resolved_durations": [0],
		"resolved_value": 1,
		"resolved_values": [1],
		"selected_target_ids": [int(cast["actor_id"])],
		"source_id": int(cast["actor_id"]),
		"status_stacking_key": str(ability["status_stacking_key"]),
		"target": {"entity_id": int(cast["actor_id"]), "kind": "entity"},
	})


func _effect_timing(
	schedule: String, effect_kind: String, resolved: Dictionary, ability: Dictionary
) -> Dictionary:
	var result := {
		"first_offset_ticks": 0, "gate": schedule, "impact_count": 1,
		"interval_ticks": 0, "persistent": false,
	}
	match schedule:
		"per_tick_for_40_ticks":
			if _is_periodic_effect(effect_kind):
				result.merge({"first_offset_ticks": 1, "impact_count": 40, "interval_ticks": 1}, true)
		"per_tick_for_50_ticks":
			if _is_periodic_effect(effect_kind):
				result.merge({"first_offset_ticks": 1, "impact_count": 50, "interval_ticks": 1}, true)
		"per_tick_for_60_ticks", "integer_accumulator_over_60_ticks":
			if _is_periodic_effect(effect_kind):
				result.merge({"first_offset_ticks": 1, "impact_count": 60, "interval_ticks": 1}, true)
		"per_tick_for_80_ticks":
			if _is_periodic_effect(effect_kind):
				result.merge({"first_offset_ticks": 1, "impact_count": 80, "interval_ticks": 1}, true)
		"per_tick_for_rank_duration":
			if _is_periodic_effect(effect_kind):
				var duration := maxi(1, int(resolved["duration_ticks"]))
				result.merge({"first_offset_ticks": 1, "impact_count": duration, "interval_ticks": 1}, true)
		"every_10_ticks_for_100_ticks":
			result.merge({"first_offset_ticks": 10, "impact_count": 10, "interval_ticks": 10}, true)
		"six_impacts_every_10_ticks":
			result.merge({"first_offset_ticks": 10, "impact_count": 6, "interval_ticks": 10}, true)
		"immediate_then_per_tick_for_50_ticks":
			if effect_kind == "spell_damage_per_tick":
				result.merge({"first_offset_ticks": 1, "impact_count": 50, "interval_ticks": 1}, true)
		"per_tick_while_commanded":
			result.merge({"first_offset_ticks": 1, "impact_count": -1, "interval_ticks": 1}, true)
		"every_10_ticks":
			result.merge({"first_offset_ticks": 10, "impact_count": -1, "interval_ticks": 10}, true)
		"continuous", "continuous_below_4000_hp_bp", "attack_impact", "attack_projectile_path", "first_attack_impact_from_invisibility", "night_after_stationary_windup", "after_30_uninterrupted_attack_move_ticks_then_first_melee_impact", "research_completion":
			result["persistent"] = true
		"immediate_at_commit_then_first_enemy_trigger":
			if effect_kind == "root_first_enemy":
				result["persistent"] = true
		"tick_boundary":
			result.merge({"first_offset_ticks": 1, "impact_count": -1, "interval_ticks": 1}, true)
		"windup_completion", "dash_completion", "next_activation_phase", "immediate_at_commit", "immediate_at_commit_then_destroy_caster":
			pass
		_:
			## Configuration already rejects unknown schedules. This branch is a
			## defensive fail-closed guard against mutable test fixtures.
			result.merge({"gate": "unsupported", "impact_count": 0}, true)
	return result


func _normalize_target(
	simulation: Variant,
	actor_id: int,
	ability: Dictionary,
	target_input: Dictionary,
	request: Dictionary,
	trigger_mode: bool = false
) -> Dictionary:
	var kind := str(ability["target_kind"])
	if kind in ["self", "self_area", "global"]:
		return {"ok": true, "target": {"entity_id": actor_id, "kind": "entity"}}
	if kind in ["attack_ground_area", "attack_line", "attack_target", "attack_target_chain", "attack_target_cone"] \
		and not trigger_mode:
		return {"code": "ability_unavailable", "ok": false}
	var target := target_input.duplicate(true)
	if target.has("internal_id") and not target.has("entity_id"):
		target["entity_id"] = int(target["internal_id"])
	if target.has("xy_mt") and not target.has("position_mt"):
		target["position_mt"] = (target["xy_mt"] as Array).duplicate()
	var wants_entity := kind in [
		"attack_target", "attack_target_chain", "attack_target_cone", "corpse", "entity",
		"entity_chain", "structure",
	]
	var wants_point := kind in ["attack_ground_area", "attack_line", "cone", "line", "point"]
	if kind == "point_or_entity":
		wants_entity = target.has("entity_id")
		wants_point = not wants_entity
	if kind == "site":
		if str(target.get("kind", "")) != "site" or str(target.get("site_id", "")).is_empty() \
			or not _valid_position(target.get("position_mt", target.get("xy_mt", null))):
			return {"code": "invalid_target", "ok": false}
		var site_position: Array = target.get("position_mt", target.get("xy_mt"))
		var site_target := {
			"kind": "site", "position_mt": [int(site_position[0]), int(site_position[1])],
			"site_id": str(target["site_id"]),
		}
		return _range_checked_target(simulation, actor_id, ability, site_target, int(request.get("rank", 1)))
	if wants_point:
		var position_value: Variant = target.get("position_mt", target.get("xy_mt", null))
		if not _valid_position(position_value):
			return {"code": "invalid_target", "ok": false}
		var position: Array = position_value
		return _range_checked_target(simulation, actor_id, ability, {
			"kind": "point", "position_mt": [int(position[0]), int(position[1])],
		}, int(request.get("rank", 1)))
	if not wants_entity or typeof(target.get("entity_id", null)) != TYPE_INT:
		return {"code": "invalid_target", "ok": false}
	var target_id := int(target["entity_id"])
	if not simulation.state.entities.has(target_id):
		return {"code": "target_unavailable", "ok": false}
	var source: Variant = simulation.state.entities[actor_id]
	var entity: Variant = simulation.state.entities[target_id]
	if not bool(entity.alive) and kind != "corpse":
		return {"code": "target_unavailable", "ok": false}
	var facts := _entity_target_facts(simulation, source, entity, request)
	for required_variant: Variant in ability["required_target_tags"]:
		if str(required_variant) not in facts:
			return {"code": "invalid_target", "ok": false}
	for forbidden_variant: Variant in ability["forbidden_target_tags"]:
		if str(forbidden_variant) in facts:
			return {"code": "invalid_target", "ok": false}
	var layer := str(facts.get("layer", "ground"))
	if layer not in ability["target_layers"]:
		return {"code": "invalid_target", "ok": false}
	var normalized := {
		"entity_id": target_id,
		"kind": "entity",
		"position_mt": [int(entity.position_x_mt), int(entity.position_y_mt)],
	}
	if bool(request.get("_skip_cast_range", false)):
		return {"ok": true, "target": normalized}
	return _range_checked_target(simulation, actor_id, ability, normalized, int(request.get("rank", 1)))


func _range_checked_target(
	simulation: Variant,
	actor_id: int,
	ability: Dictionary,
	target: Dictionary,
	rank: int
) -> Dictionary:
	var source: Variant = simulation.state.entities[actor_id]
	var target_position: Array = target["position_mt"]
	var range_mt := _ranked_int(ability, "cast_range_mt", "cast_range_mt_by_rank", maxi(1, rank))
	var dx := int(source.position_x_mt) - int(target_position[0])
	var dy := int(source.position_y_mt) - int(target_position[1])
	if dx * dx + dy * dy > range_mt * range_mt:
		return {"code": "out_of_range", "ok": false}
	return {"ok": true, "target": target}


func _entity_target_facts(
	simulation: Variant, source: Variant, target: Variant, request: Dictionary
) -> Dictionary:
	var facts: Dictionary = {}
	for tag: String in target.tags:
		facts[tag] = true
	if not str(target.catalog_id).is_empty():
		facts[str(target.catalog_id)] = true
	if int(target.owner_seat) == int(source.owner_seat):
		facts["owned"] = true
	elif int(target.owner_seat) >= 0:
		facts["hostile"] = true
	if bool(request.get("target_visible", true)):
		facts["visible"] = true
	if bool(target.alive) and "corpse" not in facts:
		facts["living"] = true
	if int(target.max_mana) > 0:
		facts["mana"] = true
	if "incomplete" not in facts:
		facts["complete"] = true
	if "hero" not in facts:
		facts["non_hero"] = true
	if state.selected_faction_id.ends_with("-v1"):
		facts[state.selected_faction_id.trim_suffix("-v1")] = true
	var target_id := int(target.internal_id)
	var layer := "ground"
	if bool(simulation.state.combat.enabled) and simulation.state.combat.actors.has(target_id):
		var combat_actor: Dictionary = simulation.state.combat.actors[target_id]
		layer = str(combat_actor.get("layer", "ground"))
		var attack: Dictionary = combat_actor.get("attack", {})
		if not attack.is_empty():
			var physical := str(attack.get("attack_type", "")) in ["blade", "hero", "pierce", "siege"]
			if physical:
				facts["physical_attack"] = true
			if physical and str(attack.get("impact_kind", "")) == "authoritative_homing_projectile":
				facts["physical_ranged"] = true
	facts[layer] = true
	facts["layer"] = layer
	return facts


func _legal_entity_candidates(
	simulation: Variant,
	actor_id: int,
	ability: Dictionary,
	candidate_entity_ids: Array,
	request: Dictionary,
	origin_override: Array = [],
	limit: int = 2_147_483_647
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var seen: Dictionary = {}
	var origin := origin_override
	if origin.is_empty() and simulation.state.entities.has(actor_id):
		var source: Variant = simulation.state.entities[actor_id]
		origin = [int(source.position_x_mt), int(source.position_y_mt)]
	var radius := _ranked_int(
		ability, "area_radius_mt", "area_radius_mt_by_rank",
		maxi(1, int(request.get("rank", 1)))
	)
	for id_variant: Variant in candidate_entity_ids:
		var candidate_id := int(id_variant)
		if seen.has(candidate_id) or not simulation.state.entities.has(candidate_id):
			continue
		seen[candidate_id] = true
		var candidate: Variant = simulation.state.entities[candidate_id]
		var candidate_request := request.duplicate(true)
		candidate_request["_skip_cast_range"] = true
		var normalized := _normalize_target(
			simulation, actor_id, ability, {"entity_id": candidate_id, "kind": "entity"},
			candidate_request, str(ability["target_kind"]).begins_with("attack_")
		)
		if not bool(normalized.get("ok", false)):
			continue
		var dx := int(candidate.position_x_mt) - int(origin[0])
		var dy := int(candidate.position_y_mt) - int(origin[1])
		if radius > 0 and dx * dx + dy * dy > radius * radius:
			continue
		result.append({
			"distance_squared": dx * dx + dy * dy,
			"entity_id": candidate_id,
			"hp": int(candidate.hp),
			"max_hp": maxi(1, int(candidate.max_hp)),
			"opaque_order_key": str((request.get("opaque_order_keys", {}) as Dictionary).get(
				str(candidate_id), str(candidate.public_id)
			)),
		})
	result.sort_custom(_candidate_less)
	if result.size() > limit:
		result.resize(limit)
	return result


func _cast_block_reason(simulation: Variant, actor_id: int, _ability_id: String) -> String:
	if not bool(simulation.state.combat.enabled):
		return ""
	for status_id: int in _sorted_int_keys(simulation.state.combat.statuses):
		var status: Dictionary = simulation.state.combat.statuses[status_id]
		if int(status.get("target_id", 0)) != actor_id:
			continue
		match str(status.get("status_kind", "")):
			"disable", "stun":
				return "stunned"
			"silence":
				return "silenced"
	return ""


func _completed_upgrades(simulation: Variant, seat: int, request: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for value: Variant in request.get("completed_upgrade_ids", []):
		result.append(str(value))
	if bool(simulation.state.economy.enabled) and simulation.state.economy.players.has(seat):
		var completed: Dictionary = simulation.state.economy.players[seat].get("completed_upgrades", {})
		for key_variant: Variant in completed.keys():
			if int(completed[key_variant]) > 0:
				result.append(str(key_variant))
	result.sort()
	var unique: Array[String] = []
	for value: String in result:
		if unique.is_empty() or unique[-1] != value:
			unique.append(value)
	return unique


func _resolved_actor_ranks(
	simulation: Variant, actor_id: int, owner_type: String, explicit_ranks: Dictionary
) -> Dictionary:
	var result: Dictionary = {}
	var is_hero := hero_owner_types.has(owner_type)
	var learned: Dictionary = explicit_ranks
	if learned.is_empty() and is_hero and simulation.state.heroes.heroes.has(actor_id):
		learned = simulation.state.heroes.heroes[actor_id].get("learned_abilities", {})
	for ability_id: String in _sorted_string_keys(registry):
		var ability: Dictionary = registry[ability_id]
		if str(ability["faction_id"]) != state.selected_faction_id \
			or owner_type not in ability["allowed_owners"]:
			continue
		result[ability_id] = int(learned.get(ability_id, 0)) if is_hero else 1
	return result


func _ensure_actor(simulation: Variant, actor_id: int, request: Dictionary) -> PackedStringArray:
	if state.actors.has(actor_id):
		refresh_actor_ranks(simulation, actor_id)
		return PackedStringArray()
	return register_actor(
		simulation, actor_id, str(request.get("actor_type_id", "")),
		request.get("ability_ranks", {})
	)


func _resolved_effect(effect: Dictionary, rank: int, rank_count: int) -> Dictionary:
	var values: Array = effect["values"].duplicate()
	var durations: Array = effect["duration_ticks"].duplicate()
	var selected_value := int(values[rank - 1]) if rank_count > 1 and values.size() == rank_count else int(values[0])
	var selected_duration := int(durations[rank - 1]) \
		if rank_count > 1 and durations.size() == rank_count else int(durations[0])
	return {
		"duration_ticks": selected_duration,
		"durations": durations,
		"value": selected_value,
		"values": values,
	}


static func _ranked_int(ability: Dictionary, base_field: String, rank_field: String, rank: int) -> int:
	if ability.has(rank_field):
		var values: Array = ability[rank_field]
		return int(values[clampi(rank - 1, 0, values.size() - 1)])
	return int(ability[base_field])


static func _selection_limit(ability: Dictionary, rank: int) -> int:
	var limit := 2_147_483_647
	for effect_variant: Variant in ability["effects"]:
		var effect: Dictionary = effect_variant
		var kind := str(effect["kind"])
		var values: Array = effect["values"]
		var value := int(values[rank - 1]) \
			if int(ability["rank_count"]) > 1 and values.size() == int(ability["rank_count"]) \
			else int(values[0])
		if kind in ["maximum_targets", "maximum_visible_targets"]:
			limit = mini(limit, value)
		elif kind in ["additional_targets", "jumps"]:
			limit = mini(limit, value + 1)
	return limit


static func _is_periodic_effect(effect_kind: String) -> bool:
	return effect_kind in [
		"energy_to_hp", "energy_to_mana_ratio", "restore_hp_per_10_ticks",
		"restore_hp_per_tick", "restore_hp_total",
		"restore_owned_biological_hp_per_tick", "spell_damage_per_impact",
		"spell_damage_per_tick", "transfer_hp_per_tick",
	]


static func _trigger_gate(ability: Dictionary, request: Dictionary) -> bool:
	match str(ability["impact_schedule"]):
		"after_30_uninterrupted_attack_move_ticks_then_first_melee_impact":
			return int(request.get("uninterrupted_attack_move_ticks", 0)) >= 30 \
				and bool(request.get("first_melee_impact", false))
		"continuous_below_4000_hp_bp":
			return int(request.get("hp_bp", BP_ONE)) < 4_000
		"first_attack_impact_from_invisibility":
			return bool(request.get("from_invisibility", false))
		"night_after_stationary_windup":
			return bool(request.get("night", false)) \
				and int(request.get("stationary_ticks", 0)) >= int(ability["windup_ticks"])
	return true


static func _candidate_less(left: Dictionary, right: Dictionary) -> bool:
	if int(left["distance_squared"]) != int(right["distance_squared"]):
		return int(left["distance_squared"]) < int(right["distance_squared"])
	var left_scaled := int(left["hp"]) * int(right["max_hp"])
	var right_scaled := int(right["hp"]) * int(left["max_hp"])
	if left_scaled != right_scaled:
		return left_scaled < right_scaled
	return str(left["opaque_order_key"]) < str(right["opaque_order_key"])


static func _target_position(simulation: Variant, target: Dictionary) -> Array:
	var target_id := _target_entity_id(target)
	if target_id > 0 and simulation.state.entities.has(target_id):
		var entity: Variant = simulation.state.entities[target_id]
		return [int(entity.position_x_mt), int(entity.position_y_mt)]
	return (target.get("position_mt", [0, 0]) as Array).duplicate()


static func _target_entity_id(target: Dictionary) -> int:
	return int(target.get("entity_id", 0))


static func _valid_position(value: Variant) -> bool:
	return typeof(value) == TYPE_ARRAY and (value as Array).size() == 2 \
		and typeof(value[0]) == TYPE_INT and typeof(value[1]) == TYPE_INT


static func _valid_simulation(simulation: Variant) -> bool:
	return simulation != null and bool(simulation.get("is_ready")) \
		and simulation.get("state") != null


func _cancel_cast_effects(cast_id: int) -> void:
	for effect_id: int in _sorted_int_keys(state.scheduled_effects):
		if int(state.scheduled_effects[effect_id]["cast_id"]) == cast_id:
			state.scheduled_effects.erase(effect_id)


func _cast_has_scheduled_effects(cast_id: int) -> bool:
	for effect_id: int in _sorted_int_keys(state.scheduled_effects):
		if int(state.scheduled_effects[effect_id]["cast_id"]) == cast_id:
			return true
	return false


static func _block_to_interrupt(reason: String) -> String:
	match reason:
		"stunned":
			return "stun"
		"silenced":
			return "silence"
		"invalid_actor":
			return "death"
		"invalid_target", "target_unavailable", "out_of_range":
			return "target_out_of_range" if reason == "out_of_range" else "target_illegal"
	return reason


static func _sorted_int_keys(source: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for key_variant: Variant in source.keys():
		result.append(int(key_variant))
	result.sort()
	return result


static func _sorted_string_keys(source: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for key_variant: Variant in source.keys():
		result.append(str(key_variant))
	result.sort()
	return result


static func _sorted_dictionary(source: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key: String in _sorted_string_keys(source):
		result[key] = source[key]
	return result


static func _append_errors(target: PackedStringArray, values: Variant) -> void:
	if typeof(values) not in [TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY]:
		target.append(str(values))
		return
	for value: Variant in values:
		target.append(str(value))


static func _compile_failure(code: String) -> Dictionary:
	return {"code": code, "ok": false, "plan": {}}


static func _receipt(accepted: bool, code: String, details: Dictionary) -> Dictionary:
	return {
		"accepted": accepted,
		"code": code,
		"details": details.duplicate(true),
	}
