import { ArrowUpRight } from "lucide-react"
import crossroadsImage from "./assets/crossroads-conquest.jpg"
import labyrinthImage from "./assets/labyrinth-run.jpg"
import miniRtsImage from "./assets/mini-rts-bridge.jpg"
import { getControllerLabUrl } from "./site-data"

type GameShowcase = {
  id: string
  title: string
  focus: string
  image: string
  imageAlt: string
  featured?: boolean
}

const GAMES: GameShowcase[] = [
  {
    id: "crossroads",
    title: "Crossroads Conquest",
    focus: "Multi-agent strategy",
    image: crossroadsImage,
    imageAlt:
      "Sol, Terra, and Luna expanding across the shared Crossroads Conquest map",
    featured: true,
  },
  {
    id: "labyrinth",
    title: "Labyrinth Run",
    focus: "Spatial reasoning",
    image: labyrinthImage,
    imageAlt: "Sol, Luna, and Terra navigating three private maze lanes",
  },
  {
    id: "mini-rts",
    title: "Mini RTS Skirmish",
    focus: "Planning, resources, and combat",
    image: miniRtsImage,
    imageAlt: "Terra and Luna militia contesting the river bridge",
  },
]

function GamePanel({ game }: { game: GameShowcase }) {
  const controllerLabUrl = getControllerLabUrl()

  return (
    <a
      aria-label={`Open ${game.title} in the Controller Lab`}
      className={
        game.featured ? "game-panel game-panel--featured" : "game-panel"
      }
      href={controllerLabUrl}
      rel="noreferrer"
      target="_blank"
    >
      <img alt={game.imageAlt} loading="lazy" src={game.image} />
      <span className="game-panel__shade" aria-hidden="true" />
      <span className="game-panel__content">
        <strong>{game.title}</strong>
        <span className="game-panel__focus">{game.focus}</span>
        <span className="game-panel__link">
          Open in Controller Lab <ArrowUpRight aria-hidden="true" />
        </span>
      </span>
    </a>
  )
}

export function DemoGallery() {
  return (
    <section
      className="demo-section section-frame"
      id="demos"
      aria-labelledby="demos-heading"
    >
      <div className="showcase-heading">
        <div>
          <p className="section-index">04 / Game showcase</p>
          <h2 id="demos-heading">See behaviour become evidence.</h2>
        </div>
        <p>
          Three games. Three different tests of agency. One inspectable evidence
          trail.
        </p>
      </div>
      <div className="game-showcase">
        {GAMES.map((game) => (
          <GamePanel game={game} key={game.id} />
        ))}
      </div>
    </section>
  )
}
