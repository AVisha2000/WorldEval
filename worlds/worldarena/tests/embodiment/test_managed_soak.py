from __future__ import annotations

import pytest
from scripts.run_embodiment_managed_soak import ManagedSoakError, validate_soak_metrics


def test_managed_soak_metrics_accept_bounded_cleanup() -> None:
    summary = validate_soak_metrics(
        iterations=4,
        handles_reaped=4,
        pending_samples=(0, 0, 0, 0),
        fd_samples=(20, 21, 20),
    )
    assert summary["handles_reaped"] == 4
    assert summary["maximum_pending_attachments"] == 0


@pytest.mark.parametrize(
    ("handles", "pending", "fds", "code"),
    [
        (3, (0, 0, 0, 0), (20, 20), "process_not_reaped"),
        (4, (0, 1, 0, 0), (20, 20), "attachment_leak"),
        (4, (0, 0, 0, 0), (20, 21, 23), "fd_growth"),
    ],
)
def test_managed_soak_metrics_fail_closed(handles, pending, fds, code) -> None:
    with pytest.raises(ManagedSoakError, match=code):
        validate_soak_metrics(
            iterations=4,
            handles_reaped=handles,
            pending_samples=pending,
            fd_samples=fds,
        )
