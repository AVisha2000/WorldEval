import { useQuery } from "@tanstack/react-query"
import { getParticipantFrame, type EpisodeView } from "@/api"

export function useParticipantFrame(episode: EpisodeView) {
  const terminal = !["queued", "running"].includes(episode.status)
  return useQuery({
    queryKey: ["participant-frame", episode.episodeId, episode.status],
    queryFn: () => getParticipantFrame(episode.episodeId),
    // Labyrinth Run is a public replay race, not a solo authority episode.  Its visual output
    // arrives through the verified maze-video endpoint, so never poll the solo frame route.
    enabled: episode.kind === "episode" && episode.taskId !== "trio-maze-race-v1",
    refetchInterval: terminal ? false : 750,
    refetchIntervalInBackground: true,
    gcTime: 0,
  })
}
