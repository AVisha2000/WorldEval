extends PanelContainer
class_name DuelSetupPanel

## Non-authoritative setup UI. Public setup summaries never contain credentials.
## A separate launch request is emitted only to the process-local coordinator;
## protected key fields clear only after its HTTP transport accepts the body.

signal setup_submitted(config: Dictionary)
signal launch_requested(request: Dictionary)
signal validation_changed(valid: bool, issues: PackedStringArray)
signal mode_changed(mode_id: String)
signal faction_changed(faction_id: String)

const MODE_ORDER := ["fixed_simultaneous", "continuous_realtime"]
const MODES := {
	"fixed_simultaneous": {
		"label": "Fixed & Simultaneous",
		"short": "Both models receive the same completed tick and their accepted moves begin together.",
		"cadence": "Every 10 simulated seconds",
		"decision_period_ticks": 100,
		"response_deadline_ms": 45000,
	},
	"continuous_realtime": {
		"label": "Continuous Real Time",
		"short": "The world keeps moving. Faster useful responses can act sooner, with identical limits.",
		"cadence": "Opportunity every 5 simulated seconds",
		"decision_period_ticks": 50,
		"response_deadline_ms": 8000,
	},
}

const FACTION_ORDER := ["vanguard-v1", "warhost-v1", "grove-v1", "crypt-v1"]
const FACTIONS := {
	"vanguard-v1": {
		"name": "Vanguard",
		"glyph": "V",
		"strength": "Flexible combined arms",
		"mechanic": "Cooperative building, strong defense, and tactical teleportation.",
	},
	"warhost-v1": {
		"name": "Warhost",
		"glyph": "W",
		"strength": "Durable aggression",
		"mechanic": "Forward pressure, garrisoned dens, and resilient expensive units.",
	},
	"grove-v1": {
		"name": "Grove",
		"glyph": "G",
		"strength": "Mobility and restoration",
		"mechanic": "Transforming ancients, night tactics, and precise ranged control.",
	},
	"crypt-v1": {
		"name": "Crypt",
		"glyph": "C",
		"strength": "Summons and spell zones",
		"mechanic": "Corpses, Blight, concentrated magic, and temporary armies.",
	},
}

const SEAT_COLORS := [Color("ffad42"), Color("43c7ff")]
const PROVIDER_ORDER := [
	"openai",
	"baseline.noop",
	"baseline.seeded_random",
	"baseline.rush",
]
const PROVIDERS := {
	"openai": {
		"label": "OpenAI Responses",
		"model": "",
		"baseline": false,
	},
	"baseline.noop": {
		"label": "Baseline · No-op",
		"model": "baseline-noop-v1",
		"baseline": true,
	},
	"baseline.seeded_random": {
		"label": "Baseline · Seeded legal",
		"model": "baseline-seeded-random-v1",
		"baseline": true,
	},
	"baseline.rush": {
		"label": "Baseline · Rush",
		"model": "baseline-rush-v1",
		"baseline": true,
	},
}
const REASONING_ORDER := ["none", "low", "medium", "high", "xhigh", "max"]

var selected_mode := "fixed_simultaneous"
var selected_faction := "vanguard-v1"
var official_locked := false
var _built := false
var _integrity_hash := ""
var _integrity_verified := false

var player_label_inputs: Array[LineEdit] = []
var player_provider_inputs: Array[OptionButton] = []
var player_model_inputs: Array[LineEdit] = []
var player_reasoning_inputs: Array[OptionButton] = []
var protected_key_inputs: Array[LineEdit] = []
var player_service_tier_inputs: Array[LineEdit] = []
var connection_labels: Array[Label] = []
var mode_buttons: Dictionary = {}
var faction_buttons: Dictionary = {}
var faction_detail_label: Label
var fairness_summary_label: Label
var validation_label: Label
var locked_banner: PanelContainer
var start_button: Button
var map_select: OptionButton
var seed_input: SpinBox
var cadence_label: Label
var observation_select: OptionButton
var memory_select: OptionButton
var match_length_select: OptionButton
var spectator_select: OptionButton
var launch_status_label: Label
var _launch_busy := false


