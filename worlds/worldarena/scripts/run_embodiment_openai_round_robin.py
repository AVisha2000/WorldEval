#!/usr/bin/env python3
"""Run an atomic Sol/Terra/Luna OpenAI round robin through the paired-duel pilot."""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import math
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Awaitable, Callable, Mapping, Sequence

from genesis_arena.embodiment.protocol import canonical_json_bytes, strict_json_loads

try:
    from scripts.run_embodiment_mvp_certification import validate_live_duel_report
except ModuleNotFoundError:  # Direct `python scripts/...` execution.
    from run_embodiment_mvp_certification import (  # type: ignore[no-redef]
        validate_live_duel_report,
    )

ROOT = Path(__file__).resolve().parents[1]
REPORT_FORMAT = "llm-controller/openai-round-robin/1.0.0"
MANIFEST_FORMAT = "llm-controller/openai-round-robin-manifest/1.0.0"
DUEL_REPORT_FORMAT = "llm-controller/live-paired-duel/1.0.0"
PAIR_MAX_LIVE_PROVIDER_CALLS = 720
AGGREGATE_MAX_LIVE_PROVIDER_CALLS = 2160
ENTRANTS = ("sol", "terra", "luna")
PAIRINGS = (("sol", "terra"), ("sol", "luna"), ("terra", "luna"))
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
_MODEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$")
_DUEL_KEY_ENV_A = "WORLDARENA_DUEL_A_API_KEY"
_MODEL_ENV = {
    "sol": "WORLDARENA_OPENAI_SOL_MODEL",
    "terra": "WORLDARENA_OPENAI_TERRA_MODEL",
    "luna": "WORLDARENA_OPENAI_LUNA_MODEL",
}
_KEY_ENV = ("WORLDARENA_OPENAI_API_KEY", "OPENAI_API_KEY")
_SECRET_NAME = re.compile(r"(?:API[_-]?KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)", re.IGNORECASE)


class TournamentError(RuntimeError):
    """A stable error that is safe to expose without leaking child process output."""


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--preflight", action="store_true")
    action.add_argument("--execute-live", action="store_true")
    parser.add_argument("--sol-model")
    parser.add_argument("--terra-model")
    parser.add_argument("--luna-model")
    parser.add_argument("--seed", type=int, default=20260721)
    parser.add_argument("--provider-timeout-s", type=float, default=45.0)
    parser.add_argument("--series-timeout-s", type=float, default=1800.0)
    parser.add_argument("--confirm-aggregate-max-live-provider-calls", type=int)
    parser.add_argument(
        "--output-dir", type=Path, default=ROOT / "artifacts" / "openai-round-robin"
    )
    parser.add_argument("--godot-executable", type=Path, default=GODOT)
    parser.add_argument("--python-executable", type=Path, default=Path(sys.executable))
    return parser


def _models(arguments: argparse.Namespace, environ: Mapping[str, str]) -> dict[str, str]:
    return {
        entrant: str(
            getattr(arguments, f"{entrant}_model") or environ.get(_MODEL_ENV[entrant], "")
        )
        for entrant in ENTRANTS
    }


def _api_key(environ: Mapping[str, str]) -> str | None:
    for name in _KEY_ENV:
        value = environ.get(name)
        if value:
            return value
    return None


