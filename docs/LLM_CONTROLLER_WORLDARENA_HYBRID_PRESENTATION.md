# LLM Controller × WorldArena hybrid presentation

Phase 3 adds a participant-scoped presentation pipeline without moving authority into the scene.
The deterministic authority remains integer-only and presentation-free; rendering converts copied
millilitre positions to floating-point scene coordinates only after the privacy boundary.

## Boundary sequence

1. Authority emits a detached internal presentation source with its opaque checkpoint hash and the
   semantic entity fields already computed by authority visibility.
2. The privacy filter accepts an explicit participant and visible-entity ID list. It rejects
   unknown fields, floats, duplicate or unknown IDs, and spectator data, then deep-copies a
   participant-only render snapshot.
3. Visible text is projected from that same filtered snapshot. Presentation does not recompute
   range, bearing, affordances, or visibility.
4. The procedural scene receives a smaller exact-shape projection. Any omitted entity is removed;
   stale hidden objects cannot remain in the scene.
5. The participant camera produces a 1280×720 lossless PNG. A bounded episode-only frame store
   binds the PNG hash, transport reference, visible-snapshot hash, text-projection hash, participant,
   observation sequence, and authority checkpoint hash.

The player hybrid observation contains the existing visible semantic payload plus only schema-safe
frame metadata. Exact render positions, the checkpoint binding, and capture records stay protected
and never enter player observations or replay goldens.

## Scene and camera

The compact arena uses a close third-person follow camera owned by the participant projection.
Procedural shapes distinguish the Operator, resource, relay, build pad, growing barricade, beacon,
and neutral. Stage-C construction progress creates a visible barricade projection derived only from
the visible build-pad state. Scene updates are idempotent and cannot mutate their source snapshot or
the authority checkpoint.

## Asset intake gate

No external model or animation was downloaded in Phase 3. The Operator node is explicitly marked
`procedural_operator_placeholder`; it must not be described as Mixamo Y Bot. Y Bot and animation
clips may replace the placeholder only after the user manually supplies them and the intake is
reviewed for identity, rig, clip list, licensing provenance, hashes, scale, and animation-only
imports. That later replacement remains presentation-only and must leave all authority and golden
hashes unchanged.

## Rendering environments

The capture API supports a real `SubViewport` and a deterministic renderer provider. macOS Godot
headless mode exposes only the dummy renderer, so headless tests use the deterministic provider
while separately exercising the scene and participant camera. The local GPU-backed certification
uses the macOS display driver and OpenGL compatibility renderer, captures the real viewport, and
validates the same PNG, privacy, digest-binding, and authority-immutability contracts.