func _ready() -> void:
	_ensure_built()
	_refresh_all()


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	name = "SetupPanel"
	custom_minimum_size = Vector2(1080, 760)
	add_theme_stylebox_override("panel", _style_box(Color("0b1723"), Color("466379"), 12, 2))

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	add_child(margin)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	margin.add_child(body)

	var heading_row := HBoxContainer.new()
	body.add_child(heading_row)
	var heading_stack := VBoxContainer.new()
	heading_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading_row.add_child(heading_stack)
	var eyebrow := _label("WORLDARENA  /  MODEL DUEL", 13, Color("7cd8ff"))
	heading_stack.add_child(eyebrow)
	var title := _label("Configure a fair match", 30, Color("f3f7fa"))
	heading_stack.add_child(title)
	var close_explanation := _label(
		"Choose how decisions are timed and one faction for both competitors. The world, rules, budgets, and faction bytes remain identical.",
		15, Color("c7d5df"))
	close_explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	heading_stack.add_child(close_explanation)

	locked_banner = PanelContainer.new()
	locked_banner.name = "LockedBanner"
	locked_banner.add_theme_stylebox_override("panel", _style_box(Color("263824"), Color("8fd37d"), 8, 1))
	var locked_text := _label("BENCHMARK\nCONFIGURATION LOCKED", 12, Color("c9f2bc"))
	locked_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	locked_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	locked_banner.add_child(locked_text)
	locked_banner.visible = false
	heading_row.add_child(locked_banner)

	var model_row := HBoxContainer.new()
	model_row.add_theme_constant_override("separation", 14)
	body.add_child(model_row)
	for slot in 2:
		model_row.add_child(_build_model_card(slot))

	var choice_row := HBoxContainer.new()
	choice_row.add_theme_constant_override("separation", 14)
	body.add_child(choice_row)
	choice_row.add_child(_build_mode_section())
	choice_row.add_child(_build_faction_section())

	body.add_child(_build_match_details())

	var summary := PanelContainer.new()
	summary.add_theme_stylebox_override("panel", _style_box(Color("102432"), Color("2f667d"), 8, 1))
	var summary_margin := MarginContainer.new()
	summary_margin.add_theme_constant_override("margin_left", 14)
	summary_margin.add_theme_constant_override("margin_right", 14)
	summary_margin.add_theme_constant_override("margin_top", 10)
	summary_margin.add_theme_constant_override("margin_bottom", 10)
	summary.add_child(summary_margin)
	var summary_row := HBoxContainer.new()
	summary_margin.add_child(summary_row)
	fairness_summary_label = _label("", 13, Color("dce8ef"))
	fairness_summary_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fairness_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary_row.add_child(fairness_summary_label)
	validation_label = _label("CHECKING", 13, Color("ffcf6b"))
	validation_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	summary_row.add_child(validation_label)
	body.add_child(summary)
	launch_status_label = _label("", 12, Color("a7bac6"))
	launch_status_label.name = "LaunchStatus"
	launch_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	launch_status_label.visible = false
	body.add_child(launch_status_label)

	var footer := HBoxContainer.new()
	body.add_child(footer)
	var privacy := _label("Keys stay in protected process memory, never enter match data, and clear after local request dispatch.", 12, Color("91aabd"))
	privacy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	privacy.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	footer.add_child(privacy)
	start_button = Button.new()
	start_button.name = "StartFairMatchButton"
	start_button.text = "START FAIR MATCH"
	start_button.custom_minimum_size = Vector2(210, 46)
	start_button.tooltip_text = "Validate both model slots and send this read-only setup request to the match host."
	start_button.add_theme_font_size_override("font_size", 14)
	start_button.add_theme_color_override("font_color", Color("07111c"))
	start_button.add_theme_stylebox_override("normal", _style_box(Color("7ed8f6"), Color("b9edff"), 8, 1))
	start_button.add_theme_stylebox_override("hover", _style_box(Color("a8e8ff"), Color.WHITE, 8, 1))
	start_button.add_theme_stylebox_override("disabled", _style_box(Color("435765"), Color("5d7180"), 8, 1))
	start_button.pressed.connect(submit_if_valid)
	footer.add_child(start_button)


