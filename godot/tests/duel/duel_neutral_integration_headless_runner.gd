extends SceneTree

const Bootstrap := preload("res://scripts/duel/match/duel_match_bootstrap.gd")
const MatchRuntime := preload("res://scripts/duel/match/duel_match_runtime.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const TIE_KEY := "worldarena-neutral-integration-key-v1"
const GOLDEN_HASH := "40bbe1348132e440830a993b523fb8e6b75647d6ebdb28e13b09952fb57c0b86"

var _failures := PackedStringArray()


func _init() -> void:
	var bootstrap := Bootstrap.create_official({
		"faction_id": "vanguard-v1", "match_seed": 4_242, "scored": false,
	})
	_check(bool(bootstrap.get("ok", false)), "official bootstrap failed")
	var attached := MatchRuntime.attach_protected_authority(
		bootstrap, TIE_KEY.to_utf8_buffer()
	)
	_check(bool(attached.get("ok", false)), "protected neutral authority failed: %s" % "; ".join(attached.get("errors", [])))
	if not bool(attached.get("ok", false)):
		_finish("")
		return
	var simulation: DuelSimulation = attached["simulation"]
	var neutral_ids: Array = attached["registered_neutral_entity_ids"]
	_check(neutral_ids.size() == 34, "official map did not register all 34 neutral creeps")
	_check(simulation.state.neutrals.enabled, "neutral state is absent from shared authority")
	_check(simulation.state.neutrals.camps.size() == 16, "shared neutral camp registry is incomplete")
	for entity_id_variant: Variant in neutral_ids:
		var entity_id := int(entity_id_variant)
		_check(simulation.state.entities.has(entity_id), "neutral entity is missing")
		_check(simulation.state.combat.actors.has(entity_id), "neutral combat actor is missing")
		_check(simulation.state.movement.actors.has(entity_id), "neutral movement actor is missing")
		_check(not simulation.grid.ground_cells_for_actor(entity_id).is_empty(), "neutral footprint is not reserved")
	_check(simulation.validate().is_empty(), "attached neutral simulation failed validation")

	var first_tick := simulation.step_tick()
	_check(first_tick["phase_ids"] == range(1, 15), "neutral tick skipped a frozen phase")
	_check(simulation.state.tick == 1, "shared tick did not advance")
	_check(simulation.state.orders.size() == 34, "idle neutral AI did not activate one durable order per creep")
	_check(simulation.validate().is_empty(), "post-tick neutral simulation failed validation")
	for event_variant: Variant in simulation.state.events:
		var event: DuelEvent = event_variant
		_check(event.event_kind != "neutral_authority_error", "neutral integration emitted an authority error")

	var summary := {
		"camps": simulation.state.neutrals.camps.size(),
		"entities": simulation.state.entities.size(),
		"events": simulation.state.events.size(),
		"neutral_entities": neutral_ids.size(),
		"orders": simulation.state.orders.size(),
		"tick": simulation.state.tick,
	}
	var hash := Codec.sha256_canonical({
		"checkpoint": simulation.snapshot(), "summary": summary,
	})
	if not GOLDEN_HASH.is_empty():
		_check(hash == GOLDEN_HASH, "neutral integration golden changed: %s" % hash)
	_finish(hash, summary)


func _finish(hash: String, summary: Dictionary = {}) -> void:
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_NEUTRAL_INTEGRATION_FAILURE: %s" % failure)
		print("DUEL_NEUTRAL_INTEGRATION_FAILED count=%d hash=%s" % [_failures.size(), hash])
		quit(1)
		return
	print("DUEL_NEUTRAL_INTEGRATION_OK hash=%s summary=%s" % [hash, JSON.stringify(summary)])
	quit(0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
