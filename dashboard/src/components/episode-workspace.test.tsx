import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { EpisodeView, ParticipantFrameView } from "@/api"
import { EpisodeWorkspace } from "@/components/episode-workspace"
import { displayRunProgress } from "@/lib/episode-progress"

const episode: EpisodeView = {
  kind: "episode",
  episodeId: "ep_scripted_demo",
  status: "running",
  observationSeq: 0,
  tick: 0,
  taskLabel: "construction-v0",
  timeline: [],
}

const advancingFrame: ParticipantFrameView = {
  blob: null,
  observationSeq: 47,
  sha256: null,
  state: "live",
}

describe("RunView progress", () => {
  it("uses advancing participant-frame progress while lifecycle status is still at zero", () => {
    expect(displayRunProgress(episode, advancingFrame)).toEqual({
      observationSeq: 47,
      tick: 47,
    })
  })

  it("never lets a frame move a confirmed lifecycle value backwards", () => {
    expect(
      displayRunProgress(
        { ...episode, observationSeq: 50, tick: 75 },
        advancingFrame
      )
    ).toEqual({
      observationSeq: 50,
      tick: 75,
    })
  })
})

const sealedEpisode: EpisodeView = {
  kind: "episode",
  episodeId: "ep_saved_demo",
  status: "success",
  observationSeq: 1194,
  tick: 1194,
  taskLabel: "construction-v0",
  timeline: [],
  result: {
    finalStateHash: "a".repeat(64),
    providerFailures: 0,
    outcome: "success",
    windows: 1194,
  },
}

function renderReplay(episode?: EpisodeView) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  render(
    <QueryClientProvider client={client}>
      <EpisodeWorkspace
        episode={episode}
        controllerMode="scripted_demo"
        mode="solo"
        view="replay"
        selected={0}
        onSelect={() => undefined}
        cancelling={false}
        onCancel={() => undefined}
      />
    </QueryClientProvider>
  )
}

afterEach(() => cleanup())

describe("saved native replay", () => {
  it("plays a saved participant-visible video and retains the public evidence bundle", async () => {
    const fetch = vi.fn(
      async () =>
        ({
          ok: true,
          json: async () => ({
            replay_id: "replay_saved_demo",
            episode_id: "ep_saved_demo",
            task_id: "construction-v0",
            label: "Construction V0 scripted demo",
            outcome: "success",
            authority_ticks: 1194,
            duration_seconds: 39,
            video: {
              available: true,
              mime_type: "video/mp4",
              width: 1280,
              height: 720,
              fps: 30,
            },
            prompts: ["must not render"],
          }),
        }) as Response
    )
    vi.stubGlobal("fetch", fetch)

    renderReplay(sealedEpisode)

    const video = await screen.findByLabelText("Saved replay video")
    expect(video).toHaveAttribute("controls")
    expect(screen.getByText("Loading native replay…")).toBeInTheDocument()
    fireEvent.loadedMetadata(video)
    expect(screen.queryByText("Loading native replay…")).not.toBeInTheDocument()
    expect(video.querySelector("source")).toHaveAttribute(
      "src",
      "/api/embodiment/replays/replay_saved_demo/video"
    )
    expect(
      screen.getByText("Construction V0 scripted demo")
    ).toBeInTheDocument()
    expect(
      screen.getByText(/Participant-visible pixels only/)
    ).toBeInTheDocument()
    expect(screen.queryByText("must not render")).not.toBeInTheDocument()
    expect(
      screen.getByRole("link", { name: "Download public bundle" })
    ).toHaveAttribute("href", "/api/embodiment/episodes/ep_saved_demo/replay")
  })

  it("reports native replay saving without exposing an archive that is not ready", async () => {
    const fetch = vi.fn(async () => new Response(null, { status: 404 }))
    vi.stubGlobal("fetch", fetch)

    renderReplay({ ...sealedEpisode, replay: { state: "saving" } })

    expect(await screen.findByText("Saving native replay…")).toBeInTheDocument()
    await waitFor(() =>
      expect(fetch).toHaveBeenCalledWith(
        "/api/embodiment/replays/ep_saved_demo",
        { cache: "no-store" }
      )
    )
    expect(
      screen.queryByLabelText("Saved replay video")
    ).not.toBeInTheDocument()
  })

  it("reports an unavailable native replay while leaving public evidence available", async () => {
    const fetch = vi.fn(async () => new Response(null, { status: 404 }))
    vi.stubGlobal("fetch", fetch)

    renderReplay({ ...sealedEpisode, replay: { state: "unavailable" } })

    expect(
      await screen.findByText("Native replay unavailable")
    ).toBeInTheDocument()
    expect(
      screen.getByRole("link", { name: "Download public bundle" })
    ).toBeInTheDocument()
  })

  it("lists and plays saved replays after a dashboard refresh without an active episode", async () => {
    const fetch = vi.fn(async () => ({
      ok: true,
      json: async () => ({
        replays: [
          {
            replay_id: "replay_construction",
            episode_id: "ep_construction",
            task_id: "construction-v0",
            label: "Construction V0 scripted demo",
            outcome: "success",
            authority_ticks: 1194,
            duration_seconds: 39,
            video: { available: true, mime_type: "video/mp4", width: 1280, height: 720, fps: 30 },
          },
          {
            replay_id: "replay_orientation",
            episode_id: "ep_orientation",
            task_id: "orientation-v0",
            label: "Orientation V0 scripted demo",
            outcome: "success",
            authority_ticks: 96,
            duration_seconds: 4,
            video: { available: true, mime_type: "video/mp4", width: 1280, height: 720, fps: 30 },
          },
        ],
      }),
    } as Response))
    vi.stubGlobal("fetch", fetch)

    renderReplay()

    expect(await screen.findByText("Saved replay library")).toBeInTheDocument()
    const firstVideo = screen.getByLabelText("Saved replay video")
    expect(firstVideo.querySelector("source")).toHaveAttribute(
      "src",
      "/api/embodiment/replays/replay_construction/video",
    )
    fireEvent.click(screen.getByRole("button", { name: /Orientation V0 scripted demo/i }))
    const selectedVideo = screen.getByLabelText("Saved replay video")
    // Browsers do not reliably reload a nested <source> after React changes it.  The player
    // must be a fresh native media element for the selected archive, not a stale buffered video.
    expect(selectedVideo).not.toBe(firstVideo)
    expect(selectedVideo.querySelector("source")).toHaveAttribute(
      "src",
      "/api/embodiment/replays/replay_orientation/video",
    )
    fireEvent.error(selectedVideo)
    expect(screen.getByRole("alert")).toHaveTextContent(
      "Native replay could not be loaded"
    )
    expect(fetch).toHaveBeenCalledWith("/api/embodiment/replays", { cache: "no-store" })
  })
})
