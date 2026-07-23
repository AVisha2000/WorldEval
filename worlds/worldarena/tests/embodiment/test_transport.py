from __future__ import annotations

import asyncio

import pytest
from genesis_arena.embodiment.transport import (
    ZERO_HASH,
    EmbodimentTransportError,
    ManagedWebSocketEndpoint,
    TransportSession,
)


def test_role_keys_round_trip_and_sequence_fail_closed() -> None:
    secret = bytearray(range(32))
    python = TransportSession(
        episode_id="ep_transport", local_sender="python", session_secret=secret
    )
    godot = TransportSession(episode_id="ep_transport", local_sender="godot", session_secret=secret)
    payload = python.encode("auth", boundary_hash=ZERO_HASH, body={"attachment_ticket": "A" * 43})
    frame = godot.decode(payload, expected_message_type="auth", expected_boundary_hash=ZERO_HASH)
    assert frame.sender == "python"
    with pytest.raises(EmbodimentTransportError, match="sequence_mismatch"):
        godot.decode(payload)
    with pytest.raises(EmbodimentTransportError, match="not_open"):
        godot.encode("hello", boundary_hash=ZERO_HASH, body={"connection_id": "connection_0"})


def test_v2_transport_round_trips_and_cross_version_frames_fail_closed() -> None:
    secret = bytearray(range(32))
    python = TransportSession(
        episode_id="ep_transport_v2",
        local_sender="python",
        session_secret=secret,
        protocol_version="llm-controller/0.2.0",
    )
    godot = TransportSession(
        episode_id="ep_transport_v2",
        local_sender="godot",
        session_secret=secret,
        protocol_version="llm-controller/0.2.0",
    )
    payload = godot.encode("hello", boundary_hash=ZERO_HASH, body={"connection_id": "v2"})
    frame = python.decode(payload, expected_message_type="hello")
    assert frame.protocol_version == "llm-controller/0.2.0"

    v1 = TransportSession(
        episode_id="ep_transport_v2", local_sender="python", session_secret=secret
    )
    second_godot = TransportSession(
        episode_id="ep_transport_v2",
        local_sender="godot",
        session_secret=secret,
        protocol_version="llm-controller/0.2.0",
    )
    with pytest.raises(EmbodimentTransportError, match="identity_mismatch"):
        v1.decode(second_godot.encode("hello", boundary_hash=ZERO_HASH, body={}))
    with pytest.raises(ValueError, match="unsupported"):
        TransportSession(
            episode_id="ep_transport_unknown",
            local_sender="python",
            session_secret=secret,
            protocol_version="llm-controller/9.9.9",
        )


class FakeWebSocket:
    def __init__(self, incoming: str) -> None:
        self.incoming = asyncio.Queue()
        self.incoming.put_nowait(incoming)
        self.sent: list[str] = []
        self.accepted = False
        self.closed = False

    async def accept(self) -> None:
        self.accepted = True

    async def receive_text(self) -> str:
        return await self.incoming.get()

    async def send_text(self, data: str) -> None:
        self.sent.append(data)

    async def close(self, code: int = 1000) -> None:
        del code
        self.closed = True


@pytest.mark.asyncio
async def test_endpoint_stays_alive_after_attachment_until_socket_close() -> None:
    secret = bytearray(range(32))
    ticket = "T" * 43
    client = TransportSession(episode_id="ep_socket", local_sender="godot", session_secret=secret)
    hello = client.encode(
        "hello", boundary_hash=ZERO_HASH, body={"connection_id": "connection_0"}
    ).decode()
    websocket = FakeWebSocket(hello)
    endpoint = ManagedWebSocketEndpoint()
    attached = endpoint.register(
        ticket=ticket,
        episode_id="ep_socket",
        connection_id="connection_0",
        session_secret=bytearray(secret),
    )
    handler = asyncio.create_task(endpoint.handle(ticket, websocket))
    socket = await asyncio.wait_for(attached, 1)
    assert not handler.done()
    auth = client.decode(websocket.sent[0].encode(), expected_message_type="auth")
    assert auth.body == {"attachment_ticket": ticket}
    await socket.send("decision_window", boundary_hash="a" * 64, body={"window": {}})
    assert client.decode(websocket.sent[1].encode()).message_type == "decision_window"
    await socket.close()
    await asyncio.wait_for(handler, 1)


@pytest.mark.asyncio
async def test_endpoint_binds_registered_v2_protocol_to_both_directions() -> None:
    secret = bytearray(range(32))
    ticket = "V" * 43
    client = TransportSession(
        episode_id="ep_socket_v2",
        local_sender="godot",
        session_secret=secret,
        protocol_version="llm-controller/0.2.0",
    )
    hello = client.encode(
        "hello", boundary_hash=ZERO_HASH, body={"connection_id": "connection_v2"}
    ).decode()
    websocket = FakeWebSocket(hello)
    endpoint = ManagedWebSocketEndpoint()
    attached = endpoint.register(
        ticket=ticket,
        episode_id="ep_socket_v2",
        connection_id="connection_v2",
        session_secret=bytearray(secret),
        protocol_version="llm-controller/0.2.0",
    )
    handler = asyncio.create_task(endpoint.handle(ticket, websocket))
    socket = await asyncio.wait_for(attached, 1)
    auth = client.decode(websocket.sent[0].encode(), expected_message_type="auth")
    assert auth.protocol_version == "llm-controller/0.2.0"
    assert socket.transport.protocol_version == "llm-controller/0.2.0"
    await socket.close()
    await asyncio.wait_for(handler, 1)


@pytest.mark.asyncio
async def test_endpoint_rejects_unknown_registered_protocol_before_attachment() -> None:
    endpoint = ManagedWebSocketEndpoint()
    with pytest.raises(ValueError, match="unsupported"):
        endpoint.register(
            ticket="U" * 43,
            episode_id="ep_socket_unknown",
            connection_id="connection_unknown",
            session_secret=bytearray(range(32)),
            protocol_version="llm-controller/9.9.9",
        )


@pytest.mark.asyncio
async def test_cancelled_attachment_future_scrubs_endpoint_secret() -> None:
    endpoint = ManagedWebSocketEndpoint()
    ticket = "C" * 43
    attached = endpoint.register(
        ticket=ticket,
        episode_id="ep_cancelled_socket",
        connection_id="connection_0",
        session_secret=bytearray(range(32)),
    )
    owned_secret = endpoint._pending[ticket].session_secret
    attached.cancel()
    await asyncio.sleep(0)
    assert owned_secret == bytearray()
    assert ticket not in endpoint._pending


@pytest.mark.asyncio
async def test_endpoint_diagnostics_and_consumed_ticket_cache_are_bounded() -> None:
    endpoint = ManagedWebSocketEndpoint(consumed_ticket_capacity=2)
    tickets = [character * 43 for character in ("A", "B", "C")]
    for index, ticket in enumerate(tickets):
        attached = endpoint.register(
            ticket=ticket,
            episode_id=f"ep_bounded_{index}",
            connection_id=f"connection_{index}",
            session_secret=bytearray(range(32)),
        )
        assert endpoint.diagnostics()["pending"] == 1
        attached.cancel()
        await asyncio.sleep(0)
        assert endpoint.diagnostics()["pending"] == 0
    assert endpoint.diagnostics() == {"pending": 0, "consumed": 2}
    assert tickets[0] not in endpoint._consumed
    assert set(endpoint.diagnostics()) == {"pending", "consumed"}
