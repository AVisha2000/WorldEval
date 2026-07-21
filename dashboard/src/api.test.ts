import { describe, expect, it, vi } from "vitest"
import {
  bundleUrl,
  cancelRun,
  createEpisode,
  getEpisode,
  getEpisodeTimeline,
  getParticipantFrame,
  getReadiness,
  getSavedReplay,
  getSavedReplays,
  savedReplayVideoUrl,
} from "@/api"

function response(value: unknown) {
  return { ok: true, json: async () => value } as Response
}

const scriptedDemoSetup = {
  controllerMode: "scripted_demo" as const,
  mode: "solo" as const,
  provider: "openai" as const,
  model: "gpt-5.6-sol",
  apiKey: "",
  opponentProvider: "scripted" as const,
  opponentModel: "balanced-v1",
  opponentApiKey: "",
  taskId: "orientation-v0",
  seed: 20240520,
}

describe("public replay routes", () => {
  it("routes solo episodes and paired series to their sealed public evidence", () => {
    expect(bundleUrl("ep_stage_c")).toBe(
      "/api/embodiment/episodes/ep_stage_c/replay"
    )
    expect(bundleUrl("series_two_leg")).toBe(
      "/api/embodiment/series/series_two_leg/replay"
    )
  })
})

describe("saved native replay routes", () => {
  const savedReplay = {
    replay_id: "replay_construction_demo",
    episode_id: "ep_construction_demo",
    task_id: "construction-v0",
    label: "Construction V0 scripted demo",
    outcome: "success",
    authority_ticks: 1194,
    duration_seconds: 39,
    video: {
      available: true,
      mime_type: "video/mp4",
      sha256: "e".repeat(64),
      width: 1280,
      height: 720,
      fps: 30,
    },
    prompts: ["must never reach the dashboard"],
  }

  it("loads only the public saved-replay projection and generates an encoded video route", async () => {
    const fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === "/api/embodiment/replays")
        return response({ replays: [savedReplay] })
      return response(savedReplay)
    })
    vi.stubGlobal("fetch", fetch)

    await expect(getSavedReplays()).resolves.toEqual([
      {
        replayId: "replay_construction_demo",
        episodeId: "ep_construction_demo",
        taskId: "construction-v0",
        label: "Construction V0 scripted demo",
        outcome: "success",
        authorityTicks: 1194,
        durationSeconds: 39,
        video: {
          available: true,
          mimeType: "video/mp4",
          width: 1280,
          height: 720,
          fps: 30,
        },
      },
    ])
    await expect(getSavedReplay("ep_construction_demo")).resolves.toMatchObject(
      {
        replayId: "replay_construction_demo",
        video: { available: true, mimeType: "video/mp4" },
      }
    )
    expect(fetch).toHaveBeenNthCalledWith(1, "/api/embodiment/replays", {
      cache: "no-store",
    })
    expect(fetch).toHaveBeenNthCalledWith(
      2,
      "/api/embodiment/replays/ep_construction_demo",
      { cache: "no-store" }
    )
    expect(savedReplayVideoUrl("replay construction/demo")).toBe(
      "/api/embodiment/replays/replay%20construction%2Fdemo/video"
    )
  })

  it("treats a missing archive as a normal pending state while native export is running", async () => {
    const fetch = vi.fn(async () => new Response(null, { status: 404 }))
    vi.stubGlobal("fetch", fetch)

    await expect(getSavedReplay("ep_still_saving")).resolves.toBeNull()
    expect(fetch).toHaveBeenCalledWith(
      "/api/embodiment/replays/ep_still_saving",
      { cache: "no-store" }
    )
  })
})

describe("certification readiness", () => {
  it("requests the no-store public readiness projection", async () => {
    const fetch = vi.fn(
      async () =>
        ({
          ok: true,
          json: async () => ({
            format: "llm-controller/embodiment-readiness-view/1.1.0",
          }),
        }) as Response
    )
    vi.stubGlobal("fetch", fetch)
    await getReadiness()
    expect(fetch).toHaveBeenCalledWith(
      "/api/embodiment/certification/readiness",
      { cache: "no-store" }
    )
  })
})

describe("participant frame route", () => {
  it("loads only a no-store image response and its player-visible sequence", async () => {
    const png = new Blob([new Uint8Array([137, 80, 78, 71])], {
      type: "image/png",
    })
    const fetch = vi.fn(
      async () =>
        new Response(png, {
          headers: {
            "Content-Type": "image/png",
            "X-Content-SHA256": "a".repeat(64),
            "X-Frame-State": "live",
            "X-Observation-Seq": "3",
          },
        })
    )
    vi.stubGlobal("fetch", fetch)

    const frame = await getParticipantFrame("ep_visible")

    expect(fetch).toHaveBeenCalledWith(
      "/api/embodiment/episodes/ep_visible/frame",
      { cache: "no-store" }
    )
    expect(frame).toMatchObject({
      observationSeq: 3,
      sha256: "a".repeat(64),
      state: "live",
    })
    expect(frame.blob?.type).toBe("image/png")
  })
})

