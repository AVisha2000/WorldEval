class_name ArenaPodium
extends Control

## Evidence-first match result overlay. This adapter renders already-computed scores;
## it never asks an LLM to rank, score, or explain the competitors.

signal dismissed

const FACTION_ORDER := ["sol", "terra", "luna"]
const CATEGORY_DEFINITIONS := [
	{"id": "objective_control", "label": "Objective control", "weight": 0.35},
	{"id": "planning_adaptation", "label": "Planning + adaptation", "weight": 0.20},
	{"id": "resource_combat_efficiency", "label": "Resource + combat", "weight": 0.15},
	{"id": "social_intelligence", "label": "Social intelligence", "weight": 0.15},
	{"id": "delegation_cognition", "label": "Delegation + cognition", "weight": 0.10},
	{"id": "reliability_safety", "label": "Reliability + safety", "weight": 0.05}
]
const MEDAL_COLORS := {
	1: Color("f4c95d"),
	2: Color("bdc9cf"),
	3: Color("c5895a")
}
const FACTION_COLORS := {
	"sol": Color("f4c95d"),
	"terra": Color("ff7a70"),
	"luna": Color("70b8ff")
}

var verification_label := "UNVERIFIED LOCAL DEMO"
var verification_detail := "No verified artifact hash was supplied."
var rendered_factions: Array[Dictionary] = []
var details_text := ""

var _content: VBoxContainer
var _verification_badge: Label
var _subtitle: Label
var _podium_row: HBoxContainer
var _details_overlay: Control
var _details_body: Label


func _ready() -> void:
	_build_interface()
	visible = false


## Render an evaluation payload. Expected production fields mirror
## MatchEvaluationResult, but conservative fallbacks keep local demo evidence legible.
func show_match_result(result: Dictionary) -> void:
	if _content == null:
		_build_interface()
	var verification := _verification_from_result(result)
	verification_label = str(verification.label)
	verification_detail = str(verification.detail)
	_verification_badge.text = verification_label
	_verification_badge.add_theme_color_override(
		"font_color", Color("9fe3d2") if bool(verification.verified) else Color("ffb35c")
	)
	_subtitle.text = "%s  ·  %s  ·  %s" % [
		str(result.get("match_id", "local-match")),
		str(result.get("formula_version", "worldarena-score/1.0.0")),
		verification_detail
	]

	rendered_factions = _normalize_factions(result)
	for child in _podium_row.get_children():
		child.queue_free()
	# Classic podium order: second at left, winner elevated in the center, third at right.
	for placement in [2, 1, 3]:
		var faction := _faction_for_placement(placement)
		_podium_row.add_child(_build_podium_column(faction, placement))

	details_text = _calculation_details(result, rendered_factions, verification)
	_details_body.text = details_text
	set_details_visible(false)
	visible = true
	move_to_front()


func set_details_visible(value: bool) -> void:
	if _details_overlay != null:
		_details_overlay.visible = value


func get_presentation_state() -> Dictionary:
	var placements: Array[String] = []
	var visual_columns: Array[String] = []
	var category_counts: Dictionary = {}
	var scores: Dictionary = {}
	for faction in rendered_factions:
		placements.append(str(faction.get("faction_id", "unknown")))
		category_counts[str(faction.get("faction_id", "unknown"))] = faction.get("categories", []).size()
		scores[str(faction.get("faction_id", "unknown"))] = float(faction.get("score", 0.0))
	for placement in [2, 1, 3]:
		visual_columns.append(str(_faction_for_placement(placement).get("faction_id", "unknown")))
	return {
		"visible": visible,
		"verification_label": verification_label,
		"verification_detail": verification_detail,
		"placement_order": placements,
		"podium_column_order": visual_columns,
		"category_counts": category_counts,
		"scores": scores,
		"details_text": details_text,
		"details_visible": _details_overlay != null and _details_overlay.visible
	}


