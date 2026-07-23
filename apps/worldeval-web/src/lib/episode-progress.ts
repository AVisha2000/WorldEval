import type { EpisodeView, ParticipantFrameView } from "@/api"

export function displayRunProgress(
  episode: EpisodeView,
  frame: ParticipantFrameView | undefined,
) {
  const frameObservationSeq = episode.kind === "episode" ? frame?.observationSeq ?? 0 : 0
  const observationSeq = Math.max(episode.observationSeq, frameObservationSeq)
  // A participant frame at observation N proves at least N authority ticks elapsed. Do not
  // invent an exact duration for direct-controller windows, but use that safe lower bound when
  // the lightweight lifecycle status has not caught up yet.
  const tick = Math.max(episode.tick, frameObservationSeq)
  return { observationSeq, tick }
}
