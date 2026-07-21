import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { useRef } from "react"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { EpisodeView, ParticipantFrameView } from "@/api"
import { EpisodeWorkspace, ReplaySpeedControls } from "@/components/episode-workspace"
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

function ReplaySpeedHarness() {
  const videoRef = useRef<HTMLVideoElement>(null)
  return <>
    <video ref={videoRef} aria-label="Replay under test" />
    <ReplaySpeedControls videoRef={videoRef} />
  </>
}

describe("Replay playback speed", () => {
  it("switches the native video between normal, 4×, and 8× playback", () => {
    render(<ReplaySpeedHarness />)
    const video = screen.getByLabelText("Replay under test") as HTMLVideoElement

    fireEvent.click(screen.getByRole("button", { name: "4×" }))
    expect(video.playbackRate).toBe(4)
    fireEvent.click(screen.getByRole("button", { name: "8×" }))
    expect(video.playbackRate).toBe(8)
    fireEvent.click(screen.getByRole("button", { name: "1×" }))
    expect(video.playbackRate).toBe(1)
  })
})

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

function renderEvaluation(episode?: EpisodeView) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <EpisodeWorkspace
        episode={episode}
        controllerMode="scripted_demo"
        mode="solo"
        view="evaluation"
        selected={0}
        onSelect={() => undefined}
        cancelling={false}
        onCancel={() => undefined}
      />
    </QueryClientProvider>
  )
}

function renderRun(episode: EpisodeView) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <EpisodeWorkspace episode={episode} controllerMode="scripted_demo" mode="duel" view="run" selected={0} onSelect={() => undefined} cancelling={false} onCancel={() => undefined} />
    </QueryClientProvider>
  )
}

function renderResult(episode: EpisodeView) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <EpisodeWorkspace episode={episode} controllerMode="scripted_demo" mode="trio" view="result" selected={0} onSelect={() => undefined} cancelling={false} onCancel={() => undefined} />
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
            scenario_id: "construction-v0",
            evaluation_profile_id: "solo-construction-v1",
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
    expect(screen.getByText("construction-v0")).toBeInTheDocument()
    expect(screen.getByText("solo-construction-v1")).toBeInTheDocument()
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
            scenario_id: "construction-v0",
            evaluation_profile_id: "solo-construction-v1",
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
            scenario_id: "orientation-v0",
            evaluation_profile_id: "solo-orientation-v1",
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

