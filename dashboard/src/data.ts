import type { EpisodeView } from "@/api"
export const DEMO_EPISODE: EpisodeView = { kind: "episode", episodeId: "ep_stage_c_preview", status: "running", observationSeq: 14, tick: 126, taskLabel: "Stage C · Construction", timeline: [
  { window: 10, intent: "Move toward the blueprint.", receipt: "accepted", ticks: "91–97", latencyMs: 182 },
  { window: 11, intent: "Adjust view to align with the doorway.", receipt: "accepted", ticks: "98–104", latencyMs: 167 },
  { window: 12, intent: "Gather the second material.", receipt: "accepted", ticks: "105–112", latencyMs: 174 },
  { window: 13, intent: "Return to the construction pad.", receipt: "accepted", ticks: "113–125", latencyMs: 193 },
  { window: 14, intent: "Resume construction at the doorway.", receipt: "accepted", ticks: "126–135", latencyMs: 188 },
] }
export const PROVIDER_MODELS = { openai: "gpt-5.6-sol", anthropic: "claude-sonnet-4-5", gemini: "gemini-2.5-pro" } as const
export const OPENAI_MODELS = [
  { value: "gpt-5.6-sol", label: "GPT-5.6 Sol · flagship" },
  { value: "gpt-5.6-terra", label: "GPT-5.6 Terra · balanced" },
  { value: "gpt-5.6-luna", label: "GPT-5.6 Luna · fast" },
] as const
