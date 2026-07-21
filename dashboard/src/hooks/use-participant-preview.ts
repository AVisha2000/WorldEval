import { useEffect, useRef, useState } from "react"
import type { EpisodeView } from "@/api"

export function useParticipantPreview(episode: EpisodeView) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const [connected, setConnected] = useState(false)
  const [readyEpisodeId, setReadyEpisodeId] = useState<string | null>(null)
  const frameReady = readyEpisodeId === episode.episodeId

  useEffect(() => {
    if (episode.kind !== "episode" || episode.status !== "running" || typeof WebSocket === "undefined") return
    const protocol = window.location.protocol === "https:" ? "wss:" : "ws:"
    const socket = new WebSocket(`${protocol}//${window.location.host}/api/embodiment/episodes/${episode.episodeId}/preview-live`)
    socket.binaryType = "blob"
    let disposed = false
    let newestReceived = 0
    socket.onopen = () => setConnected(true)
    socket.onclose = () => { if (!disposed) setConnected(false) }
    socket.onmessage = async (event) => {
      if (!(event.data instanceof Blob) || typeof createImageBitmap !== "function") return
      const received = ++newestReceived
      const canvas = canvasRef.current
      if (!canvas) return
      const bitmap = await createImageBitmap(event.data)
      // Image decoding can finish out of order.  Draw only the newest decoded participant frame
      // so a slow older PNG can never make the local stream move backwards.
      if (disposed || received !== newestReceived) {
        bitmap.close()
        return
      }
      if (canvas.width !== bitmap.width || canvas.height !== bitmap.height) {
        canvas.width = bitmap.width
        canvas.height = bitmap.height
      }
      canvas.getContext("2d")?.drawImage(bitmap, 0, 0)
      bitmap.close()
      setReadyEpisodeId(episode.episodeId)
    }
    return () => { disposed = true; socket.close(); setConnected(false) }
  }, [episode.episodeId, episode.kind, episode.status])
  return { canvasRef, connected, frameReady }
}
