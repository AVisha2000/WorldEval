import { lazy, Suspense, useRef } from "react"
import {
  MotionConfig,
  motion,
  useReducedMotion,
  useScroll,
  useSpring,
} from "motion/react"
import { CapabilityOrbit, CapabilityOrbitDescription } from "./capability-orbit"
import { CapabilityFrontier } from "./capability-frontier"
import {
  DOCUMENTATION_URL,
  getControllerLabUrl,
  getVideoDemos,
  REPOSITORY_URL,
} from "./site-data"
import "./marketing.css"

const DemoGallery = lazy(() =>
  import("./demo-gallery").then((module) => ({ default: module.DemoGallery }))
)
const EvidenceTrail = lazy(() =>
  import("./evidence-trail").then((module) => ({
    default: module.EvidenceTrail,
  }))
)

const PILLARS = [
  [
    "01",
    "Interoperable",
    "A common substrate and defined interfaces let agents, worlds, and tools work together without bespoke glue.",
  ],
  [
    "02",
    "Inspectable",
    "Every accepted action leaves an event trail in the world, creating inspectable evidence of what happened.",
  ],
  [
    "03",
    "Reproducible",
    "Deterministic worlds and versioned artifacts make results replayable and comparable.",
  ],
] as const

const WORKFLOW = [
  "Prompt",
  "World",
  "Agent action",
  "Event trail",
  "Evaluation",
] as const

function ArrowIcon() {
  return (
    <svg aria-hidden="true" className="arrow-icon" viewBox="0 0 24 24">
      <path d="M4 12h15M14 6l6 6-6 6" />
    </svg>
  )
}

function RepositoryIcon() {
  return (
    <svg aria-hidden="true" className="repository-icon" viewBox="0 0 24 24">
      <path d="M9 19c-4 1.25-4-2-5-2.5M14 22v-3.1c0-.9.1-1.45-.45-2 3-.35 6.2-1.5 6.2-6.7A5.2 5.2 0 0 0 18.4 6.6a4.8 4.8 0 0 0-.15-3.55S17.2 2.7 14 4.35a12.3 12.3 0 0 0-5.5 0C5.3 2.7 4.25 3.05 4.25 3.05A4.8 4.8 0 0 0 4.1 6.6a5.2 5.2 0 0 0-1.35 3.6c0 5.2 3.2 6.35 6.2 6.7-.45.4-.6.9-.55 1.75V22" />
    </svg>
  )
}

function Header() {
  return (
    <header className="marketing-header">
      <a className="wordmark" href="#top" aria-label="WorldEval home">
        WorldEval
      </a>
      <nav aria-label="Primary navigation">
        <a href="#frontier">Frontier</a>
        <a href="#method">Method</a>
        <a href="#demos">Demos</a>
        <a href="#evidence">Evidence</a>
      </nav>
      <a
        className="header-repository"
        href={REPOSITORY_URL}
        rel="noreferrer"
        target="_blank"
      >
        <RepositoryIcon />
        <span>View repository</span>
      </a>
    </header>
  )
}

function Hero() {
  const heroRef = useRef<HTMLElement>(null)
  const prefersReducedMotion = useReducedMotion()
  const reducedMotion = prefersReducedMotion ?? false
  const { scrollYProgress } = useScroll({
    target: heroRef,
    offset: ["start start", "end end"],
  })
  const smoothProgress = useSpring(scrollYProgress, {
    damping: 30,
    mass: 0.32,
    stiffness: 95,
  })

  return (
    <section
      aria-describedby="hero-capability-summary"
      aria-labelledby="hero-heading"
      className="marketing-hero"
      id="top"
      ref={heroRef}
    >
      <div className="hero-sticky">
        <CapabilityOrbit
          progress={smoothProgress}
          reducedMotion={reducedMotion}
        />
        <motion.div
          className="hero-copy"
          initial={{ opacity: 0, y: 24 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.8 }}
        >
          <h1 id="hero-heading">Capability keeps expanding.</h1>
          <p>
            Evaluation has to expand with it—measuring what intelligent agents
            do inside interactive, deterministic worlds, not just what they say.
          </p>
          <div className="hero-actions">
            <a className="button button--primary" href="#frontier">
              Explore the frontier <ArrowIcon />
            </a>
            <a
              className="button button--quiet"
              href={REPOSITORY_URL}
              rel="noreferrer"
              target="_blank"
            >
              <RepositoryIcon /> View repository
            </a>
          </div>
        </motion.div>
        <div className="scroll-cue">
          <span aria-hidden="true" />
          Scroll to reveal
        </div>
        <p className="hero-formula">
          Capability <i aria-hidden="true">→</i> Evaluation{" "}
          <i aria-hidden="true">→</i> Evidence
        </p>
        <p className="hero-caveat">
          Illustrative capability frontier—not a benchmark or product
          comparison.
        </p>
        <div className="hero-scroll-progress" aria-hidden="true">
          <motion.span style={{ scaleX: reducedMotion ? 1 : smoothProgress }} />
        </div>
        <CapabilityOrbitDescription />
      </div>
    </section>
  )
}