describe("paired Demo presentation and replay", () => {
  const series: EpisodeView = {
    kind: "series",
    episodeId: "series_demo",
    status: "running",
    observationSeq: 3,
    tick: 30,
    taskLabel: "Symmetric two-leg 1v1",
    timeline: [],
  }

  it("lets the user select isolated participant pixels without a spectator fallback", async () => {
    vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:duel-participant-frame")
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined)
    const pixels = new Uint8Array([137, 80, 78, 71])
    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) => {
      const participant = String(input).includes("participant_1") ? "participant_1" : "participant_0"
      return new Response(pixels, { headers: {
        "Content-Type": "image/png", "X-Content-SHA256": "a".repeat(64),
        "X-Frame-State": "live", "X-Leg-Index": "0", "X-Observation-Seq": "3",
        "X-Participant-ID": participant,
      } })
    }))
    renderRun(series)
    expect(await screen.findByRole("img", { name: "participant_0 Godot camera frame" })).toBeInTheDocument()
    expect(screen.getByLabelText("Team colour legend")).toHaveTextContent("Alpha")
    expect(screen.getByLabelText("Team colour legend")).toHaveTextContent("Bravo")
    expect(document.querySelector(".duel-participant-media > img")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Participant 1" }))
    expect(await screen.findByRole("img", { name: "participant_1 Godot camera frame" })).toBeInTheDocument()
    expect(screen.getByText(/no prompts, raw output, credentials, hidden state, or spectator view/i)).toBeInTheDocument()
  })

  it("retains the selected participant across lifecycle and workspace rerenders", async () => {
    vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:duel-participant-frame")
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined)
    const pixels = new Uint8Array([137, 80, 78, 71])
    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) => {
      const participant = String(input).includes("participant_1") ? "participant_1" : "participant_0"
      return new Response(pixels, { headers: {
        "Content-Type": "image/png", "X-Content-SHA256": "b".repeat(64),
        "X-Frame-State": "live", "X-Leg-Index": "0", "X-Observation-Seq": "4",
        "X-Participant-ID": participant,
      } })
    }))
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const workspace = (view: string, value: EpisodeView) => (
      <QueryClientProvider client={client}>
        <EpisodeWorkspace episode={value} controllerMode="scripted_demo" mode="duel" view={view} selected={0} onSelect={() => undefined} cancelling={false} onCancel={() => undefined} />
      </QueryClientProvider>
    )
    const rendered = render(workspace("run", series))
    expect(await screen.findByRole("img", { name: "participant_0 Godot camera frame" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Participant 1" }))
    expect(await screen.findByRole("img", { name: "participant_1 Godot camera frame" })).toBeInTheDocument()

    rendered.rerender(workspace("evaluation", { ...series, observationSeq: 4, tick: 40 }))
    rendered.rerender(workspace("run", { ...series, observationSeq: 5, tick: 50 }))
    expect(await screen.findByRole("img", { name: "participant_1 Godot camera frame" })).toBeInTheDocument()
  })

  it("reports durable evidence ready while refusing to invent native playback", () => {
    renderReplay({
      ...series,
      status: "success",
      seriesArchive: {
        evidenceState: "ready",
        nativeReplayState: "unavailable",
        nativeReplayReason: "participant_video_not_recorded",
        nativeArtifacts: [],
      },
    })
    expect(screen.getByText("Verified series evidence saved")).toBeInTheDocument()
    expect(screen.getByText("Native replay unavailable")).toBeInTheDocument()
    expect(screen.queryByLabelText("Saved replay video")).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Download public two-leg bundle" })).toHaveAttribute(
      "href", "/api/embodiment/series/series_demo/replay"
    )
  })

  it("keeps a sealed match finished while its participant replay is preparing", () => {
    renderReplay({
      ...series,
      status: "success",
      seriesArchive: {
        evidenceState: "saving",
        nativeReplayState: "saving",
        nativeArtifacts: [],
      },
    })
    expect(screen.getByText("Saving native replay…")).toBeInTheDocument()
    expect(screen.getByText("Replay preparing")).toBeInTheDocument()
    expect(screen.getByText(/Gameplay has finished/i)).toBeInTheDocument()
    expect(screen.queryByText("Native replay unavailable")).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Participant native replay")).not.toBeInTheDocument()
  })

  it("switches among four verified leg-and-seat native replays", () => {
    const artifacts = ([0, 1] as const).flatMap((legIndex) =>
      (["participant_0", "participant_1"] as const).map((participantId) => ({
        legIndex, participantId, sha256: "a".repeat(64),
        width: 1280 as const, height: 720 as const, fps: 30 as const,
      }))
    )
    renderReplay({
      ...series,
      status: "success",
      seriesArchive: {
        evidenceState: "ready",
        nativeReplayState: "ready",
        nativeArtifacts: artifacts,
      },
    })
    const initial = screen.getByLabelText("Participant native replay")
    expect(initial.querySelector("source")).toHaveAttribute(
      "src", "/api/embodiment/series/series_demo/legs/0/participants/participant_0/video"
    )
    fireEvent.click(screen.getByRole("button", { name: "Leg 2 · P1" }))
    const selected = screen.getByLabelText("Participant native replay")
    expect(selected).not.toBe(initial)
    expect(selected.querySelector("source")).toHaveAttribute(
      "src", "/api/embodiment/series/series_demo/legs/1/participants/participant_1/video"
    )
  })
})

