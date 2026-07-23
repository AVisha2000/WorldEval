extends SceneTree

const PlayerScript := preload("res://scripts/arena/presentation/arena_showcase_player.gd")
const PresentationScript := preload("res://tests/arena/arena_showcase_test_presentation.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var player: ArenaShowcasePlayer = PlayerScript.new()
	var presentation: Node = PresentationScript.new()
	root.add_child(player)
	root.add_child(presentation)
	var status := player.load_showcase("res://tests/arena/fixtures/unverified_showcase.json")
	assert(bool(status.loaded))
	assert(not bool(status.verified))
	assert(str(status.label) == "UNVERIFIED LOCAL DEMO")
	assert(str(status.detail).contains("refused"))
	assert(player.start(presentation))
	player.advance_to(12.0)
	assert(player.dispatched_cue_count == 2)
	player.play_to_end()
	assert(player.is_complete)
	assert(player.dispatched_cue_count == 4)
	assert(presentation.phases == ["thinking"])
	assert(presentation.event_batches == 1)
	assert(presentation.perspectives == ["spectator"])
	assert(presentation.results.size() == 1)
	assert(not bool(presentation.results[0].verified))
	assert(str(presentation.results[0].verification_label) == "UNVERIFIED LOCAL DEMO")
	assert(not bool(presentation.showcase_status.verified))

	var verified_player: ArenaShowcasePlayer = PlayerScript.new()
	var verified_presentation: Node = PresentationScript.new()
	root.add_child(verified_player)
	root.add_child(verified_presentation)
	var verified_status := verified_player.load_showcase("res://tests/arena/fixtures/verified_showcase.json")
	assert(bool(verified_status.loaded))
	assert(bool(verified_status.verified))
	assert(str(verified_status.label) == "VERIFIED MATCH REPLAY")
	assert(verified_player.start(verified_presentation))
	verified_player.play_to_end()
	assert(verified_presentation.results.size() == 1)
	assert(bool(verified_presentation.results[0].verified))
	assert(str(verified_presentation.results[0].verification_hash) == str(verified_status.replay_hash))
	print("ARENA_SHOWCASE_HEADLESS_OK unverified_cues=%d verified_cues=%d duration=90" % [player.dispatched_cue_count, verified_player.dispatched_cue_count])
	quit(0)
