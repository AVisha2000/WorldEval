#!/bin/zsh

# Fast, credential-free WorldArena test pass.
# Uses fixed scripted policies and seeds; no model API calls are made.

set -euo pipefail

PROJECT_DIR="${0:A:h}"
GODOT_PROJECT="$PROJECT_DIR/worlds/worldarena/godot"
FAST_MAX_ROUNDS="${WORLD_ARENA_FAST_ROUNDS:-8}"

cleanup() {
  if [[ -n "${FAST_RUN_DIR:-}" && -d "$FAST_RUN_DIR" ]]; then
    rm -rf -- "$FAST_RUN_DIR"
  fi
}
trap cleanup EXIT INT TERM

find_godot() {
  if [[ -n "${GODOT_BIN:-}" && -x "$GODOT_BIN" ]]; then
    print -r -- "$GODOT_BIN"
  elif command -v godot4 >/dev/null 2>&1; then
    command -v godot4
  elif command -v godot >/dev/null 2>&1; then
    command -v godot
  elif [[ -x "/Applications/Godot.app/Contents/MacOS/Godot" ]]; then
    print -r -- "/Applications/Godot.app/Contents/MacOS/Godot"
  fi
}

if [[ -x "$PROJECT_DIR/.venv/bin/python" ]]; then
  PYTHON_BIN="$PROJECT_DIR/.venv/bin/python"
else
  PYTHON_BIN="$(command -v python3)"
fi

GODOT_BIN="$(find_godot)"
if [[ -z "$GODOT_BIN" ]]; then
  print -u2 "Godot 4 was not found. Set GODOT_BIN or install Godot in /Applications."
  exit 1
fi

cd "$PROJECT_DIR"
print "WorldArena deterministic fast tests"
print "  fixed policy · fixed seeds · no API key · ${FAST_MAX_ROUNDS}-round batch cap"

"$PYTHON_BIN" -m pytest -q

"$GODOT_BIN" --headless --path "$GODOT_PROJECT" \
  --script res://tests/arena/arena_conquest_headless_runner.gd

"$GODOT_BIN" --headless --path "$GODOT_PROJECT" \
  --script res://tests/arena/arena_task_headless_runner.gd

"$GODOT_BIN" --headless --path "$GODOT_PROJECT" --quit-after 1000 -- \
  --arena-offline-demo --arena-test-rounds=4 --arena-quit-after-test

FAST_RUN_DIR="$(mktemp -d "/tmp/worldarena-fast-test.XXXXXX")"
"$GODOT_BIN" --headless --path "$GODOT_PROJECT" \
  --script res://scripts/arena/simulation/arena_batch_runner.gd -- \
  "--output=$FAST_RUN_DIR/bundle.json" \
  --run-id=fast-deterministic-smoke \
  --seed=104729 \
  --seed-label=FAST-DETERMINISTIC-SMOKE \
  "--max-rounds=$FAST_MAX_ROUNDS" \
  --policy=deterministic_demo

print ""
print "FAST_DETERMINISTIC_TESTS_OK"
