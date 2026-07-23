import { ArrowUpRight, Check, Ellipsis } from "lucide-react"
import { getControllerLabUrl, REPOSITORY_URL } from "./site-data"

const ROADMAP = [
  {
    category: "Core evaluation loop",
    title: "Observe · Act · Record · Replay",
    status: "Implemented",
    state: "complete",
  },
  {
    category: "Game adapters",
    title: "Labyrinth · Mini RTS · Crossroads",
    status: "Implemented",
    state: "complete",
  },
  {
    category: "Generative creation",
    title: "Prompt to 3D game world",
    description:
      "Turn an idea into a playable world ready for agent evaluation.",
    status: "Next",
    state: "current",
  },
  {
    category: "Expansion",
    title: "More games · More worlds · New agent teams",
    status: "Future",
    state: "future",
  },
  {
    category: "Portable layer",
    title: "Evaluation for any interactive environment",
    status: "Future",
    state: "future",
  },
] as const

function RoadmapStatus({ step }: { step: (typeof ROADMAP)[number] }) {
  return (
    <span className={`roadmap-badge roadmap-badge--${step.state}`}>
      {step.status}
      {step.state === "complete" ? <Check aria-hidden="true" /> : null}
      {step.state === "current" ? <Ellipsis aria-hidden="true" /> : null}
      {step.state === "future" ? (
        <span className="roadmap-badge__dot" aria-hidden="true" />
      ) : null}
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
            A growing list of shipped systems and next milestones—each with a
            clear status.
          </p>
        </div>
        <ol className="roadmap-list">
          {ROADMAP.map((step, index) => (
            <li
              className={`roadmap-item roadmap-item--${step.state}`}
              key={step.title}
            >
              <span className="roadmap-item__number" aria-hidden="true">
                {String(index + 1).padStart(2, "0")}
              </span>
              <div className="roadmap-item__copy">
                <span>{step.category}</span>
                <strong>{step.title}</strong>
                {"description" in step ? <p>{step.description}</p> : null}
              </div>
              <RoadmapStatus step={step} />
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
