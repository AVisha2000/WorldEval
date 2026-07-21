# External art intake

`asset_manifest.json` is the single source of truth for optional third-party art. KayKit is the
recommended initial, coherent family; Quaternius is a coherent alternative. Do not mix families
within a match without an explicit art-direction decision.

No third-party archive is committed by this repository. Before importing a pack, download it
manually from its recorded source, confirm its licence, then record the exact archive URL, release
version/date, and SHA-256 in the manifest. The helper rejects placeholder checksums and archive
URLs, verifies the archive, and refuses to overwrite an existing import.

```sh
# Inspect choices and calculate the hash of an official local download.
python3 scripts/asset_intake.py list
python3 scripts/asset_intake.py sha256 ~/Downloads/KayKit-Example.zip

# After updating that pack's archive_url, version, and sha256 in asset_manifest.json:
python3 scripts/asset_intake.py verify --pack kaykit_adventurers --archive ~/Downloads/KayKit-Example.zip
python3 scripts/asset_intake.py import --pack kaykit_adventurers --archive ~/Downloads/KayKit-Example.zip

# Fetch is opt-in and only works after the immutable URL and checksum are recorded.
python3 scripts/asset_intake.py fetch --pack kaykit_adventurers
```

Imports land in `godot/assets/external/<pack-id>/`. Open the Godot project afterward so Godot can
create its local `.godot` import cache. Review any pack-specific licence or attribution files that
ship in the archive before using the art in a build.