def tournament_preflight(
    arguments: argparse.Namespace, *, environ: Mapping[str, str] | None = None
) -> tuple[str, ...]:
    """Check local paths and environment presence without starting any subprocess or network IO."""

    env = os.environ if environ is None else environ
    missing: list[str] = []
    if PAIRINGS != (("sol", "terra"), ("sol", "luna"), ("terra", "luna")):
        missing.append("fixed_three_pair_schedule")
    if not arguments.python_executable.is_file():
        missing.append("python_executable")
    if not arguments.godot_executable.is_file():
        missing.append("pinned_godot_executable")
    if not (ROOT / "scripts" / "run_embodiment_live_duel_pilot.py").is_file():
        missing.append("paired_duel_pilot")
    models = _models(arguments, env)
    for entrant in ENTRANTS:
        if _MODEL.fullmatch(models[entrant]) is None:
            missing.append(_MODEL_ENV[entrant])
    if len(set(models.values())) != len(ENTRANTS):
        missing.append("three_distinct_models")
    if _api_key(env) is None:
        missing.append("/".join(_KEY_ENV))
    if (
        isinstance(arguments.seed, bool)
        or not isinstance(arguments.seed, int)
        # The fixed schedule derives two later seeds. Reject the entire run before the
        # first paid call if any derived seed would exceed the strict integer range.
        or not 0 <= arguments.seed <= 9_007_199_254_740_987
    ):
        missing.append("valid_three_pair_seed_range")
    if (
        isinstance(arguments.provider_timeout_s, bool)
        or isinstance(arguments.series_timeout_s, bool)
        or not math.isfinite(arguments.provider_timeout_s)
        or not math.isfinite(arguments.series_timeout_s)
        or arguments.provider_timeout_s <= 0
        or arguments.series_timeout_s <= 0
    ):
        missing.append("positive_timeouts")
    if arguments.output_dir.exists():
        missing.append("unused_output_dir")
    if (
        arguments.execute_live
        and arguments.confirm_aggregate_max_live_provider_calls
        != AGGREGATE_MAX_LIVE_PROVIDER_CALLS
    ):
        missing.append("exact_aggregate_provider_call_budget_acknowledgement")
    return tuple(missing)


async def _subprocess_runner(command: Sequence[str], environ: Mapping[str, str]) -> int:
    process = await asyncio.create_subprocess_exec(
        *command,
        env=dict(environ),
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL,
    )
    return await process.wait()


SubprocessRunner = Callable[[Sequence[str], Mapping[str, str]], Awaitable[int]]


def _child_environment(environ: Mapping[str, str], api_key: str) -> dict[str, str]:
    child = {name: value for name, value in environ.items() if _SECRET_NAME.search(name) is None}
    child[_DUEL_KEY_ENV_A] = api_key
    return child


def _command(
    arguments: argparse.Namespace,
    *,
    model_a: str,
    model_b: str,
    output_dir: Path,
    seed: int,
) -> tuple[str, ...]:
    return (
        str(arguments.python_executable),
        str(ROOT / "scripts" / "run_embodiment_live_duel_pilot.py"),
        "--execute-live",
        "--provider-a",
        "openai",
        "--provider-b",
        "openai",
        "--model-a",
        model_a,
        "--model-b",
        model_b,
        "--reuse-entrant-a-key",
        "--seed",
        str(seed),
        "--provider-timeout-s",
        str(arguments.provider_timeout_s),
        "--series-timeout-s",
        str(arguments.series_timeout_s),
        "--max-live-provider-calls",
        str(PAIR_MAX_LIVE_PROVIDER_CALLS),
        "--confirm-max-live-provider-calls",
        str(PAIR_MAX_LIVE_PROVIDER_CALLS),
        "--godot-executable",
        str(arguments.godot_executable),
        "--output-dir",
        str(output_dir),
    )


def _mapping(value: object, error: str) -> Mapping[str, object]:
    if not isinstance(value, Mapping):
        raise TournamentError(error)
    return value


def _list(value: object, error: str) -> list[object]:
    if not isinstance(value, list):
        raise TournamentError(error)
    return value


def _verify_bundle(pair_dir: Path, value: object, expected_path: str) -> None:
    reference = _mapping(value, "pair_bundle_reference_invalid")
    if reference.get("path") != expected_path:
        raise TournamentError("pair_bundle_path_invalid")
    path = pair_dir / expected_path
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != reference.get(
        "sha256"
    ):
        raise TournamentError("pair_bundle_digest_invalid")


