# WorldArena — Competitive Arena v1 Feature Plan

**Status:** Decision-complete implementation source of truth; prototype work in progress
**Target:** Local Apple Silicon prototype using Godot 4 + FastAPI + OpenAI APIs
**Primary outcome:** A readable three-model arena in which commanders expand, negotiate,
delegate, trade, betray, build defenses, and fight through simultaneous physically resolved
actions.

## 1. Product goal

WorldArena must be entertaining enough to understand in a five-minute demonstration and
controlled enough to function as a serious embodied-agent evaluation.

> Most benchmarks evaluate what AI says. WorldArena evaluates what AI does when decisions
> have physical and social consequences.

WorldArena is spectator-first. It evaluates long-horizon planning, partial-observation
reasoning, physical and resource constraints, adaptation after failure, multi-agent
coordination, negotiation and opponent modelling, safe action validation, delegation,
cognition management, auditability, and efficient use of tokens, time, and resources.
It is not a robot-safety certification. It is a safe, reproducible benchmark for foundational
embodied decision-making capabilities.

The next version replaces the isolated survival race with a three-way territorial arena.
Every faction receives private observations, submits a sealed high-level plan, and acts from
the same frozen world state. Godot executes movement, gathering, wildlife, construction,
combat, capture, supply, and consequences. Models never write coordinates or mutate the
world directly.

A viewer should be able to answer these questions within ten seconds:

- Who is winning and why?
- What is each model trying to do?
- Who is talking to whom, and is the message public or private?
- Which agreements are enforceable trades versus non-binding promises?
- What physical change occurred because of a model decision?
- Did creating specialist brains improve the commander's decisions or waste cognition?

### Success criteria

- Three independently configured models plan concurrently without API latency granting an
  initiative advantage.
- Factions fight over supplied territory, mines, wildlife, and the central Crown.
- Public and private negotiation, atomic resource trades, informal alliances, and betrayal
  are visible and auditable.
- Commanders may create bounded specialist LLM advisors while remaining the sole authority
  that submits faction plans.
- A complete match produces a deterministic, secret-free replay and machine-readable
  benchmark result.
- The graybox version is visually legible at 1280×720 and runs smoothly on the target M4.

### Non-goals for Arena v1

- Finished character art, complex animation, procedural terrain, or cinematic VFX.
- Hit-by-hit LLM control, free-form coordinates, arbitrary code execution, or direct Godot
  node access.
- Model fine-tuning or learning through weight updates.
- Shared vision, shared controller access, binding military alliances, or more than three
  factions.
- Treating dialogue quality alone as social intelligence.

## 2. Modes and fairness tracks

The same simulation rules power every mode. Presentation and cognition policy may differ,
but world mechanics must not.

### Demo mode

- Omniscient spectator view by default.
- Private dialogue is visible with a clear `PRIVATE — SPECTATOR ONLY` label.
- Auto-director focuses battles, captures, deals, supply cuts, and betrayals.
- Playback defaults to 2× so a ten-minute simulation fits a five-minute demo.
- Named faction presentation: Sol, Terra, and Luna.

### Benchmark mode

- Neutral, identical base prompt and tool contract for all factions.
- Identical observation policy, deadlines, memory limits, budgets, retry rules, and action
  catalog.
- Hidden map seed, rotated starting seats, append-only logs, and frozen scoring.
- Private messages are visible only to participants during the match; organizer/spectator
  disclosure is post-match and cannot feed back into an observation.

### Cognition tracks

Results from different tracks must never be combined into one model ranking.

| Track | Model access | Purpose |
|---|---|---|
| Standard | One commander call per faction per round; no specialists | Clean model-to-model comparison |
| Agentic | Commander plus up to three bounded specialists under one shared budget | Tests delegation and context management |
| Open Teams (`open`) | Mixed-model specialists and configurable compute, recorded in full | Experiments and demonstrations only; never compared with Standard or Agentic |

Standard and Agentic are same-model tracks: every specialist must use the exact provider,
model snapshot, and revision as its Commander. Role-specific token/output/effort caps may be
lower than the Commander's but are frozen and equal across factions. Physical Workers and
soldiers are deterministic embodied executors, never extra LLMs. Only Open Teams permits
mixed models.

## 3. Arena and district topology

Use a 420-metre equilateral-triangle battlefield inside the existing 500×500 metre world.
This is substantially larger than the current playable island but remains readable from one
strategy camera.

The authoritative map is a versioned district graph, not arbitrary polygon overlap.
`tri_13_v1` contains 13 named districts:

- Three uncapturable Core districts: `core_sol`, `core_terra`, `core_luna`.
- Three starting Homelands: `home_sol`, `home_terra`, `home_luna`.
- Three pairwise Mid-mine districts: `mine_st`, `mine_tl`, `mine_ls`.
- Three outer Wildwoods: `wild_st`, `wild_tl`, `wild_ls`.
- One central Crown district worth three normal districts at scoring time.

Every non-Core district provides:

- One control ring, flag, and outpost slot.
- Two economy/building slots.
- Three defense slots.
- Named adjacency links for capture and supply.
- Deterministic navigation waypoints and travel duration.

District ownership and supply use the static graph. Visual bodies interpolate along graph
edges, but rendered transforms and physics collisions never decide ownership, arrival time,
combat damage, or score.

## 4. Starting factions

Each faction begins symmetrically with:

- Core: 1,000 HP and one defensive tower.
- One completed Homeland outpost.
- One Commander, three Workers, and two Militia.
- Stockpile: 120 food, 90 wood, 70 stone, 0 iron, 0 crystal.
- Population/supply capacity: 8; starting use: 5.
- External district supply capacity: 2.
- No active specialist advisors.

Commander defeat does not eliminate the faction. The Commander respawns at its Core after
three rounds; during the absence, the faction cannot start a new capture and loses 20% sight
range. Core destruction eliminates that faction. Its remaining units retreat or become
neutral ruins, and its supplied districts become neutral after two resolution rounds.

