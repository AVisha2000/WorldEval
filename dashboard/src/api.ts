export type Provider = "openai" | "anthropic" | "gemini"
export type OpponentProvider = Provider | "scripted"
export type ControllerMode = "scripted_demo" | "live_provider"
export const SCRIPTED_DEMO_MODELS = {
  "orientation-v0": "orientation-demo-v1",
  "interaction-v0": "interaction-demo-v1",
  "construction-v0": "construction-demo-v1",
  "neutral-encounter-v0": "neutral-encounter-demo-v1",
} as const
export type ScriptedDemoTaskId = keyof typeof SCRIPTED_DEMO_MODELS
export type EpisodeSetup = {
  controllerMode: ControllerMode
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

/**
 * This is intentionally a small public projection of a locally archived replay.  It contains
 * only data that is safe to show beside participant-visible video; authority replays,
 * observations, prompts, provider output, and credentials never cross this API boundary.
 */
export type SavedReplaySummary = {
  replayId: string
  episodeId: string
  taskId: string
  label: string
  outcome: string
  authorityTicks: number
  durationSeconds: number
  video: {
    available: boolean
    mimeType: "video/mp4"
    width: number
    height: number
    fps: number
  }
}

export type SavedReplayAvailability = {
  state: "saving" | "ready" | "unavailable"
  replayId?: string
}

export type EpisodeView = {
  kind: "episode" | "series"
  episodeId: string
  status: "queued" | "running" | "success" | "failure" | "cancelled"
  observationSeq: number
  tick: number
  taskLabel: string
  failureCode?: string | null
  replay?: SavedReplayAvailability
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
  if (!response.ok)
    throw new Error(`Episode service returned ${response.status}`)
  return response.json() as Promise<T>
}

export async function createEpisode(setup: EpisodeSetup): Promise<EpisodeView> {
  const isScriptedDemo = setup.controllerMode === "scripted_demo"
  let controller:
    | { provider: "scripted"; model: string }
    | { provider: Provider; model: string; api_key: string }
  if (isScriptedDemo) {
    if (!isScriptedDemoTask(setup.taskId))
      throw new Error("Scripted demo task is invalid")
    controller = {
      provider: "scripted",
      model: SCRIPTED_DEMO_MODELS[setup.taskId],
    }
  } else {
    controller = {
      provider: setup.provider,
      model: setup.model,
      api_key: setup.apiKey,
    }
  }
  const raw = await checked<Record<string, unknown>>(
    await fetch("/api/embodiment/episodes", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      cache: "no-store",
      body: JSON.stringify({
        ...controller,
        task_id: setup.taskId,
        seed: setup.seed,
        observation_profile: "hybrid-visible-v1",
        maximum_episode_ticks: isScriptedDemo ? 1200 : 600,
      }),
    })
  )
  return normalizeEpisode(raw, [])
}

export function isScriptedDemoTask(
  taskId: string
): taskId is ScriptedDemoTaskId {
  return Object.hasOwn(SCRIPTED_DEMO_MODELS, taskId)
}

export async function createRun(setup: EpisodeSetup): Promise<EpisodeView> {
  if (setup.mode === "solo") return createEpisode(setup)
  const opponent =
    setup.opponentProvider === "scripted"
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
        max_live_provider_calls:
          setup.opponentProvider === "scripted" ? 360 : 720,
        entrants: [
          {
            provider: setup.provider,
            model: setup.model,
            api_key: setup.apiKey,
          },
          opponent,
        ],
      }),
    })
  )
  return normalizeSeries(raw)
}

export async function cancelRun(episodeId: string): Promise<void> {
  const route = episodeId.startsWith("series_")
    ? `/api/embodiment/series/${episodeId}/cancel`
    : `/api/embodiment/episodes/${episodeId}/cancel`
  await checked<Record<string, unknown>>(
    await fetch(route, { method: "POST", cache: "no-store" })
  )
}

export async function getEpisode(episodeId: string): Promise<EpisodeView> {
  if (episodeId.startsWith("series_")) return getSeries(episodeId)
  const status = await checked<Record<string, unknown>>(
    await fetch(`/api/embodiment/episodes/${episodeId}`, { cache: "no-store" })
  )
  const state = String(status.state ?? "queued")
  if (["completed", "failed", "cancelled"].includes(state)) {
    const result = await checked<Record<string, unknown>>(
      await fetch(`/api/embodiment/episodes/${episodeId}/result`, {
        cache: "no-store",
      })
    )
    // Lifecycle status owns the export state while the sealed result owns final authority
    // evidence. Keep the small public replay projection when the result is read separately.
    return normalizeEpisode({ ...result, replay: result.replay ?? status.replay }, [])
  }
  return normalizeEpisode(status, [])
}

