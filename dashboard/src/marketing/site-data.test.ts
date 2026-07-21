import { describe, expect, it } from "vitest"
import { getControllerLabUrl, getVideoDemos } from "./site-data"

describe("video configuration", () => {
  it("keeps missing IDs as a coming-soon configuration", () => {
    const demos = getVideoDemos({})
    expect(demos).toHaveLength(3)
    expect(demos.every((demo) => demo.youtubeId === undefined)).toBe(true)
  })

  it("maps configured IDs without inventing values for the other demos", () => {
    const demos = getVideoDemos({ VITE_YOUTUBE_TRIO_ID: "trio-real-1" })
    expect(demos[0]).toMatchObject({
      id: "trio",
      featured: true,
      youtubeId: "trio-real-1",
    })
    expect(demos[1].id).toBe("solo")
    expect(demos[1].youtubeId).toBeUndefined()
    expect(demos[2].id).toBe("duel")
    expect(demos[2].youtubeId).toBeUndefined()
  })

  it("rejects malformed YouTube IDs", () => {
    expect(
      getVideoDemos({ VITE_YOUTUBE_TRIO_ID: "not an id" })[0].youtubeId
    ).toBeUndefined()
  })

  it("defines exactly the solo, 1v1, and trio publication slots", () => {
    expect(getVideoDemos({}).map((demo) => demo.id)).toEqual([
      "trio",
      "solo",
      "duel",
    ])
  })
})

describe("Controller Lab configuration", () => {
  it("accepts a public HTTP URL", () => {
    expect(getControllerLabUrl("https://lab.example.test/worldeval")).toBe(
      "https://lab.example.test/worldeval"
    )
  })

  it.each([
    "http://localhost:8000",
    "http://127.0.0.1:8000",
    "file:///tmp/lab",
    "not a url",
  ])("never publishes a local or invalid URL: %s", (value) => {
    expect(getControllerLabUrl(value)).toBeUndefined()
  })
})