describe("three-agent Demo presentation and replay", () => {
  const trio: EpisodeView = {
    kind: "trio",
    episodeId: "trio_demo",
    status: "running",
    observationSeq: 5,
    tick: 50,
    taskLabel: "Trio Relay · three cyclic legs",
    timeline: [],
  }

  it("offers participant 2 pixels without ever substituting a spectator view", async () => {
    vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:trio-participant-frame")
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined)
    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) => {
      const match = String(input).match(/participant_[0-2]/)
      const participant = match?.[0] ?? "participant_0"
      return new Response(new Uint8Array([137, 80, 78, 71]), { headers: {
        "Content-Type": "image/png", "X-Content-SHA256": "b".repeat(64),
        "X-Frame-State": "live", "X-Leg-Index": "2", "X-Observation-Seq": "5",
        "X-Participant-ID": participant,
      } })
    }))
    renderRun(trio)
    fireEvent.click(screen.getByRole("button", { name: "Participant 2" }))
    expect(await screen.findByRole("img", {
      name: "participant_2 Godot camera frame",
    })).toBeInTheDocument()
    expect(screen.getByLabelText("Participant camera")).not.toHaveTextContent("Spectator")
    // The frame says leg 3, where the canonical cyclic schedule puts Luna in participant 2.
    expect(screen.getByLabelText("Team colour legend")).toHaveTextContent("Luna")
    expect(screen.getByLabelText("Team colour legend")).toHaveTextContent("Leg 3")
  })

  it("switches across all nine verified leg-and-participant native targets", () => {
    const artifacts = ([0, 1, 2] as const).flatMap((legIndex) =>
      (["participant_0", "participant_1", "participant_2"] as const).map((participantId) => ({
        legIndex, participantId, sha256: "c".repeat(64),
        width: 1280 as const, height: 720 as const, fps: 30 as const,
      }))
    )
    renderReplay({
      ...trio,
      status: "success",
      seriesArchive: { evidenceState: "ready", nativeReplayState: "ready", nativeArtifacts: artifacts },
    })
    expect(screen.getAllByRole("button", { name: /Leg [1-3] · P[0-2]/ })).toHaveLength(9)
    fireEvent.click(screen.getByRole("button", { name: "Leg 3 · P2" }))
    const video = screen.getByLabelText("Participant native replay")
    expect(video.querySelector("source")).toHaveAttribute(
      "src", "/api/embodiment/trio-series/trio_demo/legs/2/participants/participant_2/video"
    )
    expect(screen.getByRole("link", { name: "Download public three-leg bundle" })).toHaveAttribute(
      "href", "/api/embodiment/trio-series/trio_demo/replay"
    )
  })

  it("renders authority-typed per-leg placements", () => {
    renderResult({
      ...trio,
      status: "success",
      result: {
        finalStateHash: "d".repeat(64), providerFailures: 1,
        outcome: "Three verified cyclic legs", windows: 30,
        trioLegs: [0, 1, 2].map((legIndex) => ({
          legIndex, terminalReason: "relay_hold",
          placements: [
            { place: 1, participantIds: ["participant_0"], tied: false },
            { place: 2, participantIds: ["participant_1", "participant_2"], tied: true },
          ],
        })),
      },
    })
    expect(screen.getByLabelText("Typed trio placements")).toHaveTextContent(
      "#1 P0 · #2 P1/P2"
    )
    expect(screen.getAllByText("Typed tie placement")).toHaveLength(3)
  })
})

describe("evaluation view", () => {
  it("separates result, behavior, and replay integrity without rendering protected fields", async () => {
    const projection = {
      schema_version: "llm-controller/evaluation-projection/1.0.0",
      projection_sha256: "c".repeat(64),
      state: "supported",
      scope: "solo",
      run: {
        episode_id: "ep_saved_demo",
        task_id: "construction-v0",
        scenario_id: "multi-action-demo-v0",
        evaluation_profile_id: "solo-multi-action-showcase-v1",
        certification_eligible: false,
      },
      result: {
        final_state_hash: "a".repeat(64),
        provider_failures: 0,
        windows: 4,
        terminal: { outcome: "success" },
      },
      evaluation: { metrics: {
        task_success: { state: "supported", value: true },
        completion_tick: { state: "supported", value: 900 },
        valid_action_rate: { state: "supported", value: { basis_points: 10000 } },
        deterministic_replay_verification: { state: "supported", value: true },
        unnecessary_collisions: { state: "supported", value: 0 },
        interaction_alignment_failures: { state: "supported", value: 0 },
      } },
      prompts: ["must not render"],
    }
    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) =>
      String(input) === "/api/embodiment/replays"
        ? ({ ok: true, json: async () => ({ replays: [] }) } as Response)
        : ({ ok: true, json: async () => projection } as Response)
    ))
    renderEvaluation(sealedEpisode)
    expect(await screen.findByLabelText("Evaluation summary")).toBeInTheDocument()
    expect(screen.getByText("Result")).toBeInTheDocument()
    expect(screen.getByText("Behavior")).toBeInTheDocument()
    expect(screen.getByText("Replay integrity")).toBeInTheDocument()
    expect(screen.queryByText("must not render")).not.toBeInTheDocument()
    expect(screen.getByText("Demonstration only")).toBeInTheDocument()
  })

  it("waits clearly while current authority evidence is unsealed", async () => {
    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) =>
      String(input) === "/api/embodiment/replays"
        ? ({ ok: true, json: async () => ({ replays: [] }) } as Response)
        : new Response(null, { status: 409 })
    ))
    renderEvaluation(episode)
    expect(await screen.findByText("Waiting for sealed evaluation…")).toBeInTheDocument()
  })
})