export async function getEpisodeTimeline(
  episodeId: string
): Promise<TimelineRow[]> {
  if (episodeId.startsWith("series_")) return []
  const timeline = await checked<{ events: unknown[] }>(
    await fetch(`/api/embodiment/episodes/${episodeId}/timeline`, {
      cache: "no-store",
    })
  )
  return timelineRows(timeline.events)
}

export async function getSavedReplays(): Promise<SavedReplaySummary[]> {
  const raw = await checked<{ replays?: unknown }>(
    await fetch("/api/embodiment/replays", { cache: "no-store" })
  )
  if (!Array.isArray(raw.replays))
    throw new Error("Saved replay list is invalid")
  return raw.replays.map(parseSavedReplay)
}

/**
 * A replay archive is intentionally absent while native rendering is still underway.  A 404 is
 * therefore a normal, non-sensitive pending state rather than an episode-service failure.
 */
export async function getSavedReplay(
  episodeId: string
): Promise<SavedReplaySummary | null> {
  const response = await fetch(
    `/api/embodiment/replays/${encodeURIComponent(episodeId)}`,
    {
      cache: "no-store",
    }
  )
  if (response.status === 404) return null
  return parseSavedReplay(await checked<unknown>(response))
}

export function savedReplayVideoUrl(replayId: string): string {
  return `/api/embodiment/replays/${encodeURIComponent(replayId)}/video`
}

