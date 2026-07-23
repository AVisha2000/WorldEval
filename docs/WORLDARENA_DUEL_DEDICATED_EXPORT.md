# WorldArena Duel dedicated export boundary

This document defines the certifiable resource boundary for the Duel authority. It implements the
dedicated-server packaging part of Section 17.6 of the implementation specification; it does not
sign, publish, or deploy a build.

## Frozen contract

- Engine: `4.5.stable.official.876b29033` only.
- Platform preset: Godot 4.5's `Linux` exporter, `x86_64` architecture.
- Renderer policy: the source project remains on `gl_compatibility`.
- Runtime feature: `dedicated_server=true`, which makes an exported project use the headless display
  server and Dummy audio driver.
- Resource mode: explicit selected-resource allowlist. Every `worlds/worldarena/godot/scripts/duel/*.gd` file outside the
  visual/launch `app/` and `presentation/` subtrees must appear exactly once. Adding a new authority
  script fails certification until the preset is deliberately updated.
- Script mode: text. This lets the archive inspector compare every exported script byte-for-byte
  with its certified staged source.
- Scene conversion: disabled in the temporary stage. The one nonvisual CLI `.tscn` therefore stays
  auditable text instead of becoming an opaque generated `.scn` plus remap.
- File logging: disabled for both generic and desktop overrides. Protected managed-launch input and
  offline authority secrets therefore cannot be copied into Godot's rotating log files.
- Canonical data: every runtime file from `worlds/worldarena/game/duel_protocol/` is copied byte-for-byte into the
  temporary project at `res://data/duel_protocol/`. `README.md` is the sole documentation-only
  omission. Authority paths are relocated only in the temporary copy; checked-in gameplay code is
  not rewritten.
- Default staged entrypoint: one nonvisual `Node` scene that calls `DuelHeadlessCli`. A PCK or
  executable made from the stage therefore boots the provider-free command-line authority without
  a `--script` override.
- Managed alternate entrypoint: `duel_managed_authority_cli.gd` is packaged for the Python-owned
  live process and must be selected explicitly with `--script`. It accepts its one protected launch
  envelope only from a bounded anonymous stdin pipe; it is not the default offline entrypoint.

The authoritative policy is
`worlds/worldarena/godot/duel_dedicated_export_policy.json`, and the matching Godot preset is
`worlds/worldarena/godot/export_presets.cfg`.

## Explicit exclusions

The export cannot contain any of these trees:

- `addons/`, including Terrain3D and LimboAI or any native library;
- `assets/`, `art/`, presentation scenes, arena scenes/scripts, showcases, or tests;
- `worlds/worldarena/godot/scripts/duel/app/`, including the visual coordinator and outbound HTTP launch client;
- `worlds/worldarena/godot/scripts/duel/presentation/`;
- textures, meshes, materials, animations, visual/gameplay scenes, particles/shaders, audio,
  fonts, or native extension formats. The exact nonvisual CLI `.tscn` is the sole scene exception.

The source editor deliberately keeps only Terrain3D's editor plugin enabled for optional spectator
authoring. LimboAI remains an optional presentation dependency but is not an enabled editor plugin.
The staging step replaces the plugin list with an empty array, so neither dependency is initialized
or copied. This is tested both at preset level and against the emitted ZIP inventory.

## Validate and stage

From the repository root:

```sh
.venv/bin/python worlds/worldarena/scripts/validate_duel_dedicated_export.py \
  --godot /Applications/Godot.app/Contents/MacOS/Godot \
  --json

duel_stage="$(mktemp -d /tmp/worldarena-duel-export.XXXXXX)"
.venv/bin/python worlds/worldarena/scripts/validate_duel_dedicated_export.py \
  --stage "$duel_stage" \
  --json

/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path "$duel_stage" --import

/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path "$duel_stage" \
  --script res://certification/duel_dedicated_stage_smoke_runner.gd
```

The staging destination must be empty. The tool never clears or overwrites a non-empty directory.
It emits `DUEL_DEDICATED_STAGE_MANIFEST.json` with the source-stage inventory and SHA-256 values.
The smoke runner requires the headless display driver, Dummy audio, the nonvisual CLI scene as the
staged entrypoint, every selected script to parse, and the relocated locked catalogs to validate.

## Headless execution input

`duel_headless_cli.gd` accepts one canonical RFC 8785 JSON run document and an optional canonical
action-transcript array. The run document has this exact top-level shape:

```json
{
  "authority": {
    "alias_salt_seat_0_hex": "<32 lowercase hex bytes>",
    "alias_salt_seat_1_hex": "<32 lowercase hex bytes>",
    "default_commit_salt_seat_0_hex": "<32 lowercase hex bytes>",
    "default_commit_salt_seat_1_hex": "<32 lowercase hex bytes>",
    "tie_key_hex": "<32 lowercase hex bytes>"
  },
  "completion": {
    "fill_missing_with_noop": false,
    "post_first_application_disposition": null
  },
  "locks": {
    "match_config_sha256": "<canonical MATCH_CONFIG SHA-256>",
    "match_init_sha256": "<canonical MATCH_INIT SHA-256>",
    "transcript_sha256": "<canonical transcript SHA-256>"
  },
  "match_config": {"...": "complete match-config.v1, including null optionals"},
  "match_init": {"...": "complete immutable match-init.v1"},
  "schema_version": "worldeval-rts/headless-run/1.0.0"
}
```

