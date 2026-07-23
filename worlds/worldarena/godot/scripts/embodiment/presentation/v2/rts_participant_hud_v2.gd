class_name EmbodimentRtsParticipantHudV2
extends RefCounted

## Presentation-only RTS HUD for the resource-relay match.  This helper deliberately accepts
## just an ordinary participant observation plus the already-filtered presentation source for
## that same participant.  It never receives an authority object, checkpoint, roster internals,
## or a spectator projection.

const EntrantPalette := preload("res://scripts/embodiment/presentation/entrant_palette.gd")

const RESOURCE_RELAY_TASK := "duo-resource-relay-v0"
const CAMERA_HEIGHT := 13.5
const CAMERA_DISTANCE := 12.5
const CAMERA_PITCH_DEGREES := -47.0
const CAMERA_FOV := 52.0
const CAMERA_FAR := 82.0
const PANEL_SIZE := Vector2(560.0, 234.0)
const PANEL_POSITION := Vector2(22.0, 22.0)

const ACTION_LABELS := {
	"idle": "HOLDING POSITION",
	"walk": "ADVANCING",
	"dash": "DASHING",
	"turn": "TURNING",
	"gather": "HARVESTING MATERIAL",
	"carry": "CARRYING MATERIAL",
	"deposit": "DEPOSITING MATERIAL",
	"build": "BUILDING BARRICADE",
	"guard": "DEFENDING RELAY",
	"attack": "ENGAGING RIVAL",
	"hit": "RECOVERING",
}


static func configure_resource_relay_camera(camera: Camera3D) -> void:
	## A high, close-to-isometric local camera: it remains participant-owned, follows the avatar,
	## and reads the same filtered scene as before, while showing the relay skirmish as a map.
	## It does not change authority sight/range semantics or any capture/replay data.
	if camera == null:
		return
	camera.position = Vector3(0.0, CAMERA_HEIGHT, CAMERA_DISTANCE)
	camera.rotation_degrees = Vector3(CAMERA_PITCH_DEGREES, 0.0, 0.0)
	camera.fov = CAMERA_FOV
	camera.near = 0.1
	camera.far = CAMERA_FAR
	camera.current = true
	camera.set_meta("presentation_camera_profile", "rts_isometric_resource_relay_v1")


static func build(layer: CanvasLayer) -> RichTextLabel:
	if layer == null:
		return null
	var existing := layer.get_node_or_null("RtsObjectiveHud/Content") as RichTextLabel
	if existing != null:
		return existing
	var panel := ColorRect.new()
	panel.name = "RtsObjectiveHud"
	panel.position = PANEL_POSITION
	panel.size = PANEL_SIZE
	panel.color = Color("101a24d9")
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(panel)
	var border := ReferenceRect.new()
	border.name = "Border"
	border.position = Vector2(2.0, 2.0)
	border.size = PANEL_SIZE - Vector2(4.0, 4.0)
	border.border_color = Color("60a5fa88")
	border.border_width = 2.0
	border.editor_only = false
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(border)
	var content := RichTextLabel.new()
	content.name = "Content"
	content.position = Vector2(16.0, 12.0)
	content.size = PANEL_SIZE - Vector2(32.0, 24.0)
	content.bbcode_enabled = true
	content.fit_content = false
	content.scroll_active = false
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_theme_font_size_override("normal_font_size", 17)
	content.add_theme_color_override("default_color", Color("e2e8f0"))
	panel.add_child(content)
	return content


static func update(
		hud: RichTextLabel, observation: Dictionary, operator_source: Dictionary, entrant_id: String
) -> void:
	if hud == null:
		return
	hud.text = render_text(observation, operator_source, entrant_id)


