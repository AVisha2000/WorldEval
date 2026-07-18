#!/bin/zsh

# Double-click launcher for Genesis Arena on macOS.
set -e
cd "$(dirname "$0")"

echo "Starting WorldArena..."

if [[ ! -d .venv ]]; then
  echo "Creating Python environment..."
  python3 -m venv .venv
fi

source .venv/bin/activate
python -m pip install -q -e ".[dev]"

if [[ ! -f .env ]]; then
  cp .env.example .env
fi

echo "Starting backend on http://127.0.0.1:8000"
genesis-arena > /tmp/worldarena-backend.log 2>&1 &
BACKEND_PID=$!
trap 'kill $BACKEND_PID 2>/dev/null || true' EXIT

if command -v godot4 >/dev/null 2>&1; then
  GODOT_BIN="$(command -v godot4)"
elif command -v godot >/dev/null 2>&1; then
  GODOT_BIN="$(command -v godot)"
elif [[ -x "/Applications/Godot.app/Contents/MacOS/Godot" ]]; then
  GODOT_BIN="/Applications/Godot.app/Contents/MacOS/Godot"
else
  echo "Godot 4 was not found. Install it from https://godotengine.org/download/macos/"
  echo "Backend is still running. Press Ctrl+C to stop."
  wait $BACKEND_PID
  exit 1
fi

echo "Opening the game. Click Start benchmark in the top-right."
"$GODOT_BIN" --path godot >/tmp/worldarena-godot.log 2>&1 &
GODOT_PID=$!
wait $GODOT_PID

