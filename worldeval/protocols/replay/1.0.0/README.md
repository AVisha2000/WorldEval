# WorldEval replay bundle 1.0.0

This package defines the game-neutral outer envelope used to persist terminal WorldEval demos.
Native replay bytes are never rewritten. Their descriptors carry the native schema, verifier,
final-state hash, content hash, size, and disclosure layer.

The manifest uses `rfc8785-integer-nfc-subset-v1`: UTF-8 NFC strings, interoperable integers,
UTF-16 key ordering, compact encoding, no duplicate keys, and no floating-point values. The
`seal.value` is the lowercase SHA-256 of the canonical manifest after removing `seal`.

Media descriptors are explicitly optional because media is derived from replay evidence. Missing
media can be regenerated and does not invalidate the replay; present media must still match its
descriptor. An incomplete run is stored using `incomplete-run.v1.schema.json` and must never be
presented as a replay bundle.
