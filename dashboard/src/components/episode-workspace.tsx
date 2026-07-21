import {
  DownloadIcon,
  LoaderCircleIcon,
  LockKeyholeIcon,
  ShieldCheckIcon,
  SquareIcon,
} from "lucide-react"
import { useQuery } from "@tanstack/react-query"
import { useEffect, useRef, useState } from "react"
import type { RefObject } from "react"
import { participantTeam, participantTeams, TEAM_COLOURS } from "@/lib/participant-team"
import type {
  ControllerMode,
  EpisodeView,
  EvaluationMetric,
  ParticipantId,
  SavedReplaySummary,
  SeriesNativeReplayArtifact,
  TimelineRow,
} from "@/api"
import {
  bundleUrl,
  getEpisodeEvaluation,
  getSeriesEvaluation,
  getTrioEvaluation,
  getSeriesParticipantFrame,
  getSavedReplay,
  getSavedReplayEvaluation,
  getSavedReplays,
  liveMazeVideoUrl,
  savedReplayVideoUrl,
  seriesParticipantVideoUrl,
} from "@/api"
import { Badge } from "@/components/ui/badge"
import { Button, buttonVariants } from "@/components/ui/button"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { cn } from "@/lib/utils"
import { displayRunProgress } from "@/lib/episode-progress"
import { ParticipantFrame } from "@/components/participant-frame"
import { useParticipantFrame } from "@/hooks/use-participant-frame"
import { useParticipantPreview } from "@/hooks/use-participant-preview"
import { useRtsBroadcastPreview } from "@/hooks/use-rts-broadcast-preview"

type Props = {
  episode?: EpisodeView
  controllerMode: ControllerMode
  mode: "solo" | "duel" | "trio"
  view: string
  selected: number
  onSelect: (window: number) => void
  cancelling: boolean
  onCancel: () => void
}

