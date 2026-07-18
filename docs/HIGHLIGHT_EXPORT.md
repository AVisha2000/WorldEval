# Exporting the WorldArena highlight

Double-click [render_highlight_replay.command](../render_highlight_replay.command) in Finder. It creates a local, upload-ready MP4 from the deterministic showcase.

The output is a 90-second 1920 × 1080, 16:9 video at 30 fps (`2,700` frames), written to `exports/worldarena-highlight-YYYYMMDD-HHMMSS.mp4`. The app's native 8:5 view is padded rather than stretched so the video is upload-ready. The script reveals and opens the completed file when it finishes.

It uses Godot 4.5 to record the showcase and encodes the temporary AVI with `ffmpeg`. If no system `ffmpeg` is installed, the first run creates an ignored `.video-tools` virtual environment and downloads `imageio-ffmpeg` there. This is a contained, local dependency only; it does not upload game data. The intermediate render is removed automatically. No API key is read, printed, or embedded.

Requirements:

- Godot 4 at `/Applications/Godot.app`, or an executable `godot4` / `godot` on your `PATH`.
- The local showcase manifest at `godot/showcases/demo_highlight/showcase.json`.
- A locally installed `ffmpeg`, or an internet connection once so the exporter can bootstrap its project-local `imageio-ffmpeg` encoder.

If Godot is somewhere else, launch Terminal and run the exporter with an explicit path:

```zsh
cd /Users/arlind/Documents/WorldEval
GODOT_BIN="/path/to/Godot" ./render_highlight_replay.command
```

To render a different local showcase, pass its manifest explicitly. The showcase must be a deterministic 90-second replay compatible with the app:

```zsh
WORLD_ARENA_SHOWCASE="/absolute/path/to/showcase.json" ./render_highlight_replay.command
```

Godot 4.5 writes Motion-JPEG AVI files, which macOS’s `avconvert` cannot read. For that reason the exporter uses `ffmpeg` rather than `avconvert`. It prints a clear first-run message before downloading the isolated encoder; it never installs Homebrew or changes global Python packages.
