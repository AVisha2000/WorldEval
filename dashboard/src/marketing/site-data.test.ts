import { describe, expect, it } from "vitest"
import { getControllerLabUrl, getVideoDemos } from "./site-data"

describe("video configuration", () => {
  it("keeps missing IDs as a coming-soon configuration", () => {
    const demos = getVideoDemos({})
    expect(demos).toHaveLength(3)
    expect(demos.every((demo) => demo.youtubeId === undefined)).toBe(true)
  })

  it("maps configured IDs without inventing values for the other demos", () => {
    const demos = getVideoDemos({ VITE_YOUTUBE_MVP_ID: "mvp-real-id" })
    expect(demos[0].youtubeId).toBe("mvp-real-id")
    expect(demos[1].youtubeId).toBeUndefined()
    expect(demos[2].youtubeId).toBeUndefined()
  })

  it("rejects malformed YouTube IDs", () => {
    expect(
      getVideoDemos({ VITE_YOUTUBE_MVP_ID: "not an id" })[0].youtubeId
    ).toBeUndefined()
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
