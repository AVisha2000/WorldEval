class_name EmbodimentTrioGameDispatcherV3
extends RefCounted

const RelayAuthority := preload("res://scripts/embodiment/trio_games/trio_relay_authority.gd")
const FreeForAllAuthority := preload(
	"res://scripts/embodiment/trio_games/trio_free_for_all_authority.gd"
)
const Codec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const ProtocolIdentity := preload(
	"res://scripts/embodiment/v3/protocol/embodiment_protocol_package_identity_v3.gd"
)

const PARTICIPANTS := ["participant_0", "participant_1", "participant_2"]
const TASKS := ["trio-relay-v0", "trio-free-for-all-v0"]
const CONFIG_FIELDS := [
	"protocol_version", "episode_id", "mode", "task_id", "seed", "observation_profile",
	"timing_track", "maximum_episode_ticks", "participant_ids", "seat_rotation",
]
const WINDOW_FIELDS := [
	"episode_id", "observation_seq", "mode", "start_tick", "duration_ticks", "decisions",
]
const DECISION_FIELDS := ["disposition", "action", "fallback", "no_input_reason"]

var authority = null
var config := {}


func configure(value: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if not Codec._has_exact_fields(value, CONFIG_FIELDS) \
		or value.get("protocol_version") != ProtocolIdentity.PROTOCOL_VERSION \
		or not Codec._valid_episode_id(str(value.get("episode_id", ""))) \
		or value.get("mode") != "trio-game-v0" \
		or value.get("task_id") not in TASKS \
		or value.get("observation_profile") not in ["text-visible-v1", "hybrid-visible-v1"] \
		or value.get("timing_track") != "step-locked-v1" \
		or value.get("participant_ids") != PARTICIPANTS \
		or typeof(value.get("seed")) != TYPE_INT or value.seed < 0 \
		or typeof(value.get("maximum_episode_ticks")) != TYPE_INT \
		or value.maximum_episode_ticks != 1200 \
		or typeof(value.get("seat_rotation")) != TYPE_INT \
		or int(value.seat_rotation) not in [0, 1, 2]:
		errors.append("trio_config_invalid")
		return errors
	config = value.duplicate(true)
	authority = RelayAuthority.new() if value.task_id == "trio-relay-v0" \
		else FreeForAllAuthority.new()
	errors.append_array(authority.configure(value))
	if not errors.is_empty():
		authority = null
	return errors


func step_window(window: Variant) -> Dictionary:
	assert(authority != null, "configure before stepping")
	var result: Dictionary = authority.step_window(window)
	result["trio_result"] = _terminal_result() if bool(result.terminal.ended) else null
	return result


func observe_all() -> Dictionary:
	return authority.observe_all()


func checkpoint_hash() -> String:
	return authority.checkpoint_hash()


func terminal() -> Dictionary:
	return authority.terminal.duplicate(true)


func capability_status() -> Dictionary:
	return {
		"implemented_modes": ["trio-game-v0"],
		"implemented_observation_profiles": ["text-visible-v1", "hybrid-visible-v1"],
		"implemented_tasks": TASKS.duplicate(),
		"certified_modes": [], "certified_observation_profiles": [],
		"scored_observation_profiles": [],
	}


func decision_window_schema_valid(window: Variant) -> bool:
	if not window is Dictionary or not Codec._has_exact_fields(window, WINDOW_FIELDS) \
		or window.get("episode_id") != config.episode_id \
		or typeof(window.get("observation_seq")) != TYPE_INT \
		or window.observation_seq != authority.observation_seq \
		or window.get("mode") != "trio-game-v0" \
		or typeof(window.get("start_tick")) != TYPE_INT or window.start_tick != authority.tick \
		or typeof(window.get("duration_ticks")) != TYPE_INT or window.duration_ticks != 10 \
		or not window.get("decisions") is Dictionary \
		or window.decisions.size() != 3:
		return false
	for participant_id: String in PARTICIPANTS:
		if not window.decisions.has(participant_id):
			return false
		var decision: Variant = window.decisions[participant_id]
		if not decision is Dictionary or not Codec._has_exact_fields(decision, DECISION_FIELDS):
			return false
		match str(decision.disposition):
			"accepted":
				if not authority._is_active(participant_id) \
					or not authority._valid_action(decision.action) \
					or decision.fallback != "none" or decision.no_input_reason != null \
					or decision.action.control.duration_ticks != 10:
					return false
			"no_input":
				if not authority._is_active(participant_id) or decision.action != null \
					or decision.fallback != "neutral" \
					or decision.no_input_reason not in [
						"missing", "invalid", "timeout", "stale_observation", "budget_exhausted",
					]:
					return false
			"eliminated":
				if authority._is_active(participant_id) or decision.action != null \
					or decision.fallback != "neutral" or decision.no_input_reason != "eliminated":
					return false
			_:
				return false
	return true


func participant_presentation_source(participant_id: String) -> Dictionary:
	if participant_id not in PARTICIPANTS:
		return {}
	var observation: Dictionary = authority.observe(participant_id)
	var operator: Dictionary = authority.operators[participant_id]
	var visible_sources: Array[Dictionary] = []
	for entity_value: Variant in observation.visible_entities:
		if not entity_value is Dictionary:
			return {}
		var entity: Dictionary = entity_value
		var entity_source := {"id": str(entity.id), "kind": str(entity.kind)}
		if entity.id == "v_relay":
			entity_source["position_axial"] = {"q": 0, "r": 0}
		elif str(entity.id).begins_with("v_participant_"):
			var other_id := str(entity.id).trim_prefix("v_")
			if other_id not in PARTICIPANTS:
				return {}
			var other: Dictionary = authority.operators[other_id]
			entity_source["position_axial"] = {
				"q": int(other.position_axial.x), "r": int(other.position_axial.y),
			}
			entity_source["heading"] = int(other.heading)
			entity_source["animation_state"] = _animation_state(other_id)
		else:
			return {}
		visible_sources.append(entity_source)
	return {
		"participant_id": participant_id,
		"operator": {
			"position_axial": {"q": int(operator.position_axial.x), "r": int(operator.position_axial.y)},
			"heading": int(operator.heading), "animation_state": _animation_state(participant_id),
		},
		"visible_entities": visible_sources,
	}


func _animation_state(participant_id: String) -> String:
	var operator: Dictionary = authority.operators[participant_id]
	if not authority._is_active(participant_id):
		return "defeat"
	var receipt: Variant = authority.previous_receipts.get(participant_id)
	if receipt is Dictionary:
		if "primary_hit" in receipt.get("codes", []) or "primary_missed" in receipt.get("codes", []):
			return "attack"
		if "guard_active" in receipt.get("codes", []):
			return "guard"
		for effect: Variant in receipt.get("effects", []):
			if effect is Dictionary and effect.get("kind") == "movement_distance_mt" \
				and int(effect.get("value", 0)) > 0:
				return "walk"
	return "idle"


func _terminal_result() -> Dictionary:
	var participant_outcomes := {}
	for participant_id: String in PARTICIPANTS:
		var group := _placement_for(participant_id)
		var eliminated_tick: Variant = authority.operators[participant_id].eliminated_tick
		var outcome := "draw" if authority.terminal.outcome == "draw" else (
			"win" if authority.winner_id == participant_id else (
				"eliminated" if eliminated_tick != null else "loss"
			)
		)
		participant_outcomes[participant_id] = {
			"participant_id": participant_id, "outcome": outcome,
			"place": int(group.place), "tied": bool(group.tie),
			"eliminated_tick": eliminated_tick,
		}
	return {
		"schema_version": "llm-controller/trio-result/1.0.0",
		"task_id": str(config.task_id), "outcome": str(authority.terminal.outcome),
		"reason": str(authority.terminal.reason), "winner_id": authority.winner_id,
		"placements": authority.placements.duplicate(true),
		"participant_outcomes": participant_outcomes,
	}


func _placement_for(participant_id: String) -> Dictionary:
	for value: Variant in authority.placements:
		if value is Dictionary and participant_id in value.get("participant_ids", []):
			return value
	return {}
