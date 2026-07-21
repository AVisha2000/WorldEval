# World Arena Conquest design system

Reference: `docs/concepts/worldarena-conquest-gameplay-v1.png`

This document is the implementation contract for the Godot spectator client. The
reference image is a direction target, not a promise that generated lettering or
illustrative geometry will be copied literally.

## Product story

The screen must answer five questions without opening another panel:

1. What ends the match? Destroy every rival stronghold; the last faction survives.
2. Which stage is the match in? Opening, Fortify, Expand, War, or Endgame.
3. What is each faction doing? Its intent, active work, research, and military order.
4. Where is pressure building? Fog edges, scouts, defensive works, and siege markers.
5. Why did the state change? The battle chronicle names important events in order.

There is no World Seed, Crown, king-of-the-hill progress bar, or central score
objective. The crossroads are ordinary strategic terrain.

## Screen composition

- Canvas: 16:10; designed at 1440 by 900 and usable down to 1280 by 800.
- World: 72% of the width, framed by the faction rail on the left and chronicle on
  the right. All three home strongholds remain in the camera at the default zoom.
- Header: one line for title and match clock, one dominant objective line, one
  quieter narrative-phase line.
- Left rail: three faction cards. Each card shows keep health, territory, the three
  primary resources, population/supply, tech tier, and current intent.
- Right rail: event chronicle, newest event first. Combat, core damage, research,
  construction, scouting, negotiation, and elimination use distinct icons/colors.
- Bottom: selected task/formation at left, replay and phase timeline in the center,
  current strategic order and minimap at right.
- World labels: only strongholds, selected tasks, important resource nodes, scouts,
  and active siege. Avoid permanent labels on every unit.

## Tokens

### Color

| Token | Hex | Use |
| --- | --- | --- |
| `ink-950` | `#061016` | Opaque HUD wells and outer frame |
| `ink-900` | `#0A1820` | Primary translucent panels |
| `ink-800` | `#102631` | Secondary panels and selected rows |
| `sand-100` | `#F2E2BF` | Primary text |
| `sand-300` | `#CDB987` | Secondary text and dividers |
| `gold-500` | `#C99842` | Global objective, focus, and timeline |
| `gold-700` | `#79541F` | Panel bevel/shadow |
| `health` | `#50BC70` | Healthy stronghold and unit state |
| `danger` | `#E65B3E` | Core damage, siege, invalid order |
| `sol` | `#D25530` | Sol heraldry and territory |
| `terra` | `#2A9A70` | Terra heraldry and territory |
| `luna` | `#5367CF` | Luna heraldry and territory |
| `fog` | `#071018CC` | Unexplored map overlay |

Panels use 92% opaque `ink-950` at the outer rails and 82% opaque `ink-900` over
the world. Color is reserved for faction identity, health, danger, and state—not
decorative gradients.

### Type

- Display: uppercase serif or small-caps fallback, 18–24 px, 0.05 em tracking.
- Objective: uppercase display, 22–28 px, centered, no wrapping at 1440 px.
- Body: highly legible sans-serif, 14–16 px.
- Metadata: 12–13 px; never smaller than 12 px at the design resolution.
- Numbers use tabular figures. Resource and HP values align vertically.
- Copy must come from authoritative state; no placeholder prose in shipped replay.

### Shape and depth

- Main panels: 6 px corner radius, 1 px gold-brown border, 3 px dark inner shadow.
- Cards: 4 px radius and a 3 px faction-color identity stripe.
- Selected controls: sand/gold outline plus slightly lighter ink fill.
- Shadows: short and dark. No glassmorphism blur that obscures unit silhouettes.
- Spacing grid: 4 px base; 8 px row gap; 12 px card inset; 16 px major gutters.

## World art direction

- Compact low-poly medieval modular village art with clear silhouettes and warm,
  hand-painted color separation.
- Three factions share one architectural kit; banners, roof trims, unit rings, and
  lights provide identity. This keeps the battlefield readable and import size sane.
- Structures have four visual states: foundation, scaffold, near-complete, complete.
- Unit states are idle, walk, gather/chop, mine, build/hammer, attack, hit, retreat,
  celebrate, and defeated. Replay position is authoritative; path and animation are
  cosmetic projections.
- Fog-of-war is a dark feathered overlay with a stable discovered boundary. Distance
  fog and lighting are atmosphere only and must not imply authoritative visibility.
- Resource feedback is physical: wood chips at trees, ore/coin particles at mines,
  dust and hammer sparks during construction, masonry debris during siege.
- Lighting: warm directional key, cool ambient fill, contact shadows/AO, restrained
  bloom on fires and selection markers. Strongholds are the brightest landmarks.

## Components and state contract

### `ConquestObjectiveBanner`

- Fixed copy: `OBJECTIVE • DESTROY EVERY RIVAL STRONGHOLD`.
- Shows `strongholds_alive / strongholds_total`, round, elapsed match time, and
  current narrative phase.
- Phase is derived from state, never hard-coded to a round alone.

### `FactionScoreCard`

- Inputs: faction id/color, eliminated flag, keep HP/max, territory share,
  stockpile/income, population/supply, tech tier, force composition, and intent.
- An eliminated card desaturates and reads `STRONGHOLD DESTROYED`; it does not vanish.

### `BattleChronicle`

- Maximum six visible entries. Important events stay long enough to be read.
- Priority: match end, elimination, core damage, structure destroyed, battle/siege,
  research, treaty, construction, scouting, economy.
- Copy examples: `Sol raises an eastern watchtower`, `Luna completes Ironworking`,
  `Siege begins at Luna's outer wall`.

### `TaskInspector`

- Shows owner, actors, canonical action (`Move`, `Gather`, `Build`, `Attack`,
  `Research`, `Negotiate`, `Think`), progress, ETA, paused reason, and target.
- Multi-worker tasks show the acceleration explicitly: `2 workers • 2.0× build`.

### `PhaseTimeline`

- States: `OPENING`, `FORTIFY`, `EXPAND`, `WAR`, `ENDGAME`.
- Markers are event-derived transitions. Replay seek, pause, and speed remain visible.

### `VisibilityOverlay`

- Spectator default can see the complete arena plus each faction's visibility edge.
- Faction-view mode displays only that faction's projected observation and stale
  contact markers with a `last seen` age.

## Responsive rules

- At widths below 1360 px, hide per-faction force composition before hiding economy.
- At widths below 1180 px, collapse the chronicle to four rows and the minimap to an
  icon toggle. The objective and all keep-health cards remain visible.
- The default camera may zoom slightly, but it must never crop a home stronghold.

## Copy contract

Use `stronghold`, `keep`, `territory`, `supply`, `tech`, `scout`, `defend`, `siege`,
and the canonical action names. Remove all visible and machine-facing occurrences of
`World Seed`, `Crown`, `hold the center`, `crown surge`, and `sudden-death crown` from
the conquest rules, evaluation, demo policy, HUD, fixtures, and generated artifacts.

