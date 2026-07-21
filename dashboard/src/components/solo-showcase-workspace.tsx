import { useRef } from "react"
import { cachedSoloVideoUrl, type CachedSoloShowcaseView } from "@/api"
import { ReplaySpeedControls } from "@/components/episode-workspace"

type Props = {
  showcase?: CachedSoloShowcaseView
  showcaseError: boolean
  view: string
}

export function SoloShowcaseWorkspace({ showcase, showcaseError, view }: Props) {
  const videoRef = useRef<HTMLVideoElement>(null)
  const verification = showcase?.verification
  return (
    <section
      className="episode-workspace rts-showcase"
      aria-label="Cached solo multi-action showcase"
    >
      <div className="episode-workspace-header">
        <div>
          <p className="eyebrow">Core solo highlight · cached native participant view</p>
          <h2>{showcase?.label ?? "Solo Multi-Action Construction"}</h2>
          <p>
            {showcase?.tagline ??
              "Turn, walk, gather, carry, deposit, build, and celebrate in one sealed run."}
          </p>
        </div>
        <span className="status-badge success">verified</span>
      </div>

      {showcaseError ? (
        <p role="alert" className="error-banner">
          The checked-in solo highlight is unavailable or failed evidence verification.
        </p>
      ) : null}

      {view === "run" ? (
        <>
          <video
            ref={videoRef}
            className="rts-showcase-video"
            controls
            autoPlay
            muted
            playsInline
            src={cachedSoloVideoUrl()}
          >
            Your browser cannot play the saved solo construction video.
          </video>
          <ReplaySpeedControls videoRef={videoRef} />
          <p className="muted-copy">
            {showcase
              ? `${showcase.video.durationSeconds.toFixed(1)}-second native participant capture · ${showcase.video.width}×${showcase.video.height} · ${showcase.video.fps} FPS`
              : "Loading evidence-bound video metadata…"}
          </p>
        </>
      ) : null}

      {view === "timeline" ? (
        <div className="rts-showcase-panel" aria-label="Solo construction timeline">
          <h3>Visible action sequence</h3>
          <p>Every milestone is resolved by the Godot authority before the next one begins.</p>
          {showcase?.highlights.map((highlight) => (
            <div className="rts-showcase-row" key={highlight.atSeconds}>
              <time>{formatTime(highlight.atSeconds)}</time>
              <span>{highlight.label}</span>
            </div>
          )) ?? <p className="muted-copy">Loading safe action milestones…</p>}
        </div>
      ) : null}

      {view === "result" ? (
        <div className="rts-showcase-panel" aria-label="Solo construction result">
          <h3>Construction completed</h3>
          <p>
            The participant completed the full visible prerequisite chain in{
              verification ? ` ${verification.authorityTicks} authority ticks` : " the sealed run"
            }.
          </p>
          <div className="rts-showcase-metric">
            <strong>Controller</strong>
            <span>{showcase?.participant.model ?? "construction-demo-v1"}</span>
          </div>
        </div>
      ) : null}

      {view === "evaluation" ? (
        <div className="rts-showcase-panel" aria-label="Solo construction evaluation">
          <h3>Evidence-backed capability path</h3>
          <p>
            The recording shows orientation, navigation, gathering, carrying, depositing,
            construction, and terminal celebration through one participant-visible run.
          </p>
          <div className="rts-showcase-metric">
            <strong>Release profile</strong>
            <span>{verification?.releaseProfile ?? "worldarena-participant-1080p30-v1"}</span>
          </div>
          <div className="rts-showcase-metric">
            <strong>Renderer</strong>
            <span>{verification?.renderer ?? "godot-movie-maker+ffmpeg"}</span>
          </div>
        </div>
      ) : null}

      {view === "replay" ? (
        <div className="rts-showcase-panel" aria-label="Solo construction replay verification">
          <h3>Immutable native-video identity</h3>
          <p>The host validates the checked-in evidence and MP4 hash before the Lab starts.</p>
          <div className="rts-showcase-metric">
            <strong>Evidence</strong>
            <span className="code-block">{verification?.evidenceSha256 ?? "Loading…"}</span>
          </div>
          <div className="rts-showcase-metric">
            <strong>Replay</strong>
            <span className="code-block">{verification?.replaySha256 ?? "Loading…"}</span>
          </div>
          <div className="rts-showcase-metric">
            <strong>Final state</strong>
            <span className="code-block">{verification?.finalStateSha256 ?? "Loading…"}</span>
          </div>
        </div>
      ) : null}
    </section>
  )
}

function formatTime(seconds: number): string {
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`
}