static func render_text(
		observation: Dictionary, operator_source: Dictionary, entrant_id: String
) -> String:
	## All fields below are already present in the player's observation/source.  Entity state is
	## listed only when the entity itself is visible, keeping the HUD subject to the same privacy
	## boundary as the participant camera.
	var identity := EntrantPalette.normalize(entrant_id, "alpha")
	var self_state: Dictionary = observation.get("self", {})
	var health := clampi(int(self_state.get("health_percent", 0)), 0, 100)
	var energy := clampi(int(self_state.get("energy_percent", 0)), 0, 100)
	var carrying := _carrying(self_state.get("inventory", []))
	var action := _action_label(operator_source.get("animation_state", "idle"))
	var goal := _short_text(observation.get("goal", "Secure the relay."), 118)
	var lines: Array[String] = []
	lines.append("[color=#%s][b]%s COMMAND[/b][/color]   [color=#94a3b8]RESOURCE RELAY[/color]" % [
		EntrantPalette.color(identity).to_html(false), EntrantPalette.label(identity),
	])
	lines.append("[color=#e2e8f0]HP[/color] %d%%   [color=#e2e8f0]ENERGY[/color] %d%%   [color=#fbbf24]%s[/color]" % [
		health, energy, "CARRYING MATERIAL" if carrying else "HANDS FREE",
	])
	lines.append("[color=#7dd3fc][b]ACTION[/b][/color]  %s" % action)
	lines.append("[color=#cbd5e1][b]OBJECTIVE[/b][/color]  %s" % goal)
	var visible_lines := _visible_status_lines(observation.get("visible_entities", []), identity)
	if visible_lines.is_empty():
		lines.append("[color=#94a3b8]SCOUTING[/color]  No relay assets or rival currently in view.")
	else:
		lines.append("[color=#a7f3d0][b]IN VIEW[/b][/color]  %s" % "  •  ".join(visible_lines))
	var receipt: Variant = observation.get("previous_receipt")
	if receipt is Dictionary:
		var disposition: String = _short_text(receipt.get("disposition", ""), 28).to_upper()
		if not disposition.is_empty():
			lines.append("[color=#94a3b8]LAST WINDOW[/color]  %s" % disposition.replace("_", " "))
	return "\n".join(lines)


static func _visible_status_lines(entities: Variant, self_identity: String) -> Array[String]:
	var output: Array[String] = []
	if not entities is Array:
		return output
	for raw: Variant in entities:
		if not raw is Dictionary:
			continue
		var entity: Dictionary = raw
		var entity_id := str(entity.get("id", ""))
		var state := _short_text(entity.get("state", "visible"), 30).to_upper().replace("_", " ")
		if entity_id.begins_with("v_resource_") or entity_id.begins_with("v_drop_"):
			output.append("[color=#fbbf24]MATERIAL %s[/color]" % state)
		elif entity_id == "v_friendly_relay":
			output.append("[color=#60a5fa]RELAY %s[/color]" % state)
		elif entity_id == "v_friendly_barricade":
			output.append("[color=#a7f3d0]BARRICADE %s[/color]" % state)
		elif entity_id == "v_rival":
			var rival := "bravo" if self_identity == "alpha" else "alpha"
			output.append("[color=#%s]RIVAL %s %s[/color]" % [
				EntrantPalette.color(rival).to_html(false), EntrantPalette.label(rival), state,
			])
	# Resource relay has at most one relevant resource, one relay, one barricade and one rival
	# in its compact opening view. Keep all four visible objective actors readable.
	return output.slice(0, 4)


static func _carrying(inventory: Variant) -> bool:
	if not inventory is Array:
		return false
	for item: Variant in inventory:
		if item is Dictionary and str(item.get("kind", "")) == "material" \
				and int(item.get("count", 0)) > 0:
			return true
	return false


static func _action_label(value: Variant) -> String:
	var key := str(value).to_lower()
	return str(ACTION_LABELS.get(key, "HOLDING POSITION"))


static func _short_text(value: Variant, limit: int) -> String:
	var text := str(value).strip_edges().replace("\n", " ")
	return text.left(limit)
