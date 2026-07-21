import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import { DemoGallery } from "./demo-gallery"
import { CONTROLLER_LAB_URL } from "./site-data"

afterEach(cleanup)

describe("game showcase", () => {
  it("links every current game to the hosted Controller Lab", () => {
    render(<DemoGallery />)

    expect(
      screen.getByRole("heading", { name: "See behaviour become evidence." })
    ).toBeInTheDocument()

    for (const game of [
      "Crossroads Conquest",
      "Labyrinth Run",
      "Mini RTS Skirmish",
    ]) {
      expect(
        screen.getByRole("link", {
          name: `Open ${game} in the Controller Lab`,
        })
      ).toHaveAttribute("href", CONTROLLER_LAB_URL)
    }

    expect(
      screen.getByRole("link", {
        name: "Open Crossroads Conquest in the Controller Lab",
      })
    ).toHaveClass("game-panel--featured")
  })
})
