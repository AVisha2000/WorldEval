extends SceneTree

const ManagedCli := preload(
	"res://scripts/embodiment/transport/embodiment_managed_authority_cli.gd"
)


func _init() -> void:
	var secret := PackedByteArray()
	for value: int in 32:
		secret.append(value)
	var alpha := ManagedCli._derive_duel_preview_ticket(secret, "A".repeat(43), "participant_0")
	var bravo := ManagedCli._derive_duel_preview_ticket(secret, "A".repeat(43), "participant_1")
	if alpha != "vwRjO9yau5Bv8wOwgsBf1Mv_XX0dJaCYnfZ7HhtZJ2s" \
		or bravo != "gictFg52fKzb6rlc8AdqTQ-aW8wMOfnfsygu_LbYGs4" \
		or alpha == bravo:
		push_error("duel_preview_ticket_vector_mismatch")
		quit(1)
		return
	print("DUEL_PREVIEW_TICKET_OK")
	quit(0)
