import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import { EvidenceTrail } from "./evidence-trail"

afterEach(cleanup)

describe("roadmap list", () => {
  it("shows implemented, next, and future work with explicit statuses", () => {
    render(<EvidenceTrail />)

    expect(screen.getByText("Prompt to 3D game world")).toBeInTheDocument()
    expect(screen.getAllByText("Implemented")).toHaveLength(2)
    expect(screen.getByText("Next")).toBeInTheDocument()
    expect(screen.getAllByText("Future")).toHaveLength(2)
  })
})
