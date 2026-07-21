#!/bin/zsh

# Double-click macOS launcher for an authoritative local ArenaSimulation replay.
set -euo pipefail
cd "${0:A:h}"
exec python3 scripts/run_arena_simulation.py "$@"