func _build_interface() -> void:
	if _content != null:
		return
	name = "ArenaEvidencePodium"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var shade := ColorRect.new()
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0.004, 0.014, 0.021, 0.94)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(shade)

	var outer := MarginContainer.new()
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	outer.add_theme_constant_override("margin_left", 34)
	outer.add_theme_constant_override("margin_right", 34)
	outer.add_theme_constant_override("margin_top", 24)
	outer.add_theme_constant_override("margin_bottom", 24)
	add_child(outer)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style(Color("071923"), Color("2b6d72"), 18, 16))
	outer.add_child(panel)
	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 9)
	panel.add_child(_content)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	_content.add_child(header)
	var title := Label.new()
	title.text = "MATCH EVIDENCE PODIUM"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color("fff3c4"))
	header.add_child(title)
	_verification_badge = Label.new()
	_verification_badge.text = verification_label
	_verification_badge.add_theme_font_size_override("font_size", 13)
	_verification_badge.add_theme_color_override("font_color", Color("ffb35c"))
	header.add_child(_verification_badge)

	_subtitle = Label.new()
	_subtitle.text = "Awaiting deterministic match telemetry."
	_subtitle.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_subtitle.add_theme_font_size_override("font_size", 11)
	_subtitle.add_theme_color_override("font_color", Color("7899a5"))
	_content.add_child(_subtitle)

	_podium_row = HBoxContainer.new()
	_podium_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_podium_row.add_theme_constant_override("separation", 12)
	_content.add_child(_podium_row)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 8)
	_content.add_child(actions)
	var how := Button.new()
	how.text = "HOW CALCULATED?"
	how.tooltip_text = "Open the versioned formula and evidence accounting"
	how.pressed.connect(func() -> void: set_details_visible(true))
	actions.add_child(how)
	var close := Button.new()
	close.text = "RETURN TO ARENA"
	close.pressed.connect(func() -> void:
		visible = false
		dismissed.emit()
	)
	actions.add_child(close)

	_build_details_overlay()


func _build_details_overlay() -> void:
	_details_overlay = Control.new()
	_details_overlay.name = "CalculationDetails"
	_details_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_details_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_details_overlay)
	var shade := ColorRect.new()
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0.002, 0.009, 0.014, 0.92)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_details_overlay.add_child(shade)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -410
	panel.offset_top = -250
	panel.offset_right = 410
	panel.offset_bottom = 250
	panel.add_theme_stylebox_override("panel", _panel_style(Color("071923"), Color("69f0d0"), 18, 20))
	_details_overlay.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)
	var title := Label.new()
	title.text = "HOW WORLD ARENA CALCULATES THE SCORE"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color("fff3c4"))
	box.add_child(title)
	_details_body = Label.new()
	_details_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_details_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_details_body.add_theme_font_size_override("font_size", 13)
	_details_body.add_theme_color_override("font_color", Color("c8dcda"))
	box.add_child(_details_body)
	var close := Button.new()
	close.text = "BACK TO PODIUM"
	close.pressed.connect(func() -> void: set_details_visible(false))
	box.add_child(close)
	_details_overlay.visible = false


