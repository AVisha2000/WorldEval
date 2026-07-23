import { act, cleanup, render, renderHook, screen, waitFor } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import type { EpisodeView, ParticipantFrameView } from "@/api"
import { ParticipantFrame } from "@/components/participant-frame"
import { useParticipantPreview } from "@/hooks/use-participant-preview"

class MockWebSocket {
  static instances: MockWebSocket[] = []

  binaryType = ""
  onopen: ((event: Event) => void) | null = null
  onclose: ((event: CloseEvent) => void) | null = null
  onmessage: ((event: MessageEvent) => void) | null = null
  readonly close = vi.fn(() => this.onclose?.(new CloseEvent("close")))
  readonly url: string

  constructor(url: string) {
    this.url = url
    MockWebSocket.instances.push(this)
  }

  open() {
    this.onopen?.(new Event("open"))
  }

  message(data: unknown) {
    this.onmessage?.(new MessageEvent("message", { data }))
  }
}

function episode(status: EpisodeView["status"] = "running"): EpisodeView {
  return {
    kind: "episode",
    episodeId: "ep_visible",
    status,
    observationSeq: 0,
    tick: 0,
    taskLabel: "construction-v0",
    timeline: [],
  }
}

function series(): EpisodeView {
  return {
    kind: "series",
    episodeId: "series_visible",
    status: "running",
    observationSeq: 0,
    tick: 0,
    taskLabel: "Symmetric two-leg 1v1",
    timeline: [],
  }
}

function trio(): EpisodeView {
  return {
    kind: "trio",
    episodeId: "trio_visible",
    status: "running",
    observationSeq: 0,
    tick: 0,
    taskLabel: "Trio Relay",
    timeline: [],
  }
}

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((next) => { resolve = next })
  return { promise, resolve }
}

function imageBitmap(width: number, height: number) {
  return { width, height, close: vi.fn() } as unknown as ImageBitmap
}

function frame(blob: Blob): ParticipantFrameView {
  return {
    blob,
    observationSeq: 1,
    sha256: "a".repeat(64),
    state: "live",
  }
}

