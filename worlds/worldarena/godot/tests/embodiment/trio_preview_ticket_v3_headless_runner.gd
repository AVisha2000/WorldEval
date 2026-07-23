extends SceneTree

const ManagedCli := preload(
	"res://scripts/embodiment/v3/transport/embodiment_managed_authority_cli_v3.gd"
)
const PreviewPublisher := preload(
	"res://scripts/embodiment/presentation/preview/embodiment_preview_publisher.gd"
)


func _init() -> void:
	var secret := PackedByteArray()
	for value: int in 32:
		secret.append(value)
	var values := []
	for participant_id: String in ["participant_0", "participant_1", "participant_2"]:
		values.append(ManagedCli._derive_trio_preview_ticket(
			secret, "A".repeat(43), participant_id
		))
	if values != [
		"TmhwIY2zI-nRGxyAAcxwPgVJvTdf1ovJsoA5Sejplxc",
		"XQNdKG9cIDj9mHUJi0dacZoZ4J7g2Q8VbrLCOOePfag",
		"RzD5lISjmqwDa83RTIvmS6Je7c5yIam9STM-7yQ7Huk",
	] or values[0] == values[1] or values[1] == values[2] or values[0] == values[2] \
		or not ManagedCli._derive_trio_preview_ticket(
			secret, "A".repeat(43), "participant_3"
		).is_empty():
		push_error("trio_preview_ticket_vector_mismatch")
		quit(1)
		return
	var endpoint := PreviewPublisher._endpoint_for(
		"ws://127.0.0.1:8123/ws/embodiment/%s" % "A".repeat(43), values[2]
	)
	if endpoint != "ws://127.0.0.1:8123/internal/embodiment/preview/%s/stream" % values[2]:
		push_error("trio_preview_derived_endpoint_mismatch")
		quit(1)
		return
	print("TRIO_PREVIEW_TICKET_V3_OK")
	quit(0)