func _build_model_card(slot: int) -> PanelContainer:
	var card := PanelContainer.new()
	card.name = "ModelSlot%d" % [slot]
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", _style_box(Color("101f2c"), SEAT_COLORS[slot], 8, 2))
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	card.add_child(margin)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	margin.add_child(body)
	var header := _label("%s  MODEL %s" % ["▲" if slot == 0 else "◆", "A" if slot == 0 else "B"], 15, SEAT_COLORS[slot])
	body.add_child(header)

	var label_input := _line_edit("Display label", "Model %s" % ["A" if slot == 0 else "B"])
	label_input.name = "Player%dLabel" % [slot]
	label_input.text_changed.connect(func(_value: String) -> void: _refresh_validation())
	player_label_inputs.append(label_input)
	body.add_child(label_input)

	var provider_input := OptionButton.new()
	provider_input.name = "Player%dProvider" % [slot]
	provider_input.tooltip_text = "Select the explicit provider adapter used for this seat."
	for provider_id: String in PROVIDER_ORDER:
		provider_input.add_item(str(PROVIDERS[provider_id]["label"]))
		provider_input.set_item_metadata(provider_input.item_count - 1, provider_id)
	provider_input.item_selected.connect(func(_index: int) -> void: _on_provider_selected(slot))
	player_provider_inputs.append(provider_input)
	body.add_child(provider_input)

	var model_input := _line_edit("Exact model ID", "exact provider model snapshot")
	model_input.name = "Player%dModel" % [slot]
	model_input.max_length = 200
	model_input.tooltip_text = "Use the exact model ID recorded by the Agent Gateway. Baselines use their frozen adapter ID."
	model_input.text_changed.connect(func(_value: String) -> void: _refresh_validation())
	player_model_inputs.append(model_input)
	body.add_child(model_input)

	var lower_row := HBoxContainer.new()
	lower_row.add_theme_constant_override("separation", 8)
	body.add_child(lower_row)
	var reasoning := OptionButton.new()
	reasoning.name = "Player%dReasoning" % [slot]
	reasoning.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reasoning.tooltip_text = "Frozen reasoning setting recorded for this model slot."
	for option: String in REASONING_ORDER:
		reasoning.add_item(option.capitalize())
		reasoning.set_item_metadata(reasoning.item_count - 1, option)
	reasoning.item_selected.connect(func(_index: int) -> void: _refresh_validation())
	player_reasoning_inputs.append(reasoning)
	lower_row.add_child(reasoning)
	var key_input := _line_edit("Protected API key", "key stays private")
	key_input.name = "Player%dProtectedKey" % [slot]
	key_input.max_length = 4096
	key_input.secret = true
	key_input.secret_character = "•"
	key_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	key_input.tooltip_text = "Sent only to the local Agent Gateway. Never stored in configuration, logs, screenshots, observations, or replay."
	key_input.text_changed.connect(func(_value: String) -> void: _refresh_validation())
	protected_key_inputs.append(key_input)
	lower_row.add_child(key_input)
	var tier_input := _line_edit("Service tier (optional)", "optional non-secret provider tier")
	tier_input.name = "Player%dServiceTier" % [slot]
	tier_input.max_length = 96
	tier_input.tooltip_text = "Optional OpenAI service tier. Baselines do not accept a tier."
	tier_input.text_changed.connect(func(_value: String) -> void: _refresh_validation())
	player_service_tier_inputs.append(tier_input)
	body.add_child(tier_input)
	var connection := _label("●  Gateway check on start", 12, Color("a7bac6"))
	connection_labels.append(connection)
	body.add_child(connection)
	_apply_provider_constraints(slot)
	return card


