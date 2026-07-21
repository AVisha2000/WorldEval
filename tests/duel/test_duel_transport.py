from __future__ import annotations

import json

import pytest
from genesis_arena.duel.canonical import canonical_json_bytes
from genesis_arena.duel.transport import (
    MAX_TRANSPORT_FRAME_BYTES,
    DuelTransportAuthenticationError,
    DuelTransportPolicyError,
    DuelTransportSequenceError,
    DuelTransportSession,
    LocalConnectionState,
    LocalSessionAuthenticator,
)

MATCH_ID = "m_transport_test"
OBSERVATION_HASH = "a" * 64
CHECKPOINT_HASH = "b" * 64


def test_canonical_frames_roundtrip_with_independent_monotonic_directions() -> None:
    sender = DuelTransportSession(MATCH_ID)
    receiver = DuelTransportSession(MATCH_ID)
    first = sender.encode(
        "observation",
        boundary_hash=OBSERVATION_HASH,
        body={"observation_hash": OBSERVATION_HASH, "tick": 50},
    )
    decoded = receiver.decode(
        first,
        expected_message_type="observation",
        expected_boundary_hash=OBSERVATION_HASH,
    )
    assert decoded.sequence == 0
    assert decoded.boundary_hash_kind == "observation"

    second = sender.encode(
        "thinking_status",
        boundary_hash=OBSERVATION_HASH,
        body={"player_slot": 0, "status": "thinking"},
    )
    assert receiver.decode(second).sequence == 1
    assert sender.outbound_sequence == receiver.inbound_sequence == 2


def test_duplicate_gap_and_any_followup_after_error_fail_closed() -> None:
    sender = DuelTransportSession(MATCH_ID)
    receiver = DuelTransportSession(MATCH_ID)
    payload = sender.encode(
        "duel_ready", boundary_hash="c" * 64, body={"ready": True}
    )
    receiver.decode(payload)
    with pytest.raises(DuelTransportSequenceError, match="expected inbound sequence 1, got 0"):
        receiver.decode(payload)
    assert receiver.failed is True
    with pytest.raises(DuelTransportSequenceError, match="already failed closed"):
        receiver.decode(sender.encode("duel_ready", boundary_hash="c" * 64, body={}))

    gap_receiver = DuelTransportSession(MATCH_ID)
    value = json.loads(payload)
    value["sequence"] = 4
    with pytest.raises(DuelTransportSequenceError, match="got 4"):
        gap_receiver.decode(canonical_json_bytes(value))


def test_wrong_match_type_or_boundary_hash_poison_the_session() -> None:
    wrong_sender = DuelTransportSession("m_other")
    receiver = DuelTransportSession(MATCH_ID)
    payload = wrong_sender.encode(
        "checkpoint", boundary_hash=CHECKPOINT_HASH, body={"tick": 1}
    )
    with pytest.raises(DuelTransportPolicyError, match="wrong match"):
        receiver.decode(payload)
    assert receiver.failed

    receiver = DuelTransportSession(MATCH_ID)
    sender = DuelTransportSession(MATCH_ID)
    payload = sender.encode(
        "checkpoint", boundary_hash=CHECKPOINT_HASH, body={"tick": 1}
    )
    with pytest.raises(DuelTransportPolicyError, match="wrong message type"):
        receiver.decode(payload, expected_message_type="tick_events")

    receiver = DuelTransportSession(MATCH_ID)
    with pytest.raises(DuelTransportPolicyError, match="wrong boundary hash"):
        receiver.decode(payload, expected_boundary_hash="d" * 64)