The match ends when one faction remains or the round limit and tie-break rules complete.

## 5. Resources, mines, forests, and wildlife

All nodes and wildlife are seeded, physical, finite state owned by the Godot simulation.
Their quantities appear visually and in permitted observations.

### Resource roles

| Resource | Strategic role |
|---|---|
| Food | Unit training and one-food-per-unit round upkeep |
| Wood | Workers, scouts, militia, farms, shelters, outposts, and walls |
| Stone | Outposts, towers, mines, walls, and durable infrastructure |
| Iron | Guards, towers, siege, and advanced equipment |
| Crystal | Workshop research, siege, and late-match technology |

### District deposits

| District | Initial stock | End-of-round regeneration |
|---|---|---|
| Homeland | Forest 300, stone 200, deer food 200 | Forest +4, deer +5 |
| Mid-mine | Forest 100, stone 160, iron 220, deer food 140 | Forest +2, deer +4 |
| Wildwood | Forest 420, stone 100, deer food 180, wildlife lair | Forest +6, deer +5 |
| Crown | Stone 220, iron 160, crystal 120, animal food 120 | Animal food +3 |

Regeneration never exceeds the seeded maximum. Stone, iron, and crystal never regenerate.
A deterministic Crown surge at round 20 exposes a second small crystal vein; the event and
deposit size are derived from the match seed and disclosed in the replay.

### Harvesting

Harvesting requires a Worker in an owned, supplied district. Per Worker per completed round:

- Wood: 12 from a forest.
- Stone: 8 from a quarry.
- Iron: 5 from a completed Mine with a maximum of three assigned Workers.
- Crystal: 3 from an upgraded Mine with a maximum of two assigned Workers.
- Deer: 10 food from a successful hunt.

Each Worker has one persistent job. Additional Workers stack linearly within node staffing
limits. Inventory capacity is 400 per resource plus 50 for every completed Storage. Excess
collection is discarded and logged as waste.

### Wildlife entities

Wildlife is represented authoritatively as groups with species, count, district, route,
health, alert state, and seeded behavior. The renderer displays simple silhouettes.

| Species | Use and behavior |
|---|---|
| Deer | 10 food each; flee combat and hunters toward a valid adjacent wild/home district |
| Boar | 18 food each; stand and fight weak hunting groups before retreating |
| Wolves | Guard valuable wilderness routes; attack isolated Workers/Scouts and reproduce slowly at a lair |

Models issue `hunt(group_id, district_id)` or a broad `secure_wildlife(district_id)` order.
Godot chooses paths, target individuals, flee direction, damage, and success. Wildlife
movement is seeded and resolved after faction movement but before harvesting.

## 6. Units, structures, and technology

### Unit classes

| Unit | HP | DPS | Speed | Vision | Supply | Cost / training |
|---|---:|---:|---:|---:|---:|---|
| Commander | 150 | 20 | 4.0 m/s | 75 m | 0 | One per faction; respawns |
| Worker | 30 | 2 | 3.2 m/s | 45 m | 1 | 30 food / 1 round |
| Scout | 40 | 4 | 5.0 m/s | 90 m | 1 | 25 food + 20 wood / 1 round |
| Militia | 75 | 12 | 3.4 m/s | 55 m | 1 | 40 food + 25 wood / 1 round |
| Guard | 110 | 18 | 2.8 m/s | 55 m | 1 | 55 food + 20 iron / 2 rounds |
| Siege | 130 | 8 units / 32 structures | 2.2 m/s | 60 m | 2 | 60 food + 40 wood + 30 iron + 15 crystal / 2 rounds |

Units form engine-owned squads of at most four. Commanders provide semantic orders to a
squad or job group; they never micro-control individual attack frames.

### Structures

| Structure | HP | Cost | Build time | Effect |
|---|---:|---|---:|---|
| Outpost | 240 | 80 wood + 50 stone | 2 rounds | Required to own and score a non-Core district |
| Shelter | 180 | 80 wood + 30 stone | 1 round | +4 population capacity |
| Farm | 140 | 60 wood + 20 stone | 1 round | +18 food/round while supplied |
| Storage | 180 | 70 wood + 35 stone | 1 round | +1 external supply, +50 inventory capacity |
| Mine | 200 | 60 wood + 40 stone | 2 rounds | Enables staffed iron extraction; Workshop upgrade enables crystal |
| Wall segment | 180 | 30 wood + 45 stone | 1 round | +5% district defense per segment; maximum three |
| Tower | 300 | 70 stone + 25 iron | 2 rounds | 14 DPS, 18 m range against hostile units |
| Workshop | 220 | 120 wood + 60 stone + 40 iron | 2 rounds | Enables Guard, Siege, crystal mining, and +15% friendly damage |

Each non-Core district supports one Outpost, two economy structures, and three defense
structures. Materials are reserved when an order is accepted. Cancellation or destruction
before completion refunds 50%; completion refunds nothing. Unsupplied construction pauses
and cancels with the same refund after three unsupplied rounds.

## 7. Supply, capture, and territory

Supply is the main anti-snowball system. It rewards coherent empires and makes deep raids
useful without invisible comeback bonuses.

- Core is always supplied while alive.
- External capacity is `min(2 + completed_storages, 6)`.
- A district needs an owned adjacency path to the Core and a completed Outpost.
- The model may submit an ordered `supply_priority`; unspecified districts follow in stable
  district-ID order.
- Unsupplied districts generate no resources or land score and cannot build or train.
- After three consecutive unsupplied rounds, the Outpost becomes ruined and ownership is
  removed. Units remain but default to retreat if they receive no order.

To capture neutral or enemy land:

1. Destroy or ruin the active enemy Outpost.
2. Hold the control ring with the Commander or a Militia/Guard squad.
3. Remain uncontested for two full rounds; enemy qualifying presence freezes progress.
4. Move a Worker into the district and complete a two-round Outpost.
5. Connect and prioritize the district for supply before it produces or scores.