export async function getParticipantFrame(
  episodeId: string
): Promise<ParticipantFrameView> {
  const response = await fetch(`/api/embodiment/episodes/${episodeId}/frame`, {
    cache: "no-store",
  })
  const state = response.headers.get("X-Frame-State")
  if (
    !(["loading", "live", "finished"] as const).includes(
      state as ParticipantFrameView["state"]
    )
  ) {
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
  if (
    !response.ok ||
    response.headers.get("Content-Type")?.split(";", 1)[0] !== "image/png"
  ) {
    throw new Error(`Participant frame service returned ${response.status}`)
  }
  const observationSeq = Number(response.headers.get("X-Observation-Seq"))
  const sha256 = response.headers.get("X-Content-SHA256")
  if (
    !Number.isSafeInteger(observationSeq) ||
    observationSeq < 0 ||
    !sha256?.match(/^[0-9a-f]{64}$/)
  ) {
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
    await fetch("/api/embodiment/certification/readiness", {
      cache: "no-store",
    })
  )
}

async function getSeries(seriesId: string): Promise<EpisodeView> {
  const status = await checked<Record<string, unknown>>(
    await fetch(`/api/embodiment/series/${seriesId}`, { cache: "no-store" })
  )
  if (["completed", "failed", "cancelled"].includes(String(status.state))) {
    return normalizeSeries(
      await checked<Record<string, unknown>>(
        await fetch(`/api/embodiment/series/${seriesId}/result`, {
          cache: "no-store",
        })
      )
    )
  }
  return normalizeSeries(status)
}

export function bundleUrl(episodeId: string) {
  if (episodeId.startsWith("series_")) {
    return `/api/embodiment/series/${episodeId}/replay`
  }
  return `/api/embodiment/episodes/${episodeId}/replay`
}

function normalizeEpisode(
  raw: Record<string, unknown>,
  events: unknown[]
): EpisodeView {
  const config = (raw.config ?? {}) as Record<string, unknown>
  const state = String(raw.state ?? "queued")
  const status =
    state === "completed"
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
  const progress = raw.progress as Record<string, unknown> | null | undefined
  const progressObservationSeq = safeNonNegativeInteger(
    progress?.observation_seq
  )
  const progressTick = safeNonNegativeInteger(progress?.authority_tick)
  const resultWindows = safeNonNegativeInteger(value?.windows)
  const replay = normalizeSavedReplayAvailability(raw.replay ?? value?.replay)
  return {
    kind: "episode",
    episodeId: String(raw.episode_id),
    status,
    // The lifecycle route exposes only monotonic public timing.  It intentionally carries no
    // player observation fields, pixels, prompts, model output, or authority state.
    observationSeq: Math.max(
      timeline.length,
      progressObservationSeq,
      resultWindows
    ),
    tick: Math.max(lastTick(timeline), progressTick),
    taskLabel: String(config.task_id ?? "Live episode"),
    failureCode: typeof raw.failure === "string" ? raw.failure : null,
    replay,
    timeline,
    result: value
      ? {
          finalStateHash: String(value.final_state_hash ?? ""),
          providerFailures: Number(value.provider_failures ?? 0),
          outcome: String(terminal?.outcome ?? status),
          windows: Number(value.windows ?? timeline.length),
        }
      : undefined,
  }
}

function normalizeSeries(raw: Record<string, unknown>): EpisodeView {
  const state = String(raw.state ?? "queued")
  const status =
    state === "completed"
      ? "success"
      : state === "failed"
        ? "failure"
        : state === "cancelled"
          ? "cancelled"
          : state === "running"
            ? "running"
            : "queued"
  const value = raw.result as Record<string, unknown> | null | undefined
  const legs = Array.isArray(value?.legs)
    ? (value.legs as Record<string, unknown>[])
    : []
  return {
    kind: "series",
    episodeId: String(raw.series_id),
    status,
    observationSeq: legs.reduce(
      (sum, leg) => sum + Number(leg.windows ?? 0),
      0
    ),
    tick: legs.reduce((sum, leg) => sum + Number(leg.windows ?? 0) * 10, 0),
    taskLabel: "Symmetric two-leg 1v1",
    timeline: [],
    result: value
      ? {
          finalStateHash: String(value.plan_sha256 ?? ""),
          providerFailures: legs.reduce(
            (sum, leg) => sum + Number(leg.provider_failures ?? 0),
            0
          ),
          outcome: String(value.winner_entrant_id ?? value.status ?? status),
          windows: legs.reduce((sum, leg) => sum + Number(leg.windows ?? 0), 0),
        }
      : undefined,
  }
}

function timelineRows(events: unknown[]): TimelineRow[] {
  const rows: TimelineRow[] = []
  for (const event of events) {
    if (!event || typeof event !== "object") continue
    const item = event as Record<string, unknown>
    if (
      item.kind !== "action_receipts" ||
      !item.value ||
      typeof item.value !== "object"
    )
      continue
    const record = item.value as Record<string, unknown>
    const participants = record.participants as
      Record<string, unknown> | undefined
    const receipt = participants?.participant_0 as
      Record<string, unknown> | undefined
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

function safeNonNegativeInteger(value: unknown): number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
    ? value
    : 0
}

function parseSavedReplay(raw: unknown): SavedReplaySummary {
  if (!raw || typeof raw !== "object")
    throw new Error("Saved replay is invalid")
  const value = raw as Record<string, unknown>
  const video = value.video
  if (!video || typeof video !== "object")
    throw new Error("Saved replay video is invalid")
  const videoValue = video as Record<string, unknown>
  const replayId = nonEmptyString(value.replay_id)
  const episodeId = nonEmptyString(value.episode_id)
  const taskId = nonEmptyString(value.task_id)
  const label = nonEmptyString(value.label)
  const outcome = nonEmptyString(value.outcome)
  if (
    !replayId ||
    !episodeId ||
    !taskId ||
    !label ||
    !outcome ||
    typeof videoValue.available !== "boolean" ||
    videoValue.mime_type !== "video/mp4"
  ) {
    throw new Error("Saved replay is invalid")
  }
  return {
    replayId,
    episodeId,
    taskId,
    label,
    outcome,
    authorityTicks: safeNonNegativeInteger(value.authority_ticks),
    durationSeconds: safeNonNegativeNumber(value.duration_seconds),
    video: {
      available: videoValue.available,
      mimeType: "video/mp4",
      width: safePositiveInteger(videoValue.width),
      height: safePositiveInteger(videoValue.height),
      fps: safePositiveInteger(videoValue.fps),
    },
  }
}

function normalizeSavedReplayAvailability(
  value: unknown
): SavedReplayAvailability | undefined {
  if (!value || typeof value !== "object") return undefined
  const replay = value as Record<string, unknown>
  const state = replay.state
  if (state !== "saving" && state !== "ready" && state !== "unavailable")
    return undefined
  const replayId = nonEmptyString(replay.replay_id)
  return replayId ? { state, replayId } : { state }
}

function safePositiveInteger(value: unknown): number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0
    ? value
    : 0
}

function safeNonNegativeNumber(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0
    ? value
    : 0
}

function nonEmptyString(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null
}
