import { useRef, useState } from "react"
import {
  motion,
  type MotionValue,
  useMotionValueEvent,
  useReducedMotion,
  useScroll,
  useSpring,
  useTransform,
} from "motion/react"
import laptopPlate from "./assets/nested-zoom-01-laptop.jpg"
import housePlate from "./assets/nested-zoom-02-house.jpg"
import streetPlate from "./assets/nested-zoom-03-street.jpg"
import neighbourhoodPlate from "./assets/nested-zoom-04-neighbourhood.jpg"
import cityPlate from "./assets/nested-zoom-05-city.jpg"
import continentPlate from "./assets/nested-zoom-06-continent.jpg"
import earthPlate from "./assets/nested-zoom-07-earth.jpg"
import moonPlate from "./assets/nested-zoom-08-moon.jpg"
import solarPlate from "./assets/nested-zoom-09-solar.jpg"
import maleAstronautGoblin from "./assets/astronaut-goblin-male.png"

type ZoomPlate = {
  end: number
  fit?: "contain"
  label: string
  originX: number
  originY: number
  scale: number
  src: string
  start: number
}

type GoblinFlybyProps = {
  delay: number
  progress: MotionValue<number>
  reducedMotion: boolean
  src: string
  triggerAt: number
}

const GOBLIN_FLIGHT_DURATION = 10
const GOBLIN_LOOP_SAMPLES = 36
const GOBLIN_LOOP_END_TIME = 0.78
const GOBLIN_BOOST_START_TIME = 0.88
const GOBLIN_FLIGHT_POINTS = [
  { rotate: -4, time: 0, x: -28, y: 5 },
  { rotate: -2, time: 0.08, x: 4, y: 2 },
  { rotate: 0, time: 0.16, x: 24, y: -2 },
  ...Array.from({ length: GOBLIN_LOOP_SAMPLES + 1 }, (_, index) => {
    const loopProgress = index / GOBLIN_LOOP_SAMPLES
    const angle = Math.PI - loopProgress * Math.PI * 2

    return {
      rotate: 10 + loopProgress * 360,
      time: 0.22 + loopProgress * (GOBLIN_LOOP_END_TIME - 0.22),
      x: 50 + Math.cos(angle) * 16,
      y: -8 + Math.sin(angle) * 20,
    }
  }),
  { rotate: 370, time: GOBLIN_BOOST_START_TIME, x: 34, y: -8 },
  { rotate: 376, time: 0.92, x: 50, y: -22 },
  { rotate: 386, time: 0.96, x: 82, y: -47 },
  { rotate: 392, time: 1, x: 112, y: -70 },
]
const GOBLIN_FLIGHT_TIMES = GOBLIN_FLIGHT_POINTS.map(({ time }) => time)
const GOBLIN_FLIGHT_X = GOBLIN_FLIGHT_POINTS.map(({ x }) => `${x}vw`)
const GOBLIN_FLIGHT_Y = GOBLIN_FLIGHT_POINTS.map(({ y }) => `${y}vh`)
const GOBLIN_FLIGHT_ROTATE = GOBLIN_FLIGHT_POINTS.map(({ rotate }) => rotate)
const GOBLIN_FLIGHT_OPACITY = GOBLIN_FLIGHT_POINTS.map(({ time }) => {
  if (time <= 0.08) {
    return (time / 0.08) * 0.96
  }
  if (time >= 0.94) {
    return ((1 - time) / 0.06) * 0.96
  }
  return 0.96
})
const GOBLIN_PAUSE_SCALE =
  0.76 + Math.sin(Math.PI * GOBLIN_LOOP_END_TIME) * 0.12
