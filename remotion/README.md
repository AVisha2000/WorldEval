# WorldArena video workspace

This directory is an isolated Remotion project for trailers, explainers, benchmark result
reels, and social clips. It does not run or modify the Godot simulation.

## Requirements

- Node.js 20 or newer
- pnpm 11
- macOS 15 or newer for the currently pinned Remotion release

The repository currently pins all Remotion packages to the same exact version, as required
by Remotion. This Mac is on macOS 12.6, so dependency installation and TypeScript checks can
run here, but current Remotion Studio/rendering is not officially supported until macOS is
upgraded.

## Commands

```bash
cd remotion
pnpm install
pnpm dev
```

Useful checks and renders:

```bash
pnpm typecheck
pnpm compositions
pnpm render:frame
pnpm render:intro
```

Outputs are written to `remotion/out/` and are ignored by Git.

## First composition

`WorldArenaIntro` is an eight-second, 1920×1080, 30fps parameterized starter. Its title,
subtitle, and round count can be replaced by render-time props once the final demo script and
art direction are agreed.
