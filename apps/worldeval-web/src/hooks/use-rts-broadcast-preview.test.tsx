import { act, renderHook } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { useRtsBroadcastPreview } from "@/hooks/use-rts-broadcast-preview"
import type { EpisodeView } from "@/api"

class SocketStub {
  static instances: SocketStub[] = []
  binaryType = ""
  onopen: (() => void) | null = null
  onclose: (() => void) | null = null
  onmessage: ((event: MessageEvent) => void) | null = null
  readonly url: string
  constructor(url: string) { this.url = url; SocketStub.instances.push(this) }
  close() { this.onclose?.() }
}

const rtsEpisode: EpisodeView = {
  kind: "series", episodeId: "series_rts", status: "running", observationSeq: 0, tick: 0,
  taskId: "rts-skirmish-v0", taskLabel: "RTS Skirmish", timeline: [],
}

describe("useRtsBroadcastPreview", () => {
  afterEach(() => { SocketStub.instances = []; vi.unstubAllGlobals() })

  it("opens only the isolated broadcast endpoint for an active RTS series", () => {
    vi.stubGlobal("WebSocket", SocketStub)
    const { result } = renderHook(() => useRtsBroadcastPreview(rtsEpisode))
    expect(result.current.frameReady).toBe(false)
    expect(SocketStub.instances).toHaveLength(1)
    expect(SocketStub.instances[0].url).toContain(
      "/api/embodiment/series/series_rts/broadcast/preview-live"
    )
    expect(SocketStub.instances[0].url).not.toContain("participants")
    act(() => SocketStub.instances[0].onopen?.())
    expect(result.current.connected).toBe(true)
  })

  it("does not create a broadcast socket for another game", () => {
    vi.stubGlobal("WebSocket", SocketStub)
    renderHook(() => useRtsBroadcastPreview({ ...rtsEpisode, taskId: "duo-resource-relay-v0" }))
    expect(SocketStub.instances).toHaveLength(0)
  })
})
