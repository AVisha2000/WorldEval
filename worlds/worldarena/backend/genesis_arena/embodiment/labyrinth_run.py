"""Deterministic, visible-only WorldArena Labyrinth Run showcase.

The cached highlight is intentionally isolated from the frozen controller protocols.  Racers
receive only relative passages and a landmark label.  The replay stores public presentation
tracks and aggregate evaluation; provider scratchpads and raw decisions never enter it.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal, Mapping, Sequence

from .protocol import canonical_json_bytes, strict_json_loads

TASK_ID = "trio-maze-race-v0"
PROTOCOL_VERSION = "maze-task-plan-v1"
REPLAY_SCHEMA = "worldarena/labyrinth-run-replay/1"
SHOWCASE_SCHEMA = "worldarena/labyrinth-run-showcase-manifest/1"
ASSET_DIRECTORY = Path("godot/showcases/labyrinth_run")
PARTICIPANTS = ("participant_0", "participant_1", "participant_2")
PASSAGE_CHOICES = frozenset(("left", "forward", "right", "back", "wait"))
HEADINGS = ((0, -1), (1, 0), (0, 1), (-1, 0))
MAXIMUM_TICKS = 600
TICKS_PER_CELL = 4

MAZE_ROWS = (
    "###############",
    "#......E......#",
    "#.###.#.#######",
    "#.#...#.#.....#",
    "###.###.#.###.#",
    "#...#...#...#.#",
    "#.#########.#.#",
    "#.#...#...#.#.#",
    "#.#.#.#.#.#.#.#",
    "#...#...#...#.#",
    "#.###########.#",
    "#.........#...#",
    "#####.#####.#.#",
    "#.....#S....#.#",
    "###############",
)

LANDMARKS = {
    (13, 11): "twin-torches",
    (1, 9): "old-well",
    (5, 11): "broken-statue",
    (5, 1): "blue-crystal",
    (7, 1): "mossy-pillar",
}

ENTRANTS = (
    {
        "participant_id": "participant_0",
        "entrant_id": "sol",
        "display_name": "Sol",
        "model": "demo-sol-v1",
        "color": "#fbbf24",
        "lane": "gold",
        "style": "Right-first depth-first search",
        "thinking_ticks": 32,
    },
    {
        "participant_id": "participant_1",
        "entrant_id": "luna",
        "display_name": "Luna",
        "model": "demo-luna-v1",
        "color": "#a78bfa",
        "lane": "purple",
        "style": "Cautious left-first search",
        "thinking_ticks": 14,
    },
    {
        "participant_id": "participant_2",
        "entrant_id": "terra",
        "display_name": "Terra",
        "model": "demo-terra-v1",
        "color": "#34d399",
        "lane": "green",
        "style": "Forward-biased landmark search",
        "thinking_ticks": 20,
    },
)

_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


class LabyrinthRunError(RuntimeError):
    """The fixed race, packaged replay, or media binding is invalid."""


@dataclass(frozen=True)
class MazeTaskPlan:
    episode_id: str
    observation_id: str
    participant_id: str
    passage_choice: Literal["left", "forward", "right", "back", "wait"]
    scratchpad_update: str = ""
    protocol_version: Literal["maze-task-plan-v1"] = PROTOCOL_VERSION

    def __post_init__(self) -> None:
        if self.protocol_version != PROTOCOL_VERSION:
            raise ValueError("maze task plan protocol is invalid")
        if not isinstance(self.episode_id, str) or not self.episode_id.startswith("ep_"):
            raise ValueError("maze episode id is invalid")
        if (
            not isinstance(self.observation_id, str)
            or _SAFE_ID.fullmatch(self.observation_id) is None
        ):
            raise ValueError("maze observation id is invalid")
        if self.participant_id not in PARTICIPANTS:
            raise ValueError("maze participant is invalid")
        if self.passage_choice not in PASSAGE_CHOICES:
            raise ValueError("maze passage choice is invalid")
        if (
            not isinstance(self.scratchpad_update, str)
            or len(self.scratchpad_update.encode()) > 2048
        ):
            raise ValueError("maze scratchpad update is invalid")

    def as_dict(self) -> dict[str, str]:
        return {
            "protocol_version": self.protocol_version,
            "episode_id": self.episode_id,
            "observation_id": self.observation_id,
            "participant_id": self.participant_id,
            "passage_choice": self.passage_choice,
            "scratchpad_update": self.scratchpad_update,
        }


def parse_maze_task_plan(payload: bytes, *, expected: Mapping[str, str]) -> MazeTaskPlan:
    value = strict_json_loads(payload)
    if not isinstance(value, dict) or set(value) != {
        "protocol_version",
        "episode_id",
        "observation_id",
        "participant_id",
        "passage_choice",
        "scratchpad_update",
    }:
        raise ValueError("maze task plan fields are invalid")
    plan = MazeTaskPlan(**value)
    for field in ("episode_id", "observation_id", "participant_id"):
        if getattr(plan, field) != expected.get(field):
            raise ValueError("maze task plan is stale or mismatched")
    return plan


def maze_analysis() -> Mapping[str, Any]:
    graph = _cell_graph()
    start, exit_cell = _start_exit()
    distances = _distances(graph, start)
    dead_ends = sorted(
        cell for cell, neighbours in graph.items() if len(neighbours) == 1 and cell != start
    )
    junctions = sorted(cell for cell, neighbours in graph.items() if len(neighbours) >= 3)
    return {
        "map_sha256": hashlib.sha256("\n".join(MAZE_ROWS).encode()).hexdigest(),
        "walkable_cells": len(graph),
        "shortest_path_cells": distances[exit_cell],
        "dead_ends": [list(value) for value in dead_ends],
        "junctions": [list(value) for value in junctions],
        "reachable": len(distances) == len(graph),
    }


def build_demo_replay() -> Mapping[str, Any]:
    analysis = maze_analysis()
    if (
        not analysis["reachable"]
        or analysis["shortest_path_cells"] != 60
        or len(analysis["dead_ends"]) != 6
        or len(analysis["junctions"]) != 5
    ):
        raise LabyrinthRunError("labyrinth fixture invariants changed")
    racers = []
    events: list[dict[str, Any]] = []
    for entrant in ENTRANTS:
        segments = _policy_segments(str(entrant["entrant_id"]))
        racer, racer_events = _build_racer(entrant, segments, int(analysis["shortest_path_cells"]))
        racers.append(racer)
        events.extend(racer_events)
    racers.sort(key=lambda value: str(value["participant_id"]))
    placements = sorted(
        racers, key=lambda value: (int(value["finish_tick"]), str(value["participant_id"]))
    )
    for place, racer in enumerate(placements, 1):
        racer["place"] = place
    events.sort(
        key=lambda value: (int(value["tick"]), str(value["participant_id"]), str(value["kind"]))
    )
    body: dict[str, Any] = {
        "schema_version": REPLAY_SCHEMA,
        "protocol_version": PROTOCOL_VERSION,
        "task_id": TASK_ID,
        "episode_id": "ep_labyrinth_run_showcase",
        "authority_hz": 10,
        "maximum_ticks": MAXIMUM_TICKS,
        "map": {"rows": list(MAZE_ROWS), **analysis},
        "entrants": [
            {key: value for key, value in entrant.items() if key != "thinking_ticks"}
            for entrant in ENTRANTS
        ],
        "racers": racers,
        "events": events,
        "result": {
            "winner_id": placements[0]["participant_id"],
            "winner": placements[0]["display_name"],
            "finish_order": [value["participant_id"] for value in placements],
            "completion_tick": max(int(value["finish_tick"]) for value in racers),
            "reason": "all_racers_finished",
            "explanation": (
                "Sol won by eliminating exhausted branches more efficiently. "
                "Terra recovered from two incorrect branches. Luna completed the maze "
                "but travelled the longest route."
            ),
        },
    }
    body["final_state_sha256"] = hashlib.sha256(canonical_json_bytes(body)).hexdigest()
    return body


def public_evaluation(replay: Mapping[str, Any]) -> Mapping[str, Any]:
    _verify_replay(replay)
    racers = sorted(replay["racers"], key=lambda value: int(value["place"]))
    return {
        "task_id": TASK_ID,
        "scope": "trio_maze_race",
        "summary": replay["result"]["explanation"],
        "participants": [
            {
                key: racer[key]
                for key in (
                    "participant_id",
                    "display_name",
                    "model",
                    "color",
                    "place",
                    "finish_tick",
                    "completion_seconds",
                    "distance_cells",
                    "shortest_path_cells",
                    "path_efficiency_basis_points",
                    "unique_corridor_cells",
                    "repeated_corridor_cells",
                    "passages_explored",
                    "dead_ends_entered",
                    "successful_backtracks",
                    "collisions",
                    "invalid_decisions",
                    "idle_thinking_ticks",
                )
            }
            for racer in racers
        ],
        "verification": {
            "state": "verified",
            "deterministic": True,
            "map_sha256": replay["map"]["map_sha256"],
            "final_state_sha256": replay["final_state_sha256"],
        },
    }


@dataclass(frozen=True)
class CachedLabyrinthRun:
    video_path: Path
    manifest_sha256: str
    replay_sha256: str
    evaluation_sha256: str
    manifest: Mapping[str, Any]
    replay: Mapping[str, Any]
    evaluation: Mapping[str, Any]

    @classmethod
    def load(cls, repository_root: Path) -> CachedLabyrinthRun:
        directory = Path(repository_root).resolve() / ASSET_DIRECTORY
        try:
            manifest_bytes = (directory / "manifest.json").read_bytes()
            manifest = strict_json_loads(manifest_bytes)
        except OSError as error:
            raise LabyrinthRunError("labyrinth_showcase_missing") from error
        _validate_manifest(manifest)
        try:
            replay_bytes = (directory / manifest["replay"]["path"]).read_bytes()
            evaluation_bytes = (directory / manifest["evaluation"]["path"]).read_bytes()
            video_path = directory / manifest["video"]["path"]
            video_bytes = video_path.read_bytes()
            replay = strict_json_loads(replay_bytes)
            evaluation = strict_json_loads(evaluation_bytes)
        except OSError as error:
            raise LabyrinthRunError("labyrinth_showcase_missing") from error
        if not isinstance(replay, dict) or not isinstance(evaluation, dict):
            raise LabyrinthRunError("labyrinth_showcase_invalid")
        hashes = {
            "replay": hashlib.sha256(replay_bytes).hexdigest(),
            "evaluation": hashlib.sha256(evaluation_bytes).hexdigest(),
            "video": hashlib.sha256(video_bytes).hexdigest(),
        }
        if any(hashes[key] != manifest[key]["sha256"] for key in hashes):
            raise LabyrinthRunError("labyrinth_showcase_hash_invalid")
        if len(video_bytes) < 32 or b"ftyp" not in video_bytes[:32]:
            raise LabyrinthRunError("labyrinth_showcase_video_invalid")
        _verify_replay(replay)
        if evaluation != public_evaluation(replay):
            raise LabyrinthRunError("labyrinth_showcase_evaluation_invalid")
        return cls(
            video_path,
            hashlib.sha256(manifest_bytes).hexdigest(),
            hashes["replay"],
            hashes["evaluation"],
            manifest,
            replay,
            evaluation,
        )

    def public_view(self) -> Mapping[str, Any]:
        result = self.replay["result"]
        return {
            "showcase_id": TASK_ID,
            "task_id": TASK_ID,
            "label": self.manifest["label"],
            "tagline": self.manifest["tagline"],
            "status": "ready",
            "cached": True,
            "video": {
                key: self.manifest["video"][key]
                for key in ("duration_seconds", "fps", "height", "mime_type", "sha256", "width")
            },
            "entrants": [dict(value) for value in self.replay["entrants"]],
            "winner": {"participant_id": result["winner_id"], "display_name": result["winner"]},
            "result": dict(result),
            "timeline": [dict(value) for value in self.manifest["highlights"]],
        }

    def public_evaluation(self) -> Mapping[str, Any]:
        return {
            **self.evaluation,
            "showcase_id": TASK_ID,
            "verification": {
                **self.evaluation["verification"],
                "manifest_sha256": self.manifest_sha256,
                "replay_sha256": self.replay_sha256,
                "video_sha256": self.manifest["video"]["sha256"],
            },
        }


def _build_racer(
    entrant: Mapping[str, Any], segments: Sequence[Sequence[tuple[int, int]]], shortest: int
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    tick = 0
    distance = 0
    visits: list[tuple[int, int]] = [segments[0][0]]
    keyframes: list[dict[str, Any]] = [
        {
            "tick": 0,
            "cell": list(segments[0][0]),
            "heading": 0,
            "state": "thinking",
            "task": "exploring",
        }
    ]
    events: list[dict[str, Any]] = []
    dead_ends = 0
    backtracks = 0
    thinking_ticks = int(entrant["thinking_ticks"])
    graph = _cell_graph()
    previous_edge: frozenset[tuple[int, int]] | None = None
    unique_passages: set[frozenset[tuple[int, int]]] = set()
    for segment in segments:
        start, end = segment[0], segment[-1]
        passage = frozenset((start, end))
        choice = _relative_choice(segment, keyframes[-1]["heading"])
        tick += thinking_ticks
        task = "backtracking" if previous_edge == passage else "turning"
        if task == "backtracking":
            backtracks += 1
        events.append(
            {
                "tick": tick,
                "participant_id": entrant["participant_id"],
                "kind": "backtrack" if task == "backtracking" else "junction_choice",
                "label": "Backtracking"
                if task == "backtracking"
                else f"Trying the {choice} passage",
            }
        )
        for source, target in zip(segment, segment[1:]):
            tick += TICKS_PER_CELL
            distance += 1
            visits.append(target)
            heading = HEADINGS.index((target[0] - source[0], target[1] - source[1]))
            keyframes.append(
                {
                    "tick": tick,
                    "cell": list(target),
                    "heading": heading,
                    "state": "walk",
                    "task": task,
                }
            )
        unique_passages.add(passage)
        if len(graph[end]) == 1 and _symbol(end) not in ("S", "E"):
            dead_ends += 1
            keyframes[-1]["state"] = "surprised"
            keyframes[-1]["task"] = "dead_end"
            events.append(
                {
                    "tick": tick,
                    "participant_id": entrant["participant_id"],
                    "kind": "dead_end",
                    "label": "Dead end",
                }
            )
        previous_edge = passage
    if _symbol(segments[-1][-1]) != "E" or tick > MAXIMUM_TICKS:
        raise LabyrinthRunError("demo policy did not finish the fixed maze")
    keyframes[-1]["state"] = "celebrate"
    keyframes[-1]["task"] = "finished"
    events.append(
        {
            "tick": tick,
            "participant_id": entrant["participant_id"],
            "kind": "finish",
            "label": "Exit found!",
        }
    )
    unique_cells = len(set(visits))
    return (
        {
            "participant_id": entrant["participant_id"],
            "entrant_id": entrant["entrant_id"],
            "display_name": entrant["display_name"],
            "model": entrant["model"],
            "color": entrant["color"],
            "lane": entrant["lane"],
            "style": entrant["style"],
            "finish_tick": tick,
            "completion_seconds": f"{tick / 10:.1f}",
            "distance_cells": distance,
            "shortest_path_cells": shortest,
            "path_efficiency_basis_points": shortest * 10_000 // distance,
            "unique_corridor_cells": unique_cells,
            "repeated_corridor_cells": len(visits) - unique_cells,
            "passages_explored": len(unique_passages),
            "dead_ends_entered": dead_ends,
            "successful_backtracks": backtracks,
            "collisions": 0,
            "invalid_decisions": 0,
            "idle_thinking_ticks": thinking_ticks * len(segments),
            "keyframes": keyframes,
        },
        events,
    )


def _policy_segments(entrant_id: str) -> list[list[tuple[int, int]]]:
    graph = _decision_graph()
    start, exit_cell = _start_exit()
    position = start
    heading = 0
    visited: set[frozenset[tuple[int, int]]] = set()
    stack: list[tuple[int, int]] = []
    output: list[list[tuple[int, int]]] = []
    while position != exit_cell and len(output) < 64:
        options = []
        for end, path in graph[position]:
            outgoing = HEADINGS.index((path[1][0] - position[0], path[1][1] - position[1]))
            relative = (outgoing - heading) % 4
            options.append((relative, end, path, frozenset((position, end))))
        unvisited = [value for value in options if value[3] not in visited]
        if entrant_id == "sol":
            selected = _dfs_select(unvisited, options, stack, order=(1, 0, 3, 2))
        elif entrant_id == "luna":
            selected = _dfs_select(unvisited, options, stack, order=(3, 0, 1, 2))
        elif entrant_id == "terra":
            selected = _terra_select(unvisited, options, stack, position)
        else:
            raise ValueError("unknown maze entrant")
        relative, end, path, edge = selected
        if unvisited:
            stack.append(position)
        elif stack and end == stack[-1]:
            stack.pop()
        visited.add(edge)
        output.append(path)
        heading = HEADINGS.index((path[-1][0] - path[-2][0], path[-1][1] - path[-2][1]))
        position = end
    return output


def _dfs_select(
    options: Sequence[tuple[Any, ...]],
    all_options: Sequence[tuple[Any, ...]],
    stack: list[tuple[int, int]],
    *,
    order: Sequence[int],
) -> tuple[Any, ...]:
    if options:
        return min(options, key=lambda value: order.index(value[0]))
    if not stack:
        raise LabyrinthRunError("maze DFS stack exhausted")
    return next(value for value in all_options if value[1] == stack[-1])


def _terra_select(
    options: Sequence[tuple[Any, ...]],
    all_options: Sequence[tuple[Any, ...]],
    stack: list[tuple[int, int]],
    position: tuple[int, int],
) -> tuple[Any, ...]:
    forward = next((value for value in options if value[0] == 0), None)
    if forward is not None:
        return forward
    # After a proved dead end, Terra resumes the forward corridor to its unresolved parent
    # rather than exhaustively opening every side branch at the recovery landmark.
    recovery = next(
        (value for value in all_options if stack and value[0] == 0 and value[1] == stack[-1]),
        None,
    )
    if recovery is not None:
        return recovery
    if options:
        landmark = LANDMARKS.get(position, "unmarked-junction")
        return min(
            options,
            key=lambda value: hashlib.sha256(
                f"{landmark}:{_relative_name(value[0])}".encode()
            ).hexdigest(),
        )
    if not stack:
        raise LabyrinthRunError("Terra maze stack exhausted")
    return next(value for value in all_options if value[1] == stack[-1])


def _decision_graph() -> Mapping[
    tuple[int, int], list[tuple[tuple[int, int], list[tuple[int, int]]]]
]:
    graph = _cell_graph()
    start, exit_cell = _start_exit()
    decisions = {cell for cell, neighbours in graph.items() if len(neighbours) != 2} | {
        start,
        exit_cell,
    }
    output: dict[tuple[int, int], list[tuple[tuple[int, int], list[tuple[int, int]]]]] = {}
    for source in decisions:
        output[source] = []
        for neighbour in graph[source]:
            previous, current = source, neighbour
            path = [source, neighbour]
            while current not in decisions:
                following = next(value for value in graph[current] if value != previous)
                previous, current = current, following
                path.append(current)
            output[source].append((current, path))
    return output


def _cell_graph() -> Mapping[tuple[int, int], tuple[tuple[int, int], ...]]:
    walkable = {
        (x, y) for y, row in enumerate(MAZE_ROWS) for x, symbol in enumerate(row) if symbol != "#"
    }
    return {
        cell: tuple(
            (cell[0] + dx, cell[1] + dy)
            for dx, dy in HEADINGS
            if (cell[0] + dx, cell[1] + dy) in walkable
        )
        for cell in walkable
    }


def _distances(
    graph: Mapping[tuple[int, int], Sequence[tuple[int, int]]], start: tuple[int, int]
) -> Mapping[tuple[int, int], int]:
    queue = [start]
    output = {start: 0}
    for current in queue:
        for candidate in graph[current]:
            if candidate not in output:
                output[candidate] = output[current] + 1
                queue.append(candidate)
    return output


def _start_exit() -> tuple[tuple[int, int], tuple[int, int]]:
    start = next(
        (x, y) for y, row in enumerate(MAZE_ROWS) for x, value in enumerate(row) if value == "S"
    )
    exit_cell = next(
        (x, y) for y, row in enumerate(MAZE_ROWS) for x, value in enumerate(row) if value == "E"
    )
    return start, exit_cell


def _symbol(cell: tuple[int, int]) -> str:
    return MAZE_ROWS[cell[1]][cell[0]]


def _relative_name(relative: int) -> str:
    return ("forward", "right", "back", "left")[relative]


def _relative_choice(path: Sequence[tuple[int, int]], heading: int) -> str:
    outgoing = HEADINGS.index((path[1][0] - path[0][0], path[1][1] - path[0][1]))
    return _relative_name((outgoing - int(heading)) % 4)


def _verify_replay(value: Mapping[str, Any]) -> None:
    expected = build_demo_replay()
    if value != expected:
        raise LabyrinthRunError("labyrinth_replay_verification_failed")


def _validate_manifest(value: Any) -> None:
    if not isinstance(value, dict) or set(value) != {
        "schema_version",
        "showcase_id",
        "task_id",
        "label",
        "tagline",
        "video",
        "replay",
        "evaluation",
        "highlights",
    }:
        raise LabyrinthRunError("labyrinth_manifest_invalid")
    if (
        value["schema_version"] != SHOWCASE_SCHEMA
        or value["showcase_id"] != TASK_ID
        or value["task_id"] != TASK_ID
    ):
        raise LabyrinthRunError("labyrinth_manifest_invalid")
    for text in (value["label"], value["tagline"]):
        if not isinstance(text, str) or not text or len(text) > 180:
            raise LabyrinthRunError("labyrinth_manifest_invalid")
    for key in ("video", "replay", "evaluation"):
        item = value[key]
        if (
            not isinstance(item, dict)
            or not isinstance(item.get("path"), str)
            or Path(item["path"]).name != item["path"]
            or not re.fullmatch(r"[0-9a-f]{64}", str(item.get("sha256", "")))
        ):
            raise LabyrinthRunError("labyrinth_manifest_invalid")
    video = value["video"]
    if video.get("mime_type") != "video/mp4" or any(
        not isinstance(video.get(field), int) or video[field] <= 0
        for field in ("duration_seconds", "fps", "width", "height")
    ):
        raise LabyrinthRunError("labyrinth_manifest_invalid")
    highlights = value["highlights"]
    if not isinstance(highlights, list) or not highlights:
        raise LabyrinthRunError("labyrinth_manifest_invalid")
    previous = -1
    for item in highlights:
        if (
            not isinstance(item, dict)
            or set(item) != {"at_seconds", "label", "participant_id", "kind"}
            or not isinstance(item["at_seconds"], int)
            or item["at_seconds"] <= previous
            or item["at_seconds"] > video["duration_seconds"]
            or item["participant_id"] not in (*PARTICIPANTS, "broadcast")
        ):
            raise LabyrinthRunError("labyrinth_manifest_invalid")
        previous = item["at_seconds"]


__all__ = [
    "ASSET_DIRECTORY",
    "CachedLabyrinthRun",
    "ENTRANTS",
    "LabyrinthRunError",
    "MAZE_ROWS",
    "MazeTaskPlan",
    "PROTOCOL_VERSION",
    "TASK_ID",
    "build_demo_replay",
    "maze_analysis",
    "parse_maze_task_plan",
    "public_evaluation",
]
