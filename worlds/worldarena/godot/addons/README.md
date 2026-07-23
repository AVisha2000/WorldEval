# Optional native addons

`external_packages.json` pins the reviewed release archives installed in this directory:
Terrain3D `v1.0.1-stable` and LimboAI `v1.6.0` GDExtension build. Their upstream license files are
preserved inside each addon. Neither addon is currently enabled by `project.godot` or required by
the compact RTS arena.

Before enabling either addon, smoke-test the pinned files with Godot 4.5 and the Compatibility
renderer on the target macOS architecture. Review macOS quarantine/provenance for native binaries;
do not substitute a branch or "latest" build. LimboAI must remain outside deterministic, scored
simulation behavior and is limited to cosmetic/wildlife NPC use.
