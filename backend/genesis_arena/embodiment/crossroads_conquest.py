"""Immutable, browser-safe WorldArena: Crossroads Conquest showcase package."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from .protocol import strict_json_loads

SHOWCASE_ID = "crossroads-conquest-v0"
ASSET_DIRECTORY = Path("godot/showcases/crossroads_conquest")
MANIFEST_SCHEMA = "worldarena/crossroads-conquest-showcase-manifest/1"
EVALUATION_SCHEMA = "worldarena/crossroads-conquest-evaluation/1"
POLICY_ID = "crossroads-conquest-demo-v1"
SEED = 424242
MAX_VIDEO_BYTES = 90 * 1024 * 1024

_SHA256_LENGTH = 64
_PUBLIC_TEXT_LIMIT = 240
_PRIVATE_TERMS = frozenset(
    {
        "api_key",
        "chain_of_thought",
        "credential",
        "observation",
        "prompt",
        "raw_output",
        "scratchpad",
        "spectator",
    }
)
_ENTRANTS = (
    ("participant_0", "sol", "Sol", "△", "#fbbf24"),
    ("participant_1", "luna", "Luna", "○", "#a78bfa"),
    ("participant_2", "terra", "Terra", "□", "#34d399"),
)
_TIMELINE_WINDOWS = (
    ("opening_reveal", 0, 12, True),
    ("sol_introduction", 12, 19, True),
    ("terra_introduction", 19, 26, True),
    ("luna_introduction", 26, 33, True),
    ("terra_claims_crossroads", 33, 44, False),
    ("sol_prepares_assault", 44, 55, False),
    ("luna_observes", 55, 65, False),
    ("crossroads_clash", 65, 78, False),
    ("sol_takes_crossroads", 78, 90, False),
    ("two_front_march", 90, 102, False),
    ("terra_counterpunch", 102, 114, False),
    ("sol_breaches_terra", 114, 126, False),
    ("terra_eliminated", 126, 137, False),
    ("exposed_sol_overview", 137, 146, False),
    ("luna_strikes", 146, 158, False),
    ("sol_eliminated", 158, 169, False),
    ("verified_result", 169, 180, False),
)


class CrossroadsShowcaseError(RuntimeError):
    """The packaged Crossroads showcase is absent, incomplete, or unsafe."""


@dataclass(frozen=True)
class CachedCrossroadsShowcase:
    """A sealed local highlight with narrowly allow-listed browser projections."""

    video_path: Path
    manifest_sha256: str
    replay_sha256: str
    evaluation_sha256: str
    video_sha256: str
    manifest: Mapping[str, Any]
    evaluation: Mapping[str, Any]

    @classmethod
    def load(cls, repository_root: Path) -> CachedCrossroadsShowcase:
        directory = Path(repository_root).resolve() / ASSET_DIRECTORY
        try:
            manifest_bytes = (directory / "manifest.json").read_bytes()
            manifest = strict_json_loads(manifest_bytes)
        except OSError as error:
            raise CrossroadsShowcaseError("crossroads_showcase_missing") from error
        if not isinstance(manifest, dict):
            raise CrossroadsShowcaseError("crossroads_showcase_manifest_invalid")
        _validate_manifest(manifest)

        video_path = directory / manifest["video"]["path"]
        try:
            replay_bytes = (directory / manifest["replay"]["path"]).read_bytes()
            evaluation_bytes = (directory / manifest["evaluation"]["path"]).read_bytes()
            video_size = video_path.stat().st_size
            replay = strict_json_loads(replay_bytes)
            evaluation = strict_json_loads(evaluation_bytes)
        except OSError as error:
            raise CrossroadsShowcaseError("crossroads_showcase_incomplete") from error
        if not isinstance(replay, dict) or not isinstance(evaluation, dict):
            raise CrossroadsShowcaseError("crossroads_showcase_artifact_invalid")

        hashes = {
            "replay": hashlib.sha256(replay_bytes).hexdigest(),
            "evaluation": hashlib.sha256(evaluation_bytes).hexdigest(),
            "video": _sha256_file(video_path),
        }
        if any(hashes[name] != manifest[name]["sha256"] for name in hashes):
            raise CrossroadsShowcaseError("crossroads_showcase_hash_invalid")
        if video_size != manifest["video"]["size_bytes"] or video_size > MAX_VIDEO_BYTES:
            raise CrossroadsShowcaseError("crossroads_showcase_video_invalid")
        if not _is_fast_start_mp4(video_path, video_size):
            raise CrossroadsShowcaseError("crossroads_showcase_video_invalid")

        _validate_replay_binding(replay, manifest)
        _validate_evaluation(evaluation, manifest)
        return cls(
            video_path=video_path,
            manifest_sha256=hashlib.sha256(manifest_bytes).hexdigest(),
            replay_sha256=hashes["replay"],
            evaluation_sha256=hashes["evaluation"],
            video_sha256=hashes["video"],
            manifest=manifest,
            evaluation=evaluation,
        )

    def public_view(self) -> Mapping[str, Any]:
        """Return presentation metadata only; the authority replay has no public route."""

        video = self.manifest["video"]
        bindings = self.manifest["authority_bindings"]
        return {
            "showcase_id": SHOWCASE_ID,
            "task_id": SHOWCASE_ID,
            "title": self.manifest["title"],
            "tagline": self.manifest["tagline"],
            "status": "ready",
            "cached": True,
            "verified": True,
            "entrants": [dict(value) for value in self.manifest["entrants"]],
            "winner": dict(self.manifest["winner"]),
            "placements": [dict(value) for value in self.manifest["placements"]],
            "elimination_order": [dict(value) for value in self.manifest["elimination_order"]],
            "timeline": [dict(value) for value in self.manifest["public_timeline"]],
            "video": {
                "duration_seconds": video["duration_seconds"],
                "fps": video["fps"],
                "height": video["height"],
                "mime_type": "video/mp4",
                "sha256": self.video_sha256,
                "width": video["width"],
            },
            "authority": {
                key: bindings[key]
                for key in ("protocol", "seed", "policy_id", "map_id", "rules_id")
            },
        }

    def public_evaluation(self) -> Mapping[str, Any]:
        """Return an allow-listed result/evaluation view bound to the sealed artifacts."""

        bindings = self.manifest["authority_bindings"]
        verification = self.evaluation["verification"]
        return {
            "showcase_id": SHOWCASE_ID,
            "task_id": SHOWCASE_ID,
            "scope": "crossroads_conquest",
            "outcome": {
                "winner": dict(self.manifest["winner"]),
                "placements": [dict(value) for value in self.manifest["placements"]],
                "elimination_order": [dict(value) for value in self.manifest["elimination_order"]],
            },
            "verification": {
                "state": "verified",
                "deterministic": True,
                "deterministic_runs": verification["deterministic_runs"],
                "order_rejections": verification["order_rejections"],
                "luna_first_hostile_round": verification["luna_first_hostile_round"],
                "manifest_sha256": self.manifest_sha256,
                "replay_sha256": self.replay_sha256,
                "evaluation_sha256": self.evaluation_sha256,
                "video_sha256": self.video_sha256,
                "normalized_trace_sha256": bindings["normalized_trace_sha256"],
                "final_state_sha256": bindings["final_state_sha256"],
            },
            "factions": [_public_faction(value) for value in self.evaluation["factions"]],
        }


def _validate_manifest(value: Mapping[str, Any]) -> None:
    if set(value) != {
        "authority_bindings",
        "elimination_order",
        "entrants",
        "evaluation",
        "placements",
        "public_timeline",
        "replay",
        "schema",
        "schema_version",
        "showcase_id",
        "tagline",
        "task_id",
        "title",
        "verified",
        "video",
        "winner",
    }:
        _invalid_manifest()
    if (
        value.get("schema") != MANIFEST_SCHEMA
        or value.get("schema_version") != 1
        or value.get("showcase_id") != SHOWCASE_ID
        or value.get("task_id") != SHOWCASE_ID
        or value.get("verified") is not True
    ):
        _invalid_manifest()
    _public_text(value.get("title"))
    _public_text(value.get("tagline"))
    _validate_entrants(value.get("entrants"))
    _validate_authority_bindings(value.get("authority_bindings"))
    _validate_outcome(value)
    _asset_spec(value.get("replay"), {"path", "sha256"}, "crossroads-conquest-demo.replay.json")
    _asset_spec(value.get("evaluation"), {"path", "sha256"}, "evaluation.json")
    _validate_video(value.get("video"))
    _validate_timeline(value.get("public_timeline"))


def _validate_entrants(raw: Any) -> None:
    if not isinstance(raw, list) or len(raw) != len(_ENTRANTS):
        _invalid_manifest()
    for entrant, expected in zip(raw, _ENTRANTS):
        item = _mapping(entrant)
        if set(item) != {
            "color",
            "display_name",
            "entrant_id",
            "faction_id",
            "glyph",
            "policy_id",
        }:
            _invalid_manifest()
        participant_id, faction_id, display_name, glyph, color = expected
        if item != {
            "entrant_id": participant_id,
            "faction_id": faction_id,
            "display_name": display_name,
            "glyph": glyph,
            "color": color,
            "policy_id": POLICY_ID,
        }:
            _invalid_manifest()


def _validate_authority_bindings(raw: Any) -> None:
    value = _mapping(raw)
    if set(value) != {
        "final_state_sha256",
        "map_id",
        "map_sha256",
        "normalized_trace_sha256",
        "policy_id",
        "policy_sha256",
        "protocol",
        "rules_id",
        "rules_sha256",
        "seed",
    }:
        _invalid_manifest()
    if (
        value.get("protocol") != "world-arena/0.4"
        or value.get("seed") != SEED
        or value.get("policy_id") != POLICY_ID
        or value.get("map_id") != "tri_13_v1"
        or value.get("rules_id") != "arena-v0.4"
    ):
        _invalid_manifest()
    for key in (
        "final_state_sha256",
        "map_sha256",
        "normalized_trace_sha256",
        "policy_sha256",
        "rules_sha256",
    ):
        _sha256(value.get(key))


def _validate_outcome(manifest: Mapping[str, Any]) -> None:
    winner = _mapping(manifest.get("winner"))
    if winner != {
        "entrant_id": "participant_1",
        "faction_id": "luna",
        "display_name": "Luna",
    }:
        _invalid_manifest()
    placements = manifest.get("placements")
    expected_placements = (
        (1, "participant_1", "luna", "Luna"),
        (2, "participant_0", "sol", "Sol"),
        (3, "participant_2", "terra", "Terra"),
    )
    if not isinstance(placements, list) or len(placements) != 3:
        _invalid_manifest()
    for value, expected in zip(placements, expected_placements):
        item = _mapping(value)
        if set(item) != {"display_name", "entrant_id", "faction_id", "placement"}:
            _invalid_manifest()
        if (
            item.get("placement"),
            item.get("entrant_id"),
            item.get("faction_id"),
            item.get("display_name"),
        ) != expected:
            _invalid_manifest()
    eliminations = manifest.get("elimination_order")
    if not isinstance(eliminations, list) or len(eliminations) != 2:
        _invalid_manifest()
    for value, expected in zip(eliminations, ((1, "terra", "sol"), (2, "sol", "luna"))):
        item = _mapping(value)
        if set(item) != {"eliminated_by", "event_id", "faction_id", "order", "round"}:
            _invalid_manifest()
        if (item.get("order"), item.get("faction_id"), item.get("eliminated_by")) != expected:
            _invalid_manifest()
        round_number = item.get("round")
        if not _integer(round_number) or not 1 <= round_number <= 29:
            _invalid_manifest()
        _public_text(item.get("event_id"), limit=80)
    if eliminations[0]["round"] >= eliminations[1]["round"]:
        _invalid_manifest()


def _validate_video(raw: Any) -> None:
    value = _mapping(raw)
    if set(value) != {
        "audio_channels",
        "audio_codec",
        "codec",
        "duration_seconds",
        "fast_start",
        "fps",
        "height",
        "path",
        "pixel_format",
        "sha256",
        "size_bytes",
        "width",
    }:
        _invalid_manifest()
    _file_name(value.get("path"), expected="crossroads-conquest-broadcast.mp4")
    _sha256(value.get("sha256"))
    if (
        value.get("duration_seconds") != 180
        or value.get("fps") != 30
        or value.get("width") != 1920
        or value.get("height") != 1080
        or value.get("codec") != "h264"
        or value.get("pixel_format") != "yuv420p"
        or value.get("audio_codec") != "aac"
        or value.get("audio_channels") != 2
        or value.get("fast_start") is not True
        or not _integer(value.get("size_bytes"))
        or not 0 < value["size_bytes"] <= MAX_VIDEO_BYTES
    ):
        _invalid_manifest()


def _validate_timeline(raw: Any) -> None:
    if not isinstance(raw, list) or len(raw) != len(_TIMELINE_WINDOWS):
        _invalid_manifest()
    previous = -1.0
    for raw_item, expected in zip(raw, _TIMELINE_WINDOWS):
        item = _mapping(raw_item)
        if set(item) != {
            "at_seconds",
            "beat_id",
            "editorial",
            "event_id",
            "frame_index",
            "kind",
            "label",
            "round",
        }:
            _invalid_manifest()
        expected_id, window_start, window_end, editorial = expected
        beat_id = item.get("beat_id")
        at_seconds = item.get("at_seconds")
        round_number = item.get("round")
        frame_index = item.get("frame_index")
        event_id = item.get("event_id")
        if (
            beat_id != expected_id
            or not _number(at_seconds)
            or not window_start <= at_seconds < window_end
            or at_seconds < previous
            or not _integer(round_number)
            or not 0 <= round_number <= 29
            or not _integer(frame_index)
            or frame_index < 0
            or item.get("editorial") is not editorial
        ):
            _invalid_manifest()
        if editorial:
            if event_id != "":
                _invalid_manifest()
        else:
            _public_text(event_id, limit=80)
        _public_text(item.get("kind"), limit=48)
        _public_text(item.get("label"))
        previous = at_seconds


def _validate_replay_binding(replay: Mapping[str, Any], manifest: Mapping[str, Any]) -> None:
    if set(replay) != {
        "authority",
        "duration_seconds",
        "events",
        "initial_snapshot",
        "map_id",
        "policy",
        "protocol",
        "public_timeline",
        "result",
        "rounds",
        "rules_id",
        "schema",
        "seed",
        "showcase_id",
        "task_id",
    }:
        raise CrossroadsShowcaseError("crossroads_showcase_replay_invalid")
    bindings = manifest["authority_bindings"]
    if (
        replay.get("schema") != "worldarena/crossroads-conquest-replay/1"
        or replay.get("showcase_id") != SHOWCASE_ID
        or replay.get("task_id") != SHOWCASE_ID
        or replay.get("protocol") != bindings["protocol"]
        or replay.get("map_id") != bindings["map_id"]
        or replay.get("rules_id") != bindings["rules_id"]
        or replay.get("seed") != SEED
        or replay.get("duration_seconds") != 180
        or replay.get("public_timeline") != manifest["public_timeline"]
        or not isinstance(replay.get("initial_snapshot"), dict)
    ):
        raise CrossroadsShowcaseError("crossroads_showcase_replay_invalid")
    policy = replay.get("policy")
    authority = replay.get("authority")
    if (
        not isinstance(policy, dict)
        or set(policy) != {"id", "sha256"}
        or policy.get("id") != POLICY_ID
        or policy.get("sha256") != bindings["policy_sha256"]
        or not isinstance(authority, dict)
        or set(authority) != {"completed_rounds", "final_state_sha256", "normalized_trace_sha256"}
        or authority.get("completed_rounds") != 29
        or authority.get("normalized_trace_sha256") != bindings["normalized_trace_sha256"]
        or authority.get("final_state_sha256") != bindings["final_state_sha256"]
    ):
        raise CrossroadsShowcaseError("crossroads_showcase_replay_invalid")
    rounds = replay.get("rounds")
    if not isinstance(rounds, list) or len(rounds) != authority["completed_rounds"]:
        raise CrossroadsShowcaseError("crossroads_showcase_replay_invalid")
    for expected_round, raw_round in enumerate(rounds, start=1):
        if not isinstance(raw_round, dict) or raw_round.get("round") != expected_round:
            raise CrossroadsShowcaseError("crossroads_showcase_replay_invalid")
        plans = raw_round.get("plans")
        if (
            not isinstance(plans, dict)
            or set(plans) != {"luna", "sol", "terra"}
            or any(not isinstance(plans[faction], list) for faction in plans)
            or not isinstance(raw_round.get("frames"), list)
        ):
            raise CrossroadsShowcaseError("crossroads_showcase_replay_invalid")
    events = replay.get("events")
    if (
        not isinstance(events, list)
        or not events
        or any(not isinstance(item, dict) for item in events)
    ):
        raise CrossroadsShowcaseError("crossroads_showcase_replay_invalid")
    event_ids = {item.get("event_id", item.get("id")) for item in events}
    if any(
        item["event_id"] and item["event_id"] not in event_ids
        for item in manifest["public_timeline"]
    ):
        raise CrossroadsShowcaseError("crossroads_showcase_replay_invalid")
    result = replay.get("result")
    if not isinstance(result, dict) or result.get("winner") != "luna":
        raise CrossroadsShowcaseError("crossroads_showcase_replay_invalid")
    result_placements = result.get("placements")
    if not isinstance(result_placements, list) or [
        item.get("faction_id") if isinstance(item, dict) else item for item in result_placements
    ] != ["luna", "sol", "terra"]:
        raise CrossroadsShowcaseError("crossroads_showcase_replay_invalid")
    result_eliminations = result.get("elimination_order")
    if not isinstance(result_eliminations, list) or [
        item.get("faction_id") if isinstance(item, dict) else item for item in result_eliminations
    ] != ["terra", "sol"]:
        raise CrossroadsShowcaseError("crossroads_showcase_replay_invalid")


def _validate_evaluation(value: Mapping[str, Any], manifest: Mapping[str, Any]) -> None:
    if set(value) != {
        "derived_from",
        "factions",
        "outcome",
        "schema",
        "showcase_id",
        "verification",
    }:
        raise CrossroadsShowcaseError("crossroads_showcase_evaluation_invalid")
    if value.get("schema") != EVALUATION_SCHEMA or value.get("showcase_id") != SHOWCASE_ID:
        raise CrossroadsShowcaseError("crossroads_showcase_evaluation_invalid")
    _reject_private_fields(value)
    derived = _mapping_evaluation(value.get("derived_from"))
    if set(derived) != {"final_state_sha256", "normalized_trace_sha256", "replay_sha256"}:
        raise CrossroadsShowcaseError("crossroads_showcase_evaluation_invalid")
    if (
        derived.get("replay_sha256") != manifest["replay"]["sha256"]
        or derived.get("normalized_trace_sha256")
        != manifest["authority_bindings"]["normalized_trace_sha256"]
        or derived.get("final_state_sha256") != manifest["authority_bindings"]["final_state_sha256"]
    ):
        raise CrossroadsShowcaseError("crossroads_showcase_evaluation_invalid")
    outcome = _mapping_evaluation(value.get("outcome"))
    if (
        outcome.get("winner") != manifest["winner"]
        or outcome.get("placements") != manifest["placements"]
        or outcome.get("elimination_order") != manifest["elimination_order"]
    ):
        raise CrossroadsShowcaseError("crossroads_showcase_evaluation_invalid")
    verification = _mapping_evaluation(value.get("verification"))
    required = {"deterministic_runs", "luna_first_hostile_round", "order_rejections"}
    if not required.issubset(verification):
        raise CrossroadsShowcaseError("crossroads_showcase_evaluation_invalid")
    if (
        verification["deterministic_runs"] != 2
        or verification["order_rejections"] != 0
        or verification["luna_first_hostile_round"] != manifest["elimination_order"][0]["round"] + 1
    ):
        raise CrossroadsShowcaseError("crossroads_showcase_evaluation_invalid")
    factions = value.get("factions")
    if not isinstance(factions, list) or len(factions) != 3:
        raise CrossroadsShowcaseError("crossroads_showcase_evaluation_invalid")
    by_id = {item["faction_id"]: item for item in map(_mapping_evaluation, factions)}
    if set(by_id) != {"sol", "luna", "terra"}:
        raise CrossroadsShowcaseError("crossroads_showcase_evaluation_invalid")
    for faction_id, placement in (("luna", 1), ("sol", 2), ("terra", 3)):
        if by_id[faction_id].get("placement") != placement:
            raise CrossroadsShowcaseError("crossroads_showcase_evaluation_invalid")


def _public_faction(raw: Any) -> Mapping[str, Any]:
    item = _mapping_evaluation(raw)
    allowed = (
        "core_hp",
        "eliminated_by",
        "eliminated_round",
        "faction_id",
        "placement",
        "strongholds_destroyed",
    )
    return {key: item[key] for key in allowed if key in item}


def _asset_spec(raw: Any, fields: set[str], expected_path: str) -> None:
    item = _mapping(raw)
    if set(item) != fields:
        _invalid_manifest()
    _file_name(item.get("path"), expected=expected_path)
    _sha256(item.get("sha256"))


def _mapping(value: Any) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        _invalid_manifest()
    return value


def _mapping_evaluation(value: Any) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise CrossroadsShowcaseError("crossroads_showcase_evaluation_invalid")
    return value


def _file_name(value: Any, *, expected: str) -> None:
    if (
        not isinstance(value, str)
        or value != expected
        or Path(value).name != value
        or value in {".", ".."}
    ):
        _invalid_manifest()


def _sha256(value: Any) -> None:
    if (
        not isinstance(value, str)
        or len(value) != _SHA256_LENGTH
        or any(character not in "0123456789abcdef" for character in value)
    ):
        _invalid_manifest()


def _public_text(value: Any, *, limit: int = _PUBLIC_TEXT_LIMIT) -> None:
    if not isinstance(value, str) or not value or len(value) > limit or "\x00" in value:
        _invalid_manifest()
    lowered = value.casefold()
    if any(term.replace("_", " ") in lowered or term in lowered for term in _PRIVATE_TERMS):
        _invalid_manifest()


def _reject_private_fields(value: Any) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            lowered = str(key).casefold()
            if any(term in lowered for term in _PRIVATE_TERMS):
                raise CrossroadsShowcaseError("crossroads_showcase_evaluation_invalid")
            _reject_private_fields(child)
    elif isinstance(value, list):
        for child in value:
            _reject_private_fields(child)
    elif isinstance(value, str):
        lowered = value.casefold()
        if any(term.replace("_", " ") in lowered or term in lowered for term in _PRIVATE_TERMS):
            raise CrossroadsShowcaseError("crossroads_showcase_evaluation_invalid")


def _integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _is_fast_start_mp4(path: Path, file_size: int) -> bool:
    """Verify an MP4 signature and that its movie atom precedes media data."""

    if file_size < 24:
        return False
    offset = 0
    atom_order: list[bytes] = []
    with path.open("rb") as stream:
        while offset + 8 <= file_size and len(atom_order) < 32:
            stream.seek(offset)
            header = stream.read(16)
            if len(header) < 8:
                return False
            size = int.from_bytes(header[:4], "big")
            atom_type = header[4:8]
            header_size = 8
            if size == 1:
                if len(header) < 16:
                    return False
                size = int.from_bytes(header[8:16], "big")
                header_size = 16
            elif size == 0:
                size = file_size - offset
            if size < header_size or offset + size > file_size:
                return False
            atom_order.append(atom_type)
            offset += size
    return (
        b"ftyp" in atom_order
        and b"moov" in atom_order
        and (b"mdat" not in atom_order or atom_order.index(b"moov") < atom_order.index(b"mdat"))
    )


def _invalid_manifest() -> None:
    raise CrossroadsShowcaseError("crossroads_showcase_manifest_invalid")


__all__ = [
    "ASSET_DIRECTORY",
    "CachedCrossroadsShowcase",
    "CrossroadsShowcaseError",
    "MAX_VIDEO_BYTES",
    "SHOWCASE_ID",
]
