#!/bin/zsh

# Double-click exporter for the WorldArena demo highlight.
# Renders the deterministic local showcase at 1920x1080 / 30 fps, then produces
# an upload-ready H.264 MP4. It never uploads game data or reads API credentials.
# A first run may download an isolated local encoder if ffmpeg is not installed.

set -euo pipefail

PROJECT_DIR="${0:A:h}"
GODOT_PROJECT="$PROJECT_DIR/godot"
SHOWCASE_MANIFEST="${WORLD_ARENA_SHOWCASE:-$GODOT_PROJECT/showcases/demo_highlight/showcase.json}"
EXPORT_DIR="$PROJECT_DIR/exports"
VIDEO_TOOL_DIR="$PROJECT_DIR/.video-tools"
FPS=30
DURATION_SECONDS=90
FRAME_COUNT=$((FPS * DURATION_SECONDS))
# Godot preserves the project's 8:5 viewport while recording. Pad rather than
# stretch it so the upload file is always a standards-friendly 16:9 1080p MP4.
VIDEO_FILTER="scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black"

cleanup() {
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
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
  elif [[ -x "/Applications/Godot_mono.app/Contents/MacOS/Godot" ]]; then
    print -r -- "/Applications/Godot_mono.app/Contents/MacOS/Godot"
  fi
}

find_imageio_ffmpeg() {
  local python_bin ffmpeg_bin
  for python_bin in "$PROJECT_DIR/.venv/bin/python" "$VIDEO_TOOL_DIR/bin/python" "$(command -v python3 2>/dev/null || true)"; do
    [[ -n "$python_bin" && -x "$python_bin" ]] || continue
    ffmpeg_bin="$("$python_bin" -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())' 2>/dev/null || true)"
    if [[ -n "$ffmpeg_bin" && -x "$ffmpeg_bin" ]]; then
      print -r -- "$ffmpeg_bin"
      return 0
    fi
  done
  return 1
}

prepare_local_encoder() {
  local bootstrap_python
  bootstrap_python="$(command -v python3 2>/dev/null || true)"
  if [[ -z "$bootstrap_python" ]]; then
    print -u2 "Python 3 is required to prepare WorldArena's local video encoder."
    return 1
  fi
  print -u2 "Preparing the project-local video encoder (first run only)…"
  print -u2 "  This downloads imageio-ffmpeg into .video-tools; it does not upload any game data."
  if [[ ! -x "$VIDEO_TOOL_DIR/bin/python" ]]; then
    "$bootstrap_python" -m venv "$VIDEO_TOOL_DIR"
  fi
  "$VIDEO_TOOL_DIR/bin/python" -m pip install --disable-pip-version-check --quiet imageio-ffmpeg
  find_imageio_ffmpeg
}

if [[ ! -f "$GODOT_PROJECT/project.godot" ]]; then
  print -u2 "WorldArena's Godot project was not found at: $GODOT_PROJECT"
  exit 1
fi

if [[ ! -f "$SHOWCASE_MANIFEST" ]]; then
  print -u2 "The 90-second highlight showcase is not available yet:"
  print -u2 "  $SHOWCASE_MANIFEST"
  print -u2 "Pull the latest WorldArena files (or set WORLD_ARENA_SHOWCASE to a local showcase.json) and try again."
  exit 1
fi

GODOT_BIN="$(find_godot)"
if [[ -z "$GODOT_BIN" ]]; then
  print -u2 "Godot 4 was not found. Install Godot 4 for macOS, then run this file again."
  print -u2 "Expected app path: /Applications/Godot.app"
  exit 1
fi

mkdir -p "$EXPORT_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/worldarena-highlight.XXXXXX")"
MOVIE_AVI="$WORK_DIR/worldarena-highlight.avi"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_MP4="$EXPORT_DIR/worldarena-highlight-$STAMP.mp4"
GODOT_LOG="$WORK_DIR/godot-render.log"

print "Rendering WorldArena's ${DURATION_SECONDS}-second highlight…"
print "  ${FPS} fps · 1920x1080 · ${FRAME_COUNT} frames"

"$GODOT_BIN" \
  --path "$GODOT_PROJECT" \
  --rendering-method gl_compatibility \
  --resolution 1920x1080 \
  --fixed-fps "$FPS" \
  --disable-vsync \
  --write-movie "$MOVIE_AVI" \
  --quit-after "$FRAME_COUNT" \
  -- \
  "--arena-showcase=$SHOWCASE_MANIFEST" \
  --arena-capture \
  --arena-quit-after-test \
  >"$GODOT_LOG" 2>&1

if [[ ! -s "$MOVIE_AVI" ]]; then
  print -u2 "Godot did not produce a movie file. Recent render output:"
  tail -40 "$GODOT_LOG" >&2 || true
  exit 1
fi

print "Encoding an upload-ready H.264 MP4…"
if [[ -n "${FFMPEG_BIN:-}" && -x "$FFMPEG_BIN" ]]; then
  "$FFMPEG_BIN" -y -hide_banner -loglevel warning -i "$MOVIE_AVI" \
    -vf "$VIDEO_FILTER" -c:v libx264 -pix_fmt yuv420p -r "$FPS" -movflags +faststart "$OUTPUT_MP4"
elif command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -y -hide_banner -loglevel warning -i "$MOVIE_AVI" \
    -vf "$VIDEO_FILTER" -c:v libx264 -pix_fmt yuv420p -r "$FPS" -movflags +faststart "$OUTPUT_MP4"
else
  IMAGEIO_FFMPEG_BIN="$(find_imageio_ffmpeg || true)"
  if [[ -z "$IMAGEIO_FFMPEG_BIN" ]]; then
    IMAGEIO_FFMPEG_BIN="$(prepare_local_encoder || true)"
  fi
  if [[ -z "$IMAGEIO_FFMPEG_BIN" || ! -x "$IMAGEIO_FFMPEG_BIN" ]]; then
    print -u2 "WorldArena could not prepare its project-local H.264 encoder."
    print -u2 "Check your internet connection for the first-run download, or install ffmpeg and run again."
    exit 1
  fi
  "$IMAGEIO_FFMPEG_BIN" -y -hide_banner -loglevel warning -i "$MOVIE_AVI" \
    -vf "$VIDEO_FILTER" -c:v libx264 -pix_fmt yuv420p -r "$FPS" -movflags +faststart "$OUTPUT_MP4"
fi

if [[ ! -s "$OUTPUT_MP4" ]]; then
  print -u2 "The video encoder did not produce an MP4 file."
  exit 1
fi

print ""
print "Done — your 90-second replay is ready:"
print "  $OUTPUT_MP4"
print ""
print "The file is local only. Nothing was uploaded."
open -R "$OUTPUT_MP4"
open "$OUTPUT_MP4"
