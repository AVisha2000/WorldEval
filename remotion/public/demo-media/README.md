# WorldEval Remotion demo media

This folder is the editing library for the three pre-run demonstrations shown in the
WorldArena Controller Lab. Everything lives under `remotion/public/`, so a Remotion
composition can load an asset directly with `staticFile()`.

## Portal demo videos

| Demo | Remotion path | Canonical source |
|---|---|---|
| Labyrinth Run | `demo-media/videos/labyrinth-run-broadcast.mp4` | `godot/showcases/labyrinth_run/labyrinth-run-broadcast.mp4` |
| Mini RTS Skirmish | `demo-media/videos/mini-rts-skirmish-broadcast.mp4` | `godot/showcases/rts_skirmish/rts-skirmish-broadcast.mp4` |
| Crossroads Conquest | `demo-media/videos/crossroads-conquest-broadcast.mp4` | `godot/showcases/crossroads_conquest/crossroads-conquest-broadcast.mp4` |

These are full portal masters rather than shortened highlights. Keep them muted in an
explainer unless an approved gameplay audio track is intentionally required.

## Screenshot collections

- `screenshots/labyrinth-run/` — race overview, winner card, and mobile Controller Lab result.
- `screenshots/mini-rts-skirmish/` — economy, gathering, squad movement, bridge combat,
  retreat, stronghold assault, and victory.
- `screenshots/crossroads-conquest/` — centre conflict and evidence podium.
- `screenshots/portal/` — Run, Timeline, Result, Evaluation, and Replay views.

## Remotion example

```tsx
import {Img, staticFile} from 'remotion';
import {Video} from '@remotion/media';

<Video
  muted
  src={staticFile('demo-media/videos/labyrinth-run-broadcast.mp4')}
/>

<Img
  src={staticFile('demo-media/screenshots/labyrinth-run/winner-card.png')}
/>
```

The original source files remain in their authoritative project locations. This library is a
deliberate editing copy so Remotion work does not need to search the rest of the repository.