const GOBLIN_FLIGHT_SCALE = GOBLIN_FLIGHT_POINTS.map(({ time }) =>
  time >= GOBLIN_LOOP_END_TIME && time <= GOBLIN_BOOST_START_TIME
    ? GOBLIN_PAUSE_SCALE
    : 0.76 + Math.sin(Math.PI * time) * 0.12
)
const GOBLIN_BOOST_TIMES = [0, 0.86, GOBLIN_BOOST_START_TIME, 0.89, 0.97, 1]
const GOBLIN_BOOST_OPACITY = [0, 0, 0, 0.96, 0.82, 0]
const GOBLIN_BOOST_SCALE_X = [0.2, 0.2, 0.2, 1.08, 1.28, 0.5]
const GOBLIN_BOOST_SCALE_Y = [0.5, 0.5, 0.5, 1, 0.78, 0.4]
const PLATES: ZoomPlate[] = [
  {
    end: 0.12,
    label: "OpenAI on one laptop",
    originX: 50,
    originY: 53,
    scale: 2.8,
    src: laptopPlate,
    start: 0,
  },
  {
    end: 0.24,
    label: "The room inside the house",
    originX: 54,
    originY: 59,
    scale: 4.5,
    src: housePlate,
    start: 0.12,
  },
  {
    end: 0.36,
    label: "The house on its street",
    originX: 50,
    originY: 55,
    scale: 4.2,
    src: streetPlate,
    start: 0.24,
  },
  {
    end: 0.48,
    label: "The street inside its neighbourhood",
    originX: 50,
    originY: 62,
    scale: 3.1,
    src: neighbourhoodPlate,
    start: 0.36,
  },
  {
    end: 0.6,
    label: "The neighbourhood inside its city",
    originX: 50,
    originY: 48,
    scale: 3.7,
    src: cityPlate,
    start: 0.48,
  },
  {
    end: 0.71,
    fit: "contain",
    label: "The city inside its continent",
    originX: 50,
    originY: 47,
    scale: 4.2,
    src: continentPlate,
    start: 0.6,
  },
  {
    end: 0.81,
    fit: "contain",
    label: "The continent on Earth",
    originX: 50,
    originY: 51,
    scale: 3.2,
    src: earthPlate,
    start: 0.71,
  },
  {
    end: 0.91,
    fit: "contain",
    label: "Earth between satellites and the Moon",
    originX: 68,
    originY: 51,
    scale: 3.05,
    src: moonPlate,
    start: 0.81,
  },
  {
    end: 1,
    fit: "contain",
    label: "Earth, Moon and the solar horizon",
    originX: 57,
    originY: 48,
    scale: 2.05,
    src: solarPlate,
    start: 0.91,
  },
]

function NestedZoomPlate({
  index,
  plate,
  progress,
  reducedMotion,
}: {
  index: number
  plate: ZoomPlate
  progress: MotionValue<number>
  reducedMotion: boolean
}) {
  const scale = useTransform(
    progress,
    [plate.start, plate.end],
    [plate.scale, 1]
  )
  const stageLength = plate.end - plate.start
  const x = useTransform(
    progress,
    [plate.start, plate.start + stageLength * 0.72, plate.end],
    [`${50 - plate.originX}vw`, "0vw", "0vw"]
  )
  const y = useTransform(
    progress,
    [plate.start, plate.start + stageLength * 0.82, plate.end],
    [`${50 - plate.originY}vh`, "0vh", "0vh"]
  )
  const opacity = useTransform(() => {
    const value = progress.get()
    const isLast = index === PLATES.length - 1
    return value >= plate.start && (isLast || value < plate.end) ? 1 : 0
  })
  const portalOpacity = useTransform(
    progress,
    [plate.start, plate.start + (plate.end - plate.start) * 0.45],
    [1, 0]
  )
  const portalSize = 100 / plate.scale
  const previousPlate = index > 0 ? PLATES[index - 1] : null

  return (
    <motion.div
      aria-hidden="true"
      className={`zoom-plate${plate.fit ? " zoom-plate--contain" : ""}`}
      style={{
        opacity: reducedMotion ? (index === PLATES.length - 1 ? 1 : 0) : opacity,
        scale: reducedMotion ? 1 : scale,
        transformOrigin: `${plate.originX}% ${plate.originY}%`,
        x: reducedMotion ? 0 : x,
        y: reducedMotion ? 0 : y,
        zIndex: index + 1,
      }}
    >
      <img
        className="zoom-plate-image"
        alt=""
        loading={index < 3 ? "eager" : "lazy"}
        src={plate.src}
      />
      {previousPlate ? (
        <motion.div
          className="nested-image-portal"
          style={{
            height: `${portalSize}%`,
            left: `${plate.originX - portalSize / 2}%`,
            opacity: portalOpacity,
            top: `${plate.originY - portalSize / 2}%`,
            width: `${portalSize}%`,
          }}
        >
          <img
            alt=""
            className={previousPlate.fit ? "nested-image-portal--contain" : ""}
            loading={index < 3 ? "eager" : "lazy"}
            src={previousPlate.src}
          />
        </motion.div>
      ) : null}
    </motion.div>
  )
}

