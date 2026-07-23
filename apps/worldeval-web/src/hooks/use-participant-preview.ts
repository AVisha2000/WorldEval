import { useEffect, useRef, useState } from "react"
import type { EpisodeView, ParticipantId } from "@/api"

export function useParticipantPreview(
  episode: EpisodeView,
  participantId: ParticipantId = "participant_0",
) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const [connected, setConnected] = useState(false)
  const [readyEpisodeId, setReadyEpisodeId] = useState<string | null>(null)
  const previewIdentity = `${episode.episodeId}:${participantId}`
  const frameReady = readyEpisodeId === previewIdentity

  useEffect(() => {
    if (episode.status !== "running" || typeof WebSocket === "undefined") return
    const protocol = window.location.protocol === "https:" ? "wss:" : "ws:"
    const path = episode.kind === "trio"
      ? `/api/embodiment/trio-series/${episode.episodeId}/participants/${participantId}/preview-live`
      : episode.kind === "series"
        ? `/api/embodiment/series/${episode.episodeId}/participants/${participantId}/preview-live`
        : `/api/embodiment/episodes/${episode.episodeId}/preview-live`
    const socket = new WebSocket(`${protocol}//${window.location.host}${path}`)
    socket.binaryType = "blob"
    let disposed = false
    let pending: Blob | null = null
    let decoding = false
    let animationFrame = 0
    let lastDrawAt = Number.NEGATIVE_INFINITY
    const frameIntervalMs = 1000 / 30

    const schedule = () => {
      if (!disposed && animationFrame === 0) animationFrame = window.requestAnimationFrame(consume)
    }
    const consume = (now: number) => {
      animationFrame = 0
      if (disposed || decoding || pending === null) return
      if (now - lastDrawAt < frameIntervalMs) {
        schedule()
        return
      }
      const pixels = pending
      pending = null
      decoding = true
      void createImageBitmap(pixels).then((bitmap) => {
        if (disposed) {
          bitmap.close()
          return
        }
        // The isolated preview contract is fixed-size. A malformed binary message is dropped
        // before it can resize or clear the stable participant canvas.
        if (bitmap.width !== 1280 || bitmap.height !== 720) {
          bitmap.close()
          return
        }
        const canvas = canvasRef.current
        if (canvas) {
          if (canvas.width !== 1280 || canvas.height !== 720) {
            canvas.width = 1280
            canvas.height = 720
          }
          canvas.getContext("2d")?.drawImage(bitmap, 0, 0)
          lastDrawAt = performance.now()
          setReadyEpisodeId(previewIdentity)
        }
        bitmap.close()
      }).catch(() => {
        // Decoding failures are presentation-only drops. The last decoded canvas stays visible.
      }).finally(() => {
        decoding = false
        if (pending !== null) schedule()
      })
    }
    socket.onopen = () => setConnected(true)
    socket.onclose = () => { if (!disposed) setConnected(false) }
    socket.onmessage = (event) => {
      if (!(event.data instanceof Blob) || typeof createImageBitmap !== "function") return
      // A hard depth-one browser slot mirrors the backend hub: incoming pixels replace stale
      // undecoded pixels instead of accumulating latency or putting pressure on gameplay.
      pending = event.data
      schedule()
    }
    return () => {
      disposed = true
      pending = null
      if (animationFrame !== 0) window.cancelAnimationFrame(animationFrame)
      socket.close()
      setConnected(false)
    }
  }, [episode.episodeId, episode.kind, episode.status, participantId, previewIdentity])
  return { canvasRef, connected, frameReady }
}
