---
name: remotion-showcase
description: Build, revise, and render gameplay-led Remotion explainers for WorldArena. Use when creating demo videos, benchmark explainers, gameplay trailers, or narrated-style visual stories from the local Godot MP4.
---

# WorldArena Remotion showcase

Use the latest file in `exports/worldarena-highlight-*.mp4` as the visual backbone.

## Narrative rules

- Keep gameplay visible for at least 70% of the runtime.
- Use overlays to explain the current on-screen action: gathering, building, scouting, trade, combat, capture, scoring.
- Keep title cards below 5 seconds and never leave a section with only a background after its text has faded.
- Prefer two or three short ideas per scene over dense text walls.
- Mute gameplay unless a separate approved voiceover or soundtrack is supplied.

## Composition rules

- Make every `Sequence` fill its whole allotted time.
- Fade in at a scene start; only fade out if the next scene overlaps it.
- Use `staticFile()` with a real file under `remotion/public/`, not a symlink.
- Validate a frame from the middle of every scene before handing off a render.

## macOS 12 render fallback

Remotion 4's bundled video compositor may fail on macOS 12 during final muxing. Render the frames, then encode the retained `react-motion-render*/element-%04d.jpeg` sequence with the project-local imageio-ffmpeg binary. Confirm the output duration and inspect frames at 10s, 45s, 90s, and 115s.
