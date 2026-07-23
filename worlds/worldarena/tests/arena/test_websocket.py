from __future__ import annotations

import json

import genesis_arena.main as arena_main
from fastapi.testclient import TestClient
from genesis_arena.main import app

from .helpers import request


def _configure_message(**overrides):
    message = {
        "type": "configure_match",
        "protocol": "world-arena/0.4",
        "brain_mode": "demo",
        "mode": "demo",
        "track": "standard",
        "map_id": "tri_13_v1",
        "seed": 7,
        "max_rounds": 120,
        "agents": [
            {
                "agent_id": faction,
                "model": f"demo-{faction}",
                "reasoning_effort": "low",
                "max_specialists": 0,
            }
            for faction in ("sol", "terra", "luna")
        ],
    }
    message.update(overrides)
    return message


def _receive_until(websocket, expected_type: str):
    for _ in range(8):
        message = websocket.receive_json()
        if message.get("type") == expected_type:
            return message
    raise AssertionError(f"did not receive {expected_type}")


def test_arena_websocket_commits_then_reveals_all_plans() -> None:
    with TestClient(app) as client:
        with client.websocket_connect("/ws/arena") as websocket:
            connected = websocket.receive_json()
            assert connected == {
                "type": "connected",
                "protocol": "world-arena/0.4",
                "supports": [
                    "demo",
                    "openai",
                    "commit_reveal",
                    "simultaneous_plans",
                    "world-arena/0.2",
                    "world-arena/0.3",
                    "world-arena/0.4",
                ],
            }

            websocket.send_json(_configure_message())
            configured = websocket.receive_json()
            assert configured["type"] == "configured"
            assert configured["brain_mode"] == "demo"
            assert "api_key" not in configured

            websocket.send_json(request().model_dump(mode="json"))
            thinking = websocket.receive_json()
            assert thinking["type"] == "thinking_status"
            assert set(thinking["statuses"].values()) == {"thinking"}
            commits = _receive_until(websocket, "round_commit_hashes")
            assert len(commits["commits"]) == 3
            hashes = {item["faction_id"]: item["commit_hash"] for item in commits["commits"]}

            websocket.send_json(
                {
                    "type": "round_commits_locked",
                    "protocol": "world-arena/0.4",
                    "match_id": commits["match_id"],
                    "round": commits["round"],
                    "commit_hashes": hashes,
                }
            )
            reveal = websocket.receive_json()
            assert reveal["type"] == "round_plan_reveal"
            assert {item["faction_id"] for item in reveal["plans"]} == {
                "sol",
                "terra",
                "luna",
            }


def test_invalid_configuration_never_echoes_api_key() -> None:
    secret = "do-not-echo-this-value"
    bad_agents = _configure_message()["agents"][:2]
    with TestClient(app) as client:
        with client.websocket_connect("/ws/arena") as websocket:
            websocket.receive_json()
            websocket.send_json(
                _configure_message(api_key=secret, brain_mode="openai", agents=bad_agents)
            )
            response = websocket.receive_json()

    assert response["type"] == "error"
    assert secret not in str(response)


def test_terminal_godot_receipt_emits_a_verified_deterministic_result(
    tmp_path, monkeypatch
) -> None:
    monkeypatch.setattr(arena_main.settings, "runs_dir", tmp_path)
    with TestClient(app) as client:
        with client.websocket_connect("/ws/arena") as websocket:
            websocket.receive_json()
            websocket.send_json(_configure_message())
            websocket.receive_json()
            websocket.send_json(request().model_dump(mode="json"))
            commits = _receive_until(websocket, "round_commit_hashes")
            websocket.send_json(
                {
                    "type": "round_commits_locked",
                    "protocol": "world-arena/0.4",
                    "match_id": "match-test",
                    "round": 1,
                    "commit_hashes": {
                        item["faction_id"]: item["commit_hash"]
                        for item in commits["commits"]
                    },
                }
            )
            _receive_until(websocket, "round_plan_reveal")
            websocket.send_json(
                {
                    "type": "round_receipts",
                    "protocol": "world-arena/0.4",
                    "match_id": "match-test",
                    "round": 1,
                    "previous_state_hash": "a" * 64,
                    "state_hash": "b" * 64,
                    "events": [
                        {
                            "event_id": "evt.000001",
                            "match_id": "match-test",
                            "sequence": 0,
                            "round": 1,
                            "tick": 150,
                            "kind": "core",
                            "actor_id": "sol",
                            "visibility": "public",
                            "summary": "Sol wins WorldArena.",
                        }
                    ],
                    "terminal_outcome": {
                        "ended": True,
                        "winner": "sol",
                        "completed_rounds": 1,
                        "rules_hash": "c" * 64,
                        "map_hash": "d" * 64,
                        "tool_hash": "e" * 64,
                        "factions": [
                            {
                                "faction_id": "sol",
                                "placement": 1,
                                "won": True,
                                "draw": False,
                                "core_health": 1000,
                                "supplied_points": 1,
                                "territory_time": 1,
                                "completed_structure_value": 0,
                                "completed_structures": 0,
                            },
                            {
                                "faction_id": "terra",
                                "placement": 2,
                                "won": False,
                                "draw": False,
                                "core_health": 900,
                                "supplied_points": 1,
                                "territory_time": 1,
                                "completed_structure_value": 0,
                                "completed_structures": 0,
                            },
                            {
                                "faction_id": "luna",
                                "placement": 3,
                                "won": False,
                                "draw": False,
                                "core_health": 800,
                                "supplied_points": 1,
                                "territory_time": 1,
                                "completed_structure_value": 0,
                                "completed_structures": 0,
                            },
                        ],
                    },
                }
            )
            accepted = websocket.receive_json()
            result = websocket.receive_json()

    assert accepted["type"] == "round_receipts_accepted"
    assert result["type"] == "match_result"
    assert result["result"]["verified"] is True
    assert result["result"]["evidence_mode"] == "authoritative_receipts"
    assert result["result"]["outcome_authority"] == "godot"
    assert result["result"]["llm_judge_used"] is False
    assert result["result"]["factions"][0]["faction_id"] == "sol"
    assert result["artifact_run"] == "match-test"
    run = tmp_path / result["artifact_run"]
    assert (run / "manifest.json").is_file()
    assert (run / "rounds.jsonl").is_file()
    assert (run / "events.jsonl").is_file()
    persisted = json.loads((run / "rounds.jsonl").read_text(encoding="utf-8"))
    assert persisted["plans"][0]["observation"]["faction_id"] == "luna"
    assert "api_key" not in (run / "result.json").read_text(encoding="utf-8")