Capture progress decreases by one when the claimant no longer has a qualifying presence.
Ownership never flips directly from movement or a single late rush.

## 8. Combat and deterministic resolution

The authoritative simulation runs in a pure, headless-capable GDScript core at 10 fixed
ticks per second. One round represents 15 seconds and 150 ticks. All gameplay quantities use
integers or fixed-point values; visual floats are presentation-only.

For each attack tick:

```text
damage = base_dps × 0.1
       × workshop_modifier
       × supply_modifier
       × defender_terrain_modifier
       × seeded_variance
```

- Workshop modifier: 1.15 when the faction owns a completed supplied Workshop.
- Supply modifier: 1.00 when supplied, otherwise 0.85.
- Defender terrain modifier: 1.20 in an owned supplied district, then multiplied by
  `1 + 0.05 × completed_walls` to a maximum wall modifier of 1.15.
- Core defenders receive a further 1.10 modifier.
- Seeded variance is uniformly 0.95–1.05 from the match-local PRNG.

Target acquisition is constrained to the ordered district/path and uses this stable priority:
Commander, Worker constructing, Guard, Militia, Scout, other Worker, structure. Siege targets
structures before units. Damage from all valid attackers is accumulated from tick-start state
and applied simultaneously, allowing mutual kills. Entity iteration uses stable IDs.

After production, each non-Commander unit consumes one food. If upkeep is unpaid, all such
units become starving and receive 0.85 movement and damage. After three consecutive starving
rounds, non-defending units retreat toward Core. A fully paid upkeep round clears starvation.

## 9. Simultaneous round protocol

A normal match lasts 40 rounds. All factions act from the same round-start state.

### Round lifecycle

1. **Observe:** Godot freezes canonical state and produces three separately filtered
   observations.
2. **Advise:** In Agentic mode, selected specialists run concurrently from their faction's
   legal information.
3. **Think:** All three commanders run concurrently and return one faction plan each.
4. **Commit:** Python canonicalizes every plan with a salt and sends only the three hashes.
5. **Lock:** Godot acknowledges that all commits are sealed or timed out.
6. **Reveal:** Python sends all plans and salts in one batch; Godot verifies hashes.
7. **Validate:** Godot validates every plan against the same frozen snapshot and reserves
   accepted costs.
8. **Resolve:** Godot advances 150 fixed ticks, then economy, supply, capture, diplomacy,
   wildlife, scoring, events, and the next state hash.

Messages and new offers revealed in round N enter model observations in round N+1. A new
offer cannot be accepted in the round in which it was created. This deliberate one-round
delay preserves simultaneous play with one commander call per round.

Model latency never advances simulation time or determines initiative. A timeout or API
failure uses the deterministic fallback: continue persistent jobs, withdraw starving idle
units, and defend the nearest supplied district. Late responses are discarded and logged.

### Command economy

Each faction receives four command points and may submit at most three new physical orders
per round. Existing movement, harvesting, building, training, and defense tasks persist for
free.

| Order | CP |
|---|---:|
| Assign workers, hunt, scout/recon, repair, set supply priority | 1 |
| Build, train, research | 1 |
| Mobilize/attack, reinforce, retreat | 2 |
| Specialist create/update/pause/dismiss | 0 physical CP; cognition rules apply next round |

Communication has its own bounded slot and does not consume physical CP. Invalid individual
orders are rejected without removing valid sibling orders and without reserving costs.

### Faction plan contract

```json
{
  "schema_version": "arena-v1",
  "match_id": "match_uuid",
  "round": 12,
  "faction_id": "sol",
  "public_intent": "Cut Terra's mine supply while Luna contests the Crown.",
  "orders": [
    {
      "order_id": "sol-r12-1",
      "action": "mobilize",
      "actor_ids": ["squad_sol_2"],
      "target_id": "mine_st",
      "stance": "raid"
    }
  ],
  "communication": {
    "utterances": [
      {
        "client_ref": "msg-7",
        "visibility": "private",
        "recipients": ["luna"],
        "text": "Pressure the Crown and I will cut Terra's eastern mine."
      }
    ],
    "new_offer": null,
    "responses": []
  },
  "specialist_ops": [],
  "supply_priority": ["mine_st", "wild_st"]
}
```

Unknown fields, free coordinates, unknown/stale private entity IDs, unaffordable actions, and
more than the allowed orders/CP are rejected. Text is normalized, UI markup/control characters
are removed, and negotiation content is always treated as untrusted data rather than system
instructions.

## 10. Diplomacy, trades, alliances, and betrayal

Each faction may submit at most two utterances, one new formal offer, and one response per
pending offer in a round. Utterances are at most 320 normalized UTF-8 characters.

### Visibility

- Public speech is visible to every faction after reveal.
- Private speech and trade details are visible only to sender and explicit recipients.
- Other factions receive only an opaque `private_exchange` metadata event containing the
  participants and round, never the text, offer terms, intent, or response. This policy is
  frozen for every official benchmark run.
- Accepted public pacts and territory flags are visible to all.
- Enemy resources, plans, prompts, memory, specialist context, and rationale remain private.
- Spectator visibility is a presentation projection and must never be reused for observations.

### Formal trade

```json
{
  "kind": "trade",
  "recipient": "luna",
  "visibility": "private",
  "give": {"wood": 20},
  "receive": {"iron": 5},
  "expires_round": 15
}
```

The offered side enters escrow immediately. Acceptance escrows the recipient's side and
executes one atomic swap at the next resolution boundary. Resources cannot back multiple
offers. Offers may be accepted, rejected, countered, withdrawn, expired, executed, or fail
for explicitly logged reasons.

Because all plans in a round are sealed, an offer created in round `R` is first actionable in
round `R+1`; same-phase acceptance is invalid. A counter is represented without a special
ambiguous response value: reject the old `offer_id` and use the plan's one new-offer slot for
the replacement terms. Escrow is part of authoritative Godot state and is released exactly
once on rejection, withdrawal, expiration, validation failure, or execution.

