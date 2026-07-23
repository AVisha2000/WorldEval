# Deterministic Hero and inventory authority

This directory owns the selected faction's named Heroes, integer attributes,
experience and levels, learned ranks, six-slot inventories, dropped items,
breakable periodic consumables, and altar/Tavern revival state.

`DuelHeroSystem` consumes only the locked rules, selected-faction, and item
catalogs. It contains no faction balance constants. `DuelHeroState` is fully
canonical and is included in every checkpoint once configured.

The generic phase-10 lifecycle remains the single alive-to-dead authority.
Hero-specific death metadata is attached immediately after that transition.
Inventory, periodic effects, item despawn, and revival resolve in phase 11.
Presentation code must observe emitted events and must never mutate this state.
