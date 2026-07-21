# Duel presentation boundary and asset plan

This directory is a display-only adapter. It accepts copied projection dictionaries and public
events, and emits setup or spectator requests as signals. It never receives a mutable simulation
object, decides visibility, computes damage/resources, or turns animation callbacks into gameplay.
Perspective caches are separate complete projections: switching view never hides nodes from an
omniscient cache to approximate player knowledge.

## Projection shape

`DuelPresentation.apply_projection(perspective_id, projection)` accepts `omniscient`, `seat_0`, or
`seat_1`. The HUD recognizes these optional display fields:

- top-level `tick`, `simulation_hz`, `decision_mode`, `decision_ticks_remaining`, `objective`, and
  `day_phase`;
- two `players` with `label`, `stronghold`, `resources`, `tier`, `heroes`, `army_value`,
  `current_intent`, and `response`;
- `map` display bounds/lanes and already-filtered `entities`;
- an optional `selected` display record.

Unknown fields are ignored. All inputs are deep-copied before retention.

## Reviewed assets and fallback

The installed reviewed Kenney UI Pack Adventure vector subset supplies decorative panels, button
art, progress bars, and minimap symbols. `DuelDisplayAssetResolver` records every resolved resource
and returns `null` when it is absent; callers then use high-contrast procedural StyleBoxes/glyphs.
That fallback is deliberately presentation-only and keeps headless/unit testing independent of art.

The coherent production family remains the CC0 KayKit stack from the implementation spec. Intake
must first record archive provenance, checksum, version/date, license, allowlist, transforms, and
resulting resource paths in `godot/assets/asset_manifest.json`:

| Display need | Recommended pack | Status/use |
|---|---|---|
| Keeps, production, roads, walls | KayKit Medieval Hexagon | Pending verified intake |
| Workers, troops, Heroes, weapons | KayKit Adventurers | Pending verified intake |
| Crypt bodies | KayKit Skeletons | Pending verified intake |
| Trees, rocks, grass | KayKit Forest Nature | Pending verified intake |
| Gold/lumber/cargo | KayKit Resource Bits | Pending verified intake |
| Worker tools | KayKit RPG Tools Bits | Pending verified intake |
| Shared humanoid motion | Current KayKit Character Animations | Pending verified intake |
| HUD | Kenney UI Pack Adventure | Installed reviewed CC0 subset |

The installed Quaternius village subset may be used only as a clearly temporary environment
fallback. Do not mix it into the final KayKit production family. Mixamo remains optional and must
not become a default or undeclared dependency.

## Animation mapping

Use one reviewed medium humanoid rig and an `AnimationTree`. Strip root motion and drive state only
from recorded entity state/events. The resolver maps display states to the required clips:

`idle`, `walk`, `run`, `gather_chop`, `gather_mine`, `carry`, `build_hammer`, `repair`,
`attack_melee`, `attack_ranged`, `attack_siege`, `cast`, `hit`, `stunned`, `rooted`, `death`,
`spawn`, `transform`, and `victory`.

Animation events may play a visual particle or sound after an authoritative impact event. They may
never create damage, healing, resources, projectiles, completion, visibility, or victory. Siege,
drakes, and buildings use separate simple `AnimationPlayer` tracks. Seat identity is the same base
geometry plus amber `▲` or cyan `◆` material/banner/outline cues so color is never the only signal.