describe("run cancellation", () => {
  it("uses the scoped no-store cancellation route for episodes and series", async () => {
    const fetch = vi.fn(
      async () =>
        ({
          ok: true,
          json: async () => ({ state: "cancelled" }),
        }) as Response
    )
    vi.stubGlobal("fetch", fetch)

    await cancelRun("ep_live")
    await cancelRun("series_live")

    expect(fetch).toHaveBeenNthCalledWith(
      1,
      "/api/embodiment/episodes/ep_live/cancel",
      {
        method: "POST",
        cache: "no-store",
      }
    )
    expect(fetch).toHaveBeenNthCalledWith(
      2,
      "/api/embodiment/series/series_live/cancel",
      {
        method: "POST",
        cache: "no-store",
      }
    )
  })
})

describe("scripted solo demos", () => {
  it.each([
    ["orientation-v0", "orientation-demo-v1"],
    ["interaction-v0", "interaction-demo-v1"],
    ["construction-v0", "construction-demo-v1"],
    ["neutral-encounter-v0", "neutral-encounter-demo-v1"],
  ] as const)("uses the credential-free scripted controller for %s", async (taskId, model) => {
    let requestBody = ""
    const fetch = vi.fn(
      async (_input: RequestInfo | URL, init?: RequestInit) => {
        requestBody = String(init?.body)
        return {
          ok: true,
          json: async () => ({
            config: {},
            episode_id: "ep_demo",
            state: "queued",
          }),
        } as Response
      }
    )
    vi.stubGlobal("fetch", fetch)

    await createEpisode({ ...scriptedDemoSetup, taskId })

    const body = JSON.parse(requestBody)
    expect(body).toMatchObject({
      provider: "scripted",
      model,
      task_id: taskId,
      seed: 20240520,
      maximum_episode_ticks: 1200,
    })
    expect(body).not.toHaveProperty("api_key")
  })

  it.each(["central-relay-v0", "toString"])("rejects scripted task %s before making a request", async (taskId) => {
    const fetch = vi.fn()
    vi.stubGlobal("fetch", fetch)

    await expect(
      createEpisode({ ...scriptedDemoSetup, taskId })
    ).rejects.toThrow("Scripted demo task is invalid")
    expect(fetch).not.toHaveBeenCalled()
  })
})

describe("episode lifecycle loading", () => {
  it("loads status without repeatedly loading the full public timeline", async () => {
    const fetch = vi.fn(async (input: RequestInfo | URL) => {
      expect(String(input)).toBe("/api/embodiment/episodes/ep_live")
      return response({
        config: { task_id: "construction-v0" },
        episode_id: "ep_live",
        progress: { authority_tick: 37, observation_seq: 37 },
        state: "running",
      })
    })
    vi.stubGlobal("fetch", fetch)

    const episode = await getEpisode("ep_live")

    expect(episode.timeline).toEqual([])
    expect(episode).toMatchObject({ observationSeq: 37, tick: 37 })
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  it("loads and parses public receipts only when the timeline is requested", async () => {
    const fetch = vi.fn(async () =>
      response({
        events: [
          {
            kind: "action_receipts",
            value: {
              observation_seq: 12,
              participants: {
                participant_0: {
                  action_id: "task_build_barricade_12",
                  codes: ["accepted"],
                  disposition: "accepted",
                  start_tick: 12,
                  end_tick: 13,
                },
              },
            },
          },
        ],
      })
    )
    vi.stubGlobal("fetch", fetch)

    const rows = await getEpisodeTimeline("ep_live")

    expect(fetch).toHaveBeenCalledWith(
      "/api/embodiment/episodes/ep_live/timeline",
      { cache: "no-store" }
    )
    expect(rows).toEqual([
      {
        window: 12,
        intent: "task_build_barricade_12",
        receipt: "accepted",
        ticks: "12–13",
        latencyMs: null,
      },
    ])
  })

  it("retains the safe replay-export state from lifecycle status after it loads the sealed result", async () => {
    const fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.endsWith("/result")) {
        return response({
          config: { task_id: "construction-v0" },
          episode_id: "ep_saving_replay",
          result: { windows: 1194, terminal: { outcome: "success" } },
          state: "completed",
        })
      }
      return response({
        config: { task_id: "construction-v0" },
        episode_id: "ep_saving_replay",
        replay: { state: "saving" },
        state: "completed",
      })
    })
    vi.stubGlobal("fetch", fetch)

    await expect(getEpisode("ep_saving_replay")).resolves.toMatchObject({
      replay: { state: "saving" },
      status: "success",
    })
  })
})
