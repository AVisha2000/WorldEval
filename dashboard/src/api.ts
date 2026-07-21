export type Provider = "openai" | "anthropic" | "gemini"
export type OpponentProvider = Provider | "scripted"
export type EpisodeSetup = {
  mode: "solo" | "duel"
  provider: Provider
  model: string
  apiKey: string
  opponentProvider: OpponentProvider
  opponentModel: string
  opponentApiKey: string
  taskId: string
  seed: number
}
export type TimelineRow = {
  window: number
  intent: string
  receipt: string
  ticks: string
  latencyMs: number | null
}
export type EpisodeView = {
  kind: "episode" | "series"
  episodeId: string
  status: "queued" | "running" | "success" | "failure" | "cancelled"
  observationSeq: number
  tick: number
  taskLabel: string
  timeline: TimelineRow[]
  result?: {
    finalStateHash: string
    providerFailures: number
    outcome: string
    windows: number
  }
}

export type ParticipantFrameView = {
  blob: Blob | null
  observationSeq: number | null
  sha256: string | null
  state: "loading" | "live" | "finished"
}

export type ReadinessGate = {
  id: string
  label: string
  passed: boolean
  code: string | null
}

export type ReadinessView = {
  format: "llm-controller/embodiment-readiness-view/1.1.0"
  gates: ReadinessGate[]
  ready_for_promotion: boolean
  report_available: boolean
  runtime_capabilities: { passed: boolean; code: string | null }
  source_fingerprint: string | null
}

async function checked<T>(response: Response): Promise<T> {
  if (!response.ok) throw new Error(`Episode service returned ${response.status}`)
  return response.json() as Promise<T>
}

export async function createEpisode(setup: EpisodeSetup): Promise<EpisodeView> {
  const raw = await checked<Record<string, unknown>>(
    await fetch("/api/embodiment/episodes", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      cache: "no-store",
      body: JSON.stringify({
        provider: setup.provider,
        model: setup.model,
        api_key: setup.apiKey,
        task_id: setup.taskId,
        seed: setup.seed,
        observation_profile: "hybrid-visible-v1",
        maximum_episode_ticks: 600,
      }),
    }),
  )
  return normalizeEpisode(raw, [])
}

export async function createRun(setup: EpisodeSetup): Promise<EpisodeView> {
  if (setup.mode === "solo") return createEpisode(setup)
  const opponent = setup.opponentProvider === "scripted"
    ? { provider: "scripted", model: setup.opponentModel }
    : {
        provider: setup.opponentProvider,
        model: setup.opponentModel,
        api_key: setup.opponentApiKey,
      }
  const raw = await checked<Record<string, unknown>>(
    await fetch("/api/embodiment/series", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      cache: "no-store",
      body: JSON.stringify({
        seed: setup.seed,
        max_live_provider_calls: setup.opponentProvider === "scripted" ? 360 : 720,
        entrants: [
          { provider: setup.provider, model: setup.model, api_key: setup.apiKey },
          opponent,
        ],
      }),
    }),
  )
  return normalizeSeries(raw)
}

export async function cancelRun(episodeId: string): Promise<void> {
  const route = episodeId.startsWith("series_")
    ? `/api/embodiment/series/${episodeId}/cancel`
    : `/api/embodiment/episodes/${episodeId}/cancel`
  await checked<Record<string, unknown>>(
    await fetch(route, { method: "POST", cache: "no-store" }),
  )
}

export async function getEpisode(episodeId: string): Promise<EpisodeView> {
  if (episodeId.startsWith("series_")) return getSeries(episodeId)
  const [status, timeline] = await Promise.all([
    checked<Record<string, unknown>>(
      await fetch(`/api/embodiment/episodes/${episodeId}`, { cache: "no-store" }),
    ),
    checked<{ events: unknown[] }>(
      await fetch(`/api/embodiment/episodes/${episodeId}/timeline`, { cache: "no-store" }),
    ),
  ])
  const state = String(status.state ?? "queued")
  if (["completed", "failed", "cancelled"].includes(state)) {
    const result = await checked<Record<string, unknown>>(
      await fetch(`/api/embodiment/episodes/${episodeId}/result`, { cache: "no-store" }),
    )
    return normalizeEpisode(result, timeline.events)
  }
  return normalizeEpisode(status, timeline.events)
}

export async function getParticipantFrame(episodeId: string): Promise<ParticipantFrameView> {
  const response = await fetch(`/api/embodiment/episodes/${episodeId}/frame`, {
    cache: "no-store",
  })
  const state = response.headers.get("X-Frame-State")
  if (!(["loading", "live", "finished"] as const).includes(state as ParticipantFrameView["state"])) {
    throw new Error("Participant frame state is invalid")
  }
  if (response.status === 204) {
    return {
      blob: null,
      observationSeq: null,
      sha256: null,
      state: state as ParticipantFrameView["state"],
    }
  }
  if (!response.ok || response.headers.get("Content-Type")?.split(";", 1)[0] !== "image/png") {
    throw new Error(`Participant frame service returned ${response.status}`)
  }
  const observationSeq = Number(response.headers.get("X-Observation-Seq"))
  const sha256 = response.headers.get("X-Content-SHA256")
  if (!Number.isSafeInteger(observationSeq) || observationSeq < 0 || !sha256?.match(/^[0-9a-f]{64}$/)) {
    throw new Error("Participant frame metadata is invalid")
  }
  return {
    blob: await response.blob(),
    observationSeq,
    sha256,
    state: state as ParticipantFrameView["state"],
  }
}

