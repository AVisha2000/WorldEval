import { motion, type MotionValue, useTransform } from "motion/react"

type CapabilityArc = "bottom" | "top"

type Capability = {
  arc: CapabilityArc
  label: string
  offset: number
}

type CapabilityEra = {
  capabilities: readonly Capability[]
  end: number
  id: "3" | "4" | "5" | "future"
  number: "3" | "4" | "5" | "?"
  radius: number
  releaseLabel: "2020" | "2023" | "2025" | "SOON"
  start: number
  title: string
}

const ORBIT_CENTER = 420
const ERA_REVEAL_DURATION = 0.07

const CAPABILITY_ERAS: readonly CapabilityEra[] = [
  {
    capabilities: [
      { arc: "top", label: "TRANSLATION", offset: 18 },
      { arc: "top", label: "SUMMARIZATION", offset: 50 },
      { arc: "top", label: "Q&A", offset: 82 },
      { arc: "bottom", label: "CLASSIFICATION", offset: 28 },
      { arc: "bottom", label: "TEXT GENERATION", offset: 72 },
    ],
    end: 0.28,
    id: "3",
    number: "3",
    radius: 126,
    releaseLabel: "2020",
    start: 0,
    title: "Language generation",
  },
  {
    capabilities: [
      { arc: "top", label: "VISION", offset: 17 },
      { arc: "top", label: "ADVANCED REASONING", offset: 50 },
      { arc: "top", label: "DIAGRAMS", offset: 83 },
      { arc: "bottom", label: "MULTIMODAL UNDERSTANDING", offset: 30 },
      { arc: "bottom", label: "INSTRUCTION FOLLOWING", offset: 72 },
    ],
    end: 0.53,
    id: "4",
    number: "4",
    radius: 204,
    releaseLabel: "2023",
    start: 0.27,
    title: "Multimodal reasoning",
  },
  {
    capabilities: [
      { arc: "top", label: "CODING", offset: 18 },
      { arc: "top", label: "TOOL USE", offset: 50 },
      { arc: "top", label: "LONG CONTEXT", offset: 82 },
      { arc: "bottom", label: "MULTI-STEP EXECUTION", offset: 29 },
      { arc: "bottom", label: "AGENTIC WORKFLOWS", offset: 71 },
    ],
    end: 0.78,
    id: "5",
    number: "5",
    radius: 286,
    releaseLabel: "2025",
    start: 0.52,
    title: "Agentic execution",
  },
  {
    capabilities: [
      { arc: "top", label: "ROBOTICS", offset: 17 },
      { arc: "top", label: "COMPUTER CONTROL", offset: 50 },
      { arc: "top", label: "SCIENTIFIC DISCOVERY", offset: 83 },
      { arc: "bottom", label: "PERSISTENT AGENTS", offset: 28 },
      { arc: "bottom", label: "PHYSICAL-WORLD ACTION", offset: 72 },
    ],
    end: 1,
    id: "future",
    number: "?",
    radius: 368,
    releaseLabel: "SOON",
    start: 0.77,
    title: "The physical frontier",
  },
] as const

function arcPath(radius: number, arc: CapabilityArc) {
  const left = ORBIT_CENTER - radius
  const right = ORBIT_CENTER + radius
  const sweep = arc === "top" ? 1 : 0
  return `M ${left} ${ORBIT_CENTER} A ${radius} ${radius} 0 0 ${sweep} ${right} ${ORBIT_CENTER}`
}

function getEraTimeline(era: CapabilityEra) {
  const revealEnd = era.start + ERA_REVEAL_DURATION
  const isFinal = era.id === "future"
  const isInitial = era.id === "3"

  return {
    input: isInitial
      ? [0, era.end, Math.min(1, era.end + 0.045)]
      : isFinal
        ? [era.start, revealEnd, 1]
        : [era.start, revealEnd, era.end, Math.min(1, era.end + 0.045)],
    isFinal,
    isInitial,
    revealEnd,
  }
}

function OrbitLabel({
  capability,
  dimAt,
  index,
  pathId,
  persistent,
  progress,
  reducedMotion,
  revealAt,
}: {
  capability: Capability
  dimAt: number
  index: number
  pathId: string
  persistent: boolean
  progress: MotionValue<number>
  reducedMotion: boolean
  revealAt: number
}) {
  const labelStart = revealAt + index * 0.023
  const opacity = useTransform(
    progress,
    persistent
      ? [labelStart, labelStart + 0.025, 1]
      : [labelStart, labelStart + 0.025, dimAt, Math.min(1, dimAt + 0.045)],
    persistent ? [0, 1, 1] : [0, 1, 1, 0.3]
  )
  const filter = useTransform(
    progress,
    [labelStart, labelStart + 0.025],
    ["blur(5px)", "blur(0px)"]
  )

  return (
    <motion.text
      className="capability-orbit-label"
      dy={capability.arc === "top" ? -10 : 22}
      style={{
        filter: reducedMotion ? "none" : filter,
        opacity,
      }}
    >
      <textPath
        href={`#${pathId}-${capability.arc}`}
        startOffset={`${capability.offset}%`}
        textAnchor="middle"
      >
        {capability.label}
      </textPath>
    </motion.text>
  )
}