func _build_podium_column(faction: Dictionary, placement: int) -> Control:
	var wrapper := VBoxContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.size_flags_stretch_ratio = 1.0
	var lift := Control.new()
	lift.custom_minimum_size.y = 0 if placement == 1 else 28 if placement == 2 else 48
	wrapper.add_child(lift)

	var medal_color: Color = MEDAL_COLORS[placement]
	var card := PanelContainer.new()
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", _panel_style(Color(0.026, 0.064, 0.081, 0.98), medal_color.darkened(0.32), 14, 11))
	wrapper.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	card.add_child(box)

	var faction_id := str(faction.get("faction_id", "unknown"))
	var heading := Label.new()
	heading.text = "%s  PLACE %d  ·  %s" % [_medal_glyph(placement), placement, faction_id.to_upper()]
	heading.add_theme_font_size_override("font_size", 16 if placement == 1 else 14)
	heading.add_theme_color_override("font_color", medal_color)
	box.add_child(heading)
	var model := Label.new()
	model.text = str(faction.get("model", "unresolved model"))
	model.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	model.tooltip_text = model.text
	model.add_theme_font_size_override("font_size", 11)
	model.add_theme_color_override("font_color", FACTION_COLORS.get(faction_id, Color("a9c5c5")))
	box.add_child(model)
	var score := Label.new()
	score.text = "%05.1f / 100" % float(faction.get("score", 0.0))
	score.add_theme_font_size_override("font_size", 25 if placement == 1 else 21)
	score.add_theme_color_override("font_color", Color("fff3c4"))
	box.add_child(score)

	for category_variant in faction.get("categories", []):
		if category_variant is Dictionary:
			box.add_child(_build_category_bar(category_variant))

	var metrics: Dictionary = faction.get("metrics", {})
	var metric_label := Label.new()
	metric_label.text = "CORE %s   LAND %s   CROWN %s   TRADES %s\nTOKENS %s   INVALID %s   PACTS %s   BETRAYALS %s" % [
		_format_count(metrics.get("core", 0)), _format_count(metrics.get("territory", 0)),
		_format_count(metrics.get("crown", 0)), _format_count(metrics.get("trades", 0)),
		_format_count(metrics.get("tokens", 0)), _format_count(metrics.get("invalid", 0)),
		_format_count(metrics.get("pacts", 0)), _format_count(metrics.get("betrayals", 0))
	]
	metric_label.add_theme_font_size_override("font_size", 9)
	metric_label.add_theme_color_override("font_color", Color("a9c5c5"))
	box.add_child(metric_label)

	var best := Label.new()
	best.text = "BEST  %s" % str(faction.get("best", "No positive decision evidence recorded."))
	best.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	best.tooltip_text = best.text
	best.add_theme_font_size_override("font_size", 9)
	best.add_theme_color_override("font_color", Color("9fe3d2"))
	box.add_child(best)
	var failure := Label.new()
	failure.text = "BIGGEST MISS  %s" % str(faction.get("failure", "No negative decision evidence recorded."))
	failure.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	failure.tooltip_text = failure.text
	failure.add_theme_font_size_override("font_size", 9)
	failure.add_theme_color_override("font_color", Color("ff9c91"))
	box.add_child(failure)
	return wrapper


func _build_category_bar(category: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	var label := Label.new()
	label.text = str(category.get("label", "Category"))
	label.custom_minimum_size.x = 112
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.add_theme_font_size_override("font_size", 9)
	label.add_theme_color_override("font_color", Color("c8dcda"))
	row.add_child(label)
	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = 100
	bar.value = float(category.get("score", 0.0))
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(82, 8)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(bar)
	var value := Label.new()
	value.text = "%3.0f · %d%%" % [float(category.get("score", 0.0)), int(round(float(category.get("weight", 0.0)) * 100.0))]
	value.custom_minimum_size.x = 64
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.add_theme_font_size_override("font_size", 9)
	value.add_theme_color_override("font_color", Color("7899a5"))
	row.add_child(value)
	return row


func _normalize_factions(result: Dictionary) -> Array[Dictionary]:
	var raw_factions: Array = _record_array(result.get("factions", []))
	var normalized: Array[Dictionary] = []
	for raw_variant in raw_factions:
		if not raw_variant is Dictionary:
			continue
		var raw: Dictionary = raw_variant
		var faction_id := str(raw.get("faction_id", raw.get("id", "unknown")))
		if faction_id not in FACTION_ORDER:
			continue
		var score := clampf(float(raw.get("worldarena_score", raw.get("score", 0.0))), 0.0, 100.0)
		normalized.append({
			"faction_id": faction_id,
			"placement": clampi(int(raw.get("placement", 0)), 0, 3),
			"model": _resolved_model(raw),
			"score": score,
			"categories": _normalize_categories(raw, result.get("weights", {})),
			"metrics": _normalize_metrics(raw),
			"best": _evidence_summary(raw.get("best_decision", null), "No positive decision evidence recorded."),
			"failure": _evidence_summary(raw.get("biggest_failure", null), "No negative decision evidence recorded.")
		})
	# Fill absent factions so a malformed/local result still produces an honest three-place shell.
	for faction_id in FACTION_ORDER:
		if not _has_faction(normalized, faction_id):
			normalized.append({
				"faction_id": faction_id, "placement": 0, "model": "unresolved model", "score": 0.0,
				"categories": _normalize_categories({}, result.get("weights", {})),
				"metrics": _normalize_metrics({}),
				"best": "No positive decision evidence recorded.",
				"failure": "No negative decision evidence recorded."
			})
	# Resolve missing/duplicate placements deterministically by score, then faction ID.
	var placements_valid := true
	var seen_placements: Dictionary = {}
	for faction in normalized:
		var placement := int(faction.placement)
		if placement < 1 or placement > 3 or seen_placements.has(placement):
			placements_valid = false
		seen_placements[placement] = true
	if not placements_valid:
		normalized.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if not is_equal_approx(float(a.score), float(b.score)):
				return float(a.score) > float(b.score)
			return FACTION_ORDER.find(str(a.faction_id)) < FACTION_ORDER.find(str(b.faction_id))
		)
		for index in normalized.size():
			normalized[index].placement = index + 1
	normalized.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.placement) < int(b.placement))
	return normalized


