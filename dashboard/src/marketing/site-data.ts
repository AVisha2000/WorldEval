export type DemoAccent = "amber" | "earth" | "lunar"

export type VideoDemo = {
  id: string
  title: string
  description: string
  youtubeId?: string
  accent: DemoAccent
  featured?: boolean
}

type VideoEnvironment = {
  VITE_YOUTUBE_MVP_ID?: string
  VITE_YOUTUBE_SOLO_ID?: string
  VITE_YOUTUBE_DUEL_ID?: string
}

const YOUTUBE_ID_PATTERN = /^[A-Za-z0-9_-]{11}$/

const DEMO_DEFINITIONS = [
  {
    id: "mvp",
    title: "WorldArena MVP overview",
    description:
      "A guided tour of deterministic worlds, agent loops, and verifiable outcomes.",
    envKey: "VITE_YOUTUBE_MVP_ID",
    accent: "amber",
    featured: true,
  },
  {
    id: "solo",
    title: "Solo construction curriculum",
    description:
      "One agent turns a structured observation into a sequence of world-changing actions.",
    envKey: "VITE_YOUTUBE_SOLO_ID",
    accent: "earth",
  },
  {
    id: "duel",
    title: "Symmetric two-leg agent duel",
    description:
      "Seat-balanced matches preserve comparable evidence across both legs.",
    envKey: "VITE_YOUTUBE_DUEL_ID",
    accent: "lunar",
  },
] as const

export function getVideoDemos(
  environment: VideoEnvironment = import.meta.env as VideoEnvironment
): VideoDemo[] {
  return DEMO_DEFINITIONS.map((demo) => {
    const candidate = environment[demo.envKey]?.trim()
    const youtubeId =
      candidate && YOUTUBE_ID_PATTERN.test(candidate) ? candidate : undefined
    return {
      id: demo.id,
      title: demo.title,
      description: demo.description,
      accent: demo.accent,
      featured: "featured" in demo ? demo.featured : false,
      ...(youtubeId ? { youtubeId } : {}),
    }
  })
}

export function getControllerLabUrl(
  value = import.meta.env.VITE_CONTROLLER_LAB_URL
): string | undefined {
  if (!value?.trim()) return undefined
  try {
    const url = new URL(value.trim())
    const localHostnames = new Set([
      "localhost",
      "127.0.0.1",
      "0.0.0.0",
      "[::1]",
      "::1",
    ])
    if (
      !["http:", "https:"].includes(url.protocol) ||
      localHostnames.has(url.hostname)
    )
      return undefined
    return url.toString()
  } catch {
    return undefined
  }
}

export const REPOSITORY_URL = "https://github.com/AVisha2000/WorldArena"
export const DOCUMENTATION_URL = `${REPOSITORY_URL}#readme`
