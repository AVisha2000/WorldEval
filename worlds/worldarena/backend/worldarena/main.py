"""WorldArena application facade over the legacy compatibility namespace.

The public console command can describe itself from an installed wheel without
requiring a source checkout.  The application and legacy runner stay lazy so
workspace discovery only happens when the server is actually requested.
"""

from __future__ import annotations

import sys
from typing import Any

app: Any


def run() -> None:
    """Run the legacy-compatible WorldArena server."""

    if {"-h", "--help"}.intersection(sys.argv[1:]):
        print(
            "usage: worldarena\n\n"
            "Run the WorldArena controller from a WorldEval workspace.\n\n"
            "options:\n"
            "  -h, --help  show this help message and exit"
        )
        return

    from genesis_arena.main import run as legacy_run

    legacy_run()


def __getattr__(name: str) -> Any:
    if name == "app":
        from genesis_arena.main import app

        return app
    raise AttributeError(name)


__all__ = ["app", "run"]