function DecisionTimeline({
  rows,
  selected,
  onSelect,
}: {
  rows: TimelineRow[]
  selected: number
  onSelect: (window: number) => void
}) {
  if (rows.length === 0) {
    return (
      <section className="timeline-panel empty-panel">
        Decision receipts appear here as soon as sealed evidence is available.
      </section>
    )
  }
  return (
    <section className="timeline-panel">
      <h2 className="section-title">Decision timeline</h2>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Window</TableHead>
            <TableHead>Action</TableHead>
            <TableHead>Receipt</TableHead>
            <TableHead>Ticks</TableHead>
            <TableHead>Latency</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((row) => (
            <TableRow
              key={row.window}
              data-state={row.window === selected ? "selected" : undefined}
              onClick={() => onSelect(row.window)}
              tabIndex={0}
              onKeyDown={(event) =>
                event.key === "Enter" && onSelect(row.window)
              }
            >
              <TableCell className="font-mono">{row.window}</TableCell>
              <TableCell>{row.intent}</TableCell>
              <TableCell>{row.receipt}</TableCell>
              <TableCell className="font-mono">{row.ticks}</TableCell>
              <TableCell className="font-mono">
                {row.latencyMs === null ? "protected" : `${row.latencyMs} ms`}
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </section>
  )
}

function RunView({
  episode,
  cancelling,
  onCancel,
  duelParticipant,
  onDuelParticipantChange,
}: {
  episode: EpisodeView
  cancelling: boolean
  onCancel: () => void
  duelParticipant: ParticipantId
  onDuelParticipantChange: (participantId: ParticipantId) => void
}) {
  const frame = useParticipantFrame(episode)
  const duelFrame = useQuery({
    queryKey: ["series-participant-frame", episode.episodeId, duelParticipant, episode.status],
    queryFn: () => getSeriesParticipantFrame(episode.episodeId, duelParticipant),
    enabled: episode.kind === "series" || episode.kind === "trio",
    refetchInterval: episode.status === "queued" || episode.status === "running" ? 500 : false,
    refetchIntervalInBackground: true,
    gcTime: 0,
  })
  const progress = displayRunProgress(episode, frame.data)
  return (
    <main className="workspace-main">
      <div className="status-strip">
        <Badge variant="outline" className="status-running">
          ● {episode.status}
        </Badge>
        <span aria-label="Observation progress">
          Observation <b>{progress.observationSeq}</b>
        </span>
        <span aria-label="Authority tick">
          Tick <b>{progress.tick}</b>
        </span>
        <strong>{episode.taskLabel}</strong>
        {episode.status === "queued" || episode.status === "running" ? (
          <Button
            variant="outline"
            size="sm"
            disabled={cancelling}
            onClick={onCancel}
          >
            <SquareIcon data-icon="inline-start" />
            {cancelling ? "Cancelling…" : "Cancel run"}
          </Button>
        ) : null}
      </div>
      {episode.taskId === "trio-maze-race-v1" ? (
        <LiveMazeViewport episode={episode} />
      ) : episode.kind === "episode" ? (
        <ParticipantFrame episode={episode} frame={frame} />
      ) : episode.kind === "series" && episode.taskId === "rts-skirmish-v0" ? (
        <RtsSkirmishViewport
          episode={episode}
          participantId={duelParticipant}
          onParticipantChange={onDuelParticipantChange}
          frame={duelFrame.data}
        />
      ) : (
        <DuelParticipantViewport
          episode={episode}
          participantId={duelParticipant}
          onParticipantChange={onDuelParticipantChange}
          frame={duelFrame.data}
        />
      )}
    </main>
  )
}

function LiveMazeViewport({ episode }: { episode: EpisodeView }) {
  const videoRef = useRef<HTMLVideoElement>(null)
  const ready = episode.liveMazeVideoState === "ready"
  const running = episode.status === "queued" || episode.status === "running"
  return <section className="arena-viewport participant-frame" aria-label="Live Labyrinth Run broadcast">
    {ready ? <>
      <video ref={videoRef} className="saved-replay-video" aria-label="Live Labyrinth Run video" controls autoPlay muted playsInline>
        <source src={liveMazeVideoUrl(episode.episodeId)} type="video/mp4" />
        Your browser cannot play this live Labyrinth Run video.
      </video>
      <ReplaySpeedControls videoRef={videoRef} />
    </> : <div className="participant-frame-empty">
      <LoaderCircleIcon className="frame-spinner" />
      <h2>{running ? "Labyrinth Run is in progress" : "Preparing verified race broadcast"}</h2>
      <p>{running
        ? "Three private controllers are racing concurrently. The public replay is rendered after authority verification."
        : episode.status === "failure"
          ? "The live race could not start. Re-enter a valid provider key and try again."
          : "The race is sealed; native video is still being prepared."}</p>
    </div>}
    <div className={`participant-frame-status frame-${running ? "live" : "finished"}`}>
      <span><i />{running ? "Live race" : "Verified race"}</span>
      {episode.result ? `${episode.result.windows} provider calls` : "Three private maze views"}
    </div>
    <div className="participant-frame-privacy">
      <ShieldCheckIcon /> Public replay only · no prompts, raw output, credentials, hidden state, or spectator input
    </div>
  </section>
}

function RtsSkirmishViewport({
  episode,
  participantId,
  onParticipantChange,
  frame,
}: {
  episode: EpisodeView
  participantId: ParticipantId
  onParticipantChange: (participantId: ParticipantId) => void
  frame?: Awaited<ReturnType<typeof getSeriesParticipantFrame>>
}) {
  const [camera, setCamera] = useState<"broadcast" | "participant">("broadcast")
  const { canvasRef, connected, frameReady } = useRtsBroadcastPreview(episode)
  const terminal = episode.status !== "queued" && episode.status !== "running"
  const showBroadcast = camera === "broadcast"
  const showBroadcastPixels = frameReady && (connected || terminal)
  const teams = participantTeams(episode, frame?.legIndex ?? 0)
  return <section className="arena-viewport protected-frame rts-broadcast-viewport" aria-label="RTS Skirmish camera controls">
    {showBroadcast ? <div className="duel-participant-media rts-broadcast-media">
      <canvas ref={canvasRef} className={`participant-preview${showBroadcastPixels ? " is-live" : ""}`} aria-label="RTS broadcast presentation camera" />
      {!showBroadcastPixels ? <div className="participant-frame-empty">
        <LoaderCircleIcon className="frame-spinner" />
        <h2>{terminal ? "Broadcast capture finished" : "Connecting to RTS broadcast"}</h2>
        <p>The broadcast is a separate public presentation camera, never a player observation or fallback for one.</p>
      </div> : null}
    </div> : <DuelParticipantViewport episode={episode} participantId={participantId} onParticipantChange={onParticipantChange} frame={frame} />}
    <div className="rts-camera-controls">
      <div>
        <p className="section-title">Camera</p>
        <h2>{showBroadcast ? "Public tactical broadcast" : `${participantId.replace("participant_", "Participant ")} private view`}</h2>
      </div>
      <div className="participant-selector" role="group" aria-label="RTS Skirmish camera">
        <Button size="sm" variant={showBroadcast ? "default" : "outline"} onClick={() => setCamera("broadcast")}>Broadcast</Button>
        {teams.slice(0, 2).map((team) => <Button key={team.participantId} size="sm" variant={!showBroadcast && participantId === team.participantId ? "default" : "outline"} data-team={team.tone} onClick={() => { onParticipantChange(team.participantId); setCamera("participant") }}>{team.displayName}</Button>)}
      </div>
    </div>
    {showBroadcast ? <p className="rts-broadcast-notice"><ShieldCheckIcon /> Public tactical broadcast · presentation pixels only · never used as an agent observation, replay input, score input, or player-camera substitute.</p> : null}
  </section>
}

function DuelParticipantImage({ blob, participantId }: { blob: Blob; participantId: string }) {
  const [source] = useState(() => URL.createObjectURL(blob))
  useEffect(() => () => URL.revokeObjectURL(source), [source])
  return <img src={source} alt={`${participantId} Godot camera frame`} />
}

function DuelParticipantViewport({
  episode,
  participantId,
  onParticipantChange,
  frame,
}: {
  episode: EpisodeView
  participantId: ParticipantId
  onParticipantChange: (participantId: ParticipantId) => void
  frame?: Awaited<ReturnType<typeof getSeriesParticipantFrame>>
}) {
  const { canvasRef, connected, frameReady } = useParticipantPreview(episode, participantId)
  const terminal = episode.status !== "queued" && episode.status !== "running"
  const showLive = frameReady && (connected || terminal || !frame?.blob)
  const activeLegIndex = frame?.legIndex ?? 0
  const teams = participantTeams(episode, activeLegIndex)
  const selectedTeam = participantTeam(episode, participantId, activeLegIndex)
  return <section className="arena-viewport protected-frame duel-participant-frame" aria-label="Participant frame policy">
    <div className="duel-participant-media">
      <canvas key={participantId} ref={canvasRef} className={`participant-preview${showLive ? " is-live" : ""}`} aria-label={`${participantId} live Godot camera stream`} />
      {frame?.blob && !showLive
        ? <DuelParticipantImage key={frame.sha256} blob={frame.blob} participantId={participantId} />
        : !showLive ? <ShieldCheckIcon /> : null}
    </div>
    <h2>{selectedTeam ? `${selectedTeam.displayName} camera` : `${participantId.replace("participant_", "Participant ")} camera`}</h2>
    <ParticipantTeamLegend teams={teams} activeParticipant={participantId} legIndex={activeLegIndex} />
    <div className="participant-selector" role="group" aria-label="Participant camera">
      {teams.map((team) => <Button key={team.participantId} size="sm" variant={participantId === team.participantId ? "default" : "outline"} data-team={team.tone} aria-label={team.participantId.replace("participant_", "Participant ")} onClick={() => onParticipantChange(team.participantId)}>{team.participantId.replace("participant_", "P")} · {team.displayName}</Button>)}
    </div>
    <p>{showLive
      ? "Live 30 FPS participant stream"
      : frame?.blob
        ? `Leg ${(frame.legIndex ?? 0) + 1} · observation ${frame.observationSeq}`
        : episode.status === "queued" || episode.status === "running"
          ? "Waiting for this participant’s first frame."
          : "No participant frame was retained; no spectator view is substituted."}</p>
    <span>Participant-visible pixels only · no prompts, raw output, credentials, hidden state, or spectator view</span>
  </section>
}

function ParticipantTeamLegend({
  teams,
  activeParticipant,
  legIndex,
}: {
  teams: ReturnType<typeof participantTeams>
  activeParticipant: ParticipantId
  legIndex: number
}) {
  if (teams.length === 0) return null
  return <section className="participant-team-legend" aria-label="Team colour legend">
    <div>
      <strong>Teams</strong>
      <span>Leg {legIndex + 1} · colours follow each model through seat rotation</span>
    </div>
    <ul>
      {teams.map((team) => <li key={team.participantId} data-team={team.tone} data-active={team.participantId === activeParticipant || undefined} title={team.model}>
        <i aria-hidden="true" />
        <span>{team.displayName}</span>
        <small>{team.participantId.replace("participant_", "P")}</small>
      </li>)}
    </ul>
    <span className="sr-only">{teams.map((team) => `${team.displayName} is ${TEAM_COLOURS[team.tone]}`).join(". ")}</span>
  </section>
}

function ResultView({ episode }: { episode: EpisodeView }) {
  if (!episode.result)
    return (
      <div className="empty-workspace">
        Result becomes available after the episode seals.
      </div>
    )
  return (
    <main className="workspace-main result-view">
      <p className="section-title">Verified result</p>
      <h2>{episode.result.outcome}</h2>
      <dl>
        <dt>Decision windows</dt>
        <dd>{episode.result.windows}</dd>
        <dt>Provider fallbacks</dt>
        <dd>{episode.result.providerFailures}</dd>
        <dt>Final authority hash</dt>
        <dd className="code-block">{episode.result.finalStateHash}</dd>
      </dl>
      {episode.result.trioLegs ? <section className="evaluation-grid" aria-label="Typed trio placements">
        {episode.result.trioLegs.map((leg) => <article key={leg.legIndex}>
          <span>Leg {leg.legIndex + 1} · {leg.terminalReason}</span>
          <strong>{leg.placements.map((group) => `#${group.place} ${group.participantIds.map((id) => `P${id.replace("participant_", "")}`).join("/")}`).join(" · ")}</strong>
          <small>{leg.placements.some((group) => group.tied) ? "Typed tie placement" : "Ordered placement"}</small>
        </article>)}
      </section> : null}
    </main>
  )
}

function metricText(metric: EvaluationMetric | undefined) {
  if (!metric || metric.state === "unavailable") return "Unavailable"
  if (typeof metric.value === "boolean") return metric.value ? "Yes" : "No"
  if (typeof metric.value === "number") return String(metric.value)
  if (metric.value && typeof metric.value === "object" && "basis_points" in metric.value)
    return `${Number((metric.value as Record<string, unknown>).basis_points) / 100}%`
  return "Verified"
}

function SeriesEvaluationPanel({ episode }: { episode: EpisodeView }) {
  const evaluation = useQuery({
    queryKey: ["series-evaluation", episode.episodeId],
    queryFn: () => getSeriesEvaluation(episode.episodeId),
    retry: false,
    refetchInterval: (query) =>
      query.state.data === null && (episode.status === "queued" || episode.status === "running")
        ? 1000
        : false,
  })
  const value = evaluation.data
  return <main className="workspace-main evaluation-view">
    <p className="section-title">Authority-derived series evaluation</p>
    <h2>{episode.taskLabel}</h2>
    <p>Both seat-swapped legs are evaluated only from sealed public authority evidence.</p>
    {value ? <>
      <section className="evaluation-grid" aria-label="Paired evaluation summary">
        {value.legs.map((leg, index) => <article key={leg.run.episodeId}>
          <span>Leg {index + 1}</span>
          <strong>{leg.result.outcome}</strong>
          <small>{leg.result.windows} windows · {leg.result.providerFailures} fallbacks</small>
        </article>)}
        <article><span>Certification</span><strong>{value.certificationEligible ? "Eligible" : "Demo only"}</strong><small>{value.certificationReason ?? "Authority requirements met"}</small></article>
      </section>
      <dl className="evaluation-details">
        {value.legs.map((leg, index) => <div key={leg.projectionSha256} className="series-leg-evaluation"><dt>Leg {index + 1} integrity</dt><dd className="code-block">{leg.projectionSha256}</dd></div>)}
      </dl>
    </> : evaluation.isError ? <section className="saved-replay-state unavailable" role="alert"><LockKeyholeIcon /><div><h3>Series evaluation unavailable</h3><p>No protected evidence was requested or exposed.</p></div></section>
      : <section className="saved-replay-state" aria-live="polite"><LoaderCircleIcon className="frame-spinner" /><div><h3>Waiting for both sealed legs…</h3><p>Evaluation appears after the fixed two-leg series verifies.</p></div></section>}
    <div className="protected-note"><ShieldCheckIcon /> No observations, frames, prompts, raw model output, credentials, hidden state, or spectator data are included.</div>
  </main>
}

function TrioEvaluationPanel({ episode }: { episode: EpisodeView }) {
  const evaluation = useQuery({
    queryKey: ["trio-evaluation", episode.episodeId],
    queryFn: () => getTrioEvaluation(episode.episodeId),
    retry: false,
    refetchInterval: (query) =>
      query.state.data === null && (episode.status === "queued" || episode.status === "running")
        ? 1000
        : false,
  })
  const value = evaluation.data
  return <main className="workspace-main evaluation-view">
    <p className="section-title">Authority-derived trio evaluation</p>
    <h2>{episode.taskLabel}</h2>
    <p>Sol, Luna, and Terra each occupy every participant seat and spawn once across three sealed legs.</p>
    {value ? <>
      <section className="evaluation-grid" aria-label="Trio evaluation summary">
        {Object.entries(value.entrants).map(([entrantId, entrant]) => <article key={entrantId}>
          <span>{entrant.displayName}</span>
          <strong>{entrant.objectivePoints} points</strong>
          <small>{entrant.reliability.fallbackWindows} fallbacks · {entrant.reliability.stoppedCallsAfterElimination} calls stopped after elimination</small>
        </article>)}
      </section>
      <dl className="evaluation-details">
        <dt>Cyclic fairness</dt><dd>{value.eachEntrantUsesEachSeatOnce ? "Every entrant used every seat once" : "Unavailable"}</dd>
        <dt>Task</dt><dd>{value.taskId}</dd>
        <dt>Plan integrity</dt><dd className="code-block">{value.planSha256}</dd>
        {value.legs.map((leg) => <div key={leg.legIndex} className="series-leg-evaluation"><dt>Leg {leg.legIndex + 1}</dt><dd>{leg.terminalReason} · {leg.placements.map((group) => `#${group.placement} ${group.entrantIds.join("/")}`).join(" · ")}</dd></div>)}
      </dl>
    </> : evaluation.isError ? <section className="saved-replay-state unavailable" role="alert"><LockKeyholeIcon /><div><h3>Trio evaluation unavailable</h3><p>No protected evidence was requested or exposed.</p></div></section>
      : <section className="saved-replay-state" aria-live="polite"><LoaderCircleIcon className="frame-spinner" /><div><h3>Waiting for three sealed legs…</h3><p>Evaluation appears only after cyclic replay verification completes.</p></div></section>}
    <div className="protected-note"><ShieldCheckIcon /> No observations, frames, prompts, raw model output, credentials, hidden state, or spectator data are included.</div>
  </main>
}

function SoloEvaluationView({ episode }: { episode?: EpisodeView }) {
  const [selectedReplayId, setSelectedReplayId] = useState<string | null>(null)
  const savedReplays = useQuery({
    queryKey: ["saved-replays", "evaluation"],
    queryFn: getSavedReplays,
    retry: false,
  })
  const selectedReplay = savedReplays.data?.find((item) => item.replayId === selectedReplayId)
  const current = useQuery({
    queryKey: ["episode-evaluation", episode?.episodeId],
    queryFn: () => getEpisodeEvaluation(episode!.episodeId),
    enabled: episode?.kind === "episode" && selectedReplayId === null,
    retry: false,
    refetchInterval: (query) => query.state.data === null ? 1000 : false,
  })
  const saved = useQuery({
    queryKey: ["saved-evaluation", selectedReplayId],
    queryFn: () => getSavedReplayEvaluation(selectedReplayId!),
    enabled: selectedReplayId !== null,
    retry: false,
  })
  const projection = selectedReplayId === null ? current.data : saved.data
  const pending = selectedReplayId === null ? current.isPending : saved.isPending
  const failed = selectedReplayId === null ? current.isError : saved.isError

  return <main className="workspace-main evaluation-view">
    <p className="section-title">Authority-derived evaluation</p>
    <h2>{selectedReplay?.label ?? episode?.taskLabel ?? "Select a completed run"}</h2>
    <p>Metrics come only from sealed public receipts, events, terminal state, and replay hashes.</p>
    {projection ? <>
      <section className="evaluation-grid" aria-label="Evaluation summary">
        <article><span>Result</span><strong>{projection.result.outcome}</strong><small>Task success · {metricText(projection.metrics.task_success)}</small></article>
        <article><span>Behavior</span><strong>{metricText(projection.metrics.completion_tick)} ticks</strong><small>Valid actions · {metricText(projection.metrics.valid_action_rate)}</small></article>
        <article><span>Replay integrity</span><strong>{metricText(projection.metrics.deterministic_replay_verification)}</strong><small className="code-block">{projection.projectionSha256}</small></article>
      </section>
      <dl className="evaluation-details">
        <dt>Scenario</dt><dd>{projection.run.scenarioId ?? projection.run.taskId}</dd>
        <dt>Evaluation profile</dt><dd>{projection.run.evaluationProfileId ?? "authority-default"}</dd>
        <dt>Collision windows</dt><dd>{metricText(projection.metrics.unnecessary_collisions)}</dd>
        <dt>Alignment failures</dt><dd>{metricText(projection.metrics.interaction_alignment_failures)}</dd>
        <dt>Certification</dt><dd>{projection.run.certificationEligible ? "Eligible" : "Demonstration only"}</dd>
      </dl>
    </> : failed ? <section className="saved-replay-state unavailable" role="alert"><LockKeyholeIcon /><div><h3>Evaluation unavailable</h3><p>The safe evaluation projection could not be loaded. No protected evidence was requested.</p></div></section>
      : <section className="saved-replay-state" aria-live="polite"><LoaderCircleIcon className="frame-spinner" /><div><h3>{pending ? "Loading evaluation…" : "Waiting for sealed evaluation…"}</h3><p>Evaluation becomes available only after authority evidence seals.</p></div></section>}
    {savedReplays.data?.length ? <section className="saved-replay-library" aria-label="Saved evaluation library"><p className="section-title">Saved evaluations</p><div className="saved-replay-list">
      {episode ? <button type="button" className="saved-replay-option" aria-pressed={selectedReplayId === null} onClick={() => setSelectedReplayId(null)}><span>Current run</span><small>{episode.taskLabel}</small></button> : null}
      {savedReplays.data.map((replay) => <button key={replay.replayId} type="button" className="saved-replay-option" aria-pressed={selectedReplayId === replay.replayId} onClick={() => setSelectedReplayId(replay.replayId)}><span>{replay.label}</span><small>{replay.evaluationProfileId}</small></button>)}
    </div></section> : null}
    <div className="protected-note"><ShieldCheckIcon /> No observations, frames, prompts, raw model output, credentials, hidden state, or spectator data are included.</div>
  </main>
}

function EvaluationView({ episode }: { episode?: EpisodeView }) {
  return episode?.kind === "trio"
    ? <TrioEvaluationPanel episode={episode} />
    : episode?.kind === "series"
    ? <SeriesEvaluationPanel episode={episode} />
    : <SoloEvaluationView episode={episode} />
}

const REPLAY_SPEEDS = [1, 4, 8] as const

export function ReplaySpeedControls({
  videoRef,
}: {
  videoRef: RefObject<HTMLVideoElement | null>
}) {
  const [speed, setSpeed] = useState<number>(1)
  const selectSpeed = (next: number) => {
    if (videoRef.current) videoRef.current.playbackRate = next
    setSpeed(next)
  }
  return <div className="participant-selector" role="group" aria-label="Replay playback speed">
    <span className="section-title">Playback</span>
    {REPLAY_SPEEDS.map((value) => <Button key={value} size="sm" variant={speed === value ? "default" : "outline"} onClick={() => selectSpeed(value)}>{value}×</Button>)}
  </div>
}

function ReplayPlayer({ replay }: { replay: SavedReplaySummary }) {
  const videoRef = useRef<HTMLVideoElement>(null)
  const [playbackState, setPlaybackState] = useState<"loading" | "ready" | "error">(
    "loading"
  )

  return (
    <section className="saved-replay-player" aria-label="Saved native replay">
      <div className="saved-replay-heading">
        <div>
          <p className="section-title">Saved native replay</p>
          <h3>{replay.label}</h3>
        </div>
        <span>{replay.outcome}</span>
      </div>
      <video
        ref={videoRef}
        className="saved-replay-video"
        aria-label="Saved replay video"
        controls
        playsInline
        preload="metadata"
        onLoadedMetadata={() => setPlaybackState("ready")}
        onError={() => setPlaybackState("error")}
      >
        <source src={savedReplayVideoUrl(replay.replayId)} type={replay.video.mimeType} />
        Your browser cannot play this saved replay video.
      </video>
      <ReplaySpeedControls videoRef={videoRef} />
      {playbackState === "loading" ? (
        <p className="saved-replay-status" aria-live="polite">
          Loading native replay…
        </p>
      ) : playbackState === "error" ? (
        <p className="saved-replay-status" role="alert">
          Native replay could not be loaded. Choose the replay again or refresh the local dashboard.
        </p>
      ) : null}
      <dl className="saved-replay-meta">
        <div><dt>Authority ticks</dt><dd>{replay.authorityTicks}</dd></div>
        <div><dt>Native playback</dt><dd>{replay.video.width}×{replay.video.height} · {replay.video.fps} FPS</dd></div>
        <div><dt>Scenario</dt><dd>{replay.scenarioId}</dd></div>
        <div><dt>Evaluation</dt><dd>{replay.evaluationProfileId}</dd></div>
      </dl>
      <p className="saved-replay-privacy"><ShieldCheckIcon /> Participant-visible pixels only. This video contains no prompts, model output, credentials, hidden state, or spectator view.</p>
    </section>
  )
}

function SavedReplayLibrary({
  replays,
  selectedReplayId,
  onSelect,
}: {
  replays: SavedReplaySummary[]
  selectedReplayId: string | null
  onSelect: (replayId: string) => void
}) {
  return (
    <section className="saved-replay-library" aria-label="Saved replay library">
      <p className="section-title">Saved replay library</p>
      <h3>Rewatch a completed run</h3>
      <div className="saved-replay-list">
        {replays.map((replay) => (
          <button
            key={replay.replayId}
            type="button"
            className="saved-replay-option"
            aria-pressed={selectedReplayId === replay.replayId}
            onClick={() => onSelect(replay.replayId)}
          >
            <span>{replay.label}</span>
            <small>{replay.outcome} · {replay.authorityTicks} ticks · {replay.scenarioId}</small>
          </button>
        ))}
      </div>
    </section>
  )
}

function SoloReplayView({ episode }: { episode?: EpisodeView }) {
  const [selectedReplayId, setSelectedReplayId] = useState<string | null>(null)
  const sealedEpisode =
    episode?.kind === "episode" &&
    (episode.status === "success" || episode.status === "failure")
  const savedReplay = useQuery({
    queryKey: ["saved-replay", episode?.episodeId],
    queryFn: () => getSavedReplay(episode!.episodeId),
    enabled: sealedEpisode,
    retry: false,
    // Native Movie Maker + FFmpeg export happens after deterministic sealing.  Poll only while
    // the archive has not appeared, then stop immediately once the safe public manifest exists.
    refetchInterval: (query) =>
      sealedEpisode &&
      (episode?.replay?.state === "saving" || query.state.data === null)
        ? 1000
        : false,
  })
  const savedReplays = useQuery({
    queryKey: ["saved-replays"],
    queryFn: getSavedReplays,
    retry: false,
  })
  const selectedArchive = savedReplays.data?.find((replay) => replay.replayId === selectedReplayId)
  const replay = selectedArchive ?? savedReplay.data ?? (!episode ? savedReplays.data?.[0] : undefined)
  const replaySaving =
    sealedEpisode &&
    !savedReplay.data &&
    (episode?.replay?.state === "saving" || savedReplay.isPending)
  const replayUnavailable = sealedEpisode && !savedReplay.data && !replaySaving

  return (
    <main className="workspace-main replay-view">
      <p className="section-title">Replay evidence</p>
      <h2>Public, content-addressed episode bundle</h2>
      <p>
        The browser receives public receipts, events, checkpoints, terminal
        evaluation, and the replay summary. Protected observations, frames,
        prompts, outputs, and telemetry stay local to certification code.
      </p>
      {replay?.video.available ? (
        <ReplayPlayer key={replay.replayId} replay={replay} />
      ) : replaySaving ? (
        <section className="saved-replay-state" aria-live="polite">
          <LoaderCircleIcon className="frame-spinner" />
          <div>
            <h3>Saving native replay…</h3>
            <p>
              Godot is preparing the participant-visible video. You can keep
              this tab open; it will appear here when the archive is ready.
            </p>
          </div>
        </section>
      ) : replayUnavailable ? (
        <section className="saved-replay-state unavailable" aria-live="polite">
          <LockKeyholeIcon />
          <div>
            <h3>Native replay unavailable</h3>
            <p>
              This sealed run has no saved participant-visible video. Its public
              evidence bundle remains available below.
            </p>
          </div>
        </section>
      ) : episode?.kind === "episode" ? (
        <section className="saved-replay-state">
          <LoaderCircleIcon className="frame-spinner" />
          <div>
            <h3>Replay saves after sealing</h3>
            <p>
              Finish the current episode to create its participant-visible
              native replay.
            </p>
          </div>
        </section>
      ) : savedReplays.isPending ? (
        <section className="saved-replay-state" aria-live="polite">
          <LoaderCircleIcon className="frame-spinner" />
          <div>
            <h3>Loading saved replays…</h3>
            <p>Only completed participant-visible videos are listed here.</p>
          </div>
        </section>
      ) : savedReplays.isError ? (
        <section className="saved-replay-state unavailable" aria-live="polite">
          <LockKeyholeIcon />
          <div>
            <h3>Saved replay library unavailable</h3>
            <p>The local archive could not be read. No protected replay data was sent to the browser.</p>
          </div>
        </section>
      ) : (
        <section className="saved-replay-state">
          <LockKeyholeIcon />
          <div>
            <h3>No saved replays yet</h3>
            <p>Complete a scripted demo to add its participant-visible video here.</p>
          </div>
        </section>
      )}
      {savedReplays.data && savedReplays.data.length > 0 ? (
        <SavedReplayLibrary
          replays={savedReplays.data}
          selectedReplayId={selectedReplayId ?? replay?.replayId ?? null}
          onSelect={setSelectedReplayId}
        />
      ) : null}
      {episode?.kind === "episode" &&
      (episode.status === "success" || episode.status === "failure") ? (
        <a
          className={cn(buttonVariants({ variant: "outline" }))}
          href={bundleUrl(episode.episodeId)}
        >
          <DownloadIcon data-icon="inline-start" />
          Download public bundle
        </a>
      ) : (
        <Button variant="outline" disabled>
          {episode?.kind === "series"
            ? "Leg hashes are included in the verified result"
            : "Bundle available after sealing"}
        </Button>
      )}
      <div className="protected-note">
        <LockKeyholeIcon /> Offline genesis verification uses the protected
        local bundle and pinned Godot runtime.
      </div>
    </main>
  )
}

function SeriesReplayView({ episode }: { episode: EpisodeView }) {
  const archive = episode.seriesArchive
  const [selectedNative, setSelectedNative] = useState("0:participant_0")
  const sealed = episode.status === "success" || episode.status === "failure"
  const evidenceReady = archive?.evidenceState === "ready"
  const archiveSaving = archive?.evidenceState === "saving" || archive?.nativeReplayState === "saving"
  const trio = episode.kind === "trio"
  return <main className="workspace-main replay-view">
    <p className="section-title">{trio ? "Trio replay evidence" : "Paired replay evidence"}</p>
    <h2>{trio ? "Three-leg cyclic public archive" : "Two-leg public archive"}</h2>
    <p>The durable archive contains only sealed public leg receipts, events, evaluations, and hashes.</p>
    <section className={`saved-replay-state ${archive?.nativeReplayState === "unavailable" ? "unavailable" : ""}`} aria-live="polite">
      {evidenceReady ? <ShieldCheckIcon /> : <LoaderCircleIcon className="frame-spinner" />}
      <div>
        <h3>{evidenceReady ? "Verified series evidence saved" : archiveSaving ? "Saving native replay…" : sealed ? "Series archive unavailable" : "Replay saves after both legs seal"}</h3>
        <p>{evidenceReady ? "The content-addressed public pair remains available after the backend restarts." : archiveSaving ? "Gameplay has finished. Verified participant-visible replay files are preparing." : "No sealed public pair is currently available."}</p>
      </div>
    </section>
    {archive?.nativeReplayState === "ready" ? <SeriesNativeReplayPlayer
      seriesId={episode.episodeId}
      artifacts={archive.nativeArtifacts}
      selected={selectedNative}
      onSelect={setSelectedNative}
    /> : archiveSaving ? <section className="saved-replay-state" aria-live="polite">
        <LoaderCircleIcon className="frame-spinner" />
        <div><h3>Replay preparing</h3><p>The finished match remains available in Results and Evaluation while participant-visible native video is rendered.</p></div>
      </section> : <section className="saved-replay-state unavailable">
        <LockKeyholeIcon />
        <div><h3>Native replay unavailable</h3><p>No verified participant-visible {trio ? "trio" : "duel"} video was recorded. The dashboard does not substitute spectator pixels or claim playback is ready.</p></div>
      </section>}
    {sealed && evidenceReady ? <a className={cn(buttonVariants({ variant: "outline" }))} href={bundleUrl(episode.episodeId)}><DownloadIcon data-icon="inline-start" />Download public {trio ? "three-leg" : "two-leg"} bundle</a> : <Button variant="outline" disabled>Bundle available after sealing</Button>}
    <div className="protected-note"><ShieldCheckIcon /> Protected observations, camera frames, prompts, outputs, credentials, and spectator state remain local.</div>
  </main>
}

function SeriesNativeReplayPlayer({
  seriesId,
  artifacts,
  selected,
  onSelect,
}: {
  seriesId: string
  artifacts: SeriesNativeReplayArtifact[]
  selected: string
  onSelect: (identity: string) => void
}) {
  const videoRef = useRef<HTMLVideoElement>(null)
  const artifact = artifacts.find((value) => `${value.legIndex}:${value.participantId}` === selected) ?? artifacts[0]
  if (!artifact) return null
  const identity = `${artifact.legIndex}:${artifact.participantId}`
  return <section className="saved-replay-player" aria-label="Series native replay controls">
    <div className="saved-replay-heading"><div><p className="section-title">Participant-view playback</p><h3>Leg {artifact.legIndex + 1} · {artifact.participantId}</h3></div><span>verified</span></div>
    <div className="participant-selector" role="group" aria-label="Replay leg and participant">
      {artifacts.map((value) => {
        const valueIdentity = `${value.legIndex}:${value.participantId}`
        return <Button key={valueIdentity} size="sm" variant={valueIdentity === identity ? "default" : "outline"} onClick={() => onSelect(valueIdentity)}>Leg {value.legIndex + 1} · P{value.participantId.replace("participant_", "")}</Button>
      })}
    </div>
    <video ref={videoRef} key={identity} className="saved-replay-video" aria-label="Participant native replay" controls playsInline preload="metadata">
      <source src={seriesParticipantVideoUrl(seriesId, artifact.legIndex, artifact.participantId)} type="video/mp4" />
      Your browser cannot play this participant replay.
    </video>
    <ReplaySpeedControls videoRef={videoRef} />
    <p className="saved-replay-privacy"><ShieldCheckIcon /> Participant-visible pixels only. Each leg and seat is isolated; no spectator view is rendered.</p>
  </section>
}

function ReplayView({ episode }: { episode?: EpisodeView }) {
  return episode?.kind === "series" || episode?.kind === "trio"
    ? <SeriesReplayView episode={episode} />
    : <SoloReplayView episode={episode} />
}

export function EpisodeWorkspace({
  episode,
  controllerMode,
  mode,
  view,
  selected,
  onSelect,
  cancelling,
  onCancel,
}: Props) {
  const [duelParticipant, setDuelParticipant] = useState<ParticipantId>("participant_0")

  if (view === "replay") return <ReplayView episode={episode} />
  if (view === "evaluation") return <EvaluationView episode={episode} />
  if (!episode) {
    return (
      <div className="empty-workspace">
        <h2>
          {mode === "trio"
            ? "Configure a three-agent cyclic series"
            : mode === "duel"
            ? "Configure a symmetric two-leg series"
            : "Configure a hybrid solo episode"}
        </h2>
        <p>
          {mode === "trio"
            ? "Sol, Luna, and Terra run as keyless Demo policies through three cyclic participant-isolated legs."
            : mode === "duel"
            ? "Live provider keys are sent once to backend memory, reset between legs, and never stored in browser storage. Scripted opponents require no key."
            : controllerMode === "scripted_demo"
              ? "Start the selected deterministic, credential-free solo scenario. It runs in Godot without a model call."
              : "Your provider key is sent once to backend memory and is never stored in browser storage."}
        </p>
      </div>
    )
  }
  if (view === "timeline") {
    return (
      <div className="workspace-wide">
        <DecisionTimeline
          rows={episode.timeline}
          selected={selected}
          onSelect={onSelect}
        />
      </div>
    )
  }
  if (view === "result") return <ResultView episode={episode} />
  return (
    <RunView
      episode={episode}
      cancelling={cancelling}
      onCancel={onCancel}
      duelParticipant={duelParticipant}
      onDuelParticipantChange={setDuelParticipant}
    />
  )
}
