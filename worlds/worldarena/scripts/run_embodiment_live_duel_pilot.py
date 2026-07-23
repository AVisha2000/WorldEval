#!/usr/bin/env python3
"""Run one fail-closed, verified live paired-duel pilot.

Preflight is local and network-free. Live execution is available only through the explicit
``--execute-live`` switch and requires an exact provider-call budget acknowledgement. Provider
credentials are accepted from environment variables only and are never written to the report.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import os
import re
import shutil
import socket
import tempfile
import time
from pathlib import Path
from typing import Any, Awaitable, Callable, Mapping

import uvicorn
from fastapi import FastAPI, WebSocket
from genesis_arena.embodiment.artifacts import verify_offline_replay_with_godot
from genesis_arena.embodiment.duel.evidence import (
    DuelSeriesEvidenceBundle,
    verify_offline_paired_duel,
)
from genesis_arena.embodiment.duel.live_runtime import default_duel_series_service
from genesis_arena.embodiment.protocol import (
    EmbodimentProtocolPackage,
    canonical_json_bytes,
    strict_json_loads,
)
from genesis_arena.embodiment.transport import ManagedWebSocketEndpoint
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
REPORT_FORMAT = "llm-controller/live-paired-duel/1.0.0"
PROVIDERS = ("openai", "anthropic", "gemini")
MAX_PILOT_PROVIDER_CALLS = 720
_MODEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$")
_KEY_ENV = {
    "a": "WORLDARENA_DUEL_A_API_KEY",
    "b": "WORLDARENA_DUEL_B_API_KEY",
}
_MODEL_ENV = {
    "a": "WORLDARENA_DUEL_A_MODEL",
    "b": "WORLDARENA_DUEL_B_MODEL",
}


class PilotError(RuntimeError):
    """A stable, credential-free pilot failure."""


class _Gateway:
    def __init__(self) -> None:
        self.endpoint = ManagedWebSocketEndpoint()
        self.app = FastAPI()
        self.listener: socket.socket | None = None
        self.server: uvicorn.Server | None = None
        self.task: asyncio.Task[None] | None = None
        self.port = 0

        @self.app.websocket("/ws/embodiment/{ticket}")
        async def attach(ticket: str, websocket: WebSocket) -> None:
            await self.endpoint.handle(ticket, websocket)

    async def __aenter__(self) -> _Gateway:
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(128)
        listener.setblocking(False)
        self.listener = listener
        self.port = int(listener.getsockname()[1])
        self.server = uvicorn.Server(
            uvicorn.Config(self.app, log_level="critical", lifespan="off", access_log=False)
        )
        self.task = asyncio.create_task(self.server.serve(sockets=[listener]))
        while not self.server.started:
            if self.task.done():
                raise PilotError("gateway_start_failed")
            await asyncio.sleep(0)
        return self

    async def __aexit__(self, *_: object) -> None:
        if self.server is not None:
            self.server.should_exit = True
        if self.task is not None:
            try:
                await asyncio.wait_for(self.task, 10)
            except asyncio.TimeoutError:
                assert self.server is not None
                self.server.force_exit = True
                await asyncio.wait_for(self.task, 5)
        if self.listener is not None:
            self.listener.close()


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--preflight", action="store_true")
    action.add_argument("--execute-live", action="store_true")
    parser.add_argument("--provider-a", choices=PROVIDERS, default="openai")
    parser.add_argument("--provider-b", choices=PROVIDERS, default="openai")
    parser.add_argument("--model-a")
    parser.add_argument("--model-b")
    parser.add_argument("--reuse-entrant-a-key", action="store_true")
    parser.add_argument("--seed", type=int, default=20260721)
    parser.add_argument("--provider-timeout-s", type=float, default=45.0)
    parser.add_argument("--series-timeout-s", type=float, default=1800.0)
    parser.add_argument("--max-live-provider-calls", type=int, default=MAX_PILOT_PROVIDER_CALLS)
    parser.add_argument("--confirm-max-live-provider-calls", type=int)
    parser.add_argument(
        "--output-dir", type=Path, default=ROOT / "artifacts" / "live-duel-pilot"
    )
    parser.add_argument("--godot-executable", type=Path, default=GODOT)
    return parser


def _resolved_models(arguments: argparse.Namespace, environ: Mapping[str, str]) -> dict[str, str]:
    return {
        seat: str(getattr(arguments, f"model_{seat}") or environ.get(_MODEL_ENV[seat], ""))
        for seat in ("a", "b")
    }


def pilot_preflight(
    arguments: argparse.Namespace, *, environ: Mapping[str, str] | None = None
) -> tuple[str, ...]:
    """Return stable readiness labels without constructing a provider or network client."""

    env = os.environ if environ is None else environ
    missing: list[str] = []
    if not arguments.godot_executable.is_file():
        missing.append("pinned_godot_executable")
    models = _resolved_models(arguments, env)
    for seat in ("a", "b"):
        if _MODEL.fullmatch(models[seat]) is None:
            missing.append(_MODEL_ENV[seat])
    if not env.get(_KEY_ENV["a"]):
        missing.append(_KEY_ENV["a"])
    if arguments.reuse_entrant_a_key and arguments.provider_a != arguments.provider_b:
        missing.append("same_provider_required_for_key_reuse")
    if not arguments.reuse_entrant_a_key and not env.get(_KEY_ENV["b"]):
        missing.append(_KEY_ENV["b"])
    if isinstance(arguments.seed, bool) or arguments.seed < 0:
        missing.append("valid_seed")
    if not 4 <= arguments.max_live_provider_calls <= MAX_PILOT_PROVIDER_CALLS:
        missing.append("bounded_provider_call_budget")
    if arguments.provider_timeout_s <= 0 or arguments.series_timeout_s <= 0:
        missing.append("positive_timeouts")
    if arguments.output_dir.exists():
        missing.append("unused_output_dir")
    if (
        arguments.execute_live
        and arguments.confirm_max_live_provider_calls != arguments.max_live_provider_calls
    ):
        missing.append("matching_provider_call_budget_acknowledgement")
    return tuple(missing)


async def _wait_for_terminal(service: Any, series_id: str, timeout_s: float) -> Mapping[str, Any]:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        status = await service.status(series_id)
        if status.get("state") in ("completed", "failed", "cancelled"):
            return await service.result(series_id)
        await asyncio.sleep(0.25)
    await service.cancel(series_id)
    raise PilotError("series_timeout")


def _mapping(value: object, failure: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise PilotError(failure)
    return value


def _sequence(value: object, failure: str) -> list[Any] | tuple[Any, ...]:
    if not isinstance(value, (list, tuple)):
        raise PilotError(failure)
    return value


async def _collect_verified_evidence(
    service: Any,
    series_id: str,
    terminal: Mapping[str, Any],
    arguments: argparse.Namespace,
    package: EmbodimentProtocolPackage,
    godot_verifier: Callable[..., Awaitable[Mapping[str, Any]]],
) -> tuple[dict[str, Any], bytes, bytes]:
    outcome = _mapping(terminal.get("result"), "pair_result_missing")
    legs = _sequence(outcome.get("legs"), "pair_legs_invalid")
    if (
        terminal.get("state") != "completed"
        or outcome.get("status") != "complete"
        or outcome.get("rerun_required") is not False
        or len(legs) != 2
    ):
        raise PilotError("pair_not_complete")

    public_value = await service.replay(series_id)
    protected_value = await service.protected_bundle(series_id)
    public_bytes = public_value.bundle_bytes
    protected_bytes = protected_value.bundle_bytes
    public_pair = DuelSeriesEvidenceBundle.verify(public_bytes)
    protected_pair = DuelSeriesEvidenceBundle.verify(protected_bytes)
    identity = (series_id, outcome.get("plan_sha256"))
    if (
        public_pair.layer != "public"
        or protected_pair.layer != "protected"
        or (public_pair.series_id, public_pair.plan_sha256) != identity
        or (protected_pair.series_id, protected_pair.plan_sha256) != identity
        or public_pair.fairness_lock_sha256 != protected_pair.fairness_lock_sha256
    ):
        raise PilotError("pair_evidence_identity_mismatch")

    verified_replays = verify_offline_paired_duel(protected_bytes, package=package)
    config = _mapping(terminal.get("config"), "series_config_missing")
    entrants = _sequence(config.get("entrants"), "series_entrants_invalid")
    entrant_ids = [
        str(_mapping(value, "series_entrant_invalid").get("entrant_id")) for value in entrants
    ]
    if len(entrant_ids) != 2 or len(set(entrant_ids)) != 2:
        raise PilotError("series_entrants_invalid")
    call_counts = {entrant_id: 0 for entrant_id in entrant_ids}
    leg_reports = []
    expected_calls_per_entrant = 0
    initial_episode_ids = {f"ep_{series_id}_a", f"ep_{series_id}_b"}
    final_episode_ids: set[str] = set()

    for index, (leg_value, leg_bundle, replay) in enumerate(
        zip(legs, protected_pair.legs, verified_replays)
    ):
        leg = _mapping(leg_value, "pair_leg_invalid")
        plan = _mapping(leg.get("plan"), "pair_leg_plan_invalid")
        verification = _mapping(leg.get("verification"), "pair_leg_verification_invalid")
        windows = leg.get("windows")
        if (
            isinstance(windows, bool)
            or not isinstance(windows, int)
            or not 1 <= windows <= 180
            or leg.get("provider_failures") != 0
            or verification.get("complete") is not True
            or verification.get("verified") is not True
            or verification.get("outcome") == "void"
        ):
            raise PilotError("pair_leg_not_certifiable")
        episode_id = str(plan.get("episode_id"))
        final_episode_ids.add(episode_id)
        expected_calls_per_entrant += windows
        telemetry = _mapping(
            strict_json_loads(leg_bundle.read("telemetry")), "protected_telemetry_invalid"
        )
        audits = _sequence(telemetry.get("provider_audits"), "provider_audits_invalid")
        if len(audits) != windows * 2:
            raise PilotError("provider_audit_count_mismatch")
        for audit_value in audits:
            audit = _mapping(audit_value, "provider_audit_invalid")
            entrant_id = audit.get("entrant_id")
            result = _mapping(audit.get("result"), "provider_audit_result_invalid")
            if entrant_id not in call_counts or result.get("failure") is not None:
                raise PilotError("provider_audit_failure")
            call_counts[str(entrant_id)] += 1
        seal = await godot_verifier(
            leg_bundle.bundle_bytes,
            package=package,
            godot_executable=arguments.godot_executable,
            project_path=ROOT / "godot",
        )
        if seal.get("final_state_hash") != replay.get("final_state_hash"):
            raise PilotError("godot_replay_seal_mismatch")
        leg_reports.append(
            {
                "episode_id": episode_id,
                "final_state_hash": replay["final_state_hash"],
                "leg_index": index,
                "outcome": verification["outcome"],
                "provider_calls": len(audits),
                "provider_failures": 0,
                "replay_sha256": verification["replay_sha256"],
                "windows": windows,
            }
        )

    if any(value != expected_calls_per_entrant for value in call_counts.values()):
        raise PilotError("entrant_call_balance_mismatch")
    total_calls = sum(call_counts.values())
    if total_calls > arguments.max_live_provider_calls:
        raise PilotError("verified_calls_exceed_budget")

    public_entrants = []
    for value in entrants:
        entrant = _mapping(value, "series_entrant_invalid")
        public_entrants.append(
            {
                "entrant_id": entrant["entrant_id"],
                "model": entrant["model"],
                "provider": entrant["provider"],
                "verified_provider_calls": call_counts[str(entrant["entrant_id"])],
            }
        )
    report = {
        "decision_ticks": 10,
        "draws": outcome.get("draws"),
        "entrant_wins": outcome.get("entrant_wins"),
        "entrants": public_entrants,
        "fairness_lock_sha256": protected_pair.fairness_lock_sha256,
        "legs": leg_reports,
        "max_live_provider_calls": arguments.max_live_provider_calls,
        "mode": "model-duel-v0",
        "observation_profile": "hybrid-visible-v1",
        "plan_sha256": outcome["plan_sha256"],
        "rerun_occurred": final_episode_ids != initial_episode_ids,
        "seed": arguments.seed,
        "series_id": series_id,
        "status": "complete",
        "task_id": "central-relay-v0",
        "total_verified_provider_calls": total_calls,
        "winner_entrant_id": outcome.get("winner_entrant_id"),
    }
    return report, public_bytes, protected_bytes


EvidenceCollector = Callable[
    [
        Any,
        str,
        Mapping[str, Any],
        argparse.Namespace,
        EmbodimentProtocolPackage,
        Callable[..., Any],
    ],
    Awaitable[tuple[dict[str, Any], bytes, bytes]],
]


async def run_pilot(
    arguments: argparse.Namespace,
    *,
    environ: Mapping[str, str] | None = None,
    service_factory: Callable[..., Any] = default_duel_series_service,
    gateway_factory: Callable[[], Any] = _Gateway,
    evidence_collector: EvidenceCollector = _collect_verified_evidence,
    godot_verifier: Callable[..., Awaitable[Mapping[str, Any]]] = verify_offline_replay_with_godot,
) -> Path:
    """Execute and atomically publish a fully verified paired duel."""

    env = os.environ if environ is None else environ
    missing = pilot_preflight(arguments, environ=env)
    if missing:
        raise PilotError("preflight_failed:" + ",".join(missing))
    output_dir = arguments.output_dir.resolve()
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(
        tempfile.mkdtemp(prefix=f".{output_dir.name}.staging-", dir=output_dir.parent)
    )
    service: Any | None = None
    try:
        models = _resolved_models(arguments, env)
        key_a = env[_KEY_ENV["a"]]
        key_b = key_a if arguments.reuse_entrant_a_key else env[_KEY_ENV["b"]]
        package = EmbodimentProtocolPackage.from_repository(ROOT)
        async with gateway_factory() as gateway:
            service = service_factory(
                repository_root=ROOT,
                godot_executable=arguments.godot_executable,
                godot_project_path=ROOT / "godot",
                gateway_port=gateway.port,
                endpoint=gateway.endpoint,
                provider_timeout_s=arguments.provider_timeout_s,
            )
            created = await service.create(
                entrants=(
                    {
                        "api_key": key_a,
                        "model": models["a"],
                        "provider": arguments.provider_a,
                    },
                    {
                        "api_key": key_b,
                        "model": models["b"],
                        "provider": arguments.provider_b,
                    },
                ),
                seed=arguments.seed,
                max_live_provider_calls=arguments.max_live_provider_calls,
            )
            series_id = str(created["series_id"])
            terminal = await _wait_for_terminal(service, series_id, arguments.series_timeout_s)
            series_report, public_bytes, protected_bytes = await evidence_collector(
                service, series_id, terminal, arguments, package, godot_verifier
            )
        await service.aclose()
        service = None
        public_name = "series.public.json"
        protected_name = "series.protected.json"
        series_report["bundles"] = {
            "protected": {
                "path": protected_name,
                "sha256": hashlib.sha256(protected_bytes).hexdigest(),
            },
            "public": {
                "path": public_name,
                "sha256": hashlib.sha256(public_bytes).hexdigest(),
            },
        }
        report = {"format": REPORT_FORMAT, "series": series_report}
        (staging / public_name).write_bytes(public_bytes)
        (staging / protected_name).write_bytes(protected_bytes)
        (staging / "live-duel-report.json").write_bytes(canonical_json_bytes(report))
        if output_dir.exists():
            raise PilotError("output_dir_became_occupied")
        staging.replace(output_dir)
        return output_dir
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    finally:
        if service is not None:
            await service.aclose()


def main() -> int:
    arguments = _parser().parse_args()
    missing = pilot_preflight(arguments)
    if missing:
        print("LIVE_DUEL_PILOT_NOT_READY " + ",".join(missing))
        return 2
    if arguments.preflight:
        print("LIVE_DUEL_PILOT_READY")
        return 0
    try:
        output = asyncio.run(run_pilot(arguments))
    except Exception as error:
        code = str(error) if isinstance(error, PilotError) else "unexpected_execution_failure"
        print(f"LIVE_DUEL_PILOT_FAILED code={code}")
        return 2
    print(f"LIVE_DUEL_PILOT_COMPLETE output={output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
