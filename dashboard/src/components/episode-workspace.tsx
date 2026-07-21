import { DownloadIcon, LockKeyholeIcon, ShieldCheckIcon, SquareIcon } from "lucide-react"
import type { EpisodeView, TimelineRow } from "@/api"
import { bundleUrl } from "@/api"
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
import { ParticipantFrame } from "@/components/participant-frame"
import { useParticipantFrame } from "@/hooks/use-participant-frame"

type Props = {
  episode?: EpisodeView
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
    return <section className="timeline-panel empty-panel">Decision receipts appear here as soon as sealed evidence is available.</section>
  }
  return (
    <section className="timeline-panel">
      <h2 className="section-title">Decision timeline</h2>
      <Table>
        <TableHeader><TableRow>
          <TableHead>Window</TableHead><TableHead>Action</TableHead><TableHead>Receipt</TableHead>
          <TableHead>Ticks</TableHead><TableHead>Latency</TableHead>
        </TableRow></TableHeader>
        <TableBody>{rows.map((row) => (
          <TableRow
            key={row.window}
            data-state={row.window === selected ? "selected" : undefined}
            onClick={() => onSelect(row.window)}
            tabIndex={0}
            onKeyDown={(event) => event.key === "Enter" && onSelect(row.window)}
          >
            <TableCell className="font-mono">{row.window}</TableCell>
            <TableCell>{row.intent}</TableCell>
            <TableCell>{row.receipt}</TableCell>
            <TableCell className="font-mono">{row.ticks}</TableCell>
            <TableCell className="font-mono">{row.latencyMs === null ? "protected" : `${row.latencyMs} ms`}</TableCell>
          </TableRow>
        ))}</TableBody>
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
  const observationSeq = episode.kind === "episode"
    ? frame.data?.observationSeq ?? episode.observationSeq
    : episode.observationSeq
  return (
    <main className="workspace-main">
      <div className="status-strip">
        <Badge variant="outline" className="status-running">● {episode.status}</Badge>
        <span>Observation <b>{observationSeq}</b></span>
        <span>Tick <b>{episode.tick}</b></span>
        <strong>{episode.taskLabel}</strong>
        {episode.status === "queued" || episode.status === "running" ? (
          <Button variant="outline" size="sm" disabled={cancelling} onClick={onCancel}>
            <SquareIcon data-icon="inline-start" />{cancelling ? "Cancelling…" : "Cancel run"}
          </Button>
        ) : null}
      </div>
      {episode.kind === "episode" ? <ParticipantFrame episode={episode} frame={frame} /> : (
        <section className="arena-viewport protected-frame" aria-label="Participant frame policy">
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
  if (!episode.result) return <div className="empty-workspace">Result becomes available after the episode seals.</div>
  return (
    <main className="workspace-main result-view">
      <p className="section-title">Verified result</p>
      <h2>{episode.result.outcome}</h2>
      <dl>
        <dt>Decision windows</dt><dd>{episode.result.windows}</dd>
        <dt>Provider fallbacks</dt><dd>{episode.result.providerFailures}</dd>
        <dt>Final authority hash</dt><dd className="code-block">{episode.result.finalStateHash}</dd>
      </dl>
    </main>
  )
}

function ReplayView({ episode }: { episode: EpisodeView }) {
  return (
    <main className="workspace-main replay-view">
      <p className="section-title">Replay evidence</p>
      <h2>Public, content-addressed episode bundle</h2>
      <p>The browser receives public receipts, events, checkpoints, terminal evaluation, and the replay summary. Protected observations, frames, prompts, outputs, and telemetry stay local to certification code.</p>
      {episode.kind === "episode" && (episode.status === "success" || episode.status === "failure") ? (
        <a className={cn(buttonVariants({ variant: "outline" }))} href={bundleUrl(episode.episodeId)}>
          <DownloadIcon data-icon="inline-start" />Download public bundle
        </a>
      ) : <Button variant="outline" disabled>{episode.kind === "series" ? "Leg hashes are included in the verified result" : "Bundle available after sealing"}</Button>}
      <div className="protected-note"><LockKeyholeIcon /> Offline genesis verification uses the protected local bundle and pinned Godot runtime.</div>
    </main>
  )
}

export function EpisodeWorkspace({ episode, mode, view, selected, onSelect, cancelling, onCancel }: Props) {
  if (!episode) {
    return <div className="empty-workspace">
      <h2>{mode === "duel" ? "Configure a symmetric two-leg series" : "Configure a hybrid solo episode"}</h2>
      <p>{mode === "duel"
        ? "Live provider keys are sent once to backend memory, reset between legs, and never stored in browser storage. Scripted opponents require no key."
        : "Your provider key is sent once to backend memory and is never stored in browser storage."}</p>
    </div>
  }
  if (view === "timeline") {
    return <div className="workspace-wide"><DecisionTimeline rows={episode.timeline} selected={selected} onSelect={onSelect} /></div>
  }
  if (view === "result") return <ResultView episode={episode} />
  if (view === "replay") return <ReplayView episode={episode} />
  return <RunView episode={episode} cancelling={cancelling} onCancel={onCancel} />
}