func _build_mode_section() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _style_box(Color("0f1c28"), Color("2d495c"), 8, 1))
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 12)
	panel.add_child(margin)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 7)
	margin.add_child(body)
	body.add_child(_label("HOW SHOULD TIME WORK?", 12, Color("90dafa")))
	var group := ButtonGroup.new()
	for mode_id in MODE_ORDER:
		var info: Dictionary = MODES[mode_id]
		var button := Button.new()
		button.name = "Mode_%s" % mode_id
		button.toggle_mode = true
		button.button_group = group
		button.text = str(info["label"])
		button.tooltip_text = str(info["short"])
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.add_theme_font_size_override("font_size", 14)
		button.pressed.connect(func() -> void: select_mode(mode_id))
		mode_buttons[mode_id] = button
		body.add_child(button)
	var fairness := _label("", 12, Color("a9bac5"))
	fairness.name = "ModeExplanation"
	fairness.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(fairness)
	return panel


func _build_faction_section() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _style_box(Color("0f1c28"), Color("2d495c"), 8, 1))
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 12)
	panel.add_child(margin)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 7)
	margin.add_child(body)
	body.add_child(_label("ONE MIRRORED FACTION", 12, Color("90dafa")))
	var button_row := HBoxContainer.new()
	button_row.add_theme_constant_override("separation", 5)
	body.add_child(button_row)
	var group := ButtonGroup.new()
	for faction_id in FACTION_ORDER:
		var info: Dictionary = FACTIONS[faction_id]
		var button := Button.new()
		button.name = "Faction_%s" % faction_id
		button.toggle_mode = true
		button.button_group = group
		button.text = "%s\n%s" % [info["glyph"], info["name"]]
		button.tooltip_text = "%s — %s" % [info["strength"], info["mechanic"]]
		button.custom_minimum_size = Vector2(94, 54)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_font_size_override("font_size", 12)
		button.pressed.connect(func() -> void: select_faction(faction_id))
		faction_buttons[faction_id] = button
		button_row.add_child(button)
	faction_detail_label = _label("", 12, Color("a9bac5"))
	faction_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(faction_detail_label)
	return panel


func _build_match_details() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style_box(Color("0c1925"), Color("274255"), 7, 1))
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 9)
	margin.add_theme_constant_override("margin_bottom", 9)
	panel.add_child(margin)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	margin.add_child(body)
	body.add_child(_label("MATCH DETAILS", 12, Color("90dafa")))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	body.add_child(row)
	map_select = _option([{"label": "Crossroads Duel", "id": "crossroads-duel-v1"}], "Symmetric certified map pool.")
	row.add_child(_field("Map", map_select))
	seed_input = SpinBox.new()
	seed_input.min_value = 1
	seed_input.max_value = 2147483647
	seed_input.value = 847221
	seed_input.step = 1
	seed_input.tooltip_text = "Public reproducible match seed."
	row.add_child(_field("Seed", seed_input))
	cadence_label = _label("", 12, Color("e0e8ed"))
	cadence_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_field("Cadence", cadence_label))
	observation_select = _option([{"label": "Full belief view", "id": "full-belief-v1"}], "Both models receive the same observation profile.")
	row.add_child(_field("Observation", observation_select))
	memory_select = _option([
		{"label": "Fresh match", "id": "fresh-match-with-bounded-scratchpad"},
		{"label": "Adaptive series", "id": "adaptive-series"},
	], "Fresh match is the official provider-neutral track.")
	row.add_child(_field("Memory", memory_select))
	match_length_select = _option([{"label": "30 minutes", "id": 18000}], "Maximum simulated match length.")
	row.add_child(_field("Limit", match_length_select))
	spectator_select = _option([
		{"label": "Live 1×", "id": "live_1x"},
		{"label": "Headless", "id": "headless"},
	], "Continuous live matches cannot be sped up; replay may use any speed.")
	row.add_child(_field("Spectator", spectator_select))
	return panel


