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
