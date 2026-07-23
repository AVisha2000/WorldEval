# WorldArena Duel managed authority

`managed_process` is the unattended live-match launch mode. The Python Duel service owns one
headless Godot process for each match, while Godot remains authoritative for simulation and Python
remains authoritative for model/provider scheduling.

## Production path

1. `DuelMatchService` assembles and locks MATCH_INIT, creates the authenticated gateway session,
   registers a single-use WebSocket attachment capability, and builds a one-use launch spec.
2. `GodotManagedProcessLauncher` validates the configured executable/project and independently
   rejects every gateway URL except an explicit `ws://` loopback endpoint whose final path segment
   is the registered attachment capability.
3. Python starts the fixed `duel_managed_authority_cli.gd` resource directly. Arguments contain
   only the executable path, fixed headless flags, project path, and fixed resource path.
4. One canonical `worldeval-rts/managed-authority-launch/1.0.0` JSON object is written to the
   child's anonymous stdin transport. Python closes stdin immediately after the write.
5. Godot accepts only an anonymous pipe or socket-like handle, reads at most 4 MiB through EOF,
   verifies exact UTF-8 and canonical JSON, validates exact fields and 32-byte key material, and
   configures the existing `DuelMatchController`.
6. Godot emits a small fixed `worldarena_duel_managed_started` control record. The Python launcher
   then returns an owned handle to `DuelMatchService`; normal authenticated WebSocket attachment
   and match execution continue through the existing gateway.
7. Completion, cancellation, service shutdown, bootstrap failure, and authentication failure all
   terminate and reap the exact owned child. Termination is bounded and escalates to kill.

The bootstrap never calls a model provider. Its only network client is the existing Duel gateway
client, which accepts loopback WebSocket URLs only.

## Protected-material policy

The child environment is rebuilt from a minimal non-secret allowlist instead of inheriting the
service environment. Provider API keys therefore cannot enter Godot. The following values are also
forbidden from argv, environment variables, output records, and persistent launch files:

- WebSocket attachment capability and gateway URL
- authenticated session secret
- deterministic tie key
- both observer-alias salts
- canonical MATCH_INIT bytes

Godot project file logging is disabled on desktop and other platforms. The launcher captures and
drains stdout/stderr without forwarding or retaining arbitrary child output; it recognizes only
fixed, bounded control records. Neither error path interpolates launch data or internal exception
text.

The built-in application runner disables Uvicorn access logging because the one-use WebSocket
attachment capability is transported in the socket path. Alternate ASGI deployment commands must
also disable or explicitly redact access logs for `/ws/duel/*`; using an external server with raw
path logging is outside this credential-safe deployment profile.

Python serializes through a mutable byte buffer and overwrites/releases that buffer after handoff.
The launch spec's private byte arrays are also overwritten after managed launch, caller-owned
claim, cancellation, or service shutdown. Godot overwrites its raw stdin buffer and transient key
arrays immediately after the controller has derived/copied the required authority state. Python
and Godot strings are immutable, so the guarantee for string capabilities is reference release,
not an impossible in-place overwrite; the capability remains valid only until the one WebSocket
attachment consumes it.

## Stable launch failures

Public service/API failures expose only stable codes, including:

- `duel_godot_executable_unavailable`
- `duel_godot_project_unavailable`
- `duel_godot_gateway_not_loopback`
- `duel_godot_spawn_failed`
- `duel_godot_ipc_failed`
- `duel_godot_bootstrap_timeout`
- `duel_godot_bootstrap_input_rejected`
- `duel_godot_environment_rejected`
- `duel_godot_engine_mismatch`
- `duel_godot_controller_rejected`
- `duel_godot_controller_start_failed`

Exception text, paths supplied inside a launch document, and Godot parser/controller diagnostics do
not cross the public API.

## Configuration

The application passes these existing settings into the default service:

- `GENESIS_GODOT_EXECUTABLE`: pinned Godot 4.5 executable
- `GENESIS_GODOT_PROJECT_PATH`: WorldArena Godot project directory
- `GENESIS_PORT`: loopback API/WebSocket port

The default repository configuration discovers the conventional macOS Godot path or a `godot`
binary on `PATH` when it is used outside the application settings object. Missing or incompatible
runtimes fail closed when a managed match is explicitly created; constructing the service makes no
process or network call.

## Packaging boundary

The certified dedicated resource archive includes `duel_managed_authority_cli.gd`, but its default
scene remains the provider-free offline transcript CLI. The managed application path currently runs
the pinned Godot executable with the certified project resource using `--script`. A separately
packaged managed-server executable would need a dedicated default scene/console wrapper per target
platform; that packaging variant is not silently claimed by this implementation.

Godot 4.5 reports Python's macOS asyncio stdin socketpair as `STD_HANDLE_UNKNOWN`, while ordinary
shell pipes report `STD_HANDLE_PIPE`. The bootstrap accepts those two nonpersistent handle kinds and
rejects `STD_HANDLE_CONSOLE`, `STD_HANDLE_FILE`, and `STD_HANDLE_INVALID`. This distinction is covered
by both a real pinned-engine smoke test and fake-process isolation tests.

## Verification

```text
.venv/bin/pytest -q \
  worlds/worldarena/tests/duel/test_duel_managed_process_launcher.py \
  worlds/worldarena/tests/duel/test_duel_match_service.py \
  worlds/worldarena/tests/duel/test_duel_api.py
```

The focused suite verifies canonical stdin-only handoff, a stripped child environment, loopback
rejection before spawn, stable bootstrap errors, parent-side byte scrubbing, idempotent bounded
shutdown, the real pinned Godot bootstrap, service lifecycle behavior, and API classification.
