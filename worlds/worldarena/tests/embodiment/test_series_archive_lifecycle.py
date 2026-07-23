from __future__ import annotations

import asyncio
import threading
from types import SimpleNamespace

import genesis_arena.embodiment.trio_games.service as trio_service_module
import pytest
from genesis_arena.embodiment.duel.evidence import DuelSeriesExecution
from genesis_arena.embodiment.duel.service import DuelSeriesService
from genesis_arena.embodiment.trio_games.evidence import TrioSeriesExecution
from genesis_arena.embodiment.trio_games.scheduling import TRIO_DEMO_ENTRANTS
from genesis_arena.embodiment.trio_games.service import TrioSeriesService


class _SlowFailingArchive:
    def __init__(self) -> None:
        self.started = threading.Event()
        self.release = threading.Event()

    def save(self, *_args: object, **_kwargs: object) -> None:
        self.started.set()
        if not self.release.wait(timeout=5):
            raise AssertionError("test archive release was not signalled")
        raise OSError("bounded archive fixture failure")


@pytest.mark.asyncio
async def test_duo_authority_finishes_while_native_archive_is_still_saving() -> None:
    archive = _SlowFailingArchive()

    async def execute(spec, _credentials, _cancel_event):
        execution = object.__new__(DuelSeriesExecution)
        object.__setattr__(execution, "result", SimpleNamespace(public_dict=lambda: {}))
        object.__setattr__(
            execution,
            "evidence",
            SimpleNamespace(
                public=SimpleNamespace(series_id=spec.series_id),
                protected=SimpleNamespace(),
            ),
        )
        return execution

    service = DuelSeriesService(execute, archive=archive)  # type: ignore[arg-type]
    service._evaluation_projection = lambda _record: {}  # type: ignore[method-assign]
    service._timeline_projection = lambda _record: {}  # type: ignore[method-assign]
    created = await service.create(
        entrants=(
            {"provider": "demo", "model": "duelist-alpha-v1"},
            {"provider": "demo", "model": "duelist-bravo-v1"},
        ),
        seed=17,
    )
    try:
        assert await asyncio.to_thread(archive.started.wait, 1)
        status = await service.status(created["series_id"])
        assert status["state"] == "completed"
        assert status["archive"]["evidence"]["state"] == "saving"
        assert status["archive"]["native_replay"] == {"state": "saving"}
        assert await service.archive_status(created["series_id"]) == status["archive"]
    finally:
        archive.release.set()
        await service.aclose()


@pytest.mark.asyncio
async def test_trio_authority_finishes_while_native_archive_is_still_saving(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    archive = _SlowFailingArchive()
    monkeypatch.setattr(trio_service_module, "_timeline", lambda _bundle: {})

    async def execute(_spec, _cancel_event):
        execution = object.__new__(TrioSeriesExecution)
        object.__setattr__(execution, "result", SimpleNamespace(public_dict=lambda: {}))
        object.__setattr__(
            execution,
            "evidence",
            SimpleNamespace(public=SimpleNamespace(), protected=SimpleNamespace()),
        )
        object.__setattr__(execution, "evaluation", {})
        return execution

    service = TrioSeriesService(execute, archive=archive)  # type: ignore[arg-type]
    created = await service.create(
        task_id="trio-relay-v0",
        seed=23,
        entrants=tuple(
            {"provider": "demo", "model": entrant.model}
            for entrant in TRIO_DEMO_ENTRANTS
        ),
    )
    try:
        assert await asyncio.to_thread(archive.started.wait, 1)
        status = await service.status(created["series_id"])
        assert status["state"] == "completed"
        assert status["archive_state"] == "saving"
        assert status["archive"] == {
            "evidence": {"state": "saving"},
            "native_replay": {"state": "saving"},
        }
        assert await service.archive_status(created["series_id"]) == status["archive"]
    finally:
        archive.release.set()
        await service.aclose()
