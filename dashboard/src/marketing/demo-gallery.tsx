import { useState } from "react"
import { Play } from "lucide-react"
import type { VideoDemo } from "./site-data"

function PosterArt({ accent }: Pick<VideoDemo, "accent">) {
  return (
    <svg
      aria-hidden="true"
      className="poster-art"
      viewBox="0 0 800 450"
      preserveAspectRatio="xMidYMid slice"
    >
      <defs>
        <linearGradient id={`sky-${accent}`} x1="0" x2="0" y1="0" y2="1">
          <stop offset="0" stopColor="currentColor" stopOpacity="0.08" />
          <stop offset="1" stopColor="currentColor" stopOpacity="0" />
        </linearGradient>
      </defs>
      <path
        d="M0 322L78 278l62 26 77-79 67 66 103-132 83 112 72-40 108 91 150-56v164H0Z"
        fill={`url(#sky-${accent})`}
        stroke="currentColor"
        strokeWidth="1.2"
      />
      <path
        d="M0 355c146-60 244 40 388-12 131-48 265-25 412 40M0 390c196-39 390 29 800-4"
        fill="none"
        stroke="currentColor"
        strokeOpacity="0.6"
      />
      <path
        d="M400 450V290M240 450l104-160M560 450L456 290M80 430h640M145 395h510M205 360h390M267 325h266"
        fill="none"
        stroke="currentColor"
        strokeOpacity="0.24"
      />
      <g fill="none" stroke="currentColor" strokeOpacity="0.75">
        <path d="M566 276v-76h84v76M590 200v-42h34v42M566 232h84M608 158v-55m0 0 75 28m-75-28-52 22" />
        <path d="M152 307v-48h64v48m-45-48v-35h26v35" />
      </g>
      <circle
        cx="642"
        cy="105"
        r="77"
        fill="none"
        stroke="currentColor"
        strokeOpacity="0.28"
      />
    </svg>
  )
}

function VideoFacade({ demo }: { demo: VideoDemo }) {
  const [loaded, setLoaded] = useState(false)

  if (loaded && demo.youtubeId) {
    return (
      <div className="video-embed">
        <iframe
          allow="encrypted-media; picture-in-picture"
          allowFullScreen
          loading="lazy"
          src={`https://www.youtube-nocookie.com/embed/${demo.youtubeId}?rel=0&modestbranding=1`}
          title={demo.title}
        />
      </div>
    )
  }

  return (
    <article
      className={`demo-facade demo-facade--${demo.accent}${demo.featured ? "demo-facade--featured" : ""}`}
    >
      <PosterArt accent={demo.accent} />
      <div className="demo-copy">
        <h3>{demo.title}</h3>
        <p>{demo.description}</p>
      </div>
      {demo.youtubeId ? (
        <>
          <button
            className="play-button"
            onClick={() => setLoaded(true)}
            type="button"
            aria-label={`Load ${demo.title} video`}
          >
            <Play aria-hidden="true" fill="currentColor" />
          </button>
          <a
            className="youtube-link"
            href={`https://www.youtube.com/watch?v=${demo.youtubeId}`}
            rel="noreferrer"
            target="_blank"
          >
            Watch on YouTube
          </a>
        </>
      ) : (
        <span className="coming-soon">Local poster · video coming soon</span>
      )}
    </article>
  )
}

export function DemoGallery({ demos }: { demos: VideoDemo[] }) {
  return (
    <section
      className="demo-section section-frame"
      id="demos"
      aria-labelledby="demos-heading"
    >
      <div className="section-heading-row">
        <div>
          <p className="section-index">04 / Gameplay evidence</p>
          <h2 id="demos-heading">See behaviour become evidence.</h2>
        </div>
        <p>
          Participant-view video is requested only after you choose to play.
          Until publication, each slot keeps a local poster and makes no
          third-party request.
        </p>
      </div>
      <div className="demo-layout">
        {demos.map((demo) => (
          <VideoFacade demo={demo} key={demo.id} />
        ))}
      </div>
    </section>
  )
}
