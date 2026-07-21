# React + TypeScript + Vite + shadcn/ui

This is a template for a new Vite project with React, TypeScript, and shadcn/ui.

## Adding components

To add components to your app, run the following command:

```bash
npx shadcn@latest add button
```

This will place the ui components in the `src/components` directory.

## Using components

To use the components in your app, import them as follows:

```tsx
import { Button } from "@/components/ui/button"
```

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

All values are optional. Missing videos render coming-soon posters and never create a YouTube
iframe. A video iframe is created only after a visitor clicks its play control.

| Variable                  | Purpose                                                                            |
| ------------------------- | ---------------------------------------------------------------------------------- |
| `VITE_CONTROLLER_LAB_URL` | Public HTTP(S) URL for the external Controller Lab. Localhost values are rejected. |
| `VITE_YOUTUBE_MVP_ID`     | YouTube ID for the WorldArena MVP overview.                                        |
| `VITE_YOUTUBE_SOLO_ID`    | YouTube ID for the solo construction curriculum.                                   |
| `VITE_YOUTUBE_DUEL_ID`    | YouTube ID for the symmetric two-leg duel.                                         |

The three demo definitions live together in `src/marketing/site-data.ts`. The GitHub Pages workflow
reads matching repository variables named `CONTROLLER_LAB_URL`, `YOUTUBE_MVP_ID`,
`YOUTUBE_SOLO_ID`, and `YOUTUBE_DUEL_ID`.
