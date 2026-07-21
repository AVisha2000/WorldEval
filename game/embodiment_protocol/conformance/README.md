# Embodiment protocol conformance corpus

`protocol-conformance.v1.json` is the shared Python/Godot Phase-0 corpus. Consumers must preserve
the case order and must not normalize a `raw_json` input before parsing it. This is what makes the
duplicate-key cases meaningful.

For an `instance` input, serialize with the protocol canonical JSON implementation before applying
the wire byte ceiling. When `utf8_repeat` is present, replace the string at its RFC 6901 `pointer`
with `text` repeated `count` times before serialization. Limits on `memory_update` and observation
`memory` are UTF-8 byte limits; JSON Schema `maxLength` remains only a structural/code-point guard.

`advance_ticks` is the authoritative time advance for the resolved decision window. In particular,
a malformed, stale, missing, or timed-out duel response becomes `no_input` with neutral controls and
still advances the common fixed ten-tick window.