func _field(title: String, control: Control) -> VBoxContainer:
	var field := VBoxContainer.new()
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.add_theme_constant_override("separation", 3)
	field.add_child(_label(title.to_upper(), 10, Color("8099aa")))
	control.custom_minimum_size.y = 34
	field.add_child(control)
	return field


func _option(options: Array, tooltip: String) -> OptionButton:
	var select := OptionButton.new()
	select.tooltip_text = tooltip
	for raw_option: Variant in options:
		var option: Dictionary = raw_option
		select.add_item(str(option["label"]))
		select.set_item_metadata(select.item_count - 1, option["id"])
	return select


func select_mode(mode_id: String) -> bool:
	_ensure_built()
	if not MODES.has(mode_id) or (official_locked and mode_id != selected_mode):
		return false
	selected_mode = mode_id
	_refresh_all()
	mode_changed.emit(mode_id)
	return true


func select_faction(faction_id: String) -> bool:
	_ensure_built()
	if not FACTIONS.has(faction_id) or (official_locked and faction_id != selected_faction):
		return false
	selected_faction = faction_id
	_refresh_all()
	faction_changed.emit(faction_id)
	return true


func set_player_label(slot: int, value: String) -> void:
	_ensure_built()
	if slot >= 0 and slot < player_label_inputs.size():
		player_label_inputs[slot].text = value
		_refresh_validation()


func set_player_model(slot: int, value: String) -> void:
	_ensure_built()
	if slot >= 0 and slot < player_model_inputs.size():
		player_model_inputs[slot].text = value
		_refresh_validation()


func select_player_provider(slot: int, provider_id: String) -> bool:
	_ensure_built()
	if slot < 0 or slot >= player_provider_inputs.size() or not PROVIDERS.has(provider_id):
		return false
	var select := player_provider_inputs[slot]
	for index in select.item_count:
		if str(select.get_item_metadata(index)) == provider_id:
			select.select(index)
			_apply_provider_constraints(slot)
			_refresh_validation()
			return true
	return false


func player_provider_id(slot: int) -> String:
	_ensure_built()
	if slot < 0 or slot >= player_provider_inputs.size():
		return ""
	var select := player_provider_inputs[slot]
	return str(select.get_item_metadata(select.selected))


func set_player_reasoning(slot: int, reasoning_id: String) -> bool:
	_ensure_built()
	if slot < 0 or slot >= player_reasoning_inputs.size():
		return false
	var select := player_reasoning_inputs[slot]
	for index in select.item_count:
		if str(select.get_item_metadata(index)) == reasoning_id:
			select.select(index)
			return true
	return false


func set_protected_key(slot: int, secret_value: String) -> void:
	_ensure_built()
	if slot >= 0 and slot < protected_key_inputs.size():
		protected_key_inputs[slot].text = secret_value
		_refresh_validation()


func set_player_service_tier(slot: int, value: String) -> void:
	_ensure_built()
	if slot >= 0 and slot < player_service_tier_inputs.size():
		player_service_tier_inputs[slot].text = value
		_refresh_validation()


func set_connection_state(slot: int, state: String, detail: String = "") -> void:
	_ensure_built()
	if slot < 0 or slot >= connection_labels.size():
		return
	var normalized := state.to_lower()
	var color := Color("a7bac6")
	var label := "Gateway not checked"
	if normalized == "ready":
		color = Color("8ce6a3")
		label = "Gateway ready"
	elif normalized == "checking":
		color = Color("ffcf6b")
		label = "Checking gateway…"
	elif normalized == "error":
		color = Color("ff8c87")
		label = "Gateway needs attention"
	connection_labels[slot].text = "●  %s%s" % [label, " — " + detail if not detail.is_empty() else ""]
	connection_labels[slot].add_theme_color_override("font_color", color)


func set_official_locked(locked: bool) -> void:
	_ensure_built()
	official_locked = locked
	locked_banner.visible = locked
	for button: Button in mode_buttons.values():
		button.disabled = locked
	for button: Button in faction_buttons.values():
		button.disabled = locked
	map_select.disabled = locked
	seed_input.editable = not locked
	observation_select.disabled = locked
	memory_select.disabled = locked
	match_length_select.disabled = locked
	_refresh_validation()


