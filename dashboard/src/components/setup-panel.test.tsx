import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"
import type { EpisodeSetup } from "@/api"
import { SetupPanel } from "@/components/setup-panel"

const setup: EpisodeSetup = {
  mode: "solo",
  provider: "openai",
  model: "gpt-5.6-sol",
  apiKey: "",
  opponentProvider: "scripted",
  opponentModel: "balanced-v1",
  opponentApiKey: "",
  taskId: "construction-v0",
  seed: 20240520,
}

describe("SetupPanel", () => {
  it("offers the OpenAI 5.6 family at fixed low reasoning effort", async () => {
    const user = userEvent.setup()
    render(<SetupPanel setup={setup} pending={false} onChange={vi.fn()} onSubmit={vi.fn()} />)

    await user.click(screen.getByRole("combobox", { name: "Model" }))
    expect(await screen.findByRole("option", { name: "GPT-5.6 Sol · flagship" })).toBeInTheDocument()
    expect(screen.getByRole("option", { name: "GPT-5.6 Terra · balanced" })).toBeInTheDocument()
    expect(screen.getByRole("option", { name: "GPT-5.6 Luna · fast" })).toBeInTheDocument()
    expect(screen.getByText("OpenAI Responses · reasoning effort fixed to low.")).toBeInTheDocument()
  })
})
