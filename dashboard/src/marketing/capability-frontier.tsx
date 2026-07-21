import { useRef } from "react"
import {
  motion,
  type MotionValue,
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
          {PLATES.map((plate, index) => (
            <NestedZoomPlate
              index={index}
              key={plate.src}
              plate={plate}
              progress={smoothScrollProgress}
              reducedMotion={reducedMotion}
            />
          ))}

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
