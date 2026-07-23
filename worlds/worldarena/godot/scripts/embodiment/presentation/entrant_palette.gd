class_name EmbodimentEntrantPalette
extends RefCounted

## Public, presentation-only identity palette.  Entrant identity is supplied by the managed
## series roster (or derived from the public trio seat rotation), never from hidden authority
## state.  Keeping this here makes camera frames immediately legible without changing gameplay.

const IDENTITIES := {
	"alpha": {"label": "ALPHA", "color": Color("38bdf8")},
	"bravo": {"label": "BRAVO", "color": Color("fb7185")},
	"sol": {"label": "SOL", "color": Color("fbbf24")},
	"luna": {"label": "LUNA", "color": Color("a78bfa")},
	"terra": {"label": "TERRA", "color": Color("34d399")},
}
const FALLBACK := {"label": "OPERATOR", "color": Color("cbd5e1")}


static func normalize(value: Variant, fallback: String = "") -> String:
	var identity := str(value).to_lower().strip_edges()
	if IDENTITIES.has(identity):
		return identity
	return fallback if IDENTITIES.has(fallback) else ""


static func label(identity: String) -> String:
	var values: Dictionary = IDENTITIES.get(identity, FALLBACK)
	return str(values.label)


static func color(identity: String) -> Color:
	var values: Dictionary = IDENTITIES.get(identity, FALLBACK)
	return values.color


static func tint_avatar(avatar: Node3D, identity: String) -> void:
	var resolved := normalize(identity)
	if str(avatar.get_meta("presentation_entrant_id", "")) == resolved:
		return
	avatar.set_meta("presentation_entrant_id", resolved)
	avatar.set_meta("presentation_color_hex", color(resolved).to_html(false))
	_apply_tint_recursive(avatar, color(resolved))


static func _apply_tint_recursive(node: Node, tint: Color) -> void:
	if node is MeshInstance3D:
		var material := StandardMaterial3D.new()
		material.albedo_color = tint
		material.metallic = 0.08
		material.roughness = 0.48
		node.material_override = material
	for child: Node in node.get_children():
		_apply_tint_recursive(child, tint)
