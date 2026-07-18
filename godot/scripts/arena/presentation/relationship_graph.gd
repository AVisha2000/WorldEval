extends Control

const FACTION_IDS := ["sol", "terra", "luna"]

var faction_colors := {
	"sol": Color("f4c95d"),
	"terra": Color("ff7a70"),
	"luna": Color("70b8ff")
}
var relations: Array = []


func set_relations(value: Array) -> void:
	relations = value.duplicate(true)
	queue_redraw()


func apply_relation(event: Dictionary) -> void:
	var payload: Dictionary = event.get("payload", {})
	var relation_id := str(event.get("pact_id", payload.get("pact_id", payload.get("offer_id", event.get("event_id", "")))))
	var replaced := false
	for index in range(relations.size()):
		if str(relations[index].get("id", "")) == relation_id:
			relations[index] = {
				"id": relation_id,
				"actor_id": event.get("actor_id", ""),
				"target_id": event.get("target_id", _first_target(event)),
				"state": event.get("state", "pending"),
				"summary": event.get("summary", "")
			}
			replaced = true
			break
	if not replaced:
		relations.append({
			"id": relation_id,
			"actor_id": event.get("actor_id", ""),
			"target_id": event.get("target_id", _first_target(event)),
			"state": event.get("state", "pending"),
			"summary": event.get("summary", "")
		})
	tooltip_text = str(event.get("summary", "Faction relationship"))
	queue_redraw()


func _draw() -> void:
	var positions := {
		"sol": Vector2(size.x * 0.5, 18.0),
		"terra": Vector2(size.x - 34.0, size.y - 26.0),
		"luna": Vector2(34.0, size.y - 26.0)
	}
	for relation_variant in relations:
		var relation: Dictionary = relation_variant
		var actor := str(relation.get("actor_id", ""))
		var target := str(relation.get("target_id", ""))
		if not positions.has(actor) or not positions.has(target):
			continue
		var state := str(relation.get("state", "pending"))
		var color := Color("f4c95d")
		var width := 2.0
		if state in ["acknowledged", "active", "accepted", "executed"]:
			color = Color("70b8ff")
			width = 3.0
		elif state in ["broken", "betrayed"]:
			color = Color("ff5964")
			width = 4.0
		var start: Vector2 = positions[actor]
		var finish: Vector2 = positions[target]
		if state in ["broken", "betrayed"]:
			var midpoint := start.lerp(finish, 0.5)
			var normal := (finish - start).normalized().orthogonal() * 5.0
			draw_line(start, midpoint - normal, color, width, true)
			draw_line(midpoint + normal, finish, color, width, true)
		else:
			draw_dashed_line(start, finish, color, width, 7.0, true, true)

	var font := ThemeDB.fallback_font
	for faction_id in FACTION_IDS:
		var center: Vector2 = positions[faction_id]
		var color: Color = faction_colors[faction_id]
		draw_circle(center, 15.0, Color(0.015, 0.04, 0.055, 1.0))
		draw_arc(center, 15.0, 0.0, TAU, 32, color, 3.0, true)
		draw_string(font, center + Vector2(-10.0, 5.0), faction_id.substr(0, 1).to_upper(), HORIZONTAL_ALIGNMENT_CENTER, 20.0, 15, color.lightened(0.25))


func _first_target(event: Dictionary) -> String:
	var targets: Array = event.get("target_ids", [])
	return str(targets[0]) if not targets.is_empty() else ""