def _verified_pair_summary(
    pair_dir: Path,
    *,
    aliases: tuple[str, str],
    models: tuple[str, str],
    seed: int,
) -> dict[str, object]:
    report_path = pair_dir / "live-duel-report.json"
    try:
        report_bytes = report_path.read_bytes()
        report = strict_json_loads(report_bytes)
    except Exception as error:
        raise TournamentError("pair_report_unreadable") from error
    if canonical_json_bytes(report) != report_bytes:
        raise TournamentError("pair_report_not_canonical")
    root = _mapping(report, "pair_report_invalid")
    series = _mapping(root.get("series"), "pair_series_invalid")
    entrants = _list(series.get("entrants"), "pair_entrants_invalid")
    legs = _list(series.get("legs"), "pair_legs_invalid")
    if (
        root.get("format") != DUEL_REPORT_FORMAT
        or series.get("status") != "complete"
        or series.get("mode") != "model-duel-v0"
        or series.get("seed") != seed
        or series.get("max_live_provider_calls") != PAIR_MAX_LIVE_PROVIDER_CALLS
        or len(entrants) != 2
        or len(legs) != 2
    ):
        raise TournamentError("pair_report_contract_mismatch")
    for index, entrant_value in enumerate(entrants):
        entrant = _mapping(entrant_value, "pair_entrant_invalid")
        if entrant.get("provider") != "openai" or entrant.get("model") != models[index]:
            raise TournamentError("pair_entrant_identity_mismatch")
    for leg_value in legs:
        leg = _mapping(leg_value, "pair_leg_invalid")
        if leg.get("provider_failures") != 0:
            raise TournamentError("pair_provider_failure")
    total_calls = series.get("total_verified_provider_calls")
    if (
        isinstance(total_calls, bool)
        or not isinstance(total_calls, int)
        or not 4 <= total_calls <= PAIR_MAX_LIVE_PROVIDER_CALLS
    ):
        raise TournamentError("pair_provider_call_count_invalid")
    bundles = _mapping(series.get("bundles"), "pair_bundles_invalid")
    _verify_bundle(pair_dir, bundles.get("public"), "series.public.json")
    _verify_bundle(pair_dir, bundles.get("protected"), "series.protected.json")

    certification_gate = validate_live_duel_report(report_path)
    if certification_gate.get("passed") is not True:
        code = certification_gate.get("code")
        if not isinstance(code, str) or not code:
            code = "live_duel_report_invalid"
        raise TournamentError(f"pair_certification_validation_failed:{code}")

    entrant_ids = [
        str(_mapping(value, "pair_entrant_invalid").get("entrant_id")) for value in entrants
    ]
    if entrant_ids != ["entrant_0", "entrant_1"]:
        raise TournamentError("pair_entrant_identity_mismatch")
    winner_id = series.get("winner_entrant_id")
    if winner_id is not None and winner_id not in entrant_ids:
        raise TournamentError("pair_winner_invalid")
    wins = _list(series.get("entrant_wins"), "pair_win_counts_invalid")
    draws = series.get("draws")
    if (
        len(wins) != 2
        or any(isinstance(value, bool) or not isinstance(value, int) for value in wins)
        or isinstance(draws, bool)
        or not isinstance(draws, int)
        or sum(wins) + draws != 2
    ):
        raise TournamentError("pair_score_invalid")
    series_id = series.get("series_id")
    if not isinstance(series_id, str) or _MODEL.fullmatch(series_id) is None:
        raise TournamentError("pair_series_id_invalid")
    return {
        "draws": draws,
        "entrant_wins": wins,
        "entrants": list(aliases),
        "pair_id": f"{aliases[0]}-vs-{aliases[1]}",
        "report_path": f"pairs/{aliases[0]}-vs-{aliases[1]}/live-duel-report.json",
        "report_sha256": hashlib.sha256(report_bytes).hexdigest(),
        "seed": seed,
        "series_id": series_id,
        "total_verified_provider_calls": total_calls,
        "winner": None if winner_id is None else aliases[entrant_ids.index(winner_id)],
    }


