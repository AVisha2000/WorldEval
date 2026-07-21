import { ArrowUpRight, Check } from "lucide-react"
import { getControllerLabUrl, REPOSITORY_URL } from "./site-data"

const ROADMAP = [
  {
    status: "Shipped",
    detail: "Observe · Act · Record · Replay",
    state: "complete",
  },
  {
    status: "Live now",
    detail: "Labyrinth · Mini RTS · Crossroads",
    state: "complete",
  },
  {
    status: "Next",
    detail: "More games · More worlds · New agent teams",
    state: "current",
  },
  {
    status: "Future",
    detail: "A portable evaluation layer for any interactive environment",
    state: "future",
  },
] as const

function RoadmapMarker({
  index,
  state,
}: {
  index: number
  state: (typeof ROADMAP)[number]["state"]
}) {
  return (
    <span className="roadmap-marker" aria-hidden="true">
      {state === "complete" ? <Check /> : index + 1}
    </span>
  )
}

export function EvidenceTrail() {
  const controllerLabUrl = getControllerLabUrl()

  return (
    <>
      <section
        className="roadmap-section section-frame"
        id="evidence"
        aria-labelledby="roadmap-heading"
      >
        <div className="roadmap-heading">
          <div>
            <p className="section-index">05 / Roadmap</p>
            <h2 id="roadmap-heading">
              From one game to any interactive world.
            </h2>
          </div>
          <p>
            The evaluation loop stays stable while new games, agents, and
            evidence adapters plug in.
          </p>
        </div>
        <ol className="roadmap-rail">
          {ROADMAP.map((step, index) => (
            <li
              className={`roadmap-step roadmap-step--${step.state}`}
              key={step.status}
            >
              <RoadmapMarker index={index} state={step.state} />
              <span className="roadmap-status">{step.status}</span>
              <strong>{step.detail}</strong>
            </li>
          ))}
        </ol>
      </section>

      <section
        className="lab-cta section-frame"
        aria-labelledby="lab-cta-heading"
      >
        <div>
          <h2 id="lab-cta-heading">Put an agent in the world.</h2>
          <p>
            Open the Controller Lab to run a game and inspect what the agent
            actually did.
          </p>
        </div>
        <div className="lab-cta__actions">
          <a
            className="button button--primary"
            href={controllerLabUrl}
            rel="noreferrer"
            target="_blank"
          >
            Open the Controller Lab <ArrowUpRight aria-hidden="true" />
          </a>
          <a
            className="lab-cta__secondary"
            href={REPOSITORY_URL}
            rel="noreferrer"
            target="_blank"
          >
            View the repository <ArrowUpRight aria-hidden="true" />
          </a>
        </div>
      </section>
    </>
  )
}