describe("participant live preview", () => {
  const drawImage = vi.fn()
  let rafNow = 0
  let rafId = 0

  beforeEach(() => {
    MockWebSocket.instances = []
    rafNow = 0
    rafId = 0
    vi.stubGlobal("WebSocket", MockWebSocket)
    vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockReturnValue(
      { drawImage } as unknown as CanvasRenderingContext2D,
    )
    vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:canonical-frame")
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined)
    vi.spyOn(performance, "now").mockImplementation(() => rafNow)
    vi.spyOn(window, "requestAnimationFrame").mockImplementation((callback) => {
      const id = ++rafId
      queueMicrotask(() => callback(rafNow += 34))
      return id
    })
    vi.spyOn(window, "cancelAnimationFrame").mockImplementation(() => undefined)
  })

  afterEach(() => {
    cleanup()
    drawImage.mockReset()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it("uses a depth-one queue and decodes only the newest participant JPEG", async () => {
    const older = new Blob(["older"], { type: "image/jpeg" })
    const newest = new Blob(["newest"], { type: "image/jpeg" })
    const newestDecode = deferred<ImageBitmap>()
    const newestBitmap = imageBitmap(1280, 720)
    const decode = vi.fn(() => newestDecode.promise)
    vi.stubGlobal("createImageBitmap", decode)

    const { result } = renderHook(() => useParticipantPreview(episode()))
    const canvas = document.createElement("canvas")
    result.current.canvasRef.current = canvas
    document.body.append(canvas)
    const socket = MockWebSocket.instances[0]

    expect(socket.url).toBe(
      `ws://${window.location.host}/api/embodiment/episodes/ep_visible/preview-live`,
    )
    expect(socket.binaryType).toBe("blob")

    act(() => socket.open())
    expect(result.current.connected).toBe(true)

    act(() => socket.message(older))
    act(() => socket.message(newest))
    await waitFor(() => expect(decode).toHaveBeenCalledExactlyOnceWith(newest))

    await act(async () => {
      newestDecode.resolve(newestBitmap)
      await Promise.resolve()
    })
    expect(drawImage).toHaveBeenCalledExactlyOnceWith(newestBitmap, 0, 0)
    expect(canvas).toHaveProperty("width", 1280)
    expect(canvas).toHaveProperty("height", 720)
    expect(result.current.frameReady).toBe(true)

    expect(drawImage).toHaveBeenCalledExactlyOnceWith(newestBitmap, 0, 0)
    expect(newestBitmap.close).toHaveBeenCalledOnce()
  })

  it("opens a participant-scoped paired stream and reconnects when seat selection changes", () => {
    const view = renderHook(
      ({ participantId }: { participantId: "participant_0" | "participant_1" }) =>
        useParticipantPreview(series(), participantId),
      { initialProps: { participantId: "participant_0" as "participant_0" | "participant_1" } },
    )
    expect(MockWebSocket.instances[0].url).toBe(
      `ws://${window.location.host}/api/embodiment/series/series_visible/participants/participant_0/preview-live`,
    )
    view.rerender({ participantId: "participant_1" as const })
    expect(MockWebSocket.instances[0].close).toHaveBeenCalledOnce()
    expect(MockWebSocket.instances[1].url).toBe(
      `ws://${window.location.host}/api/embodiment/series/series_visible/participants/participant_1/preview-live`,
    )
    expect(view.result.current.frameReady).toBe(false)
  })

  it("opens the isolated participant 2 trio stream", () => {
    renderHook(() => useParticipantPreview(trio(), "participant_2"))
    expect(MockWebSocket.instances[0].url).toBe(
      `ws://${window.location.host}/api/embodiment/trio-series/trio_visible/participants/participant_2/preview-live`,
    )
  })

  it("drops stale frames that arrive while a JPEG decode is busy", async () => {
    const first = new Blob(["first"], { type: "image/jpeg" })
    const stale = new Blob(["stale"], { type: "image/jpeg" })
    const newest = new Blob(["newest"], { type: "image/jpeg" })
    const firstDecode = deferred<ImageBitmap>()
    const newestDecode = deferred<ImageBitmap>()
    const decode = vi.fn((blob: Blob) => blob === first ? firstDecode.promise : newestDecode.promise)
    vi.stubGlobal("createImageBitmap", decode)

    const { result } = renderHook(() => useParticipantPreview(episode()))
    result.current.canvasRef.current = document.createElement("canvas")
    const socket = MockWebSocket.instances[0]
    act(() => socket.open())
    act(() => socket.message(first))
    await waitFor(() => expect(decode).toHaveBeenCalledExactlyOnceWith(first))

    act(() => socket.message(stale))
    act(() => socket.message(newest))
    await act(async () => {
      firstDecode.resolve(imageBitmap(1280, 720))
      await Promise.resolve()
    })
    await waitFor(() => expect(decode).toHaveBeenCalledTimes(2))
    expect(decode.mock.calls[1]?.[0]).toBe(newest)
    expect(decode.mock.calls.some(([blob]) => blob === stale)).toBe(false)

    await act(async () => {
      newestDecode.resolve(imageBitmap(1280, 720))
      await Promise.resolve()
    })
    expect(drawImage).toHaveBeenCalledTimes(2)
  })

  it("keeps a canonical fallback visible until the first participant-pixel preview is decoded", async () => {
    const fallback = new Blob(["canonical"], { type: "image/png" })
    const preview = new Blob(["participant-pixels"], { type: "image/jpeg" })
    const bitmap = imageBitmap(1280, 720)
    vi.stubGlobal("createImageBitmap", vi.fn(async () => bitmap))

    render(
      <ParticipantFrame
        episode={episode()}
        frame={{ data: frame(fallback), isError: false } as never}
      />,
    )
    const socket = MockWebSocket.instances[0]
    expect(screen.getByRole("img", { name: "Active participant Godot camera frame" })).toBeVisible()
    expect(screen.queryByText("Connecting to participant camera")).not.toBeInTheDocument()

    act(() => socket.open())
    act(() => socket.message(preview))

    await waitFor(() => expect(screen.queryByRole("img", { name: "Active participant Godot camera frame" })).not.toBeInTheDocument())
    expect(screen.getByLabelText("Active participant Godot camera stream")).toBeVisible()
    expect(screen.queryByText("Connecting to participant camera")).not.toBeInTheDocument()
    expect(screen.getByText("Live stream")).toBeInTheDocument()
  })

  it("uses the canonical snapshot after an active stream disconnect, but retains the final live frame", async () => {
    const fallback = new Blob(["canonical"], { type: "image/png" })
    const preview = new Blob(["participant-pixels"], { type: "image/jpeg" })
    vi.stubGlobal("createImageBitmap", vi.fn(async () => imageBitmap(1280, 720)))

    const view = render(
      <ParticipantFrame
        episode={episode()}
        frame={{ data: frame(fallback), isError: false } as never}
      />,
    )
    const socket = MockWebSocket.instances[0]
    act(() => socket.open())
    act(() => socket.message(preview))
    await waitFor(() => expect(screen.queryByRole("img")).not.toBeInTheDocument())

    act(() => socket.close())
    await waitFor(() => expect(screen.getByRole("img", {
      name: "Active participant Godot camera frame",
    })).toBeVisible())

    view.rerender(
      <ParticipantFrame
        episode={episode("success")}
        frame={{ data: frame(fallback), isError: false } as never}
      />,
    )
    await waitFor(() => expect(screen.queryByRole("img")).not.toBeInTheDocument())
  })

  it("does not decode or render non-binary websocket messages", async () => {
    const decode = vi.fn()
    vi.stubGlobal("createImageBitmap", decode)
    const { result } = renderHook(() => useParticipantPreview(episode()))
    result.current.canvasRef.current = document.createElement("canvas")
    const socket = MockWebSocket.instances[0]

    act(() => socket.open())
    act(() => socket.message('{"prompt":"must never be rendered"}'))
    await act(async () => { await Promise.resolve() })

    expect(decode).not.toHaveBeenCalled()
    expect(result.current.frameReady).toBe(false)
  })
})
