from __future__ import annotations

import asyncio
import hashlib
from pathlib import Path

import pytest
from genesis_arena.embodiment.control_games.movement_maze_demo import (
    MOVEMENT_MAZE_DEMO_MODEL,
    MOVEMENT_MAZE_POLICY_ID,
    MOVEMENT_MAZE_SCENARIO_ID,
    movement_maze_demo_behavior,
)
from genesis_arena.embodiment.control_games.operator_action_course_demo import (
    OPERATOR_ACTION_COURSE_DEMO_MODEL,
    OPERATOR_ACTION_COURSE_POLICY_ID,
    OPERATOR_ACTION_COURSE_SCENARIO_ID,
    operator_action_course_demo_behavior,
)
from genesis_arena.embodiment.demo_provider import DemoBehavior, DemoPolicyLock, DemoProvider
from genesis_arena.embodiment.protocol import (
    ProtocolValidationError,
    canonical_json_bytes,
    strict_json_loads,
)
from genesis_arena.embodiment.protocol_registry import EmbodimentProtocolRegistry
from genesis_arena.embodiment.providers.contracts import ProviderRequest

ROOT = Path(__file__).resolve().parents[2]
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
PROTOCOL_VERSION = "llm-controller/0.2.0"

pytestmark = pytest.mark.skipif(not GODOT.is_file(), reason="pinned local Godot is unavailable")


async def _read_message(reader: asyncio.StreamReader) -> dict:
    prefix = await asyncio.wait_for(reader.readexactly(4), timeout=5.0)
    size = int.from_bytes(prefix, "big")
    if not 1 <= size <= 1_048_576:
        raise AssertionError("Godot policy bridge returned an invalid frame size")
    value = strict_json_loads(
        await asyncio.wait_for(reader.readexactly(size), timeout=5.0)
    )
    if not isinstance(value, dict) or "error" in value:
        raise AssertionError(f"Godot policy bridge returned an invalid message: {value!r}")
    return value


async def _send_message(writer: asyncio.StreamWriter, value: dict) -> None:
    payload = canonical_json_bytes(value)
    writer.write(len(payload).to_bytes(4, "big") + payload)
    await writer.drain()