def test_noncanonical_trailing_duplicate_and_oversized_json_are_rejected() -> None:
    sender = DuelTransportSession(MATCH_ID)
    payload = sender.encode(
        "duel_ready", boundary_hash="c" * 64, body={"ready": True}
    )
    receiver = DuelTransportSession(MATCH_ID)
    with pytest.raises(DuelTransportPolicyError, match="invalid"):
        receiver.decode(payload + b"\n")

    duplicate = payload.replace(b'"sequence":0', b'"sequence":0,"sequence":0')
    receiver = DuelTransportSession(MATCH_ID)
    with pytest.raises(DuelTransportPolicyError, match="invalid"):
        receiver.decode(duplicate)

    receiver = DuelTransportSession(MATCH_ID)
    with pytest.raises(DuelTransportPolicyError, match="byte limit"):
        receiver.decode(b"{" + b" " * MAX_TRANSPORT_FRAME_BYTES + b"}")


def test_provider_frames_cannot_carry_omniscient_hashes_at_any_depth() -> None:
    session = DuelTransportSession(MATCH_ID)
    with pytest.raises(DuelTransportPolicyError, match="outbound"):
        session.encode(
            "observation",
            boundary_hash=OBSERVATION_HASH,
            body={"nested": {"state_hash": CHECKPOINT_HASH}},
        )
    assert session.failed

    trusted = DuelTransportSession(MATCH_ID)
    payload = trusted.encode(
        "checkpoint",
        boundary_hash=CHECKPOINT_HASH,
        body={"state_hash": CHECKPOINT_HASH, "tick": 300},
    )
    assert DuelTransportSession(MATCH_ID).decode(payload).body["tick"] == 300


def test_message_type_selects_one_fixed_boundary_hash_kind() -> None:
    session = DuelTransportSession(MATCH_ID)
    assert json.loads(
        session.encode("configure_duel", boundary_hash="1" * 64, body={})
    )["boundary_hash_kind"] == "config"
    assert json.loads(
        session.encode("match_init", boundary_hash="2" * 64, body={})
    )["boundary_hash_kind"] == "protocol"
    assert json.loads(
        session.encode("observation_pair", boundary_hash="3" * 64, body={})
    )["boundary_hash_kind"] == "checkpoint"
    assert json.loads(
        session.encode("match_result", boundary_hash="4" * 64, body={})
    )["boundary_hash_kind"] == "result"


def test_ephemeral_local_authentication_attaches_once_and_never_reconnects() -> None:
    token = bytes(range(32))
    auth = LocalSessionAuthenticator(token)
    assert auth.state is LocalConnectionState.WAITING
    assert token.hex() not in repr(auth)
    auth.attach(token=token, connection_id="godot-pid-42")
    assert auth.state is LocalConnectionState.ATTACHED
    assert auth.connection_id == "godot-pid-42"
    with pytest.raises(DuelTransportAuthenticationError, match="reused or reattached"):
        auth.attach(token=token, connection_id="second-socket")
    auth.close(connection_id="godot-pid-42")
    assert auth.state is LocalConnectionState.CLOSED
    with pytest.raises(DuelTransportAuthenticationError, match="reused or reattached"):
        auth.attach(token=token, connection_id="reconnect")


def test_bad_authentication_closes_token_and_close_identity_is_exact() -> None:
    token = b"x" * 32
    auth = LocalSessionAuthenticator(token)
    with pytest.raises(DuelTransportAuthenticationError, match="authentication failed"):
        auth.attach(token=b"y" * 32, connection_id="bad")
    assert auth.state is LocalConnectionState.CLOSED

    auth = LocalSessionAuthenticator(token)
    auth.attach(token=token, connection_id="expected")
    with pytest.raises(DuelTransportAuthenticationError, match="ambiguous"):
        auth.close(connection_id="other")
    assert auth.state is LocalConnectionState.ATTACHED


def test_closed_transport_never_encodes_or_decodes_again() -> None:
    session = DuelTransportSession(MATCH_ID)
    session.close()
    with pytest.raises(DuelTransportSequenceError, match="closed"):
        session.encode("duel_ready", boundary_hash="c" * 64, body={})
    with pytest.raises(DuelTransportSequenceError, match="closed"):
        session.decode(b"{}")
