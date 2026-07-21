import type { CSSProperties } from "react"
import type {
  CachedCrossroadsEvaluationView,
  CachedCrossroadsShowcaseView,
  CrossroadsFactionId,
} from "@/api"
import { cachedCrossroadsVideoUrl } from "@/api"

type Props = {
  evaluation?: CachedCrossroadsEvaluationView
  evaluationError: boolean
  showcase?: CachedCrossroadsShowcaseView
  showcaseError: boolean
  view: string
}

const FACTION_COLORS: Record<CrossroadsFactionId, string> = {
  sol: "#fbbf24",
  luna: "#a78bfa",
  terra: "#34d399",
}

function formatTime(seconds: number): string {
  return `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, "0")}`
}

function displayFaction(value: CrossroadsFactionId): string {
  return value[0].toUpperCase() + value.slice(1)
}

function factionForBeat(beatId: string): CrossroadsFactionId | null {
  if (beatId.includes("sol")) return "sol"
  if (beatId.includes("terra")) return "terra"
  if (beatId.includes("luna")) return "luna"
  return null
}

export function CrossroadsWorkspace({
  evaluation,
  evaluationError,
  showcase,
  showcaseError,
  view,
}: Props) {
  return (
    <section
      className="episode-workspace rts-showcase crossroads-showcase"
      aria-label="Cached Crossroads Conquest showcase"
    >
      <div className="episode-workspace-header crossroads-header">
        <div>
          <p className="eyebrow">Third featured highlight · sealed 180-second broadcast</p>
          <h2>{showcase?.title ?? "WorldArena: Crossroads Conquest"}</h2>
          <p>{showcase?.tagline ?? "Three strongholds. One crossroads. Last faction standing."}</p>
        </div>
        <span className="status-badge success">Verified replay</span>
      </div>

      <div className="crossroads-faction-chips" aria-label="Crossroads factions">
        {showcase?.entrants.map((entrant) => (
          <span
            key={entrant.entrantId}
            style={{ "--faction-color": entrant.color } as CSSProperties}
          >
            <b aria-hidden="true">{entrant.glyph}</b>
            <strong>{entrant.displayName}</strong>
            <small>#{showcase.placements.find((item) => item.factionId === entrant.factionId)?.placement}</small>
          </span>
        )) ?? <span className="muted-copy">Loading Sol, Luna, and Terra…</span>}
      </div>

      {showcaseError ? (
        <p role="alert" className="error-banner">
          The saved Crossroads Conquest package is unavailable or failed verification.
        </p>
      ) : null}

      {view === "run" ? (
        <>
          <video
            className="rts-showcase-video crossroads-video"
            controls
            autoPlay
            muted
            playsInline
            src={cachedCrossroadsVideoUrl()}
          >
            Your browser cannot play the saved Crossroads Conquest broadcast.
          </video>
          <p className="muted-copy">
            {showcase
              ? `${showcase.video.durationSeconds}-second authority-verified broadcast · ${showcase.video.width}×${showcase.video.height} · ${showcase.video.fps} FPS · seed ${showcase.authority.seed}`
              : "Loading verified video metadata…"}
          </p>
        </>
      ) : null}

      {view === "timeline" ? (
        <div className="rts-showcase-panel" aria-label="Crossroads Conquest timeline">
          <h3>Broadcast timeline</h3>
          <p>Editorial chapters are bound to authority events, not assumed round timing.</p>
          {showcase?.timeline.map((event) => {
            const factionId = factionForBeat(event.beatId)
            return <div className="rts-showcase-row" key={event.beatId}>
              <time>{formatTime(event.atSeconds)}</time>
              <span>
                {factionId ? (
                  <b style={{ color: FACTION_COLORS[factionId] }}>
                    {displayFaction(factionId)} · {" "}
                  </b>
                ) : null}
                {event.label}
              </span>
            </div>
          }) ?? <p className="muted-copy">Loading the public tactical story…</p>}
        </div>
      ) : null}

      {view === "result" ? (
        <div className="rts-showcase-panel crossroads-result" aria-label="Crossroads Conquest result">
          <p className="eyebrow">Last stronghold standing</p>
          <h3>Luna wins</h3>
          <p>Sol eliminated Terra · Luna eliminated Sol</p>
          <div className="crossroads-podium">
            {showcase?.placements.map((placement) => (
              <article
                key={placement.factionId}
                style={{ "--faction-color": FACTION_COLORS[placement.factionId] } as CSSProperties}
              >
                <span>#{placement.placement}</span>
                <strong>{placement.displayName}</strong>
              </article>
            )) ?? <p className="muted-copy">Loading the verified podium…</p>}
          </div>
          {showcase?.eliminationOrder.map((elimination) => (
            <div className="rts-showcase-row" key={elimination.eventId}>
              <time>Round {elimination.round}</time>
              <span>{displayFaction(elimination.eliminatedBy)} eliminated {displayFaction(elimination.factionId)}</span>
            </div>
          )) ?? null}
        </div>
      ) : null}

      {view === "evaluation" ? (
        <div className="rts-showcase-panel" aria-label="Crossroads Conquest evaluation">
          <h3>Authority-derived evaluation</h3>
          {evaluationError ? (
            <p role="alert" className="error-banner">The public Crossroads evaluation is unavailable.</p>
          ) : null}
          {evaluation ? (
            <>
              <div className="crossroads-verification-grid">
                <div><strong>{evaluation.verification.deterministicRuns}</strong><span>identical authority runs</span></div>
                <div><strong>{evaluation.verification.orderRejections}</strong><span>rejected orders</span></div>
                <div><strong>R{evaluation.verification.lunaFirstHostileRound}</strong><span>Luna’s first hostile order</span></div>
              </div>
              <div className="crossroads-faction-results">
                {evaluation.factions.toSorted((left, right) => left.placement - right.placement).map((faction) => (
                  <article
                    key={faction.factionId}
                    style={{ "--faction-color": FACTION_COLORS[faction.factionId] } as CSSProperties}
                  >
                    <header><span>#{faction.placement}</span><strong>{displayFaction(faction.factionId)}</strong></header>
                    <dl>
                      <div><dt>Final core HP</dt><dd>{faction.coreHp}</dd></div>
                      <div><dt>Eliminated</dt><dd>{faction.eliminatedRound === null ? "Survived" : `Round ${faction.eliminatedRound}`}</dd></div>
                      <div><dt>Strongholds destroyed</dt><dd>{faction.strongholdsDestroyed}</dd></div>
                    </dl>
                  </article>
                ))}
              </div>
            </>
          ) : <p className="muted-copy">Loading evaluation only for this tab…</p>}
        </div>
      ) : null}

      {view === "replay" ? (
        <div className="rts-showcase-panel" aria-label="Crossroads Conquest replay verification">
          <h3>Immutable replay identity</h3>
          <p>The replay stays server-side. The public result is bound to the policy, normalized trace, final state, evaluation, and broadcast hashes.</p>
          {evaluation?.verification.state === "verified" ? (
            <>
              <div className="rts-showcase-metric"><strong>Policy</strong><span>{showcase?.authority.policyId ?? "crossroads-conquest-demo-v1"}</span></div>
              <div className="rts-showcase-metric"><strong>Final state</strong><span className="code-block">{evaluation.verification.finalStateSha256}</span></div>
              <div className="rts-showcase-metric"><strong>Replay</strong><span className="code-block">{evaluation.verification.replaySha256}</span></div>
              <div className="rts-showcase-metric"><strong>Video</strong><span className="code-block">{evaluation.verification.videoSha256}</span></div>
            </>
          ) : <p className="muted-copy">Loading replay verification status…</p>}
        </div>
      ) : null}
    </section>
  )
}
