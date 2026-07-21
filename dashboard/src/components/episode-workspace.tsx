import {
  DownloadIcon,
  LoaderCircleIcon,
  LockKeyholeIcon,
  ShieldCheckIcon,
  SquareIcon,
} from "lucide-react"
import { useQuery } from "@tanstack/react-query"
import { useState } from "react"
import type { ControllerMode, EpisodeView, SavedReplaySummary, TimelineRow } from "@/api"
import { bundleUrl, getSavedReplay, getSavedReplays, savedReplayVideoUrl } from "@/api"
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

type Props = {
  episode?: EpisodeView
  controllerMode: ControllerMode
  mode: "solo" | "duel"
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
}: {
  episode: EpisodeView
  cancelling: boolean
  onCancel: () => void
}) {
  const frame = useParticipantFrame(episode)
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
      {episode.kind === "episode" ? (
        <ParticipantFrame episode={episode} frame={frame} />
      ) : (
        <section
          className="arena-viewport protected-frame"
          aria-label="Participant frame policy"
        >
          <ShieldCheckIcon />
          <h2>Paired participant streams protected</h2>
          <p>Each model receives only its own player-visible camera frame.</p>
          <span>Two-leg series views remain isolated by participant</span>
        </section>
      )}
    </main>
  )
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
    </main>
  )
}

function ReplayPlayer({ replay }: { replay: SavedReplaySummary }) {
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
            <small>{replay.outcome} · {replay.authorityTicks} ticks</small>
          </button>
        ))}
      </div>
    </section>
  )
}

function ReplayView({ episode }: { episode?: EpisodeView }) {
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
  if (view === "replay") return <ReplayView episode={episode} />
  if (!episode) {
    return (
      <div className="empty-workspace">
        <h2>
          {mode === "duel"
            ? "Configure a symmetric two-leg series"
            : "Configure a hybrid solo episode"}
        </h2>
        <p>
          {mode === "duel"
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
    <RunView episode={episode} cancelling={cancelling} onCancel={onCancel} />
  )
}
