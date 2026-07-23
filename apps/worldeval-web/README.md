# WorldArena dashboard and public site

This Vite workspace has two entry points:

- the local FastAPI-backed Controller Lab for credential-free Demo runs; and
- the static WorldArena GitHub Pages site.

The Demo provider requires no API key and makes no provider network call. Its versioned mock
policies still travel through strict JSON parsing, validation, Godot authority, evaluation, and
replay. Demo results are always non-certifying.

## Local Controller Lab

```bash
cd dashboard
pnpm install --frozen-lockfile
pnpm dev
```

Run the backend from the repository root in another terminal:

```bash
.venv/bin/uvicorn genesis_arena.main:app --host 127.0.0.1 --port 8000
```

Select **Demo (no API key)** in Setup. The product exposes solo Stages A–D, the multi-action
showcase and two solo control games, the seat-swapped 1v1 ladder, and three-seat Relay/Free-for-All
Demo games. The browser receives participant-filtered pixels and allow-listed timeline/evaluation
data only—never prompts, raw provider output, credentials, hidden state, or spectator views.

The **Pre-run saves** library also exposes four immutable highlights: Solo Multi-Action
Construction, Labyrinth Run, Mini RTS Skirmish, and **Crossroads Conquest**. Every video is checked
into the repository and served through a cached `GET` route, so a fresh hosted Lab needs no local
run archive. Crossroads playback never posts a new run; its Evaluation and Replay tabs fetch the
public evaluation lazily, while the authority replay stays server-side and has no browser route.

## Builds

The normal build preserves the FastAPI-backed Controller Lab:

```bash
pnpm build
```

The dedicated GitHub Pages build selects the static WorldEval marketing site and defaults to the
`/WorldEval/` base path:

```bash
pnpm build:pages
```

The Pages workflow derives the base path from the GitHub repository name. For another deployment
target, set `VITE_BASE_PATH=/repository-name/`.

## Public-site configuration

The public game showcase uses checked-in screenshots from Crossroads Conquest, Labyrinth Run, and
Mini RTS Skirmish. Every game card and the primary call to action open the hosted Controller Lab.

| Variable                  | Purpose                                                                                          |
| ------------------------- | ------------------------------------------------------------------------------------------------ |
| `VITE_CONTROLLER_LAB_URL` | Optional public HTTP(S) override for the Controller Lab. Localhost values fall back to the hosted lab. |

The hosted lab URL is the default in `src/marketing/site-data.ts`; the Pages workflow can override
it with the repository variable `CONTROLLER_LAB_URL`. Invalid and local URLs fall back to
`https://lab.openai-buildweek.lissan.dev/` so the published site always has a working destination.

## Verification

```bash
pnpm lint
pnpm test
pnpm typecheck
pnpm build
pnpm build:pages
```
