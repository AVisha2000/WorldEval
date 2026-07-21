import { motion, useReducedMotion } from "motion/react"

const EVENTS = [
  {
    index: "01",
    title: "Agent observed world state",
    detail: "A bounded, visibility-filtered observation enters the loop.",
  },
  {
    index: "02",
    title: "Action requested",
    detail: "The agent selects an action through the defined interface.",
  },
  {
    index: "03",
    title: "World event emitted",
    detail: "The deterministic world applies rules and records the event.",
  },
  {
    index: "04",
    title: "Outcome evaluated",
    detail: "Versioned criteria connect the outcome back to evidence.",
  },
] as const

export function EvidenceTrail() {
  const reducedMotion = useReducedMotion()
  return (
    <section
      className="evidence-section section-frame"
      id="evidence"
      aria-labelledby="evidence-heading"
    >
      <div className="evidence-intro">
        <div>
          <p className="section-index">05 / Behavioural interpretability</p>
          <h2 id="evidence-heading">A trail you can inspect.</h2>
        </div>
        <p>
          WorldEval shows observable decisions and events—not private reasoning
          or hidden motivation.
        </p>
      </div>
      <ol className="event-trail">
        {EVENTS.map((event, index) => (
          <motion.li
            initial={reducedMotion ? false : { opacity: 0, x: -18 }}
            key={event.index}
            transition={{ delay: index * 0.08, duration: 0.5 }}
            viewport={{ amount: 0.45, once: true }}
            whileInView={{ opacity: 1, x: 0 }}
          >
            <span className="event-index">{event.index}</span>
            <span className="event-node" aria-hidden="true" />
            <div>
              <h3>{event.title}</h3>
              <p>{event.detail}</p>
            </div>
          </motion.li>
        ))}
      </ol>
    </section>
  )
}
