import { useEffect, useRef, useState } from "react"
import type { EpisodeView } from "@/api"

/**
 * A deliberately separate public broadcast channel for RTS Skirmish.  It is not a fallback for
 * a player camera: its endpoint carries presentation JPEG pixels only, and this hook never asks
 * for player observations, semantic state, or a participant frame.
 */
export function useRtsBroadcastPreview(episode: EpisodeView) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const [connected, setConnected] = useState(false)
  const [readyEpisodeId, setReadyEpisodeId] = useState<string | null>(null)
  const active = episode.kind === "series" && episode.taskId === "rts-skirmish-v0"

  useEffect(() => {
    if (!active || episode.status !== "running" || typeof WebSocket === "undefined") return
    const protocol = window.location.protocol === "https:" ? "wss:" : "ws:"
    const socket = new WebSocket(
      `${protocol}//${window.location.host}/api/embodiment/series/${episode.episodeId}/broadcast/preview-live`
    )
    socket.binaryType = "blob"
    let disposed = false
    let pending: Blob | null = null
    let decoding = false
    let animationFrame = 0
    let lastDrawAt = Number.NEGATIVE_INFINITY

    const schedule = () => {
      if (!disposed && animationFrame === 0) animationFrame = window.requestAnimationFrame(consume)
    }
    const consume = (now: number) => {
      animationFrame = 0
      if (disposed || decoding || pending === null) return
      if (now - lastDrawAt < 1000 / 30) {
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
        // The broadcast has a separately authenticated/sanitized fixed-resolution JPEG
        // contract. Reject anything else before it can alter the stable canvas.
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
          setReadyEpisodeId(episode.episodeId)
        }
        bitmap.close()
      }).catch(() => {
        // Presentation-only decoding failure: retain the last good public frame.
      }).finally(() => {
        decoding = false
        if (pending !== null) schedule()
      })
    }
    socket.onopen = () => setConnected(true)
    socket.onclose = () => { if (!disposed) setConnected(false) }
    socket.onmessage = (event) => {
      if (!(event.data instanceof Blob) || typeof createImageBitmap !== "function") return
      // Bounded newest-frame queue: broadcast rendering can never introduce gameplay latency.
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
  }, [active, episode.episodeId, episode.status])

  return { canvasRef, connected, frameReady: readyEpisodeId === episode.episodeId }
}
