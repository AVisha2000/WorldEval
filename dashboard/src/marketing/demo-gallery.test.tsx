import { cleanup, render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { afterEach, describe, expect, it } from "vitest"
import { DemoGallery } from "./demo-gallery"
import type { VideoDemo } from "./site-data"

const configuredDemo: VideoDemo = {
  id: "configured",
  title: "Configured demo",
  description: "A configured privacy-conscious demo.",
  youtubeId: "configured-id",
  accent: "amber",
  featured: true,
}

afterEach(cleanup)

describe("demo gallery", () => {
  it("does not create a YouTube iframe before visitor interaction", async () => {
    const user = userEvent.setup()
    render(<DemoGallery demos={[configuredDemo]} />)

    expect(screen.queryByTitle("Configured demo")).not.toBeInTheDocument()
    expect(
      screen.getByRole("link", { name: "Watch on YouTube" })
    ).toHaveAttribute("href", "https://www.youtube.com/watch?v=configured-id")

    await user.click(
      screen.getByRole("button", { name: "Load Configured demo video" })
    )
    expect(await screen.findByTitle("Configured demo")).toHaveAttribute(
      "src",
      "https://www.youtube-nocookie.com/embed/configured-id?rel=0&modestbranding=1"
    )
  })

  it("renders a polished fallback when no ID is configured", () => {
    render(
      <DemoGallery demos={[{ ...configuredDemo, youtubeId: undefined }]} />
    )
    expect(screen.getByText("Coming soon")).toBeInTheDocument()
    expect(
      screen.queryByRole("button", { name: /Load/ })
    ).not.toBeInTheDocument()
    expect(
      screen.queryByRole("link", { name: "Watch on YouTube" })
    ).not.toBeInTheDocument()
  })
})
