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

  beforeEach(() => {
    MockWebSocket.instances = []
    vi.stubGlobal("WebSocket", MockWebSocket)
    vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockReturnValue(
      { drawImage } as unknown as CanvasRenderingContext2D,
    )
    vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:canonical-frame")
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined)
  })

  afterEach(() => {
    cleanup()
    drawImage.mockReset()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it("uses the isolated live-preview route and never lets an older async decode move the view backwards", async () => {
    const older = new Blob(["older"], { type: "image/png" })
    const newest = new Blob(["newest"], { type: "image/png" })
    const olderDecode = deferred<ImageBitmap>()
    const newestDecode = deferred<ImageBitmap>()
    const olderBitmap = imageBitmap(1280, 720)
    const newestBitmap = imageBitmap(1280, 720)
    const decode = vi.fn((blob: Blob) => blob === older ? olderDecode.promise : newestDecode.promise)
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
    await waitFor(() => expect(decode).toHaveBeenCalledTimes(2))

    await act(async () => {
      newestDecode.resolve(newestBitmap)
      await Promise.resolve()
    })
    expect(drawImage).toHaveBeenCalledExactlyOnceWith(newestBitmap, 0, 0)
    expect(canvas).toHaveProperty("width", 1280)
    expect(canvas).toHaveProperty("height", 720)
    expect(result.current.frameReady).toBe(true)

    await act(async () => {
      olderDecode.resolve(olderBitmap)
      await Promise.resolve()
    })
    expect(drawImage).toHaveBeenCalledExactlyOnceWith(newestBitmap, 0, 0)
    expect(olderBitmap.close).toHaveBeenCalledOnce()
    expect(newestBitmap.close).toHaveBeenCalledOnce()
  })

  it("keeps a canonical fallback visible until the first participant-pixel preview is decoded", async () => {
    const fallback = new Blob(["canonical"], { type: "image/png" })
    const preview = new Blob(["participant-pixels"], { type: "image/png" })
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
    const preview = new Blob(["participant-pixels"], { type: "image/png" })
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