async def run_tournament(
    arguments: argparse.Namespace,
    *,
    environ: Mapping[str, str] | None = None,
    runner: SubprocessRunner = _subprocess_runner,
) -> Path:
    """Run all three pairs and publish only a fully validated tournament directory."""

    env = os.environ if environ is None else environ
    missing = tournament_preflight(arguments, environ=env)
    if missing:
        raise TournamentError("preflight_failed:" + ",".join(missing))
    api_key = _api_key(env)
    assert api_key is not None
    models = _models(arguments, env)
    output_dir = arguments.output_dir.resolve()
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(
        tempfile.mkdtemp(prefix=f".{output_dir.name}.staging-", dir=output_dir.parent)
    )
    try:
        pairs_root = staging / "pairs"
        pairs_root.mkdir()
        pair_reports = []
        child_env = _child_environment(env, api_key)
        for index, aliases in enumerate(PAIRINGS):
            pair_id = f"{aliases[0]}-vs-{aliases[1]}"
            pair_dir = pairs_root / pair_id
            seed = arguments.seed + index
            command = _command(
                arguments,
                model_a=models[aliases[0]],
                model_b=models[aliases[1]],
                output_dir=pair_dir,
                seed=seed,
            )
            if await runner(command, child_env) != 0:
                raise TournamentError(f"pair_execution_failed:{pair_id}")
            pair_reports.append(
                _verified_pair_summary(
                    pair_dir,
                    aliases=aliases,
                    models=(models[aliases[0]], models[aliases[1]]),
                    seed=seed,
                )
            )

        total_calls = sum(int(value["total_verified_provider_calls"]) for value in pair_reports)
        if total_calls > AGGREGATE_MAX_LIVE_PROVIDER_CALLS:
            raise TournamentError("aggregate_provider_call_budget_exceeded")
        standings = {
            entrant: {"drawn_legs": 0, "leg_wins": 0, "paired_series_wins": 0}
            for entrant in ENTRANTS
        }
        for pair in pair_reports:
            aliases = pair["entrants"]
            wins = pair["entrant_wins"]
            for index, alias in enumerate(aliases):
                standings[alias]["leg_wins"] += wins[index]
                standings[alias]["drawn_legs"] += pair["draws"]
            winner = pair["winner"]
            if winner is not None:
                standings[winner]["paired_series_wins"] += 1
        report = {
            "aggregate_max_live_provider_calls": AGGREGATE_MAX_LIVE_PROVIDER_CALLS,
            "entrants": [
                {"entrant_id": entrant, "model": models[entrant], "provider": "openai"}
                for entrant in ENTRANTS
            ],
            "format": REPORT_FORMAT,
            "pair_max_live_provider_calls": PAIR_MAX_LIVE_PROVIDER_CALLS,
            "pairings": pair_reports,
            "standings": standings,
            "status": "complete",
            "total_verified_provider_calls": total_calls,
        }
        report_bytes = canonical_json_bytes(report)
        (staging / "round-robin-report.json").write_bytes(report_bytes)
        manifest = {
            "format": MANIFEST_FORMAT,
            "report": {
                "path": "round-robin-report.json",
                "sha256": hashlib.sha256(report_bytes).hexdigest(),
            },
            "status": "complete",
        }
        (staging / "tournament.manifest.json").write_bytes(canonical_json_bytes(manifest))
        if output_dir.exists():
            raise TournamentError("output_dir_became_occupied")
        staging.replace(output_dir)
        return output_dir
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def main() -> int:
    arguments = _parser().parse_args()
    missing = tournament_preflight(arguments)
    if missing:
        print("OPENAI_ROUND_ROBIN_NOT_READY " + ",".join(missing))
        return 2
    if arguments.preflight:
        print("OPENAI_ROUND_ROBIN_READY")
        return 0
    try:
        output = asyncio.run(run_tournament(arguments))
    except Exception as error:
        code = str(error) if isinstance(error, TournamentError) else "unexpected_execution_failure"
        print(f"OPENAI_ROUND_ROBIN_FAILED code={code}")
        return 2
    print(f"OPENAI_ROUND_ROBIN_COMPLETE output={output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