The runner accepts only the official fixed profile: mode `fixed_simultaneous`, 100-tick cadence,
45,000 ms declared response deadline, 10 Hz, mirrored official faction/map, and an 18,000-tick
limit. `MATCH_INIT.artifacts.engine_build` must identify the frozen
`godot-4.5.stable.official.876b29033` artifact with SHA-256
`39b904eb0014941330f6435796ae0a041979802047495eb6fb87d59f327de719`; the CLI separately verifies
the running executable's Godot version identity. It does not sleep or consult wall time; once
actions are present, simulation advances as quickly as the host can execute deterministic ticks.
Continuous mode is rejected because a no-network process cannot truthfully invent provider arrival
gates or realtime deadline outcomes.

Each optional transcript entry is the canonical fixed reveal request without `match_id`:

```json
{
  "activation_tick": 1,
  "batches": [
    {"batch": {"...": "slot-0 action_batch"}, "player_slot": 0, "salt_hex": "<32 bytes>"},
    {"batch": {"...": "slot-1 action_batch"}, "player_slot": 1, "salt_hex": "<32 bytes>"}
  ],
  "boundary_tick": 0,
  "disposition": "continue",
  "observation_seq": 0,
  "opportunity_id": "opp_00000000"
}
```

Entries are ordered by `observation_seq`; boundary tick is `seq * 100`, activation tick is boundary
plus one, and both batches must bind to the exact observer-specific hash emitted by the rerun. The
CLI verifies the transcript hash before bootstrap and then repeats batch/schema, observation,
commit, and reveal checks inside Godot. With `fill_missing_with_noop=true`, a missing entry becomes
a deterministic empty command batch for each seat using the locked default commit salts. This is
useful for diagnostics and baseline policies; scored model actions should normally be explicit.
`post_first_application_disposition` is an explicit short-run diagnostic/replay control and may be
one of the four official terminal dispositions. It is never inferred from model behavior.

The run document and reveal transcript are protected inputs because they contain authority and
commit salts. Keep them outside the output directory with deployment-controlled permissions, and
do not publish them with replay artifacts. The CLI hashes and consumes them but never copies those
secret fields into its output bundle.

Source-project invocation:

```sh
input_sha256="$(shasum -a 256 /absolute/run.json | cut -d ' ' -f 1)"
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path /absolute/WorldEval/worlds/worldarena/godot \
  --script res://scripts/duel/match/duel_headless_cli.gd -- \
  --input=/absolute/run.json \
  --expected-input-sha256="$input_sha256" \
  --transcript=/absolute/actions.json \
  --output-dir=/absolute/new-output-directory
```

The equivalent environment variables are `WORLDARENA_DUEL_HEADLESS_INPUT`,
`WORLDARENA_DUEL_HEADLESS_INPUT_SHA256`, `WORLDARENA_DUEL_HEADLESS_TRANSCRIPT`, and
`WORLDARENA_DUEL_HEADLESS_OUTPUT_DIR`. Explicit arguments override environment values. Input,
transcript, and output paths must be absolute; the output directory must be absent or empty. Omit
the transcript path only when the locked transcript is the canonical empty array (`[]`).

On success the directory contains canonical `accepted-actions.ndjson`,
`compiled-orders.ndjson`, `public-events.ndjson`, `state-checkpoints.json`,
`action-receipts.ndjson`, `terminal-result.json`, and `replay-manifest.json`. The manifest validates
against `replay-manifest.v1.schema.json`, names the four publishable replay roles, reports zero
provider requests/tokens, and labels both provider tiers `offline-transcript`. Receipts appear both
in accepted-action rows and in the convenience receipt stream. The protected tie key, alias salts,
commit salts, observations, working memory, and raw model material are not emitted.

## Export and inspect the actual package

Godot can generate a resource ZIP without installing platform export templates. Keeping the archive
outside the staged project avoids making the output a candidate input:

```sh
duel_archive="${duel_stage}.zip"
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path "$duel_stage" \
  --export-pack "WorldArena Duel Dedicated Server" "$duel_archive"

.venv/bin/python worlds/worldarena/scripts/validate_duel_dedicated_export.py \
  --inspect-zip "$duel_archive" \
  --json
```

The archive inspector rejects unsafe or duplicate paths, any non-allowlisted file, every forbidden
visual/native suffix or directory, missing authority/protocol files, changed staged authority
bytes, and protocol bytes that differ from `worlds/worldarena/game/duel_protocol/`. A passing archive currently has
68 authority scripts, one nonvisual CLI scene, 35 canonical protocol files, Godot's two internal
UID/class-cache files, and `project.binary`; it has no presentation or native payload.

## Certification limits

- The checked-in machine does not currently have Godot 4.5 Linux release templates, so an
  `x86_64` executable was not produced. Resource ZIP export and full archive inspection do work.
- The standalone runner re-executes economy-enabled matches only from the official genesis state.
  `duel_replay.gd` still rejects economy-enabled checkpoint restoration, so arbitrary mid-match
  restore/seek and independent replay-from-checkpoint certification remain unavailable. The
  emitted replay manifest and checkpoints are deterministic execution evidence for the Python
  sealing/verifier layer; they do not pretend that the missing restoration API exists.
- Linux executable creation, containerization, signing, publishing, and deployment must be separate
  release steps after installing the exact 4.5 templates. A produced ZIP/PCK must pass the archive
  inspector before it is paired with a release template.

Godot's dedicated-server export model and the `dedicated_server` feature behavior are described in
the [official Godot documentation](https://docs.godotengine.org/en/4.5/tutorials/export/exporting_for_dedicated_servers.html).