async def _run_policy_loop(
    *,
    task_id: str,
    scenario_id: str,
    policy_id: str,
    model: str,
    behavior: DemoBehavior,
    seed: int,
    inject_invalid_first_output: bool = False,
) -> tuple[dict, ...]:
    episode_id = f"ep_policy_loop_{task_id.removesuffix('-v0').replace('-', '_')}"
    fixture = f"{scenario_id}:{policy_id}:loop-v1\n".encode()
    lock = DemoPolicyLock(
        scenario_id=scenario_id,
        policy_id=policy_id,
        fixture_sha256=hashlib.sha256(fixture).hexdigest(),
        seed=seed,
        participant_id="participant_0",
        model=model,
        total_decision_budget=100,
    )

    selected_behavior = behavior
    if inject_invalid_first_output:

        def invalid_then_visible_policy(request, policy_lock, call_index):
            if call_index == 0:
                return b"{}"
            return behavior(request, policy_lock, call_index)

        selected_behavior = invalid_then_visible_policy
    provider = DemoProvider(lock, behavior=selected_behavior, fixture_bytes=fixture)
    registry = EmbodimentProtocolRegistry.from_repository(ROOT)
    package = registry.package(PROTOCOL_VERSION)
    maximum_ticks = 300 if task_id == "operator-action-course-v0" else 200
    config = {
        "protocol_version": PROTOCOL_VERSION,
        "episode_id": episode_id,
        "mode": "solo-curriculum-v0",
        "task_id": task_id,
        "seed": seed,
        "observation_profile": "text-visible-v1",
        "timing_track": "step-locked-v1",
        "maximum_episode_ticks": maximum_ticks,
        "participant_ids": ["participant_0"],
    }
    package.validate("episode-config", config)
    connected: asyncio.Future[tuple[asyncio.StreamReader, asyncio.StreamWriter]] = (
        asyncio.get_running_loop().create_future()
    )

    async def accept_bridge(
        reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        if connected.done():
            writer.close()
            await writer.wait_closed()
            return
        connected.set_result((reader, writer))

    server = await asyncio.start_server(accept_bridge, "127.0.0.1", 0)
    socket = server.sockets[0]
    port = int(socket.getsockname()[1])
    process = await asyncio.create_subprocess_exec(
        str(GODOT),
        "--no-header",
        "--headless",
        "--path",
        str(ROOT / "godot"),
        "--script",
        "res://tests/embodiment/control_game_demo_policy_bridge_v2.gd",
        "--",
        str(port),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    reader, writer = await asyncio.wait_for(connected, timeout=5.0)
    server.close()
    await server.wait_closed()
    transcript: list[dict] = []
    try:
        await _send_message(writer, {"config": config})
        initial = await _read_message(reader)
        observation = initial["observation"]
        package.validate("observation", observation)
        transcript.append(initial)
        while not observation["terminal"]["ended"]:
            result = await provider.request(
                ProviderRequest(
                    episode_id=episode_id,
                    participant_id="participant_0",
                    observation_seq=observation["observation_seq"],
                    deadline_monotonic_ns=1,
                    model=model,
                    system_prompt=(
                        "Use only the current participant-visible control-game observation."
                    ),
                    observation_json=canonical_json_bytes(observation),
                    action_schema_json=canonical_json_bytes(
                        package.schema("controller-action")
                    ),
                )
            )
            action = None
            if result.raw_output is not None:
                try:
                    candidate = strict_json_loads(result.raw_output)
                    package.validate("controller-action", candidate)
                    if (
                        isinstance(candidate, dict)
                        and candidate.get("episode_id") == episode_id
                        and candidate.get("observation_seq")
                        == observation["observation_seq"]
                    ):
                        action = candidate
                except ProtocolValidationError:
                    pass
            duration = 1 if action is not None else 3
            decision = (
                {
                    "disposition": "accepted",
                    "action": action,
                    "fallback": "none",
                    "no_input_reason": None,
                }
                if action is not None
                else {
                    "disposition": "no_input",
                    "action": None,
                    "fallback": "neutral",
                    "no_input_reason": "invalid",
                }
            )
            window = {
                "episode_id": episode_id,
                "observation_seq": observation["observation_seq"],
                "mode": "solo-curriculum-v0",
                "start_tick": observation["tick"],
                "duration_ticks": duration,
                "decisions": {"participant_0": decision},
            }
            package.validate("decision-window", window)
            await _send_message(writer, {"window": window})
            message = await _read_message(reader)
            step_result = message["result"]
            package.validate("multi-participant-step-result", step_result)
            transcript.append({"window": window, "result": step_result})
            observation = step_result["observations"]["participant_0"]
        assert await asyncio.wait_for(process.wait(), timeout=5.0) == 0
    finally:
        writer.close()
        await writer.wait_closed()
        if process.returncode is None:
            process.terminate()
            await process.wait()
    return tuple(transcript)


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("task_id", "scenario_id", "policy_id", "model", "behavior"),
    (
        (
            MOVEMENT_MAZE_SCENARIO_ID,
            MOVEMENT_MAZE_SCENARIO_ID,
            MOVEMENT_MAZE_POLICY_ID,
            MOVEMENT_MAZE_DEMO_MODEL,
            movement_maze_demo_behavior,
        ),
        (
            OPERATOR_ACTION_COURSE_SCENARIO_ID,
            OPERATOR_ACTION_COURSE_SCENARIO_ID,
            OPERATOR_ACTION_COURSE_POLICY_ID,
            OPERATOR_ACTION_COURSE_DEMO_MODEL,
            operator_action_course_demo_behavior,
        ),
    ),
)
async def test_real_visible_demo_policy_loop_reaches_deterministic_terminal(
    task_id: str,
    scenario_id: str,
    policy_id: str,
    model: str,
    behavior: DemoBehavior,
) -> None:
    first = await _run_policy_loop(
        task_id=task_id,
        scenario_id=scenario_id,
        policy_id=policy_id,
        model=model,
        behavior=behavior,
        seed=20240522,
    )
    second = await _run_policy_loop(
        task_id=task_id,
        scenario_id=scenario_id,
        policy_id=policy_id,
        model=model,
        behavior=behavior,
        seed=20240522,
    )

    assert first == second
    final = first[-1]["result"]
    assert final["terminal"]["ended"] is True
    assert final["terminal"]["outcome"] == "success"
    assert all(
        "position" not in canonical_json_bytes(record).decode().casefold()
        for record in first
        if "observation" in record
    )


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("task_id", "scenario_id", "policy_id", "model", "behavior"),
    (
        (
            MOVEMENT_MAZE_SCENARIO_ID,
            MOVEMENT_MAZE_SCENARIO_ID,
            MOVEMENT_MAZE_POLICY_ID,
            MOVEMENT_MAZE_DEMO_MODEL,
            movement_maze_demo_behavior,
        ),
        (
            OPERATOR_ACTION_COURSE_SCENARIO_ID,
            OPERATOR_ACTION_COURSE_SCENARIO_ID,
            OPERATOR_ACTION_COURSE_POLICY_ID,
            OPERATOR_ACTION_COURSE_DEMO_MODEL,
            operator_action_course_demo_behavior,
        ),
    ),
)
async def test_invalid_demo_output_records_deterministic_neutral_progress_without_stalling(
    task_id: str,
    scenario_id: str,
    policy_id: str,
    model: str,
    behavior: DemoBehavior,
) -> None:
    arguments = {
        "task_id": task_id,
        "scenario_id": scenario_id,
        "policy_id": policy_id,
        "model": model,
        "behavior": behavior,
        "seed": 20240523,
        "inject_invalid_first_output": True,
    }
    transcript = await _run_policy_loop(**arguments)
    repeated = await _run_policy_loop(**arguments)

    assert transcript == repeated
    first_step = transcript[1]
    receipt = first_step["result"]["receipts"]["participant_0"]
    assert receipt["disposition"] == "no_input"
    assert receipt["no_input_reason"] == "invalid"
    assert receipt["applied_ticks"] == 3
    assert first_step["result"]["observations"]["participant_0"]["tick"] == 3
    assert transcript[-1]["result"]["terminal"]["outcome"] == "success"
