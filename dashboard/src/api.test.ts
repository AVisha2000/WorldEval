import { describe, expect, it, vi } from "vitest"
import { bundleUrl, cancelRun, getParticipantFrame, getReadiness } from "@/api"

describe("public replay routes", () => {
  it("routes solo episodes and paired series to their sealed public evidence", () => {
    expect(bundleUrl("ep_stage_c")).toBe("/api/embodiment/episodes/ep_stage_c/replay")
    expect(bundleUrl("series_two_leg")).toBe(
      "/api/embodiment/series/series_two_leg/replay",
    )
  })
})

describe("certification readiness", () => {
  it("requests the no-store public readiness projection", async () => {
    const fetch = vi.fn(async () => ({
      ok: true,
      json: async () => ({ format: "llm-controller/embodiment-readiness-view/1.1.0" }),
    } as Response))
    vi.stubGlobal("fetch", fetch)
    await getReadiness()
    expect(fetch).toHaveBeenCalledWith(
      "/api/embodiment/certification/readiness",
      { cache: "no-store" },
    )
  })
})

describe("participant frame route", () => {
  it("loads only a no-store image response and its player-visible sequence", async () => {
    const png = new Blob([new Uint8Array([137, 80, 78, 71])], { type: "image/png" })
    const fetch = vi.fn(async () => new Response(png, {
      headers: {
        "Content-Type": "image/png",
        "X-Content-SHA256": "a".repeat(64),
        "X-Frame-State": "live",
        "X-Observation-Seq": "3",
      },
    }))
    vi.stubGlobal("fetch", fetch)

    const frame = await getParticipantFrame("ep_visible")

    expect(fetch).toHaveBeenCalledWith(
      "/api/embodiment/episodes/ep_visible/frame",
      { cache: "no-store" },
    )
    expect(frame).toMatchObject({ observationSeq: 3, sha256: "a".repeat(64), state: "live" })
    expect(frame.blob?.type).toBe("image/png")
  })
})

describe("run cancellation", () => {
  it("uses the scoped no-store cancellation route for episodes and series", async () => {
    const fetch = vi.fn(async () => ({
      ok: true,
      json: async () => ({ state: "cancelled" }),
    } as Response))
    vi.stubGlobal("fetch", fetch)

    await cancelRun("ep_live")
    await cancelRun("series_live")

    expect(fetch).toHaveBeenNthCalledWith(1, "/api/embodiment/episodes/ep_live/cancel", {
      method: "POST",
      cache: "no-store",
    })
    expect(fetch).toHaveBeenNthCalledWith(2, "/api/embodiment/series/series_live/cancel", {
      method: "POST",
      cache: "no-store",
    })
  })
})
