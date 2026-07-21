"""Session-only lifecycle service for symmetric paired model duels."""

from __future__ import annotations

import asyncio
import re
import secrets
from dataclasses import asdict, dataclass, field
from typing import Awaitable, Callable, Mapping, Tuple

from ..baselines import BASELINE_TIERS
from ..credentials import SessionCredential
from .contracts import DuelEntrant, PairedDuelResult
from .evidence import DuelSeriesEvidenceBundle, DuelSeriesExecution

_PROVIDERS = frozenset(("openai", "anthropic", "gemini", "scripted"))
_MODEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$")


class DuelSeriesNotFoundError(KeyError):
    pass


class DuelSeriesEvidenceNotReadyError(RuntimeError):
    pass


@dataclass(frozen=True)
class DuelSeriesSpec:
    series_id: str
    entrants: Tuple[DuelEntrant, DuelEntrant]
    seed: int
    schedule_nonce: str
    max_live_provider_calls: int = 2160

    @property
    def mode(self) -> str:
        return (
            "scripted-duel-v0"
            if any(entrant.provider == "scripted" for entrant in self.entrants)
            else "model-duel-v0"
        )

    def public_dict(self) -> Mapping[str, object]:
        return {
            "entrants": [entrant.as_dict() for entrant in self.entrants],
            "max_live_provider_calls": self.max_live_provider_calls,
            "schedule_nonce": self.schedule_nonce,
            "seed": self.seed,
            "series_id": self.series_id,
        }


SeriesExecutor = Callable[
    [
        DuelSeriesSpec,
        Mapping[str, SessionCredential],
        asyncio.Event,
    ],
    Awaitable[DuelSeriesExecution],
]


@dataclass
class _Record:
    spec: DuelSeriesSpec
    credentials: Mapping[str, SessionCredential] = field(repr=False)
    state: str = "queued"
    result: PairedDuelResult | None = None
    public_evidence: DuelSeriesEvidenceBundle | None = None
    protected_evidence: DuelSeriesEvidenceBundle | None = None
    failure: str | None = None
    cancel_event: asyncio.Event = field(default_factory=asyncio.Event)
    task: asyncio.Task[None] | None = None