### Non-aggression pact

```json
{
  "kind": "non_aggression",
  "recipient": "terra",
  "visibility": "public_on_accept",
  "duration_rounds": 5,
  "regions": ["*"],
  "expires_round": 20
}
```

Pacts are recorded but not engine-enforced. Hostile action is always legal. Godot emits a
structured `pact_violation` referencing the pact and violating action; the pact ends and the
UI presents a betrayal. Natural-language promises remain informal and are never automatically
scored as contracts.

No pact shares vision, observations, tools, or controller access in Arena v1. Agents may
truthfully or deceptively communicate discoveries through ordinary messages.

## 11. Commander and specialist brains

Each faction owns one persistent Commander and up to three persistent specialist definitions
chosen from Scout, Economy, Military, and Diplomacy. Specialists are non-recursive advisors:
they may recommend but cannot issue world actions, communicate externally, create more agents,
or retain undeclared memory.

In Standard and Agentic, a specialist is a fresh bounded call to a copy of its own Commander's
configured model snapshot; it cannot select a cheaper, stronger, or different model. It sees
only its narrow brief and the same faction-legal projection, never opponent prompts, memory,
hidden state, private messages, or enemy specialists. Open Teams is the only track in which a
mixed-model roster is legal, and its results remain a separate category.

Creating or changing a specialist takes effect next round. Active specialists run first in
parallel; the Commander receives only short structured recommendations and submits the final
plan. The replay records whether the Commander accepted, modified, rejected, or ignored advice.
Specialists may be paused, re-briefed, reprioritized, or dismissed. Contradictory, unused, and
duplicated advice is recorded so delegation can be scored from outcomes instead of prose.

### Agentic cognition budget

Each faction receives 120 cognition units for a 40-round match:

- Commander call: 2 units per round; 80 units are reserved and cannot be spent by advisors.
- Specialist call: 1 unit; at most two specialists may be invoked in one round.
- Remaining 40 units permit at most 40 specialist-round calls across the match.
- Commander context/output caps: 6,000 input tokens / 1,200 output-and-reasoning tokens.
- Specialist caps: 2,000 input / 400 output-and-reasoning tokens.
- Maximum three defined specialists; zero recursive delegation.

Provider-reported input, cached input, output, reasoning, latency, and estimated monetary cost
are logged separately. Cognition units determine legal compute; API price never affects the
world. Failed or timed-out calls consume their allocated unit to prevent free retries.

Specialist output is restricted to:

```json
{
  "specialist_id": "sol_military_1",
  "role": "military",
  "assessment": "Terra's mine route is defended but its Wildwood link is exposed.",
  "risks": ["Luna may take the Crown while our militia move east."],
  "recommended_orders": ["Raid wild_st before attacking mine_st."],
  "recommendation_summary": "Cut the exposed supply link before the mine assault."
}
```

No raw chain-of-thought is requested, stored, or displayed. All API calls use `store=false`.

## 12. Fog of war and observation policy

Godot generates ground-truth state and projects each faction's legal observation from the
same code path.

Every observation includes:

- Exact friendly units, jobs, resources, structures, supply, budgets, memory summary, and
  outstanding offers.
- Public territory scores and visibly represented flags.
- Districts and entities currently inside friendly vision.
- Stale last-seen enemy records labeled with the observation round.
- Public messages and private messages involving the faction.
- Recent visible outcomes and legal semantic action targets.

Unknown cells must not leak resource types, exact enemy health, internal node paths, private
events, or precise hidden coordinates through IDs, errors, logs, or ordering. Switching the UI
from spectator to faction view must rebuild the presentation from that faction's projection so
spectator-only content cannot remain in caches or tooltips.

## 13. Spectator UI and communication presentation

The first release uses primitive meshes, procedural overlays, generated icons, and the current
dark blue-green theme. Graphics polish is not a dependency.

### Live layout

```text
┌────────────────────────────────────────────────────────────────────────────┐
│ WORLD ARENA  R12/40  THINKING  00:18      [Director] [View] [Pause] [1×]  │
├────────────────┬───────────────────────────────────────┬───────────────────┤
│ SOL faction    │                                       │ DIPLOMACY         │
│ TERRA faction  │             3D ARENA                  │ Public / Private  │
│ LUNA faction   │                                       │ Deals / System    │
│ RELATIONS      │                                       │                   │
├────────────────┴───────────────────────────────────────┴───────────────────┤
│ SELECTED COMMANDER: intent · orders · specialist recommendations           │
├────────────────────────────────────────────────────────────────────────────┤
│ ◀ event  ◀ round        timeline / highlights          round ▶  event ▶   │
└────────────────────────────────────────────────────────────────────────────┘
```

- Top bar: round, phase, timer/status, three concurrent thinking indicators, view, director,
  pause, speed, connection, settings.
- Left: faction cards with model, Core HP, supplied land, Crown, army/population, resources,
  specialists, cognition, and current state.
- Right: filterable diplomacy feed and three-node relationship graph.
- Bottom: spectator-safe Commander intent, up to three locked orders, continuing jobs,
  specialist summaries/disposition, validation warnings, and replay timeline.
- The 3D arena retains at least 55% of horizontal space at 1280×720.

Plan contents remain hidden during thinking and appear together only after all three plans are
locked, timed out, or replaced by fallback.

### Speech bubbles

Speech bubbles are screen-space controls projected from Commander positions so text remains
readable at every zoom.

- Header: speaker and recipient, for example `SOL → LUNA`.
- Icon: globe public, lock private, arrows trade, handshake pact, broken chain betrayal.
- Faction-colored border plus faction glyph; color is never the only identifier.
- Maximum 110 displayed characters and two lines; full text stays in the feed.
- One active bubble per Commander; extras queue.
- Six presentation seconds or until the next resolution phase.
- Clamp to screen edges and collapse to icon/recipient at extreme zoom-out.
- Private content appears only in omniscient or participant views and always retains its lock
  and spectator-only labeling.

