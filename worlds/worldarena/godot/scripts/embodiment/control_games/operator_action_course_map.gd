class_name EmbodimentOperatorActionCourseMapV2
extends RefCounted


const PROTOCOL_VERSION := "llm-controller/0.2.0"
const TASK_ID := "operator-action-course-v0"
const STATIONS := [
	{"id": "walk", "affordance": "move_forward"},
	{"id": "turn", "affordance": "turn_right"},
	{"id": "gather", "affordance": "gather"},
	{"id": "carry", "affordance": "carry_forward"},
	{"id": "deposit", "affordance": "deposit"},
	{"id": "build", "affordance": "build"},
	{"id": "dash", "affordance": "dash"},
	{"id": "guard", "affordance": "guard"},
	{"id": "primary", "affordance": "primary"},
	{"id": "cancel", "affordance": "cancel_interaction"},
	{"id": "hazard", "affordance": "wait_for_hazard"},
	{"id": "celebrate", "affordance": "celebrate"},
]


static func station_id(index: int) -> String:
	assert(index >= 0 and index < STATIONS.size())
	return STATIONS[index].id


static func station_affordance(index: int) -> String:
	assert(index >= 0 and index < STATIONS.size())
	return STATIONS[index].affordance


static func visible_id(index: int) -> String:
	return "v_station_%s" % station_id(index)
