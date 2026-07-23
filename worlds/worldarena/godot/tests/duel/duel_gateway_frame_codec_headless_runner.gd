extends SceneTree

const GatewayCodec := preload("res://scripts/duel/protocol/duel_gateway_frame_codec.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const MATCH_ID := "m_gateway-codec"
const EXPECTED_GOLDEN := "bdf0cd4608049fb498f949e7a7229b7fb838065f8d027d9b4a60b0f23fb9cdd5"
const ZERO_HASH := "0000000000000000000000000000000000000000000000000000000000000000"
const CONFIG_HASH := "abababababababababababababababababababababababababababababababab"
const HELLO_VECTOR := "{\"auth_tag\":\"a09ba32014d4705f9d06f57deca9e5894c29d0698833f2977911c7761e0cfa90\",\"body\":{\"connection_id\":\"conn-vector\",\"engine_version\":\"4.5.stable.official.876b29033\",\"headless\":true},\"boundary_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"boundary_hash_kind\":\"session\",\"match_id\":\"m_gateway-codec\",\"message_type\":\"hello\",\"protocol_version\":\"worldeval-rts/1.0.0\",\"sender\":\"godot\",\"sequence\":0}"
const AUTH_VECTOR := "{\"auth_tag\":\"cccdbde8cc417291095c5e7564a4b4ced967ae45219493a23db65672553faecc\",\"body\":{\"accepted\":true,\"connection_id\":\"conn-vector\"},\"boundary_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"boundary_hash_kind\":\"session\",\"match_id\":\"m_gateway-codec\",\"message_type\":\"auth\",\"protocol_version\":\"worldeval-rts/1.0.0\",\"sender\":\"gateway\",\"sequence\":0}"
const CONFIG_VECTOR := "{\"auth_tag\":\"f2f6341b3de398f382119d306ca53a58888d509230e50b8e42cf79ffcf0f085f\",\"body\":{\"accepted\":true,\"config_hash\":\"abababababababababababababababababababababababababababababababab\"},\"boundary_hash\":\"abababababababababababababababababababababababababababababababab\",\"boundary_hash_kind\":\"config\",\"match_id\":\"m_gateway-codec\",\"message_type\":\"config_accepted\",\"protocol_version\":\"worldeval-rts/1.0.0\",\"sender\":\"godot\",\"sequence\":1}"

var _failures := PackedStringArray()


func _init() -> void:
	var summary := _test_cross_runtime_vectors()
	_test_authentication_and_fail_closed()
	_test_noncanonical_and_sequence_rejection()
	_test_boundary_and_visibility_policy()
	var golden := Codec.sha256_canonical(summary)
	_check(golden == EXPECTED_GOLDEN, "gateway codec golden changed: " + golden)
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_GATEWAY_CODEC_FAILURE: " + failure)
		print("DUEL_GATEWAY_CODEC_FAILED count=%d hash=%s" % [_failures.size(), golden])
		quit(1)
		return
	print("DUEL_GATEWAY_CODEC_OK hash=%s summary=%s" % [golden, JSON.stringify(summary)])
	quit(0)


func _test_cross_runtime_vectors() -> Dictionary:
	var token := _vector_token()
	var godot := GatewayCodec.new()
	var gateway := GatewayCodec.new()
	_check(godot.configure(MATCH_ID, token, "godot").is_empty(), "Godot codec configure failed")
	_check(gateway.configure(MATCH_ID, token, "gateway").is_empty(), "gateway codec configure failed")
	var hello := godot.encode("hello", ZERO_HASH, {
		"connection_id": "conn-vector",
		"engine_version": "4.5.stable.official.876b29033",
		"headless": true,
	})
	_check(bool(hello.get("ok", false)), "Godot hello encode failed")
	_check(_payload_text(hello) == HELLO_VECTOR, "Godot hello bytes disagree with Python vector")
	var hello_in := gateway.decode(HELLO_VECTOR.to_utf8_buffer())
	_check(bool(hello_in.get("ok", false)), "gateway did not accept Python hello vector")
	var auth := gateway.encode("auth", ZERO_HASH, {
		"accepted": true,
		"connection_id": "conn-vector",
	})
	_check(bool(auth.get("ok", false)), "gateway auth encode failed")
	_check(_payload_text(auth) == AUTH_VECTOR, "gateway auth bytes disagree with Python vector")
	_check(bool(godot.decode(AUTH_VECTOR.to_utf8_buffer()).get("ok", false)),
		"Godot did not accept Python auth vector")
	var config := godot.encode("config_accepted", CONFIG_HASH, {
		"accepted": true,
		"config_hash": CONFIG_HASH,
	})
	_check(bool(config.get("ok", false)), "Godot config acknowledgement encode failed")
	_check(_payload_text(config) == CONFIG_VECTOR,
		"Godot config acknowledgement disagrees with Python vector")
	_check(bool(gateway.decode(CONFIG_VECTOR.to_utf8_buffer()).get("ok", false)),
		"gateway did not accept Python config acknowledgement vector")
	var disposition_core := {
		"code": "dispatch_grid_drift",
		"disposition": "void_infrastructure",
		"match_id": MATCH_ID,
		"reason": "gateway_infrastructure_failure",
	}
	var disposition_body := disposition_core.duplicate(true)
	disposition_body["request_id"] = Codec.sha256_canonical(disposition_core)
	var disposition := gateway.encode("gateway_disposition", CONFIG_HASH, disposition_body)
	_check(bool(disposition.get("ok", false)), "gateway disposition encode failed")
	_check(bool(godot.decode(disposition["payload"]).get("ok", false)),
		"Godot did not accept authenticated gateway disposition")
	var disposition_ack_body := disposition_body.duplicate(true)
	disposition_ack_body["accepted"] = true
	var disposition_ack := godot.encode(
		"gateway_disposition_accepted", CONFIG_HASH, disposition_ack_body
	)
	_check(bool(disposition_ack.get("ok", false)), "Godot disposition acknowledgement encode failed")
	_check(bool(gateway.decode(disposition_ack["payload"]).get("ok", false)),
		"gateway did not accept authenticated disposition acknowledgement")
	var start_core := {"match_id": MATCH_ID, "observation_seq": 0, "tick": 0}
	var start_body := start_core.duplicate(true)
	start_body["start_id"] = Codec.sha256_canonical(start_core)
	var start := gateway.encode("continuous_start", CONFIG_HASH, start_body)
	_check(bool(start.get("ok", false)), "continuous start encode failed")
	_check(bool(godot.decode(start["payload"]).get("ok", false)),
		"Godot did not accept authenticated continuous start")
	var start_ack_body := start_body.duplicate(true)
	start_ack_body["accepted"] = true
	var start_ack := godot.encode("continuous_start_accepted", CONFIG_HASH, start_ack_body)
	_check(bool(start_ack.get("ok", false)), "continuous start acknowledgement encode failed")
	_check(bool(gateway.decode(start_ack["payload"]).get("ok", false)),
		"gateway did not accept authenticated continuous start acknowledgement")
	return {
		"auth_sha256": Codec.sha256_text(AUTH_VECTOR),
		"config_sha256": Codec.sha256_text(CONFIG_VECTOR),
		"disposition_ack_sha256": Codec.sha256_bytes(disposition_ack["payload"]),
		"disposition_sha256": Codec.sha256_bytes(disposition["payload"]),
		"godot_inbound_sequence": godot.inbound_sequence(),
		"godot_outbound_sequence": godot.outbound_sequence(),
		"hello_sha256": Codec.sha256_text(HELLO_VECTOR),
		"start_ack_sha256": Codec.sha256_bytes(start_ack["payload"]),
		"start_sha256": Codec.sha256_bytes(start["payload"]),
	}


func _test_authentication_and_fail_closed() -> void:
	var gateway: Variant = _configured("gateway")
	var tampered := HELLO_VECTOR.replace(
		"a09ba32014d4705f9d06f57deca9e5894c29d0698833f2977911c7761e0cfa90",
		"b09ba32014d4705f9d06f57deca9e5894c29d0698833f2977911c7761e0cfa90"
	)
	var rejected: Dictionary = gateway.decode(tampered.to_utf8_buffer())
	_check(not bool(rejected.get("ok", false))
		and str(rejected.get("code", "")) == "authentication_failed",
		"tampered authentication tag was not rejected")
	var after_failure: Dictionary = gateway.decode(HELLO_VECTOR.to_utf8_buffer())
	_check(str(after_failure.get("code", "")) == "codec_failed_closed",
		"codec accepted traffic after authentication failure")


func _test_noncanonical_and_sequence_rejection() -> void:
	var noncanonical: Variant = _configured("gateway")
	var rejected: Dictionary = noncanonical.decode((HELLO_VECTOR + "\n").to_utf8_buffer())
	_check(str(rejected.get("code", "")) == "inbound_frame_invalid",
		"noncanonical whitespace was not rejected")
	var replay: Variant = _configured("gateway")
	_check(bool(replay.decode(HELLO_VECTOR.to_utf8_buffer()).get("ok", false)),
		"valid hello failed before replay check")
	var replayed: Dictionary = replay.decode(HELLO_VECTOR.to_utf8_buffer())
	_check(str(replayed.get("code", "")) == "sequence_violation",
		"replayed sequence was not rejected")
	var invalid_utf8: Variant = _configured("gateway")
	_check(str(invalid_utf8.decode(PackedByteArray([0xff])).get("code", ""))
		== "inbound_frame_invalid", "invalid UTF-8 was not rejected")


func _test_boundary_and_visibility_policy() -> void:
	var wrong_boundary: Variant = _configured("godot")
	var rejected: Dictionary = wrong_boundary.encode("hello", CONFIG_HASH, {})
	_check(str(rejected.get("code", "")) == "outbound_frame_invalid",
		"hello accepted a non-session boundary")
	var leak: Variant = _configured("godot")
	var leaked: Dictionary = leak.encode("observation", CONFIG_HASH, {
		"nested": {"checkpoint_hash": CONFIG_HASH},
	})
	_check(str(leaked.get("code", "")) == "outbound_frame_invalid",
		"provider-visible frame accepted a hidden world hash")
	var wrong_sender: Variant = _configured("gateway")
	var wrong: Dictionary = wrong_sender.decode(AUTH_VECTOR.to_utf8_buffer())
	_check(str(wrong.get("code", "")) == "wrong_sender",
		"codec accepted a frame from its own role")


func _configured(role: String) -> Variant:
	var codec := GatewayCodec.new()
	var errors := codec.configure(MATCH_ID, _vector_token(), role)
	_check(errors.is_empty(), "%s codec setup failed" % role)
	return codec


func _vector_token() -> PackedByteArray:
	var token := PackedByteArray()
	for value: int in 32:
		token.append(value)
	return token


func _payload_text(result: Dictionary) -> String:
	return (result.get("payload", PackedByteArray()) as PackedByteArray).get_string_from_utf8()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