function GoblinFlightRun({
  delay,
  src,
}: Pick<GoblinFlybyProps, "delay" | "src">) {
  return (
    <motion.div
      aria-hidden="true"
      animate={{
        opacity: GOBLIN_FLIGHT_OPACITY,
        rotate: GOBLIN_FLIGHT_ROTATE,
        scale: GOBLIN_FLIGHT_SCALE,
        x: GOBLIN_FLIGHT_X,
        y: GOBLIN_FLIGHT_Y,
      }}
      className="goblin-flight goblin-flight--male"
      initial={{
        opacity: 0,
        rotate: GOBLIN_FLIGHT_ROTATE[0],
        scale: 0.78,
        x: GOBLIN_FLIGHT_X[0],
        y: GOBLIN_FLIGHT_Y[0],
      }}
      transition={{
        delay,
        duration: GOBLIN_FLIGHT_DURATION,
        ease: "linear",
        times: GOBLIN_FLIGHT_TIMES,
      }}
    >
      <span className="goblin-vapor-trail goblin-vapor-trail--wake" />
      <span className="goblin-vapor-trail goblin-vapor-trail--core" />
      <motion.span
        animate={{
          opacity: GOBLIN_BOOST_OPACITY,
          scaleX: GOBLIN_BOOST_SCALE_X,
          scaleY: GOBLIN_BOOST_SCALE_Y,
        }}
        className="goblin-boost goblin-boost--smoke"
        initial={{ opacity: 0, scaleX: 0.2, scaleY: 0.5 }}
        transition={{
          delay,
          duration: GOBLIN_FLIGHT_DURATION,
          ease: "linear",
          times: GOBLIN_BOOST_TIMES,
        }}
      />
      <motion.span
        animate={{
          opacity: GOBLIN_BOOST_OPACITY,
          scaleX: GOBLIN_BOOST_SCALE_X,
          scaleY: GOBLIN_BOOST_SCALE_Y,
        }}
        className="goblin-boost goblin-boost--flame"
        initial={{ opacity: 0, scaleX: 0.2, scaleY: 0.5 }}
        transition={{
          delay,
          duration: GOBLIN_FLIGHT_DURATION,
          ease: "linear",
          times: GOBLIN_BOOST_TIMES,
        }}
      />
      <img
        alt=""
        className="goblin-flyby"
        decoding="async"
        loading="lazy"
        src={src}
      />
    </motion.div>
  )
}

function GoblinFlyby({
  delay,
  progress,
  reducedMotion,
  src,
  triggerAt,
}: GoblinFlybyProps) {
  const [runId, setRunId] = useState(0)
  const hasPlayed = useRef(false)

  useMotionValueEvent(progress, "change", (value) => {
    if (reducedMotion) {
      return
    }

    if (value >= triggerAt && !hasPlayed.current) {
      hasPlayed.current = true
      setRunId((current) => current + 1)
    }
  })

  return reducedMotion || runId === 0 ? null : (
    <GoblinFlightRun delay={delay} key={runId} src={src} />
  )
}

export function CapabilityFrontier() {
  const sectionRef = useRef<HTMLElement>(null)
  const prefersReducedMotion = useReducedMotion()
  const reducedMotion = prefersReducedMotion ?? false
  const { scrollYProgress } = useScroll({
    target: sectionRef,
    offset: ["start start", "end end"],
  })
  const smoothScrollProgress = useSpring(scrollYProgress, {
    damping: 28,
    mass: 0.35,
    stiffness: 90,
  })
  const finaleOpacity = useTransform(() =>
    Math.min(1, Math.max(0, (smoothScrollProgress.get() - 0.955) / 0.035))
  )

  return (
    <section
      className={`world-expansion${reducedMotion ? " world-expansion--reduced" : ""}`}
      id="frontier"
      ref={sectionRef}
      aria-labelledby="frontier-heading"
    >
      <div className="expansion-sticky">
        <div className="expansion-copy">
          <p className="section-index">01 / Capability frontier</p>
          <h2 id="frontier-heading">From one device to an entire world.</h2>
          <p>
            As the capability frontier expands, so does the space that needs to
            be evaluated.
          </p>
          <ol className="expansion-stages" aria-label="Expansion stages">
            {PLATES.map((plate, index) => (
              <li key={plate.label}>
                <span>{String(index + 1).padStart(2, "0")}</span>
                {plate.label}
              </li>
            ))}
          </ol>
          <p className="trademark-note">
            OpenAI is a trademark of OpenAI. WorldEval is independent and is not
            endorsed by OpenAI.
          </p>
        </div>

        <div
          className="infinity-stage"
          role="img"
          aria-label="One continuous nested camera pullback begins on an OpenAI laptop, exits through the house window, rises above its street and city, and continues past Earth, satellites, a rocket and the Moon to the Sun."
        >
          <div aria-hidden="true" className="goblin-asset-preload">
            <img alt="" decoding="async" loading="eager" src={maleAstronautGoblin} />
          </div>

          {PLATES.map((plate, index) => (
            <NestedZoomPlate
              index={index}
              key={plate.src}
              plate={plate}
              progress={smoothScrollProgress}
              reducedMotion={reducedMotion}
            />
          ))}

          <GoblinFlyby
            delay={1}
            progress={smoothScrollProgress}
            reducedMotion={reducedMotion}
            src={maleAstronautGoblin}
            triggerAt={0.945}
          />

          <motion.p
            className="solar-finale-copy"
            style={{ opacity: reducedMotion ? 1 : finaleOpacity }}
          >
            What’s possible with a single prompt keeps expanding.
          </motion.p>

          <div className="infinity-reticle" aria-hidden="true">
            <span />
          </div>
        </div>

        <p className="infinite-zoom-watermark">
          Infinite zoom created with <strong>5.6 Sol</strong>
        </p>

        <div className="expansion-progress" aria-hidden="true">
          <motion.span
            style={{ scaleX: reducedMotion ? 1 : smoothScrollProgress }}
          />
        </div>
      </div>
    </section>
  )
}
