import { useEffect, useState } from "react"
import type { UseQueryResult } from "@tanstack/react-query"
import { LoaderCircleIcon, ShieldCheckIcon } from "lucide-react"
import type { EpisodeView, ParticipantFrameView } from "@/api"

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
  const terminal = !["queued", "running"].includes(episode.status)
  const state = frame.data?.state ?? (terminal ? "finished" : "loading")
  const label = state === "finished" ? "Finished" : state === "live" ? "Live" : "Loading"

  return (
    <section className="arena-viewport participant-frame" aria-label="Active participant camera">
      {frame.data?.blob ? (
        <ParticipantFrameImage key={frame.data.sha256} blob={frame.data.blob} />
      ) : (
        <div className="participant-frame-empty">
          {frame.isError ? <ShieldCheckIcon /> : <LoaderCircleIcon className="frame-spinner" />}
          <h2>{frame.isError ? "Participant camera unavailable" : terminal ? "Episode finished" : "Connecting to participant camera"}</h2>
          <p>{frame.isError
            ? "No protected episode data was exposed."
            : terminal
              ? "The episode ended before a participant frame was available."
              : "Waiting for the first player-visible Godot frame."}</p>
        </div>
      )}
      <div className={`participant-frame-status frame-${state}`}>
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
