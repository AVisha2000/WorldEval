import { cleanup, render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { EpisodeSetup } from "@/api"
import { SetupPanel } from "@/components/setup-panel"

const setup: EpisodeSetup = {
  controllerMode: "live_provider",
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
  afterEach(cleanup)

  it("offers the OpenAI 5.6 family at fixed low reasoning effort", async () => {
    const user = userEvent.setup()
    render(<SetupPanel setup={setup} pending={false} onChange={vi.fn()} onSubmit={vi.fn()} />)

    await user.click(screen.getByRole("combobox", { name: "Model" }))
    expect(await screen.findByRole("option", { name: "GPT-5.6 Sol · flagship" })).toBeInTheDocument()
    expect(screen.getByRole("option", { name: "GPT-5.6 Terra · balanced" })).toBeInTheDocument()
    expect(screen.getByRole("option", { name: "GPT-5.6 Luna · fast" })).toBeInTheDocument()
    expect(screen.getByText("OpenAI Responses · reasoning effort fixed to low.")).toBeInTheDocument()
  })

  it("starts any scripted solo stage without a key and hides provider controls", async () => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    const onSubmit = vi.fn()
    render(<SetupPanel setup={{ ...setup, controllerMode: "scripted_demo", taskId: "orientation-v0" }} pending={false} onChange={onChange} onSubmit={onSubmit} />)

    expect(screen.getByRole("button", { name: "Start scripted demo" })).toBeEnabled()
    expect(screen.queryByLabelText("API key")).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Provider")).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Model")).not.toBeInTheDocument()
    expect(screen.getByRole("combobox", { name: "Workflow" })).toBeDisabled()
    expect(screen.getByText(/Credential-free, deterministic hybrid solo demos/i)).toBeInTheDocument()

    await user.click(screen.getByRole("combobox", { name: "Task" }))
    expect(await screen.findByRole("option", { name: "Stage A Orientation" })).toBeInTheDocument()
    expect(screen.getByRole("option", { name: "Stage B Interaction" })).toBeInTheDocument()
    expect(screen.getByRole("option", { name: "Stage C Construction" })).toBeInTheDocument()
    expect(screen.getByRole("option", { name: "Stage D Neutral Encounter" })).toBeInTheDocument()
    await user.click(screen.getByRole("option", { name: "Stage D Neutral Encounter" }))
    expect(onChange).toHaveBeenCalledWith(expect.objectContaining({ taskId: "neutral-encounter-v0" }))

    await user.click(screen.getByRole("radio", { name: "Live provider" }))
    expect(onChange).toHaveBeenCalledWith(expect.objectContaining({ controllerMode: "live_provider" }))
  })
})