func set_faction_integrity(content_hash: String, verified_equal: bool) -> void:
	_integrity_hash = content_hash
	_integrity_verified = verified_equal
	_refresh_validation()


func validate_setup() -> Dictionary:
	_ensure_built()
	var issues := PackedStringArray()
	if not MODES.has(selected_mode):
		issues.append("Choose a decision mode.")
	if not FACTIONS.has(selected_faction):
		issues.append("Choose a mirrored faction.")
	for slot in 2:
		if player_label_inputs[slot].text.strip_edges().is_empty():
			issues.append("Model %s needs a display label." % ["A" if slot == 0 else "B"])
		var provider_id := player_provider_id(slot)
		var model_id := player_model_inputs[slot].text.strip_edges()
		var reasoning := str(player_reasoning_inputs[slot].get_item_metadata(
			player_reasoning_inputs[slot].selected
		))
		var tier := player_service_tier_inputs[slot].text.strip_edges()
		if not PROVIDERS.has(provider_id):
			issues.append("Model %s needs an installed provider." % ["A" if slot == 0 else "B"])
		elif bool(PROVIDERS[provider_id]["baseline"]):
			if model_id != str(PROVIDERS[provider_id]["model"]):
				issues.append("Model %s baseline identity is not frozen." % ["A" if slot == 0 else "B"])
			if reasoning != "none":
				issues.append("Model %s baseline reasoning must be None." % ["A" if slot == 0 else "B"])
			if not protected_key_inputs[slot].text.is_empty() or not tier.is_empty():
				issues.append("Model %s baseline cannot receive a key or service tier." % ["A" if slot == 0 else "B"])
		else:
			if model_id.is_empty():
				issues.append("Model %s needs an exact OpenAI model ID." % ["A" if slot == 0 else "B"])
			if protected_key_inputs[slot].text.is_empty():
				issues.append("Model %s needs a protected OpenAI API key." % ["A" if slot == 0 else "B"])
			if not tier.is_empty() and not _is_safe_service_tier(tier):
				issues.append("Model %s service tier contains unsupported characters." % ["A" if slot == 0 else "B"])
	if int(seed_input.value) <= 0:
		issues.append("Seed must be a positive whole number.")
	if official_locked and not _integrity_verified:
		issues.append("Official matches need a host-verified mirrored faction content hash.")
	return {"valid": issues.is_empty(), "issues": issues}


func build_submission() -> Dictionary:
	_ensure_built()
	var mode: Dictionary = MODES[selected_mode]
	var players: Array[Dictionary] = []
	for slot in 2:
		var reasoning := player_reasoning_inputs[slot]
		players.append({
			"slot": slot,
			"label": player_label_inputs[slot].text.strip_edges(),
			"provider": player_provider_id(slot),
			"model": player_model_inputs[slot].text.strip_edges(),
			"reasoning": str(reasoning.get_item_metadata(reasoning.selected)),
		})
	return {
		"protocol_version": "worldeval-rts/1.0.0",
		"ruleset_id": "duel-rules-v1",
		"decision_mode": selected_mode,
		"control_profile": "hybrid-v1",
		"observation_profile": str(observation_select.get_item_metadata(observation_select.selected)),
		"faction_preset_id": selected_faction,
		"mirror_faction": true,
		"map_id": str(map_select.get_item_metadata(map_select.selected)),
		"seed": int(seed_input.value),
		"simulation_hz": 10,
		"decision_period_ticks": int(mode["decision_period_ticks"]),
		"response_deadline_ms": int(mode["response_deadline_ms"]),
		"maximum_match_ticks": int(match_length_select.get_item_metadata(match_length_select.selected)),
		"memory_policy": str(memory_select.get_item_metadata(memory_select.selected)),
		"spectator_profile": str(spectator_select.get_item_metadata(spectator_select.selected)),
		"official_fields_locked": official_locked,
		"players": players,
		"fairness": {
			"mirrored_faction": true,
			"equal_control_profile": true,
			"equal_observation_profile": true,
			"working_memory_bytes_per_player": 4096,
			"faction_content_hash": _integrity_hash,
			"faction_content_hash_equal": _integrity_verified,
		},
	}