func _normalize_categories(raw: Dictionary, weights_variant: Variant) -> Array[Dictionary]:
	var weights: Dictionary = weights_variant if weights_variant is Dictionary else {}
	var by_id: Dictionary = {}
	var categories_variant: Variant = raw.get("categories", [])
	if categories_variant is Dictionary:
		for key in categories_variant:
			var value: Variant = categories_variant[key]
			by_id[str(key)] = value if value is Dictionary else {"score": value}
	else:
		for item_variant in _record_array(categories_variant):
			if item_variant is Dictionary:
				by_id[str(item_variant.get("category", item_variant.get("id", "")))] = item_variant
	var normalized: Array[Dictionary] = []
	for definition in CATEGORY_DEFINITIONS:
		var category_id := str(definition.id)
		var item: Dictionary = by_id.get(category_id, {})
		var weight := clampf(float(item.get("weight", weights.get(category_id, definition.weight))), 0.0, 1.0)
		normalized.append({
			"id": category_id,
			"label": str(definition.label),
			"score": clampf(float(item.get("score", 0.0)), 0.0, 100.0),
			"weight": weight,
			"weighted_contribution": clampf(float(item.get("weighted_contribution", float(item.get("score", 0.0)) * weight)), 0.0, 100.0),
			"measurement_count": maxi(0, int(item.get("measurement_count", 0))),
			"event_ids": _record_array(item.get("event_ids", [])),
			"action_ids": _record_array(item.get("action_ids", []))
		})
	return normalized


func _normalize_metrics(raw: Dictionary) -> Dictionary:
	var metrics: Dictionary = raw.get("metrics", {}) if raw.get("metrics", {}) is Dictionary else {}
	var raw_metrics: Dictionary = raw.get("raw_metrics", {}) if raw.get("raw_metrics", {}) is Dictionary else {}
	var outcome: Dictionary = raw_metrics.get("outcome", {}) if raw_metrics.get("outcome", {}) is Dictionary else {}
	var territory: Dictionary = raw_metrics.get("territory", {}) if raw_metrics.get("territory", {}) is Dictionary else {}
	var diplomacy: Dictionary = raw_metrics.get("diplomacy", {}) if raw_metrics.get("diplomacy", {}) is Dictionary else {}
	var cognition: Dictionary = raw_metrics.get("cognition", {}) if raw_metrics.get("cognition", {}) is Dictionary else {}
	var usage: Dictionary = cognition.get("usage", raw.get("usage", {})) if cognition.get("usage", raw.get("usage", {})) is Dictionary else {}
	var weighted_tokens := float(raw.get("weighted_tokens", metrics.get("tokens", 0)))
	if weighted_tokens <= 0.0:
		weighted_tokens = float(usage.get("input_tokens", 0)) + float(usage.get("output_tokens", 0)) + float(usage.get("reasoning_tokens", 0))
	return {
		"core": metrics.get("core", outcome.get("core_health", 0)),
		"territory": metrics.get("territory", territory.get("final_supplied_points", territory.get("territory_time", 0))),
		"crown": metrics.get("crown", territory.get("crown_hold_rounds", 0)),
		"trades": metrics.get("trades", diplomacy.get("trades_executed", 0)),
		"tokens": metrics.get("tokens", weighted_tokens),
		"invalid": metrics.get("invalid", raw.get("invalid_orders", 0)),
		"pacts": metrics.get("pacts", diplomacy.get("pacts_accepted", 0)),
		"betrayals": metrics.get("betrayals", diplomacy.get("betrayals", raw_metrics.get("betrayals", 0)))
	}


