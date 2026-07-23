extends SceneTree

const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")

var _failures := PackedStringArray()


func _init() -> void:
	_check(DisplayServer.get_name() == "headless", "display driver is not headless")
	_check(AudioServer.get_driver_name() == "Dummy", "audio driver is not Dummy")
	_check(
		str(ProjectSettings.get_setting("application/run/main_scene", ""))
		== "res://scripts/duel/match/duel_headless_cli.tscn",
		"staged default scene is not the nonvisual Duel headless CLI"
	)
	_check(
		ProjectSettings.get_setting(
			"editor/export/convert_text_resources_to_binary", true
		) == false,
		"staged nonvisual scene would be converted to an unaudited binary resource"
	)
	_check(
		ProjectSettings.get_setting("debug/file_logging/enable_file_logging", true) == false
		and ProjectSettings.get_setting(
			"debug/file_logging/enable_file_logging.pc", true
		) == false,
		"staged authority could persist protected launch data to a Godot log"
	)
	var preset := ConfigFile.new()
	var preset_error := preset.load("res://export_presets.cfg")
	_check(preset_error == OK, "export preset could not be loaded")
	var selected_variant: Variant = preset.get_value(
		"preset.0", "export_files", PackedStringArray()
	)
	_check(
		typeof(selected_variant) == TYPE_PACKED_STRING_ARRAY,
		"export_files is not a PackedStringArray"
	)
	var selected := PackedStringArray()
	if typeof(selected_variant) == TYPE_PACKED_STRING_ARRAY:
		selected = selected_variant
	var authority_script_count := 0
	for path: String in selected:
		_check(not "/presentation/" in path, "presentation script selected: " + path)
		_check(not "/app/" in path, "visual/launch application script selected: " + path)
		_check(ResourceLoader.exists(path), "selected authority script is absent: " + path)
		if ResourceLoader.exists(path):
			var resource: Resource = load(path)
			if path.ends_with(".tscn"):
				_check(
					resource is PackedScene,
					"selected nonvisual entrypoint is not a packed scene: " + path
				)
			else:
				_check(resource is Script, "selected authority resource is not a script: " + path)
			if not path.ends_with(".tscn") and resource is Script:
				authority_script_count += 1
				var script := resource as Script
				_check(script.can_instantiate(), "selected authority script failed to parse: " + path)

	var catalogs := CatalogLoader.load_official_catalogs()
	_check(
		bool(catalogs.get("ok", false)),
		"staged canonical protocol package failed validation: %s"
		% str(catalogs.get("errors", PackedStringArray()))
	)
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_DEDICATED_STAGE_FAILURE: " + failure)
		print("DUEL_DEDICATED_STAGE_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print(
		"DUEL_DEDICATED_STAGE_OK authority_scripts=%d catalog_hash=%s"
		% [authority_script_count, str(catalogs.get("aggregate_hash", ""))]
	)
	quit(0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
