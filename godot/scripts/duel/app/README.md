# Interactive Duel launch path

`duel_v1.tscn` is rooted at `DuelAppCoordinator`. It keeps three boundaries separate:

- `DuelPresentation` owns setup and read-only spectator widgets;
- `DuelLaunchClient` sends one strict `caller_owned` match request to the loopback service and
  consumes its creation-only launch claim exactly once;
- `DuelMatchController` owns the authenticated Godot authority lifecycle.

The setup panel emits a credential-free public summary separately from the protected API request.
OpenAI slots require an explicit model, reasoning value, and key. Baseline slots use the frozen
provider/model pairs and force `reasoning=none` with no key or service tier. Protected LineEdits are
cleared only after the injected HTTP transport accepts the request body. The real transport keeps
one in-flight byte copy, overwrites it on completion, and exposes no body through debug state.

The one-time claim response is validated for exact fields. JSON byte arrays for the session token,
tie key, and observer salts are converted to `PackedByteArray` before
`DuelMatchController.configure_launch`. The coordinator starts the controller and reveals the live
surface only after the authenticated authority reports ready.

Run the focused contract test with:

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path godot \
  --script res://tests/duel/duel_launch_path_headless_runner.gd
```