func _calculation_details(result: Dictionary, factions: Array[Dictionary], verification: Dictionary) -> String:
	var measurements := 0
	var event_references := 0
	var action_references := 0
	for faction in factions:
		for category_variant in faction.get("categories", []):
			if not category_variant is Dictionary:
				continue
			measurements += int(category_variant.get("measurement_count", 0))
			event_references += category_variant.get("event_ids", []).size()
			action_references += category_variant.get("action_ids", []).size()
	var formula := "35% Objective control + 20% Planning/adaptation + 15% Resource/combat efficiency + 15% Social intelligence + 10% Delegation/cognition + 5% Reliability/safety."
	return "%s\n\nFormula version: %s\n%s\n\nEvidence accounting: %d category records · %d measurements · %d event references · %d committed-action references.\n\nNO LLM JUDGE. Scores are computed from deterministic, Godot-authoritative telemetry and versioned measurements. A model never grades itself or another competitor.\n\nVerification: %s — %s" % [
		"WORLD ARENA SCORE = weighted sum of six 0–100 category scores.",
		str(result.get("formula_version", "worldarena-score/1.0.0")), formula,
		factions.size() * CATEGORY_DEFINITIONS.size(), measurements, event_references, action_references,
		str(verification.label), str(verification.detail)
	]


func _verification_from_result(result: Dictionary) -> Dictionary:
	var nested: Dictionary = result.get("verification", {}) if result.get("verification", {}) is Dictionary else {}
	var supplied_flag := bool(result.get("verified", nested.get("verified", false)))
	var supplied_hash := str(result.get("verification_hash", result.get("artifact_hash", nested.get("hash", "")))).to_lower()
	if supplied_flag and _is_sha256(supplied_hash):
		return {"verified": true, "label": "VERIFIED MATCH RESULT", "detail": "artifact %s…%s" % [supplied_hash.left(8), supplied_hash.right(6)]}
	var reason := str(result.get("verification_detail", nested.get("detail", "No verified artifact hash was supplied.")))
	if supplied_flag and not _is_sha256(supplied_hash):
		reason = "Verified flag refused because its artifact hash was missing or malformed."
	return {"verified": false, "label": str(result.get("verification_label", "UNVERIFIED LOCAL DEMO")), "detail": reason}


func _resolved_model(raw: Dictionary) -> String:
	for field in ["resolved_model", "model_id", "model"]:
		var value := str(raw.get(field, "")).strip_edges()
		if not value.is_empty():
			return value
	return "unresolved model"


func _evidence_summary(value: Variant, fallback: String) -> String:
	if value is Dictionary:
		var summary := str(value.get("summary", "")).strip_edges()
		if summary.is_empty():
			return fallback
		var round_number := int(value.get("round", 0))
		return "R%02d · %s" % [round_number, summary] if round_number > 0 else summary
	var text := str(value).strip_edges() if value != null else ""
	return text if not text.is_empty() else fallback


func _faction_for_placement(placement: int) -> Dictionary:
	for faction in rendered_factions:
		if int(faction.get("placement", 0)) == placement:
			return faction
	return {"faction_id": "unknown", "placement": placement, "model": "unresolved model", "score": 0.0, "categories": [], "metrics": {}}


func _has_faction(factions: Array[Dictionary], faction_id: String) -> bool:
	for faction in factions:
		if str(faction.get("faction_id", "")) == faction_id:
			return true
	return false


func _record_array(value: Variant) -> Array:
	if value is Array:
		return value
	if value is Dictionary:
		return value.values()
	return []


func _format_count(value: Variant) -> String:
	var numeric := float(value)
	if numeric >= 1000000.0:
		return "%.1fM" % (numeric / 1000000.0)
	if numeric >= 1000.0:
		return "%.1fk" % (numeric / 1000.0)
	return str(int(round(numeric)))


func _medal_glyph(placement: int) -> String:
	return "◆ GOLD" if placement == 1 else "◇ SILVER" if placement == 2 else "● BRONZE"


func _is_sha256(value: String) -> bool:
	if value.length() != 64:
		return false
	for character in value:
		if character not in "0123456789abcdef":
			return false
	return true


func _panel_style(fill: Color, border: Color, radius: int, margin: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = margin
	style.content_margin_right = margin
	style.content_margin_top = margin
	style.content_margin_bottom = margin
	return style
