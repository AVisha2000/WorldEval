class_name EmbodimentVersionedReplayDispatcher
extends RefCounted

const CanonicalCodec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const LegacyVerifier := preload("res://scripts/embodiment/replay/embodiment_replay_verifier.gd")
const V2Verifier := preload("res://scripts/embodiment/v2/replay/embodiment_replay_verifier_v2.gd")
const V3Verifier := preload("res://scripts/embodiment/v3/replay/embodiment_replay_verifier_v3.gd")
const LegacyIdentity := preload("res://scripts/embodiment/protocol/embodiment_protocol_package_identity.gd")
const V2Identity := preload("res://scripts/embodiment/v2/protocol/embodiment_protocol_package_identity_v2.gd")
const V3Identity := preload("res://scripts/embodiment/v3/protocol/embodiment_protocol_package_identity_v3.gd")


func verify(payload: PackedByteArray) -> Dictionary:
	var parsed := CanonicalCodec.parse_canonical(payload, V2Verifier.MAX_REPLAY_BYTES)
	if not bool(parsed.get("ok", false)) or not parsed.get("value") is Dictionary:
		return {"ok": false, "code": "replay_json_invalid"}
	var replay: Dictionary = parsed.value
	var version: Variant = replay.get("protocol_version")
	var package_hash: Variant = replay.get("protocol_package_sha256")
	if version == "llm-controller/0.1.0" and package_hash == LegacyIdentity.SHA256:
		var legacy_result: Dictionary = LegacyVerifier.new().verify(payload)
		if bool(legacy_result.get("ok", false)):
			legacy_result["protocol_version"] = "llm-controller/0.1.0"
			legacy_result["protocol_package_sha256"] = LegacyIdentity.SHA256
		return legacy_result
	if version == V2Identity.PROTOCOL_VERSION and package_hash == V2Identity.SHA256:
		return V2Verifier.new().verify(payload)
	if version == V3Identity.PROTOCOL_VERSION and package_hash == V3Identity.SHA256:
		return V3Verifier.new().verify(payload)
	return {"ok": false, "code": "replay_protocol_package_unsupported"}
