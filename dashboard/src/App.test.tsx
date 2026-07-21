import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { cleanup, render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import App from "@/App"

function response(value: Record<string, unknown>) {
  return { ok: true, json: async () => value } as Response
}

const readiness = {
  format: "llm-controller/embodiment-readiness-view/1.1.0",
  gates: [
    { id: "offline", label: "Offline certification", passed: true, code: null },
    { id: "approved_mixamo_y_bot", label: "Approved Y Bot", passed: false, code: "evidence_file_invalid" },
    { id: "live_provider_managed_solo", label: "Live providers", passed: false, code: "live_provider_report_missing" },
    { id: "live_model_paired_duel", label: "Live two-model duel", passed: false, code: "live_duel_report_missing" },
    { id: "browser_visual_qa", label: "Browser lifecycle", passed: false, code: "browser_report_missing" },
    { id: "final_native_video", label: "Final native video", passed: false, code: "final_video_missing" },
  ],
  ready_for_promotion: false,
  report_available: true,
  runtime_capabilities: { passed: false, code: "runtime_capabilities_not_released" },
  source_fingerprint: "a".repeat(64),
}

function lifecycleFetch() {
  return vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input)
    if (url.endsWith("/certification/readiness")) return response(readiness)
    if (url.endsWith("/frame")) {
      return new Response(null, { status: 204, headers: { "X-Frame-State": "finished" } })
    }
    if (init?.method === "POST") {
      const series = url.endsWith("/series")
      return response({
        config: {},
        state: "cancelled",
        ...(series ? { series_id: "series_test" } : { episode_id: "ep_test" }),
      })
    }
    if (url.endsWith("/timeline")) return response({ events: [] })
    const series = url.includes("/series/")
    return response({
      config: {},
      result: null,
      state: "cancelled",
      ...(series ? { series_id: "series_test" } : { episode_id: "ep_test" }),
    })
  })
}

function renderApp() {
  const queryClient = new QueryClient({
    defaultOptions: { mutations: { retry: false }, queries: { retry: false } },
  })
  render(<QueryClientProvider client={queryClient}><App /></QueryClientProvider>)
  return queryClient
}