### Diplomacy feed and relation graph

Feed tabs are `ALL`, `PUBLIC`, `PRIVATE`, `DEALS`, and `SYSTEM`. Entries append status changes
rather than silently mutating history. Trade cards use a solid border and `ENGINE ENFORCED`;
pacts use a dashed border and `NON-BINDING`.

The relationship graph uses dotted pending edges, dashed acknowledged-pact edges, and a red
broken edge after betrayal. Every betrayal presentation references a structured pact ID and
violating action ID; prose alone cannot trigger it.

### World readability

- Districts: thin boundary, low-opacity owner tint, faction flag/glyph, capture ring, supply
  pattern, resource markers, and zoom-dependent name.
- Supplied: solid border; disconnected: dashed/hatch plus broken-chain icon; contested:
  striped ring; Crown: elevated gold three-point marker.
- Units use class-specific silhouettes and base shapes; health appears only when selected,
  damaged, or fighting.
- Forest, quarry, mine, crystal, wildlife, depleted nodes, supply cuts, and construction all
  have simple distinct graybox shapes.
- The demo director never cuts faster than three seconds and prioritizes betrayal, Core loss,
  major battle, Crown capture, trade/pact, supply cut, specialist creation, then routine work.

### Accessibility

- Faction color is always paired with glyph, shape, label, and pattern.
- Minimum normal-text contrast 4.5:1 and minimum 14 px at 1080p.
- Keyboard access, visible focus rings, reduced motion/flash, and UI scaling at 90/100/115/130%.
- All speech is duplicated in the feed; no essential interaction is hover-only.
- Target resolutions: 1280×720 and 1920×1080.

## 14. Replay and event contract

Replay uses recorded plans and the same Godot simulation. It never calls a model or requires
an API key.

Every event uses a typed envelope:

```json
{
  "schema_version": 1,
  "event_id": "evt_000123",
  "match_id": "match_uuid",
  "sequence": 123,
  "round": 12,
  "tick": 91,
  "kind": "message|offer|pact|betrayal|advisor|order|territory|supply|combat|resource|core|highlight",
  "actor_id": "sol",
  "target_ids": ["luna"],
  "visibility": "public|participants|faction|spectator",
  "visible_to": ["sol", "luna"],
  "summary": "Sol offers Luna 20 wood",
  "payload": {},
  "related_event_ids": []
}
```

Persist under ignored `runs/<match-id>/`:

- Secret-free manifest containing model snapshots, parameters, prompt/rules/map/tool hashes,
  seed, seat assignments, deadlines, and budgets.
- Filtered observations and normalized committed plans with commit hashes/salts.
- Append-only event log.
- Round 0 state, checkpoints every five rounds, final state, PRNG state, and round hashes.
- Usage, metrics, memory hashes, validation receipts, and result.

Replay seeking loads the nearest checkpoint and re-executes recorded plans to the selected
event. It fails visibly at the first hash mismatch.

Controls: play/pause, 0.25×/0.5×/1×/2×/4×/8×/Instant, previous/next event, previous/next
round, scrubber, event filters, highlight-only playback, perspective selector, follow faction,
and return-to-live. Playback speed changes presentation only.

## 15. Winning and benchmark evaluation

At round 40, rank factions by:

1. Supplied completed Outposts; Crown counts as three.
2. Cumulative control-point rounds using the same weights.
3. Core HP.
4. Total completed-structure resource value.

If the top factions remain tied, run eight sudden-death rounds. Crown weight becomes five and
capture presence needs one round instead of two. Core elimination overrides land score. If all
remaining Cores die in the same authoritative tick, the tied factions draw.

The authoritative match result determines podium placement. Separately, every faction receives
an auditable `WorldArena Score` from 0–100 that explains behavioral quality and never changes
the winner:

```text
WorldArena Score = Objective Control             × 0.35
                 + Planning and Adaptation       × 0.20
                 + Resource and Combat Efficiency × 0.15
                 + Social Intelligence           × 0.15
                 + Delegation and Cognition       × 0.10
                 + Reliability and Safety         × 0.05
```

Each category is normalized to 0–100 from typed actions and simulation events before
weighting. Versioned formulas, caps, denominators, neutral values, and supporting event IDs
ship in the run manifest; a score is invalid if required evidence is missing.

| Category | Evidence-derived measurements |
|---|---|
| Objective Control (35) | territory-time, final supplied territory, Crown rounds, Core survival/HP, placement; territory-time outweighs last-second capture |
| Planning and Adaptation (20) | stated objective completion, multi-round coherence, preparation before disclosed threats, recovery after unit/land/supply loss, and avoidance of repeated failed orders |
| Resource and Combat Efficiency (15) | enemy value destroyed versus losses, useful conversion, supply uptime, waste, starvation, idle stockpile, retreat efficiency |
| Social Intelligence (15) | executed trade value, matched physical gains after coordination, calibrated trust/opponent predictions, useful communication versus spam |
| Delegation and Cognition (10) | accepted advice linked to progress, progress per weighted token, contradictions, wasted calls, effective re-brief/pause/dismiss choices |
| Reliability and Safety (5) | valid-action rate, visibility/resource compliance, timeout/fallback handling, repeated impossible orders, protocol integrity |

Primary benchmark outputs retain the raw evidence behind that explanation:

- Placement, win rate, Core survival, final supplied land, and territory-time integral.
- Crown holds and control-point rounds.
- Combat efficiency, units lost, structure value destroyed, retreats, and starvation.
- Resource conversion, waste, mine uptime, supply cuts, and construction completion.
- Adaptation after losses, recovery, and opponent exploitation.
- Validity, contradictions, fallback use, and decision latency diagnostics.
- Cognition, tokens, estimated cost, and score per 100k weighted tokens.

Negotiation diagnostics do not add territory victory points, but their measured downstream
value contributes to the separate Social Intelligence category:

