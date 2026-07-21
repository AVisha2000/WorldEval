import { useQuery } from "@tanstack/react-query"
import { getParticipantFrame, type EpisodeView } from "@/api"

export function useParticipantFrame(episode: EpisodeView) {
  const terminal = !["queued", "running"].includes(episode.status)
  return useQuery({
    queryKey: ["participant-frame", episode.episodeId, episode.status],
    queryFn: () => getParticipantFrame(episode.episodeId),
    enabled: episode.kind === "episode",
    refetchInterval: terminal ? false : 750,
    refetchIntervalInBackground: true,
    gcTime: 0,
  })
}
