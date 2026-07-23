#!/bin/zsh

# Double-click launcher for WorldArena on macOS.
set -e
cd "$(dirname "$0")"

echo "Starting WorldArena..."

if [[ ! -d .venv ]]; then
  echo "Creating Python environment..."
  python3 -m venv .venv
fi

source .venv/bin/activate
python -m pip install -q -e ".[dev]"

echo "Starting backend on http://127.0.0.1:8000"
EXISTING_PID="$(lsof -tiTCP:8000 -sTCP:LISTEN 2>/dev/null | head -1)"
if [[ -n "$EXISTING_PID" ]]; then
  EXISTING_COMMAND="$(ps -p "$EXISTING_PID" -o command= 2>/dev/null)"
  if [[ "$EXISTING_COMMAND" == *"$PWD/.venv/bin/worldarena"* || "$EXISTING_COMMAND" == *"$PWD/.venv/bin/genesis-arena"* ]]; then
    echo "Restarting the existing WorldArena backend..."
    kill "$EXISTING_PID"
    wait "$EXISTING_PID" 2>/dev/null || true
  else
    echo "Port 8000 is already used by another application: $EXISTING_COMMAND"
    echo "Close that application, then launch WorldArena again."
    exit 1
  fi
fi
worldarena > /tmp/worldarena-backend.log 2>&1 &
BACKEND_PID=$!
trap 'kill $BACKEND_PID 2>/dev/null || true' EXIT

if [[ -n "${GODOT_BIN:-}" && -x "$GODOT_BIN" ]]; then
  : # Use an explicit path supplied by the user.
elif command -v godot4 >/dev/null 2>&1; then
  GODOT_BIN="$(command -v godot4)"
elif command -v godot >/dev/null 2>&1; then
  GODOT_BIN="$(command -v godot)"
elif [[ -x "/Applications/Godot.app/Contents/MacOS/Godot" ]]; then
  GODOT_BIN="/Applications/Godot.app/Contents/MacOS/Godot"
elif [[ -x "/Applications/Godot_mono.app/Contents/MacOS/Godot" ]]; then
  GODOT_BIN="/Applications/Godot_mono.app/Contents/MacOS/Godot"
else
  echo "Godot 4 was not found. Install it from https://godotengine.org/download/macos/"
  echo "Backend is still running. Press Ctrl+C to stop."
  wait $BACKEND_PID
  exit 1
fi

echo "Opening WorldArena. Configure three models, or leave the key blank for Demo mode."
"$GODOT_BIN" --path worlds/worldarena/godot >/tmp/worldarena-godot.log 2>&1 &
GODOT_PID=$!
set +e
wait $GODOT_PID
GODOT_STATUS=$?
set -e

if [[ $GODOT_STATUS -ne 0 ]]; then
  echo "WorldArena closed with an error. Recent Godot output:"
  tail -40 /tmp/worldarena-godot.log 2>/dev/null || true
  echo "Recent backend output:"
  tail -20 /tmp/worldarena-backend.log 2>/dev/null || true
fi

exit $GODOT_STATUS