function WhyWorldEval() {
  return (
    <section
      className="why-section section-frame"
      id="method"
      aria-labelledby="why-heading"
    >
      <div className="why-statement">
        <p className="section-index">02 / Why WorldEval</p>
        <h2 id="why-heading">
          The evaluation layer for an expanding frontier.
        </h2>
        <p>
          Language alone cannot capture what an agent actually does in a world.
          Observable behaviour inside a deterministic environment produces
          evidence we can inspect and reproduce.
        </p>
      </div>
      <ol className="pillar-list">
        {PILLARS.map(([index, title, copy]) => (
          <li key={title}>
            <span>{index}</span>
            <h3>{title}</h3>
            <p>{copy}</p>
          </li>
        ))}
      </ol>
    </section>
  )
}

function EvaluationWorkflow() {
  return (
    <section
      className="workflow-section section-frame"
      aria-labelledby="workflow-heading"
    >
      <div>
        <p className="section-index">03 / Evaluation method</p>
        <h2 id="workflow-heading">
          From prompt to action.
          <span>From action to evidence.</span>
        </h2>
        <p className="workflow-formula">
          Capability <span aria-hidden="true">→</span> Evaluation{" "}
          <span aria-hidden="true">→</span> Evidence
        </p>
      </div>
      <ol className="workflow-rail">
        {WORKFLOW.map((step, index) => (
          <li key={step}>
            <span>{String(index + 1).padStart(2, "0")}</span>
            <i aria-hidden="true" />
            <strong>{step}</strong>
          </li>
        ))}
      </ol>
      <p className="observable-note">
        Observable behaviour, not private reasoning.
      </p>
    </section>
  )
}

function BuildAndRepository() {
  const controllerLabUrl = getControllerLabUrl()
  return (
    <section
      className="build-section section-frame"
      aria-labelledby="build-heading"
    >
      <div className="build-status">
        <p className="section-index">06 / Build status</p>
        <h2 id="build-heading">Built in the open.</h2>
        <dl>
          <div>
            <dt>Repository</dt>
            <dd>Public source</dd>
          </div>
          <div>
            <dt>Core</dt>
            <dd>Deterministic research prototype</dd>
          </div>
          <div>
            <dt>Evidence</dt>
            <dd>Versioned events and replay artifacts</dd>
          </div>
          <div>
            <dt>Controller Lab</dt>
            <dd>
              {controllerLabUrl
                ? "External lab configured"
                : "Live lab coming soon"}
            </dd>
          </div>
        </dl>
      </div>
      <div className="repository-cta">
        <p>
          Capability <span aria-hidden="true">→</span> Evaluation{" "}
          <span aria-hidden="true">→</span> Evidence
        </p>
        <h2>Evaluate the world agents act in.</h2>
        <div className="cta-actions">
          <a
            className="button button--primary"
            href={REPOSITORY_URL}
            rel="noreferrer"
            target="_blank"
          >
            View repository <ArrowIcon />
          </a>
          <a
            className="button button--quiet"
            href={DOCUMENTATION_URL}
            rel="noreferrer"
            target="_blank"
          >
            Read the documentation <ArrowIcon />
          </a>
          {controllerLabUrl ? (
            <a
              className="lab-link"
              href={controllerLabUrl}
              rel="noreferrer"
              target="_blank"
            >
              Open Controller Lab <ArrowIcon />
            </a>
          ) : (
            <a className="lab-link" href="#demos">
              Live lab coming soon <ArrowIcon />
            </a>
          )}
        </div>
      </div>
    </section>
  )
}

function Footer() {
  return (
    <footer className="marketing-footer section-frame">
      <a className="wordmark" href="#top">
        WorldEval
      </a>
      <p>Observable behaviour in deterministic worlds.</p>
      <div>
        <a href={REPOSITORY_URL} rel="noreferrer" target="_blank">
          Repository
        </a>
        <a href={DOCUMENTATION_URL} rel="noreferrer" target="_blank">
          Documentation
        </a>
      </div>
    </footer>
  )
}

export function MarketingSite() {
  const demos = getVideoDemos()
  return (
    <MotionConfig
      reducedMotion="user"
      transition={{ duration: 0.6, ease: [0.22, 1, 0.36, 1] }}
    >
      <a className="skip-link" href="#main-content">
        Skip to content
      </a>
      <div className="marketing-shell">
        <Header />
        <main id="main-content">
          <Hero />
          <CapabilityFrontier />
          <WhyWorldEval />
          <EvaluationWorkflow />
          <Suspense
            fallback={
              <div className="section-placeholder" aria-hidden="true" />
            }
          >
            <DemoGallery demos={demos} />
          </Suspense>
          <Suspense
            fallback={
              <div
                className="section-placeholder section-placeholder--short"
                aria-hidden="true"
              />
            }
          >
            <EvidenceTrail />
          </Suspense>
          <BuildAndRepository />
        </main>
        <Footer />
      </div>
    </MotionConfig>
  )
}

export default MarketingSite