## Exact DuelCreateMatchRequest JSON shape. UI-only labels, presentation
## preferences, integrity copy, and fairness prose are deliberately excluded.
func build_launch_request() -> Dictionary:
	_ensure_built()
	var mode: Dictionary = MODES[selected_mode]
	var players: Array[Dictionary] = []
	for slot in 2:
		var provider_id := player_provider_id(slot)
		var player := {
			"slot": slot,
			"provider": provider_id,
			"model": player_model_inputs[slot].text.strip_edges(),
			"reasoning": str(player_reasoning_inputs[slot].get_item_metadata(
				player_reasoning_inputs[slot].selected
			)),
		}
		if provider_id == "openai":
			player["credential"] = protected_key_inputs[slot].text
			var tier := player_service_tier_inputs[slot].text.strip_edges()
			if not tier.is_empty():
				player["service_tier"] = tier
		players.append(player)
	var spectator_id := str(spectator_select.get_item_metadata(spectator_select.selected))
	return {
		"decision_mode": selected_mode,
		"faction_preset_id": selected_faction,
		"mirror_faction": true,
		"map_id": str(map_select.get_item_metadata(map_select.selected)),
		"seed": int(seed_input.value),
		"decision_period_ticks": int(mode["decision_period_ticks"]),
		"response_deadline_ms": int(mode["response_deadline_ms"]),
		"authority_launch_mode": "caller_owned",
		"players": players,
		"maximum_match_ticks": int(match_length_select.get_item_metadata(match_length_select.selected)),
		"memory_policy": str(memory_select.get_item_metadata(memory_select.selected)),
		"spectator": {
			"enabled": spectator_id != "headless",
			"initial_perspective": "omniscient",
			"record_replay": true,
		},
	}


func submit_if_valid() -> bool:
	var validation := validate_setup()
	if _launch_busy or not bool(validation["valid"]):
		_refresh_validation()
		return false
	var public_config := build_submission()
	var request := build_launch_request()
	setup_submitted.emit(public_config.duplicate(true))
	launch_requested.emit(request)
	return true


func acknowledge_launch_dispatched() -> void:
	## This is the only path that clears credentials. It is called after the
	## HTTP layer returned OK from request_raw/its injected equivalent.
	_ensure_built()
	for key_input: LineEdit in protected_key_inputs:
		key_input.clear()
	_refresh_validation()


func set_launch_state(state: String, detail: String = "") -> void:
	_ensure_built()
	var normalized := state.to_lower()
	_launch_busy = normalized in ["dispatching", "creating", "claiming", "connecting"]
	launch_status_label.visible = normalized != "idle"
	var color := Color("a7bac6")
	var label := ""
	match normalized:
		"dispatching", "creating":
			color = Color("ffcf6b")
			label = "Creating the protected local match…"
		"claiming":
			color = Color("ffcf6b")
			label = "Claiming the one-time authority launch…"
		"connecting":
			color = Color("7cd8ff")
			label = "Authority configured; authenticating the live gateway…"
		"ready":
			color = Color("8ce6a3")
			label = "Live authority connected."
		"error":
			color = Color("ff8c87")
			label = "Launch failed"
		_:
			launch_status_label.visible = false
	if not detail.is_empty():
		label += " — " + detail
	launch_status_label.text = label
	launch_status_label.add_theme_color_override("font_color", color)
	_refresh_validation()


func protected_keys_are_clear() -> bool:
	_ensure_built()
	for key_input: LineEdit in protected_key_inputs:
		if not key_input.text.is_empty():
			return false
	return true


func _on_provider_selected(slot: int) -> void:
	_apply_provider_constraints(slot)
	_refresh_validation()


