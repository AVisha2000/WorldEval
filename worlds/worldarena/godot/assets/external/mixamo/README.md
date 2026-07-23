# Mixamo import and retarget contract

The manually downloaded Mixamo **Y Bot** intake is installed locally for the embodiment MVP. Its
human approval, account-scoped source record, export settings, repository paths, and SHA-256 hashes
are sealed in `approved-y-bot.manifest.json`. Adobe-ID sign-in and download remain manual; no
automation may retrieve or replace Adobe-hosted assets without another explicit approved decision.

Expected source settings: a humanoid character/skeleton exported as FBX Binary, one animation per
file, **without skin** for clips after the base character. Keep the downloaded FBX files in a local
review location first, record Adobe source page/date, export settings, licence terms applicable to
the account, and SHA-256 in an approved intake manifest before import.

The embodiment MVP's approved body identity is Mixamo **Y Bot**. The presentation must fail closed
if the sealed files change; it must not silently substitute another rig or return to a procedural
placeholder while claiming the approved identity.

Required normalized clips for the embodiment Operator state machine:

- `idle`
- `walk`
- `run`
- `attack`
- `guard`
- `gather`
- `build`
- `hit`
- `celebrate`
- `defeat`

Import/retarget only after the base skeleton is accepted. In Godot, set the source skeleton profile,
retarget to the project humanoid skeleton, inspect root motion and facing, then save a local
AnimationLibrary/AnimationTree mapping. Do not use Mixamo clips for authoritative simulation;
they are presentation-only.
