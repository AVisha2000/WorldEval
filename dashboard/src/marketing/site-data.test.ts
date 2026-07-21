import { describe, expect, it } from "vitest"
import { CONTROLLER_LAB_URL, getControllerLabUrl } from "./site-data"

describe("Controller Lab configuration", () => {
  it("accepts a public HTTP URL", () => {
    expect(getControllerLabUrl("https://lab.example.test/worldeval")).toBe(
      "https://lab.example.test/worldeval"
    )
  })

  it("uses the hosted Build Week lab by default", () => {
    expect(getControllerLabUrl()).toBe(CONTROLLER_LAB_URL)
  })

  it.each([
    "http://localhost:8000",
    "http://127.0.0.1:8000",
    "file:///tmp/lab",
    "not a url",
  ])("falls back from a local or invalid URL: %s", (value) => {
    expect(getControllerLabUrl(value)).toBe(CONTROLLER_LAB_URL)
  })
})