func _apply_provider_constraints(slot: int) -> void:
	if slot < 0 or slot >= player_provider_inputs.size():
		return
	var provider_id := player_provider_id(slot)
	if not PROVIDERS.has(provider_id):
		return
	var baseline := bool(PROVIDERS[provider_id]["baseline"])
	player_model_inputs[slot].editable = not baseline
	player_reasoning_inputs[slot].disabled = baseline
	protected_key_inputs[slot].editable = not baseline
	player_service_tier_inputs[slot].editable = not baseline
	if baseline:
		player_model_inputs[slot].text = str(PROVIDERS[provider_id]["model"])
		set_player_reasoning(slot, "none")
		protected_key_inputs[slot].clear()
		player_service_tier_inputs[slot].clear()
	elif str(player_model_inputs[slot].text) in [
		"baseline-noop-v1", "baseline-seeded-random-v1", "baseline-rush-v1"
	]:
		player_model_inputs[slot].clear()


func _is_safe_service_tier(value: String) -> bool:
	if value.is_empty() or value.length() > 96:
		return false
	var first := value.unicode_at(0)
	if not ((first >= 48 and first <= 57) or (first >= 65 and first <= 90) \
		or (first >= 97 and first <= 122)):
		return false
	for index in value.length():
		var code := value.unicode_at(index)
		var allowed := (code >= 48 and code <= 57) \
			or (code >= 65 and code <= 90) \
			or (code >= 97 and code <= 122) \
			or code in [45, 46, 58, 95]
		if not allowed:
			return false
	return true


func _refresh_all() -> void:
	if not _built:
		return
	for mode_id in mode_buttons:
		mode_buttons[mode_id].button_pressed = mode_id == selected_mode
	for faction_id in faction_buttons:
		faction_buttons[faction_id].button_pressed = faction_id == selected_faction
	var mode: Dictionary = MODES[selected_mode]
	var mode_explanation := find_child("ModeExplanation", true, false) as Label
	if mode_explanation != null:
		mode_explanation.text = str(mode["short"])
	cadence_label.text = str(mode["cadence"])
	var faction: Dictionary = FACTIONS[selected_faction]
	faction_detail_label.text = "%s — %s" % [faction["strength"], faction["mechanic"]]
	_refresh_validation()


func _refresh_validation() -> void:
	if not _built or validation_label == null:
		return
	var validation := validate_setup()
	var integrity := "host check pending"
	if _integrity_verified:
		integrity = "content hash verified%s" % ["  %s…" % _integrity_hash.left(10) if not _integrity_hash.is_empty() else ""]
	fairness_summary_label.text = "✓ Same %s faction  •  ✓ Equal action, context, and memory budgets  •  %s" % [
		str(FACTIONS[selected_faction]["name"]), integrity]
	if bool(validation["valid"]) and not _launch_busy:
		validation_label.text = "READY  ✓"
		validation_label.add_theme_color_override("font_color", Color("8ce6a3"))
		start_button.disabled = false
	else:
		if _launch_busy:
			validation_label.text = "LAUNCHING…"
			validation_label.tooltip_text = "A protected match launch is already in progress."
			validation_label.add_theme_color_override("font_color", Color("ffcf6b"))
		else:
			validation_label.text = "%d ITEM%s NEEDED" % [validation["issues"].size(), "" if validation["issues"].size() == 1 else "S"]
			validation_label.tooltip_text = "\n".join(validation["issues"])
			validation_label.add_theme_color_override("font_color", Color("ff9b92"))
		start_button.disabled = true
	validation_changed.emit(bool(validation["valid"]), validation["issues"])


func _line_edit(placeholder: String, accessible_description: String) -> LineEdit:
	var input := LineEdit.new()
	input.placeholder_text = placeholder
	input.tooltip_text = accessible_description
	input.custom_minimum_size.y = 34
	input.add_theme_font_size_override("font_size", 13)
	return input


func _label(text_value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", maxi(12, font_size))
	label.add_theme_color_override("font_color", color)
	return label


func _style_box(fill: Color, border: Color, radius: int, width: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(width)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	return style