class DuelSeriesService:
    def __init__(self, executor: SeriesExecutor) -> None:
        self._executor = executor
        self._records: dict[str, _Record] = {}
        self._lock = asyncio.Lock()

    async def create(
        self,
        *,
        entrants: tuple[Mapping[str, object], Mapping[str, object]],
        seed: int,
        max_live_provider_calls: int = 2160,
    ) -> Mapping[str, object]:
        if isinstance(seed, bool) or not isinstance(seed, int) or seed < 0:
            raise ValueError("seed is invalid")
        if not isinstance(entrants, tuple) or len(entrants) != 2:
            raise ValueError("exactly two entrants are required")
        if (
            isinstance(max_live_provider_calls, bool)
            or not isinstance(max_live_provider_calls, int)
            or not 1 <= max_live_provider_calls <= 2160
        ):
            raise ValueError("max_live_provider_calls is invalid")
        series_id = f"series_{secrets.token_hex(12)}"
        public_entrants = []
        credential_values: list[str | None] = []
        for index, value in enumerate(entrants):
            if not isinstance(value, Mapping):
                raise ValueError("entrant shape is invalid")
            provider = value.get("provider")
            model = value.get("model")
            expected_fields = (
                {"provider", "model"}
                if provider == "scripted"
                else {
                    "provider",
                    "model",
                    "api_key",
                }
            )
            if set(value) != expected_fields:
                raise ValueError("entrant shape is invalid")
            key = value.get("api_key")
            if (
                provider not in _PROVIDERS
                or not isinstance(model, str)
                or _MODEL.fullmatch(model) is None
            ):
                raise ValueError("entrant provider or model is invalid")
            if provider == "scripted" and model not in BASELINE_TIERS:
                raise ValueError("scripted baseline tier is invalid")
            if provider != "scripted" and (not isinstance(key, str) or not key):
                raise ValueError("entrant credential is invalid")
            public_entrants.append(DuelEntrant(f"entrant_{index}", str(provider), model))
            credential_values.append(key)

        if sum(entrant.provider == "scripted" for entrant in public_entrants) > 1:
            raise ValueError("at most one scripted entrant is allowed")

        credentials: dict[str, SessionCredential] = {}
        task_owns_credentials = False
        try:
            for entrant, value in zip(public_entrants, credential_values):
                if value is not None:
                    credentials[entrant.entrant_id] = SessionCredential(value)
            spec = DuelSeriesSpec(
                series_id,
                (public_entrants[0], public_entrants[1]),
                seed,
                secrets.token_hex(16),
                max_live_provider_calls,
            )
            record = _Record(spec, credentials)
            async with self._lock:
                self._records[series_id] = record
                record.task = asyncio.create_task(
                    self._run(record), name=f"duel-series-{series_id}"
                )
                task_owns_credentials = True
            return self._status(record)
        finally:
            if not task_owns_credentials:
                for credential in credentials.values():
                    credential.close()

    async def _run(self, record: _Record) -> None:
        record.state = "running"
        try:
            execution = await self._executor(record.spec, record.credentials, record.cancel_event)
            if not isinstance(execution, DuelSeriesExecution):
                raise TypeError("duel series executor returned an invalid execution")
            if (
                execution.evidence is not None
                and execution.evidence.public.series_id != record.spec.series_id
            ):
                raise ValueError("duel series evidence belongs to a different series")
            record.result = execution.result
            if execution.evidence is not None:
                record.public_evidence = execution.evidence.public
                record.protected_evidence = execution.evidence.protected
            record.state = "completed"
        except asyncio.CancelledError:
            record.state = "cancelled"
        except Exception:
            record.failure = "duel_series_execution_failed"
            record.state = "failed"
        finally:
            for credential in record.credentials.values():
                credential.close()

    async def status(self, series_id: str) -> Mapping[str, object]:
        return self._status(await self._record(series_id))

    async def result(self, series_id: str) -> Mapping[str, object]:
        record = await self._record(series_id)
        if record.state not in ("completed", "failed", "cancelled"):
            raise RuntimeError("duel_series_result_not_ready")
        value = dict(self._status(record))
        value["result"] = None if record.result is None else asdict(record.result)
        return value

    async def replay(self, series_id: str) -> DuelSeriesEvidenceBundle:
        record = await self._record(series_id)
        if record.public_evidence is None:
            raise DuelSeriesEvidenceNotReadyError("duel_series_evidence_not_ready")
        return record.public_evidence

    async def protected_bundle(self, series_id: str) -> DuelSeriesEvidenceBundle:
        """Return protected pair evidence only to trusted local certification code."""

        record = await self._record(series_id)
        if record.protected_evidence is None:
            raise DuelSeriesEvidenceNotReadyError("duel_series_evidence_not_ready")
        return record.protected_evidence

    async def cancel(self, series_id: str) -> Mapping[str, object]:
        record = await self._record(series_id)
        if record.task is not None and not record.task.done():
            record.cancel_event.set()
            record.task.cancel()
            await asyncio.gather(record.task, return_exceptions=True)
        return self._status(record)

    async def aclose(self) -> None:
        async with self._lock:
            records = tuple(self._records.values())
        for record in records:
            if record.task is not None and not record.task.done():
                record.cancel_event.set()
                record.task.cancel()
        await asyncio.gather(
            *(record.task for record in records if record.task is not None),
            return_exceptions=True,
        )
        for record in records:
            for credential in record.credentials.values():
                credential.close()

    async def _record(self, series_id: str) -> _Record:
        async with self._lock:
            record = self._records.get(series_id)
        if record is None:
            raise DuelSeriesNotFoundError(series_id)
        return record

    @staticmethod
    def _status(record: _Record) -> Mapping[str, object]:
        return {
            "config": record.spec.public_dict(),
            "failure": record.failure,
            "series_id": record.spec.series_id,
            "state": record.state,
        }


__all__ = [
    "DuelSeriesEvidenceNotReadyError",
    "DuelSeriesNotFoundError",
    "DuelSeriesService",
    "DuelSeriesSpec",
    "SeriesExecutor",
]