function CapabilityRing({
  era,
  progress,
  reducedMotion,
}: {
  era: CapabilityEra
  progress: MotionValue<number>
  reducedMotion: boolean
}) {
  const { input, isFinal, isInitial, revealEnd } = getEraTimeline(era)
  const opacity = useTransform(
    progress,
    input,
    isInitial ? [1, 1, 0.38] : isFinal ? [0, 1, 1] : [0, 1, 1, 0.38]
  )
  const pathLength = useTransform(progress, [era.start, revealEnd], [0, 1])
  const pathId = `capability-orbit-${era.id}`

  return (
    <g className={`capability-ring capability-ring--${era.id}`}>
      {isFinal ? (
        <motion.circle
          className="capability-ring-line"
          cx={ORBIT_CENTER}
          cy={ORBIT_CENTER}
          r={era.radius}
          style={{ opacity }}
        />
      ) : (
        <motion.circle
          className="capability-ring-line"
          cx={ORBIT_CENTER}
          cy={ORBIT_CENTER}
          pathLength={reducedMotion ? 1 : pathLength}
          r={era.radius}
          style={{ opacity }}
        />
      )}
      {era.capabilities.map((capability, index) => (
        <OrbitLabel
          capability={capability}
          dimAt={isFinal ? 1.1 : era.end}
          index={index}
          key={capability.label}
          pathId={pathId}
          persistent={isFinal}
          progress={progress}
          reducedMotion={reducedMotion}
          revealAt={revealEnd - 0.012}
        />
      ))}
    </g>
  )
}

function EraMarker({
  era,
  progress,
}: {
  era: CapabilityEra
  progress: MotionValue<number>
}) {
  const { input, isFinal, isInitial } = getEraTimeline(era)
  const opacity = useTransform(
    progress,
    input,
    isInitial ? [1, 1, 0] : isFinal ? [0, 1, 1] : [0, 1, 1, 0]
  )

  return (
    <>
      <motion.text
        className={`capability-era-number capability-era-number--${era.id}`}
        style={{ opacity }}
        textAnchor="middle"
        x={ORBIT_CENTER}
        y={ORBIT_CENTER + 31}
      >
        {era.number}
      </motion.text>
      <motion.text
        className="capability-era-release"
        style={{ opacity }}
        textAnchor="middle"
        x={ORBIT_CENTER}
        y={ORBIT_CENTER + 61}
      >
        {era.releaseLabel}
      </motion.text>
    </>
  )
}

function MobileEraReadout({
  era,
  progress,
}: {
  era: CapabilityEra
  progress: MotionValue<number>
}) {
  const { input, isFinal, isInitial } = getEraTimeline(era)
  const opacity = useTransform(
    progress,
    input,
    isInitial ? [1, 1, 0] : isFinal ? [0, 1, 1] : [0, 1, 1, 0]
  )

  return (
    <motion.div className="mobile-era-readout" style={{ opacity }}>
      <p>
        GPT / {era.number}{" "}
        <span>
          {era.releaseLabel} · {era.title}
        </span>
      </p>
      <small>
        {era.capabilities.map((capability) => capability.label).join(" · ")}
      </small>
    </motion.div>
  )
}

export function CapabilityOrbit({
  progress,
  reducedMotion,
}: {
  progress: MotionValue<number>
  reducedMotion: boolean
}) {
  const cameraScale = useTransform(progress, [0, 1], [0.9, 1.03])
  const cameraRotate = useTransform(progress, [0, 1], [-2.5, 2])

  return (
    <div className="capability-orbit" aria-hidden="true">
      <motion.div
        className="capability-orbit-camera"
        style={{
          rotate: reducedMotion ? 0 : cameraRotate,
          scale: reducedMotion ? 1 : cameraScale,
        }}
      >
        <svg viewBox="0 0 840 840">
          <defs>
            <radialGradient id="capability-core" cx="34%" cy="28%" r="72%">
              <stop offset="0%" stopColor="#ffe4b4" />
              <stop offset="20%" stopColor="#eaae58" />
              <stop offset="66%" stopColor="#5e3b1d" />
              <stop offset="100%" stopColor="#17110b" />
            </radialGradient>
            {CAPABILITY_ERAS.map((era) => (
              <g key={era.id}>
                <path
                  d={arcPath(era.radius, "top")}
                  id={`capability-orbit-${era.id}-top`}
                />
                <path
                  d={arcPath(era.radius, "bottom")}
                  id={`capability-orbit-${era.id}-bottom`}
                />
              </g>
            ))}
          </defs>

          <g className="capability-orbit-crosshairs">
            <path d="M 24 420 H 816" />
            <path d="M 420 24 V 816" />
          </g>

          {CAPABILITY_ERAS.map((era) => (
            <CapabilityRing
              era={era}
              key={era.id}
              progress={progress}
              reducedMotion={reducedMotion}
            />
          ))}

          <circle
            className="capability-core-glow"
            cx={ORBIT_CENTER}
            cy={ORBIT_CENTER}
            r="102"
          />
          <circle
            className="capability-core"
            cx={ORBIT_CENTER}
            cy={ORBIT_CENTER}
            fill="url(#capability-core)"
            r="78"
          />
          <text
            className="capability-core-label"
            textAnchor="middle"
            x={ORBIT_CENTER}
            y={ORBIT_CENTER - 27}
          >
            GPT
          </text>
          {CAPABILITY_ERAS.map((era) => (
            <EraMarker
              era={era}
              key={era.id}
              progress={progress}
            />
          ))}
        </svg>
      </motion.div>

      <div className="mobile-era-readouts">
        {CAPABILITY_ERAS.map((era) => (
          <MobileEraReadout era={era} key={era.id} progress={progress} />
        ))}
      </div>
    </div>
  )
}

export function CapabilityOrbitDescription() {
  return (
    <ol className="sr-only" id="hero-capability-summary">
      {CAPABILITY_ERAS.map((era) => (
        <li key={era.id}>
          GPT {era.number} ({era.releaseLabel}):{" "}
          {era.capabilities.map(({ label }) => label).join(", ")}
          {era.id === "future" ? ". Illustrative future capabilities." : "."}
        </li>
      ))}
    </ol>
  )
}