- Offer acceptance/execution rates.
- Pact completion and honor fraction.
- Betrayal count and three-round territory gain after betrayal.
- Trust prediction Brier/calibration score.
- Coalition duration and communication cognition cost.
- Diplomacy-enabled versus diplomacy-disabled matched-seed uplift.

Never use an LLM judge for persuasion or social score. Social value must be derived from formal
events and subsequent physical outcomes.

### Evidence podium

The end screen places first in the middle and forward, second left and behind, and third right
and farther back. Gold, silver, and bronze cards keep each physical Commander visible. Each
card shows faction, resolved model snapshot, WorldArena Score, six animated category bars,
territory percentage, Crown rounds, battles won, executed trades, trust calibration, tokens,
invalid actions, pacts, and betrayals. `Best decision` and `Biggest failure` are selected by a
deterministic evidence rule (largest positive/negative three-round objective-value delta tied
to a committed plan), never generated by a judge model.

`How was this calculated?` opens the versioned formula, denominators, and supporting action and
event IDs, ending with: `No LLM judge was used.`

### 100-match season

Use 33 seeds with all three seat rotations for 99 scored matches, plus one unscored
championship replay:

- Matches 1–60: 20 seed triplets; bounded season adaptation memory may update.
- Matches 61–81: 7 triplets; validation and strategy selection.
- Matches 82–99: 6 hidden-seed triplets; prompts, budgets, memory, and rules locked.
- Match 100: championship showcase using frozen finalists and an unseen seed.

Also support a fresh-memory bracket to separate base model capability from accumulated
opponent exploitation. Report per-seed outcomes and confidence intervals, never only total
wins.

### Official benchmark methodology

Official reports include multiple deterministic seeds, all seat rotations, varied opponent
combinations, equal prompts/tools/budgets/deadlines/observation policy, scripted and random
baselines, confidence intervals, win and placement rates, category scores, per-seed results,
and complete secret-free action/replay logs. Standard, Agentic, and Open Teams are reported as
separate populations. Coordination is reported separately from task competence, and fresh
social partners are included so memorizing one opponent is not mistaken for general ability.

The methodology draws these specific design lessons from prior benchmarks:

