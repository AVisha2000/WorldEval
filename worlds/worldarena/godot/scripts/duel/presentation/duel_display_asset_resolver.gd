extends RefCounted
class_name DuelDisplayAssetResolver

## Display-only asset lookup for the Duel spectator. The resolver is intentionally
## unable to receive simulation objects or influence authoritative state.

const DISPLAY_TEXTURES := {
	"panel": "res://assets/external/kenney_ui_pack_adventure/Vector/panel_grey_dark.svg",
	"panel_accent": "res://assets/external/kenney_ui_pack_adventure/Vector/panel_grey_bolts_blue.svg",
	"button": "res://assets/external/kenney_ui_pack_adventure/Vector/button_grey.svg",
	"minimap_ring": "res://assets/external/kenney_ui_pack_adventure/Vector/minimap_ring_grey_detail.svg",
	"warning": "res://assets/external/kenney_ui_pack_adventure/Vector/minimap_icon_exclamation_yellow.svg",
	"objective": "res://assets/external/kenney_ui_pack_adventure/Vector/minimap_icon_star_white.svg",
}

const ANIMATION_STATE_TO_CLIP := {
	"idle": "idle",
	"move": "walk",
	"walk": "walk",
	"run": "run",
	"gather_lumber": "gather_chop",
	"gather_gold": "gather_mine",
	"carry": "carry",
	"build": "build_hammer",
	"repair": "repair",
	"attack_melee": "attack_melee",
	"attack_ranged": "attack_ranged",
	"attack_siege": "attack_siege",
	"cast": "cast",
	"hit": "hit",
	"stunned": "stunned",
	"rooted": "rooted",
	"dead": "death",
	"spawn": "spawn",
	"transform": "transform",
	"victory": "victory",
}

var _resolved_paths: Dictionary = {}


func texture(display_key: String) -> Texture2D:
	var path := str(DISPLAY_TEXTURES.get(display_key, ""))
	if path.is_empty() or not ResourceLoader.exists(path, "Texture2D"):
		_resolved_paths[display_key] = "procedural-style-fallback"
		return null
	var loaded := ResourceLoader.load(path, "Texture2D") as Texture2D
	if loaded == null:
		_resolved_paths[display_key] = "procedural-style-fallback"
		return null
	_resolved_paths[display_key] = path
	return loaded


func animation_clip_for_state(display_state: String) -> String:
	return str(ANIMATION_STATE_TO_CLIP.get(display_state.to_lower(), "idle"))


func resolved_paths() -> Dictionary:
	return _resolved_paths.duplicate(true)


func recommended_pack_status() -> Dictionary:
	return {
		"active_ui": "kenney_ui_pack_adventure",
		"production_family": "kaykit",
		"characters": "kaykit_adventurers:checksum-pending",
		"crypt_characters": "kaykit_skeletons:checksum-pending",
		"environment": "kaykit_medieval_hexagon:checksum-pending",
		"nature": "kaykit_forest_nature:checksum-pending",
		"resources": "kaykit_resource_bits:checksum-pending",
		"tools": "kaykit_rpg_tools_bits:checksum-pending",
		"animations": "kaykit_character_animations:checksum-pending",
		"fallback": "procedural tactical glyphs and approved Kenney UI",
	}