describe("Controller dashboard", () => {
  beforeEach(() => {
    localStorage.clear()
    vi.stubGlobal("fetch", vi.fn(async () => response(readiness)))
    vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:participant-frame")
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined)
  })
  afterEach(() => {
    cleanup()
    document.body.removeAttribute("style")
  })
  it("renders setup and real lifecycle navigation without demo evidence", () => {
    render(<QueryClientProvider client={new QueryClient()}><App /></QueryClientProvider>)
    expect(screen.getByRole("heading", { name: /WorldArena Controller Lab/i })).toBeInTheDocument()
    expect(screen.getByLabelText("API key")).toHaveAttribute("autocomplete", "off")
    expect(screen.getByRole("tab", { name: "Timeline" })).toBeInTheDocument()
    expect(screen.getByRole("tab", { name: "Replay" })).toBeInTheDocument()
    expect(screen.getByText("Configure a hybrid solo episode")).toBeInTheDocument()
  })
  it("renders credential-free certification readiness", async () => {
    renderApp()
    expect(await screen.findByText("1/6 gates verified")).toBeInTheDocument()
    expect(screen.getByText("Offline certification")).toBeInTheDocument()
    expect(screen.getByText("Runtime capabilities remain unreleased")).toBeInTheDocument()
  })
  it("keeps the credential in component state and never browser storage", async () => {
    const user = userEvent.setup()
    render(<QueryClientProvider client={new QueryClient()}><App /></QueryClientProvider>)
    await user.type(screen.getByLabelText("API key"), "secret-session-key")
    expect(screen.getByLabelText("API key")).toHaveValue("secret-session-key")
    expect(JSON.stringify(localStorage)).not.toContain("secret-session-key")
  })

  it("clears a submitted solo credential without retaining it as mutation variables", async () => {
    const user = userEvent.setup()
    const fetch = lifecycleFetch()
    vi.stubGlobal("fetch", fetch)
    const queryClient = renderApp()
    const secret = "solo-session-secret"

    await user.type(screen.getByLabelText("API key"), secret)
    await user.click(screen.getByRole("button", { name: "Start episode" }))

    await waitFor(() => expect(screen.getByLabelText("API key")).toHaveValue(""))
    const post = fetch.mock.calls.find(([, init]) => init?.method === "POST")
    expect(post).toBeDefined()
    expect(JSON.parse(String(post?.[1]?.body))).toMatchObject({
      api_key: secret,
      maximum_episode_ticks: 600,
    })
    const mutations = queryClient.getMutationCache().getAll()
    expect(mutations).toHaveLength(1)
    expect(mutations[0].state.variables).toBeUndefined()
    expect(JSON.stringify(mutations[0].state)).not.toContain(secret)
  })

  it("launches a credential-free scripted opponent without retaining the model key", async () => {
    const user = userEvent.setup()
    const fetch = lifecycleFetch()
    vi.stubGlobal("fetch", fetch)
    const queryClient = renderApp()
    const secret = "duel-session-alpha"

    await user.click(document.getElementById("run-mode")!)
    await user.click(await screen.findByText("Symmetric two-leg 1v1"))
    expect(screen.getByText("Configure a symmetric two-leg series")).toBeInTheDocument()
    expect(screen.getByText(/Scripted opponents require no key/)).toBeInTheDocument()
    expect(screen.getByLabelText("Scripted tier")).toBeInTheDocument()
    expect(screen.queryByLabelText("Opponent API key")).not.toBeInTheDocument()
    await user.type(screen.getByLabelText("API key"), secret)
    await user.click(screen.getByRole("button", { name: "Start two-leg series" }))

    await waitFor(() => {
      expect(screen.getByLabelText("API key")).toHaveValue("")
    })
    const post = fetch.mock.calls.find(([, init]) => init?.method === "POST")
    expect(post).toBeDefined()
    expect(JSON.parse(String(post?.[1]?.body)).entrants).toEqual([
      expect.objectContaining({ provider: "openai", api_key: secret }),
      { provider: "scripted", model: "balanced-v1" },
    ])
    expect(JSON.parse(String(post?.[1]?.body)).max_live_provider_calls).toBe(360)
    const mutations = queryClient.getMutationCache().getAll()
    expect(mutations).toHaveLength(1)
    expect(mutations[0].state.variables).toBeUndefined()
    expect(JSON.stringify(mutations[0].state)).not.toContain(secret)
  })

  it("continues polling after the first running status response", async () => {
    const user = userEvent.setup()
    let statusReads = 0
    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.endsWith("/certification/readiness")) return response(readiness)
      if (url.endsWith("/frame")) {
        return new Response(null, { status: 204, headers: { "X-Frame-State": "finished" } })
      }
      if (init?.method === "POST") {
        return response({
          config: { task_id: "orientation-v0" },
          episode_id: "ep_polling",
          state: "running",
        })
      }
      if (url.endsWith("/timeline")) return response({ events: [] })
      if (url.endsWith("/result")) {
        return response({
          config: { task_id: "orientation-v0" },
          episode_id: "ep_polling",
          result: {
            final_state_hash: "b".repeat(64),
            provider_failures: 0,
            terminal: { outcome: "success" },
            windows: 4,
          },
          state: "completed",
        })
      }
      statusReads += 1
      return response({
        config: { task_id: "orientation-v0" },
        episode_id: "ep_polling",
        state: statusReads === 1 ? "running" : "completed",
      })
    }))
    renderApp()

    await user.type(screen.getByLabelText("API key"), "polling-session-secret")
    await user.click(screen.getByRole("button", { name: "Start episode" }))

    expect(await screen.findByText("● running")).toBeInTheDocument()
    expect(await screen.findByText("● success", {}, { timeout: 2500 })).toBeInTheDocument()
    expect(statusReads).toBeGreaterThanOrEqual(2)
  })

  it("shows the current participant frame and retains a finished player-visible view", async () => {
    const user = userEvent.setup()
    let statusReads = 0
    const framePng = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10])
    const fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.endsWith("/certification/readiness")) return response(readiness)
      if (init?.method === "POST") {
        return response({
          config: { task_id: "orientation-v0" },
          episode_id: "ep_camera",
          state: "running",
        })
      }
      if (url.endsWith("/timeline")) return response({ events: [] })
      if (url.endsWith("/frame")) {
        return new Response(framePng, {
          headers: {
            "Content-Type": "image/png",
            "X-Content-SHA256": "c".repeat(64),
            "X-Frame-State": statusReads > 1 ? "finished" : "live",
            "X-Observation-Seq": statusReads > 1 ? "2" : "1",
          },
        })
      }
      if (url.endsWith("/result")) {
        return response({
          config: { task_id: "orientation-v0" },
          episode_id: "ep_camera",
          result: {
            final_state_hash: "d".repeat(64),
            provider_failures: 0,
            terminal: { outcome: "success" },
            windows: 2,
          },
          state: "completed",
        })
      }
      statusReads += 1
      return response({
        config: { task_id: "orientation-v0" },
        episode_id: "ep_camera",
        state: statusReads > 1 ? "completed" : "running",
      })
    })
    vi.stubGlobal("fetch", fetch)
    renderApp()

    await user.type(screen.getByLabelText("API key"), "camera-session-secret")
    await user.click(screen.getByRole("button", { name: "Start episode" }))

    expect(await screen.findByRole("img", { name: "Active participant Godot camera frame" })).toHaveAttribute(
      "src",
      "blob:participant-frame",
    )
    expect(screen.getByText(/Participant-visible pixels only/)).toBeInTheDocument()
    expect(screen.queryByText("camera-session-secret")).not.toBeInTheDocument()
    expect(await screen.findByText("● success", {}, { timeout: 2500 })).toBeInTheDocument()
    expect(await screen.findByText("Finished")).toBeInTheDocument()
    expect(screen.getByText("Observation 2")).toBeInTheDocument()
  })
})