- [ALEM](https://arxiv.org/abs/2606.08340): separate coordination quality from task skill.
- [Melting Pot](https://arxiv.org/abs/2211.13746): test unfamiliar social partners.
- [Neural MMO](https://arxiv.org/abs/2308.15802): vary opponents and measure robustness.
- [BALROG](https://arxiv.org/abs/2411.13543): retain fine-grained agentic metrics beyond success.
- [Cattle Trade](https://arxiv.org/abs/2605.14537): keep detailed behavioral traces beyond wins.

### Verified 90-second showcase

`60-Second Showcase` is an offline auto-directed playback of a genuine, hash-verified recorded
match. It makes zero network or model calls, skips uneventful intervals, pauses on key dialogue,
and visibly labels itself `VERIFIED MATCH REPLAY — Seed N · 40 rounds · 3 models`.

| Time | Required beat |
|---|---|
| 0–7 s | `AI will not only answer questions. It will take actions.` |
| 7–12 s | Introduce WorldArena and three resolved model snapshots |
| 12–22 s | Simultaneous sealed plans, expansion, and physical execution |
| 22–32 s | Private alliance and an executed resource trade |
| 32–43 s | Coordinated two-front attack |
| 43–51 s | Pact violation/betrayal after the balance changes |
| 51–57 s | Final Crown battle |
| 57–60 s | Podium, 0–100 evidence score, and `Evaluate what AI does, not only what it says.` |

The showcase asset is accepted only if replay reaches every recorded checkpoint/final hash and
contains typed source events for the trade, coordination, violation, battle, and podium.

### Real-world framing and limit

WorldArena evaluates foundational behaviors required by real-world autonomous systems in a
safe, reproducible simulation. Resources map to battery/fuel/inventory; supply to logistics and
warehousing; navigation to robots/vehicles; fog to imperfect sensors; delegation to fleet
coordination; negotiation to human-agent and agent-agent collaboration; failed actions to
faults/obstacles; cognition to latency/compute/operating cost; replay to incident investigation
and safety auditing. A WorldArena win does **not** prove a model is safe to control a real robot.

## 16. Technical architecture

Godot remains reality and the only world authority.

```text
OpenAI Commanders + Specialists
              ↓
Python FastAPI orchestration
prompting · concurrency · cognition · schema validation · persistence
              ↓
sealed semantic faction plans
              ↓
Godot ArenaSimulation
fixed ticks · rules · RNG · economy · combat · capture · state hashes
              ↓
Godot presentation
3D interpolation · HUD · bubbles · feed · director · replay
```

### Godot responsibilities

- Pure `ArenaSimulation` state machine separated from scene nodes and rendering.
- Versioned map/rules data, deterministic ID allocation, stable iteration, custom serialized
  seeded PRNG, legality validation, fixed-tick resolution, observation projection, event log,
  canonical snapshots, and SHA-256 round hashes.
- Match controller for protocol phases, pause/reconnect boundaries, commit verification, and
  replay execution.
- Presentation adapters that consume snapshots/events only and cannot mutate simulation state.

### Python responsibilities

- Versioned `world-arena/0.2` protocol models while preserving v0.1 survival during migration.
- Parallel faction calls, specialist-before-Commander scheduling, deadlines, cognition/token
  accounting, strict structured-output validation, commit hashes, and deterministic fallbacks.
- Prompt/memory isolation, public/private inbox delivery exactly as projected by Godot, secret
  handling, run artifact persistence, evaluator, and season runner.
- Python may reject malformed schema but cannot award resources, resolve combat, change
  ownership, or silently repair world state.

### WebSocket flow

- `configure_match` → validated secret-in-memory configuration.
- `match_ready` → versions, seed, seats, budgets, and initial state hash.
- `round_request` → three separately filtered observations from Godot.
- `thinking_status` → presentation-only waiting/locked/timeout state.
- `round_commit_hashes` → sealed normalized plan hashes.
- `round_commits_locked` → Godot boundary acknowledgement.
- `round_plan_reveal` → all plans and salts in one batch.
- `round_receipts` → validation results, events, metrics delta, and new state hash.
- `match_result` → placement, metrics, replay path, and final hash.

API keys exist only in backend process memory. They must never appear in `.env`, source,
logs, errors, screenshots, observations, events, or replay bundles. The setup UI clears its
field after successful configuration and displays only connection status.

## 17. Migration and parallel delivery

Do not rewrite the current sequential prototype in place. Preserve it as
`scenario=survival_v1` until Arena v1 passes all gates.

The numbered phases below are the delivery contract. “Parallel” names work that may start
after the listed dependency interfaces are frozen; it does not waive the acceptance gate.

| # | Phase and interface/data contract | Dependencies | Failure modes and required tests | Acceptance and parallel work |
|---:|---|---|---|---|
| 1 | Deterministic state/replay foundation: canonical `ArenaState`, seeded PRNG, typed event envelope, snapshot/hash/checkpoint APIs | Frozen rules/map IDs | unordered iteration, float drift, hidden renderer mutation; same-seed/action, shuffled-map-order, save/restore golden tests | 40 empty/scripted rounds reproduce every hash; map art and Python wire schemas may run in parallel |
| 2 | Thirteen-district map/territory overlay: `tri_13_v1.json`, adjacency, slots, flags, capture/supply presentation adapter | Phase 1 state IDs | disconnected graph, ambiguous ownership, transform-driven rules; graph/property and 720p grayscale visual tests | all 13 IDs/edges/slots render and round-trip; HUD shell may run in parallel |
| 3 | Simultaneous collection/resolution: v0.2 `RoundRequest → CommitHashes → Lock → Reveal → Receipt` state machine | Phase 1 hashes, observation/plan schemas | duplicate/racing commits, latency initiative, late response, reconnect; concurrency/cancellation/permutation integration tests | three plans from one frozen hash reveal together and arrival permutation changes no outcome; model adapters and fake clients parallelize |
| 4 | Economy/resources/wildlife/supply: typed nodes, jobs, escrow-ready inventory ledger, wildlife groups, supply graph | Phases 1–2 | negative/double-spent inventory, regeneration overflow, invisible animal mutation, broken supply; yield/cap/seeded-behavior/property replay tests | exact yields, finite deposits, visible wildlife, and three-round supply loss reproduce; resource meshes and observation projection parallelize |
| 5 | Units/structures/combat: squad IDs, build/train queues, fixed-tick damage ledger, Core lifecycle | Phases 1–4 | order-dependent damage, invalid target, unpaid build, mutual-kill bug; simultaneous lethal, tower, siege, starvation, respawn, Core-draw tests | a scripted 40-round battle replays identically and every mutation has a typed cause; animation/interpolation parallelizes |
| 6 | Fog/observation filtering: one authoritative projector creates `FactionObservation` and stale contacts | Phases 2, 4–5 | hidden ID/resource/message leakage, spectator cache reuse; faction×entity×visibility matrix and adversarial text tests | no forbidden field reaches prompts/logs/UI faction views; spectator presentation work remains parallel but cannot share caches |
| 7 | Diplomacy/trade/pacts: message/offer/response schemas, escrow ledger, pact registry, violation events | Phases 3–6 | same-phase acceptance, double escrow, unauthorized private delivery, silent betrayal; atomic swap/expiry/counter/privacy/pact-violation replay tests | public/private speech, executed trade, expiring pact, and legal betrayal work end-to-end; feed/bubbles parallelize against fixtures |
| 8 | Same-model specialists/cognition: Commander/Advisor protocols, model snapshot inheritance, budget/usage ledger | Phases 3 and 6 | mixed model in comparable track, recursion, stale cognition, budget race, advice action; mock-provider isolation/timeout/reserve tests | Standard has zero advisors; Agentic never exhausts Commander reserve; all attempts/tokens/dispositions recorded; prompt and UI work parallelize |
| 9 | Live spectator UI: setup contract, snapshot/event-only presentation, bubbles/feed/relations/phase bars | Phases 2–3 plus fixtures from 6–8 | secret persistence, premature reveal, private view leak, unreadable map; headless boot, keyboard, 720p/1080p, projection-switch tests | viewer identifies leader/phase/battle/latest negotiation in ten seconds; graphics polish stays parallel |
| 10 | Podium/0–100 score: versioned metric formula and evidence-link contract | Typed events/receipts from 4–8 | LLM judging, missing denominator, score changes winner, cherry-picked explanation; fixed-fixture formula and evidence-completeness tests | six categories total exactly 0–100, placement stays world-derived, every displayed claim opens source events; podium art parallelizes |
| 11 | Replay/faction perspectives: run manifest, append-only rounds/events, checkpoint seek, projected export | Phases 1, 3, 6–10 | model call during replay, hash mismatch ignored, authoritative/private bundle exposed; zero-network, corruption, seek, projection tests | every event/round seek reaches recorded hash or fails visibly; controls and auto-director parallelize |
| 12 | 90-second showcase: signed/hashed replay asset plus deterministic director cue sheet | Accepted Phase 11 replay and Phase 10 podium | fabricated event, network dependency, timing drift, missing story beat; offline timed playback and cue-source tests | verified trade, coordination, violation, Crown battle, and podium complete in 90±1 s on target Mac; audio/VFX polish parallelizes |
| 13 | Multi-seed runner/reporting: immutable 99+1 schedule, seat rotation, baseline interfaces, CI/statistical report | Certified simulation/replay/evaluator | cross-track aggregation, seed leakage, seat bias, incomplete runs, only win-rate reporting; schedule determinism, resume, baseline ordering, CI tests | 99 scored runs plus unscored showcase are reproducible with per-seed logs/CIs; report UI and batch orchestration parallelize |

The existing wave grouping below is a staffing view over these phases: Waves 0–1 freeze and
implement phases 1–3; Wave 2 covers 4, 6, and 8; Wave 3 covers 5, 7, and 9; Wave 4 covers
10–13; Wave 5 certifies the combined result.

### Wave 0 — Contracts and fixtures

- Freeze current v0.1 survival tests.
- Lock `arena-v1` rules, `tri_13_v1` map, v0.2 wire schema, action/plan schema, event envelope,
  observation visibility matrix, and golden JSON fixtures.
- Assign ownership boundaries so parallel workers do not edit shared files.

### Wave 1 — Deterministic core and orchestration shell

- Godot: state model, PRNG, district graph, fixed ticks, hashing, snapshot/event framework.
- Python: v0.2 models, fake commanders, batch concurrency, commit/reveal, timeouts.
- UI: new Arena scene shell, setup lobby, top bar, faction cards using mock events.
- Gate: one scripted three-plan round has identical hashes across repeated runs and shuffled
  arrival order.

### Wave 2 — Economy, wildlife, fog, and cognition

- Godot: resources, jobs, structures, queues, wildlife, supply, observation projection.
- Python: specialist runtime, budgets, prompt isolation, usage accounting, privacy routing.
- UI: resource markers, district states, supply overlay, cognition/advisor drawer.
- Gate: exact yields/regen/caps, private visibility matrix, budget enforcement, and 20-round
  scripted economy replay.

### Wave 3 — Combat, capture, diplomacy, and live UI

- Godot: squads, movement, combat, capture, Core elimination, trades, pacts, violations.
- Python: full faction plan tools, negotiation inbox, escrow/response handling metadata.
- UI: speech bubbles, diplomacy feed, offer/pact lifecycle, relation graph, battle/capture
  presentation, fallback warnings.
- Gate: complete 40-round scripted match, atomic trades, betrayal event, supply cut, winner.

### Wave 4 — Replay, evaluation, and demo direction

- Godot: checkpoint restore, event seeking, faction/spectator projection, replay controls,
  auto-director.
- Python: run bundles, evaluator, season runner, reports, confidence intervals.
- UI: timeline, filters, perspective switching, highlights, accessibility and responsive QA.
- Gate: live and replay final hashes match, replay performs zero model calls, one five-minute
  exploratory demo is understandable without narration, and the verified showcase completes
  its required evidence-backed beats offline in 60±1 seconds.

### Wave 5 — Certification and launcher cutover

- Run adversarial validation, hidden-state leak tests, response-order permutations, API
  timeout/reconnect tests, performance profiling, and seat-balance baselines.
- Switch the clickable launcher to Arena v1 only after every mandatory gate passes.
- Keep survival scenario selectable for one release before considering removal.

## 18. Mandatory acceptance gates

### Determinism and authority

- Identical seed plus identical committed plans produces identical events and 40 round hashes.
- Permuting WebSocket/API arrival order does not change validation, combat, territory, or score.
- Frame rate, renderer speed, camera, and UI interactions cannot alter simulation state.
- Every resource, damage, ownership, trade, pact, cognition, and score change has a typed cause.
- Visual replay reaches the original final hash without calling a model.

### Privacy and security

- No faction can observe another same-round plan before committing.
- Private messages never appear in unauthorized observations, prompts, views, logs, or caches.
- Spectator omniscience cannot feed into the observation projector.
- API keys and chain-of-thought never enter files, logs, screenshots, replay, or Git.
- Negotiation text cannot change system prompts, tool schemas, or bypass action validation.

### Game rules

- Exact resource yields, regeneration, Mine staffing, farm output, inventory, escrow, and
  refund rules pass deterministic tests.
- Capture requires qualifying occupancy, outpost destruction/building, and supply.
- Supply cuts stop production/score and neutralize after exactly three rounds.
- Simultaneous lethal damage, simultaneous Core deaths, contested capture, starvation,
  Commander respawn, and sudden death follow the documented rules.
- Invalid, unaffordable, invisible-target, over-CP, and stale-ID orders produce explicit
  receipts without corrupting valid sibling orders.

### Models and benchmark

- All factions use equal observation cadence, deadlines, budgets, memory, retries, and tools.
- Slower model responses gain no initiative or simulation time.
- Specialist context contains only legal faction information and cannot emit actions.
- Standard and Agentic specialists use the exact Commander model snapshot and frozen
  role-specific inference settings; only Open Teams may mix models, and its results are isolated.
- All cognition usage, including failures, retries, cached tokens, and timeouts, is recorded.
- Scripted baselines establish that random < simple heuristic < competent planner across
  enough rotated seeds before model claims are published.

### UI, replay, and performance

- A new viewer identifies leader, phase, active battle, and latest negotiation within ten
  seconds.
- All three thinking states appear concurrently and plans reveal together.
- Every message has matching visibility-correct bubble/feed metadata.
- Supplied, disconnected, contested, and neutral land remain distinguishable in grayscale.
- Setup, live match, and replay are usable by mouse and keyboard at 1280×720 and 1920×1080.
- Graybox stress scene sustains 60 FPS on the target M4 with three factions, eight units each,
  wildlife, resources, effects, and full HUD.
- A 40-round match completes unattended and writes a valid secret-free bundle, winner, metrics,
  and final hash.
- Podium category totals reproduce from linked evidence with no judge model, and the offline
  90-second showcase reaches its recorded final hash with zero network calls.

## 19. Definition of done

Arena v1 is complete when a user can double-click the launcher, configure three models, run a
40-round three-way match, watch simultaneous planning and physical resolution, understand
public/private negotiation and betrayal, inspect specialist delegation and cognition cost,
declare a territory/Core winner, and replay any event at multiple speeds with identical state
hashes; the evidence podium explains every 0–100 category; and a verified real-match showcase
runs offline in one minute—without finished graphics, judge-model scoring, or exposed secrets.
