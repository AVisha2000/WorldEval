extends SceneTree

const PodiumScript := preload("res://scripts/arena/presentation/arena_podium.gd")
const CATEGORIES := [
	"objective_control", "planning_adaptation", "resource_combat_efficiency",
	"social_intelligence", "delegation_cognition", "reliability_safety"
]
const WEIGHTS := {
	"objective_control": 0.35, "planning_adaptation": 0.20,
	"resource_combat_efficiency": 0.15, "social_intelligence": 0.15,
	"delegation_cognition": 0.10, "reliability_safety": 0.05
}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var podium: ArenaPodium = PodiumScript.new()
	root.add_child(podium)
	await process_frame
	podium.show_match_result(_result_fixture())
	await process_frame
	var state := podium.get_presentation_state()
	assert(bool(state.visible))
	assert(str(state.verification_label) == "VERIFIED MATCH RESULT")
	assert(state.placement_order == ["sol", "terra", "luna"])
	assert(state.podium_column_order == ["terra", "sol", "luna"])
	assert(int(state.category_counts.sol) == 6)
	assert(int(state.category_counts.terra) == 6)
	assert(int(state.category_counts.luna) == 6)
	assert(float(state.scores.sol) == 82.0)
	assert(str(state.details_text).contains("NO LLM JUDGE"))
	assert(str(state.details_text).contains("18 category records"))
	podium.set_details_visible(true)
	assert(bool(podium.get_presentation_state().details_visible))
	print("ARENA_PODIUM_HEADLESS_OK columns=%s categories=18 verified=true" % str(state.podium_column_order))
	quit(0)


func _result_fixture() -> Dictionary:
	return {
		"schema_version": 2,
		"formula_version": "worldarena-score/1.0.0",
		"match_id": "podium-headless",
		"verified": true,
		"verification_hash": "a".repeat(64),
		"weights": WEIGHTS,
		"factions": [
			_faction("sol", "gpt-5.6-sol", 1, 82.0),
			_faction("terra", "gpt-5.6-terra", 2, 70.0),
			_faction("luna", "gpt-5.6-luna", 3, 61.0)
		]
	}


func _faction(faction_id: String, model: String, placement: int, score: float) -> Dictionary:
	var categories: Array[Dictionary] = []
	for category in CATEGORIES:
		categories.append({
			"category": category,
			"score": score,
			"weight": WEIGHTS[category],
			"weighted_contribution": score * float(WEIGHTS[category]),
			"measurement_count": placement + 1,
			"event_ids": ["event.%s.%s" % [faction_id, category]],
			"action_ids": ["plan.%s.%s" % [faction_id, category]]
		})
	return {
		"faction_id": faction_id,
		"model_id": model,
		"placement": placement,
		"worldarena_score": score,
		"categories": categories,
		"metrics": {
			"core": 1000 - placement * 100, "territory": 9 - placement,
			"crown": 6 - placement, "trades": placement, "tokens": 45000 + placement,
			"invalid": placement - 1, "pacts": 3 - placement, "betrayals": placement - 1
		},
		"best_decision": {"round": 8, "summary": "Converted a supplied flank into durable Crown pressure."},
		"biggest_failure": {"round": 15, "summary": "Overextended one group beyond its supply chain."}
	}
