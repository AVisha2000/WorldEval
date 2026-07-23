"""WorldEval command-line entrypoint."""

from __future__ import annotations

import sys
from typing import Sequence

_USAGE = """usage: worldeval <command> [options]

commands:
  feature    create, claim, validate, and complete repository features

run `worldeval feature --help` for feature workflow commands.
"""


def main(argv: Sequence[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if not arguments or arguments[0] in {"-h", "--help"}:
        print(_USAGE, end="")
        return 0
    if arguments and arguments[0] == "feature":
        from .features.cli import main as feature_main

        return int(feature_main(arguments[1:]) or 0)
    print(_USAGE, file=sys.stderr, end="")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