export async function getReadiness(): Promise<ReadinessView> {
  return checked<ReadinessView>(
    await fetch("/api/embodiment/certification/readiness", { cache: "no-store" }),
  )
}

async function getSeries(seriesId: string): Promise<EpisodeView> {
  const status = await checked<Record<string, unknown>>(
    await fetch(`/api/embodiment/series/${seriesId}`, { cache: "no-store" }),
  )
  if (["completed", "failed", "cancelled"].includes(String(status.state))) {
    return normalizeSeries(await checked<Record<string, unknown>>(
      await fetch(`/api/embodiment/series/${seriesId}/result`, { cache: "no-store" }),
    ))
  }
  return normalizeSeries(status)
}

export function bundleUrl(episodeId: string) {
  if (episodeId.startsWith("series_")) {
    return `/api/embodiment/series/${episodeId}/replay`
  }
  return `/api/embodiment/episodes/${episodeId}/replay`
}

function normalizeEpisode(raw: Record<string, unknown>, events: unknown[]): EpisodeView {
  const config = (raw.config ?? {}) as Record<string, unknown>
  const state = String(raw.state ?? "queued")
  const status = state === "completed"
    ? "success"
    : state === "failed"
      ? "failure"
      : state === "cancelled"
        ? "cancelled"
        : state === "running"
          ? "running"
          : "queued"
  const timeline = timelineRows(events)
  const value = raw.result as Record<string, unknown> | null | undefined
  const terminal = value?.terminal as Record<string, unknown> | undefined
  return {
    kind: "episode",
    episodeId: String(raw.episode_id),
    status,
    observationSeq: timeline.length,
    tick: lastTick(timeline),
    taskLabel: String(config.task_id ?? "Live episode"),
    timeline,
    result: value ? {
      finalStateHash: String(value.final_state_hash ?? ""),
      providerFailures: Number(value.provider_failures ?? 0),
      outcome: String(terminal?.outcome ?? status),
      windows: Number(value.windows ?? timeline.length),
    } : undefined,
  }
}

function normalizeSeries(raw: Record<string, unknown>): EpisodeView {
  const state = String(raw.state ?? "queued")
  const status = state === "completed" ? "success" : state === "failed" ? "failure"
    : state === "cancelled" ? "cancelled" : state === "running" ? "running" : "queued"
  const value = raw.result as Record<string, unknown> | null | undefined
  const legs = Array.isArray(value?.legs) ? value.legs as Record<string, unknown>[] : []
  return {
    kind: "series",
    episodeId: String(raw.series_id),
    status,
    observationSeq: legs.reduce((sum, leg) => sum + Number(leg.windows ?? 0), 0),
    tick: legs.reduce((sum, leg) => sum + Number(leg.windows ?? 0) * 10, 0),
    taskLabel: "Symmetric two-leg 1v1",
    timeline: [],
    result: value ? {
      finalStateHash: String(value.plan_sha256 ?? ""),
      providerFailures: legs.reduce((sum, leg) => sum + Number(leg.provider_failures ?? 0), 0),
      outcome: String(value.winner_entrant_id ?? value.status ?? status),
      windows: legs.reduce((sum, leg) => sum + Number(leg.windows ?? 0), 0),
    } : undefined,
  }
}

function timelineRows(events: unknown[]): TimelineRow[] {
  const rows: TimelineRow[] = []
  for (const event of events) {
    if (!event || typeof event !== "object") continue
    const item = event as Record<string, unknown>
    if (item.kind !== "action_receipts" || !item.value || typeof item.value !== "object") continue
    const record = item.value as Record<string, unknown>
    const participants = record.participants as Record<string, unknown> | undefined
    const receipt = participants?.participant_0 as Record<string, unknown> | undefined
    if (!receipt) continue
    const codes = Array.isArray(receipt.codes) ? receipt.codes.map(String) : []
    rows.push({
      window: Number(record.observation_seq ?? rows.length),
      intent: String(receipt.action_id ?? "neutral input"),
      receipt: String(receipt.disposition ?? codes[0] ?? "recorded"),
      ticks: `${Number(receipt.start_tick ?? 0)}–${Number(receipt.end_tick ?? 0)}`,
      latencyMs: null,
    })
  }
  return rows
}

function lastTick(rows: TimelineRow[]): number {
  const final = rows.at(-1)?.ticks.split("–").at(-1)
  return final ? Number(final) : 0
}
