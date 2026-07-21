/* eslint-disable react-hooks/refs -- The preview hook returns render state alongside a canvas ref; this component never reads ref.current during render. */
import { useEffect, useState } from "react"
import type { UseQueryResult } from "@tanstack/react-query"
import { LoaderCircleIcon, ShieldCheckIcon } from "lucide-react"
import type { EpisodeView, ParticipantFrameView } from "@/api"
import { useParticipantPreview } from "@/hooks/use-participant-preview"

function ParticipantFrameImage({ blob }: { blob: Blob }) {
  const [source] = useState(() => URL.createObjectURL(blob))

  useEffect(() => () => URL.revokeObjectURL(source), [source])

  return <img src={source} alt="Active participant Godot camera frame" />
}

export function ParticipantFrame({
  episode,
  frame,
}: {
  episode: EpisodeView
  frame: UseQueryResult<ParticipantFrameView, Error>
}) {
  const preview = useParticipantPreview(episode)
  const terminal = !["queued", "running"].includes(episode.status)
  const unavailable = episode.failureCode === "embodiment_provider_unavailable"
  const state = frame.data?.state ?? (terminal ? "finished" : "loading")
  // Keep the last verified live frame when the episode ends, but fall back to the canonical
  // snapshot during an unexpected active-stream disconnect whenever one is available.
  const showLivePreview = preview.frameReady && (preview.connected || terminal || !frame.data?.blob)
  const presentationState = terminal ? "finished" : showLivePreview ? "live" : state
  const label = presentationState === "finished"
    ? "Finished"
    : preview.connected || preview.frameReady
      ? "Live stream"
      : presentationState === "live"
        ? "Live"
        : "Loading"

  return (
    <section className="arena-viewport participant-frame" aria-label="Active participant camera">
      <canvas
        ref={preview.canvasRef}
        className={`participant-preview${showLivePreview ? " is-live" : ""}`}
        aria-label="Active participant Godot camera stream"
      />
      {frame.data?.blob && !showLivePreview ? (
        <ParticipantFrameImage key={frame.data.sha256} blob={frame.data.blob} />
      ) : !showLivePreview ? (
        <div className="participant-frame-empty">
          {frame.isError ? <ShieldCheckIcon /> : <LoaderCircleIcon className="frame-spinner" />}
          <h2>{frame.isError ? "Participant camera unavailable" : unavailable ? "Model task unavailable" : terminal ? "Episode finished" : "Connecting to participant camera"}</h2>
          <p>{frame.isError
            ? "No protected episode data was exposed."
            : unavailable
              ? "The model could not return a valid task. Re-enter the session key and start a new episode."
            : terminal
              ? "The episode ended before a participant frame was available."
              : "Waiting for the first player-visible Godot frame."}</p>
        </div>
      ) : null}
      <div className={`participant-frame-status frame-${presentationState}`}>
        <span><i />{label}</span>
        {frame.data?.observationSeq === null || frame.data?.observationSeq === undefined
          ? "Participant view"
          : `Observation ${frame.data.observationSeq}`}
      </div>
      <div className="participant-frame-privacy">
        <ShieldCheckIcon /> Participant-visible pixels only · no prompts, model output, credentials, or spectator state
      </div>
    </section>
  )
}
