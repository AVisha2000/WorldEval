import { useRef, useState } from "react"
import { useMutation, useQuery } from "@tanstack/react-query"
import type { EpisodeSetup } from "@/api"
import { cancelRun, createRun, getEpisode, getReadiness } from "@/api"
import worldArenaThumbnail from "@/assets/worldarena-build-things-thumbnail.jpg"
import { EpisodeWorkspace } from "@/components/episode-workspace"
import { ReadinessPanel } from "@/components/readiness-panel"
import { SetupPanel } from "@/components/setup-panel"
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs"

const INITIAL_SETUP: EpisodeSetup = {
  mode: "solo",
  provider: "openai",
  model: "gpt-5.6-sol",
  apiKey: "",
  opponentProvider: "scripted",
  opponentModel: "balanced-v1",
  opponentApiKey: "",
  taskId: "construction-v0",
  seed: 20240520,
}

export function App() {
  const [setup, setSetup] = useState(INITIAL_SETUP)
  const submittedSetup = useRef<EpisodeSetup | null>(null)
  const [episodeId, setEpisodeId] = useState<string | null>(null)
  const [selected, setSelected] = useState(0)
  const [view, setView] = useState("run")
  const create = useMutation({
    mutationFn: () => {
      const submitted = submittedSetup.current
      if (submitted === null) throw new Error("Episode setup is unavailable")
      return createRun(submitted)
    },
    onSuccess: (episode) => {
      setEpisodeId(episode.episodeId)
      setView("run")
    },
    onSettled: () => {
      submittedSetup.current = null
      setSetup((current) => ({ ...current, apiKey: "", opponentApiKey: "" }))
    },
  })
  const status = useQuery({
    queryKey: ["episode", episodeId],
    queryFn: () => getEpisode(episodeId!),
    enabled: episodeId !== null,
    refetchInterval: (query) => query.state.data === undefined
      || ["queued", "running"].includes(query.state.data.status)
      ? 1000
      : false,
    refetchIntervalInBackground: true,
  })
  const cancel = useMutation({
    mutationFn: () => {
      if (episodeId === null) throw new Error("Run identifier is unavailable")
      return cancelRun(episodeId)
    },
    onSuccess: () => status.refetch(),
  })
  const readiness = useQuery({
    queryKey: ["certification-readiness"],
    queryFn: getReadiness,
    refetchInterval: 10_000,
    retry: false,
  })
  const episode = status.data ?? create.data
  return (
    <div className="app-shell">
      <header className="app-header">
        <div className="app-header-brand">
          <h1>
            WorldArena <span>Controller Lab</span>
          </h1>
          <img
            alt="WorldArena agents building on a shared world"
            className="app-header-thumbnail"
            height="68"
            src={worldArenaThumbnail}
            width="120"
          />
        </div>
        <Tabs value={view} onValueChange={setView}>
          <TabsList variant="line">
            <TabsTrigger value="run">Run</TabsTrigger>
            <TabsTrigger value="timeline">Timeline</TabsTrigger>
            <TabsTrigger value="result">Result</TabsTrigger>
            <TabsTrigger value="replay">Replay</TabsTrigger>
          </TabsList>
        </Tabs>
      </header>
      <ReadinessPanel readiness={readiness.data} unavailable={readiness.isError} />
      <div className="app-body">
        <SetupPanel
          setup={setup}
          pending={create.isPending}
          onChange={setSetup}
          onSubmit={() => {
            if (create.isPending) return
            submittedSetup.current = setup
            create.mutate()
          }}
        />
        <EpisodeWorkspace
          episode={episode}
          mode={setup.mode}
          view={view}
          selected={selected}
          onSelect={setSelected}
          cancelling={cancel.isPending}
          onCancel={() => cancel.mutate()}
        />
      </div>
      {create.isError || status.isError ? (
        <div role="alert" className="error-banner">
          Episode service unavailable. The API key was not retained by the browser.
        </div>
      ) : null}
    </div>
  )
}

export default App
