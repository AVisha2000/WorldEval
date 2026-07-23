# Native participant-video export

WorldArena release videos are reconstructed from independently verified authority replays. Godot
Movie Maker renders the selected participant camera, then FFmpeg produces a browser-compatible
H.264/AAC MP4. The pipeline does not use Remotion and does not make a provider or upload request.

The publication profile is 1920×1080 at 30 FPS. This is deliberately separate from the existing
1280×720 browser replay/archive contract, which remains unchanged.

## Prerequisites

- Godot 4 at `/Applications/Godot.app/Contents/MacOS/Godot`, or pass `--godot`.
- FFmpeg with H.264 and AAC support. The local development environment can use the isolated
  `imageio-ffmpeg` executable under `.venv`; pass another executable with `--ffmpeg` when needed.
- The approved Mixamo Y Bot manifest and all hash-bound files referenced by it.
- A sealed `hybrid-visible-v1` authority replay for the participant being exported.

No API key is used. The replay remains local protected input and is not copied into the public
video sidecar.

## Render one participant camera

From the repository root:

```bash
.venv/bin/python worlds/worldarena/scripts/render_worldarena_native_replay.py \
  --replay /absolute/path/to/authority.replay.json \
  --showcase solo \
  --scenario-id multi-action-demo-v0 \
  --participant participant_0 \
  --output exports/worldarena-scripted-demos/participant-0.mp4
```

The command chooses the immutable v1, v2, or v3 Movie Maker renderer from the replay's verified
protocol identity. It rejects a participant not present in the replay and rejects text-only replay
evidence because a release video must be bound to the participant-visible hybrid profile.

Use `--showcase duo` for a verified two-participant game and `--showcase trio` for a verified
Sol/Luna/Terra `trio-free-for-all-v0` leg. Trio evidence records the cyclic seat rotation and the
selected participant's Demo entrant identity. The solo profile accepts only a replay whose
authority receipts and public events prove the complete `multi-action-demo-v0` sequence.

Successful export creates the MP4 and a sibling `*.mp4.evidence.json`. The canonical sidecar binds:

- the replay, protocol-package, terminal-checkpoint, and approved Y Bot manifest hashes;
- the episode, task, participant, and total authority ticks;
- the exact expected Movie Maker frame count at three render frames per authority tick;
- 1920×1080, 30 FPS, H.264, `yuv420p`, AAC, and fast-start verification; and
- the final MP4 byte length and SHA-256 digest.

Only hashes and safe run identity fields are present. Prompts, provider output, credentials, hidden
coordinates, protected observations, and spectator state are not written to the sidecar.

## Multiplayer archives

When `GENESIS_FFMPEG_EXECUTABLE` resolves to an executable, the managed two-agent browser archive renders
both participant cameras for both symmetric legs. The managed three-agent archive renders all
three participant cameras for all three cyclic legs. A render failure leaves the verified authority
result intact but reports native playback as unavailable; it never publishes a partial set as a
complete multiplayer archive. Those browser artifacts remain 1280×720; use this release command
to produce a selected 1920×1080 publication export from protected replay evidence.

Before publication, visually inspect representative frames from every selected participant video.
Uploading and configuring third-party video IDs are separate user-authorized release actions.
