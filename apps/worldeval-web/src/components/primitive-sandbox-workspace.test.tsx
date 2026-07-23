import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import {
  cleanup,
  render,
  screen,
  waitFor,
  within,
} from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { afterEach, describe, expect, it, vi } from "vitest"
import App from "@/App"

const catalog = {
  gameId: "worldarena-primitive-sandbox-v0",
  protocol: "worldeval-agent/0.1.0",
  actionProfile: "semantic-grid-actions-v1",
  observationProfile: "semantic-grid-visible-v1",
  decisionProfile: "dynamic-step-locked-v1",
  scenarios: [
    {
      scenarioId: "tree-chop-nominal-v0",
      label: "Tree chop · nominal",
      objective: "Reach the target tree, equip the axe, and destroy it.",
    },
    {
      scenarioId: "tree-chop-interrupted-v0",
      label: "Tree chop · interrupted",
      objective:
        "Retreat to base when a hostile appears inside the tree safety radius.",
    },
  ],
}

function sandboxRun(verified = true) {
  return {
    runId: "sandbox_interrupted_demo_v0",
    status: "ready",
    scenarioId: "tree-chop-interrupted-v0",
    onboarding: {
      initializationHash: "f".repeat(64),
      humanBriefing: {
        premise: "A deterministic grid world for reusable semantic actions.",
        controlledRole: "One visible worker",
        successModel:
          "Satisfy the objective without delegating strategy to the game.",
      },
      availableActions: ["move_to", "equip", "use_tool", "wait", "cancel"],
    },
    objective: {
      objectiveId: "tree-chop-interrupted-v0",
      instruction:
        "Destroy the tree only while its safety radius is uncontested.",
      safetyConstraints: ["Do not engage a hostile near the target."],
      fallbackOutcome: "Return safely to base with the tree intact.",
    },
    grid: {
      width: 30,
      height: 25,
      base: { x: 2, y: 12 },
      agent: { x: 2, y: 12 },
      tree: { x: 23, y: 12 },
      barrier: { x: 12, y: 12 },
      enemy: { x: 23, y: 12 },
    },
    observationSeq: 8,
    tick: 42,
    activeLease: {
      status: "closed",
      remainingTicks: 0,
      authorizedStepId: null,
    },
    plan: {
      planId: "return-to-base-v1",
      sourceObservationSeq: 7,
      executionPolicy: "confirm_each_boundary",
      currentStepId: "retreat",
      steps: [
        {
          stepId: "retreat",
          action: {
            type: "move_to",
            arguments: {
              coordinate: { x: 2, y: 12 },
              navigation: "direct_only",
            },
          },
          status: "completed",
        },
        {
          stepId: "hold",
          action: "wait",
          arguments: { ticks: 1 },
          status: "proposed",
        },
      ],
    },
    timeline: [
      {
        tick: 0,
        type: "plan_submitted",
        label: "Approach, equip, and chop proposed.",
      },
      {
        tick: 8,
        type: "movement_blocked",
        label: "Direct movement stopped at the new barrier.",
      },
      {
        tick: 9,
        type: "plan_replaced",
        label: "Explicit waypoints route around the barrier.",
      },
      {
        tick: 20,
        type: "hostile_near_target",
        label: "A hostile entered the target safety radius.",
      },
      {
        tick: 21,
        type: "plan_aborted",
        label: "The chop plan was revoked before tool use.",
      },
      {
        tick: 42,
        type: "terminal_success",
        label: "The agent returned to base; the tree remains intact.",
      },
    ],
    evaluation: {
      objectiveOutcome: "safe_retreat",
      validResponseRate: "100%",
      planSuspensions: 2,
      interruptReplacementTicks: 1,
      staleActionAttempts: 0,
      correctToolSelection: true,
      forbiddenGameAutonomyCount: 0,
      correctRetreat: true,
      modelCalls: 8,
      providerCalls: 0,
      replayVerified: verified,
    },
    replay: {
      verified,
      bundleUrl: "/api/worldeval/replays/sandbox_interrupted_demo_v0",
      primaryUrl:
        "/api/worldeval/replays/sandbox_interrupted_demo_v0/files/primary",
    },
  }
}

function response(value: unknown) {
  return { ok: true, json: async () => value } as Response
}

function renderApp(runVerified = true) {
  const fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const route = String(input)
    if (route === "/api/worldeval/sandbox" && init === undefined)
      return response(catalog)
    if (route === "/api/worldeval/sandbox" && init?.cache === "no-store")
      return response(catalog)
    if (route === "/api/worldeval/sandbox/runs" && init?.method === "POST")
      return response(sandboxRun(runVerified))
    throw new Error(`Unexpected request: ${route}`)
  })
  vi.stubGlobal("fetch", fetch)
  const queryClient = new QueryClient({
    defaultOptions: { mutations: { retry: false }, queries: { retry: false } },
  })
  render(
    <QueryClientProvider client={queryClient}>
      <App />
    </QueryClientProvider>
  )
  return fetch
}

describe("Primitive Sandbox Controller Lab", () => {
  afterEach(() => cleanup())

  it("opens from the prominent game card and exposes the full verified decision trail", async () => {
    const user = userEvent.setup()
    const fetch = renderApp()

    const card = screen
      .getByText("/games/primitive-sandbox/")
      .closest("article")
    expect(card).not.toBeNull()
    expect(within(card!).getByText("Protocol lab")).toBeInTheDocument()
    await user.click(
      within(card!).getByRole("button", { name: "Open Primitive Sandbox" })
    )

    const workspace = await screen.findByLabelText(
      "WorldArena Primitive Sandbox"
    )
    expect(
      within(workspace).getByRole("heading", { name: "Primitive Sandbox" })
    ).toBeInTheDocument()
    expect(
      await within(workspace).findByText("worldeval-agent/0.1.0")
    ).toBeInTheDocument()
    expect(
      within(workspace).getByRole("button", { name: /Tree chop · interrupted/ })
    ).toHaveAttribute("aria-pressed", "true")

    await user.click(
      within(workspace).getByRole("button", {
        name: "Run deterministic scenario",
      })
    )
    expect(
      await within(workspace).findByText("Verified replay saved")
    ).toBeInTheDocument()
    expect(
      within(workspace).getByRole("img", { name: /30 by 25 semantic grid/ })
    ).toHaveAttribute("data-grid-width", "30")
    expect(
      within(workspace).getByRole("img", {
        name: /barrier at \(12, 12\).*enemy at \(23, 12\)/i,
      })
    ).toBeInTheDocument()
    expect(
      within(workspace).getByText("What the agent knows at reset")
    ).toBeInTheDocument()
    expect(
      within(workspace).getByLabelText("Submitted plan and proposed steps")
    ).toHaveTextContent("move_to")
    expect(
      within(workspace).getByLabelText("Submitted plan and proposed steps")
    ).toHaveTextContent("proposed")

    const post = fetch.mock.calls.find(([, init]) => init?.method === "POST")
    expect(post?.[0]).toBe("/api/worldeval/sandbox/runs")
    expect(JSON.parse(String(post?.[1]?.body))).toEqual({
      scenarioId: "tree-chop-interrupted-v0",
    })

    await user.click(screen.getByRole("tab", { name: "Timeline" }))
    expect(within(workspace).getByText("Movement blocked")).toBeInTheDocument()
    expect(
      within(workspace).getByText("Hostile near target")
    ).toBeInTheDocument()

    await user.click(screen.getByRole("tab", { name: "Result" }))
    expect(
      within(workspace).getByText(/Evidence complete:/)
    ).toBeInTheDocument()
    expect(within(workspace).getByText("Safe retreat")).toBeInTheDocument()

    await user.click(screen.getByRole("tab", { name: "Evaluation" }))
    expect(
      within(workspace).getByText(/Forbidden Game Autonomy Count/i)
    ).toBeInTheDocument()
    expect(
      within(workspace).getByText(/Valid Response Rate/i)
    ).toBeInTheDocument()

    await user.click(screen.getByRole("tab", { name: "Replay" }))
    expect(
      within(workspace).getByText(
        /canonical bundle survived offline verification/i
      )
    ).toBeInTheDocument()
    expect(
      within(workspace).getByRole("link", { name: /Download replay bundle/ })
    ).toHaveAttribute(
      "href",
      "/api/worldeval/replays/sandbox_interrupted_demo_v0"
    )
    expect(
      within(workspace).getByRole("link", { name: /Download primary replay/ })
    ).toHaveAttribute(
      "href",
      "/api/worldeval/replays/sandbox_interrupted_demo_v0/files/primary"
    )
  })

  it("withholds completion when the replay has not independently verified", async () => {
    const user = userEvent.setup()
    renderApp(false)

    await user.click(
      screen.getByRole("button", { name: "Open Primitive Sandbox" })
    )
    const workspace = await screen.findByLabelText(
      "WorldArena Primitive Sandbox"
    )
    await user.click(
      await within(workspace).findByRole("button", {
        name: "Run deterministic scenario",
      })
    )
    await waitFor(() =>
      expect(
        within(workspace).getByTestId("sandbox-completion-status")
      ).toHaveTextContent("Replay verification pending")
    )
    expect(
      within(workspace).queryByText("Verified replay saved")
    ).not.toBeInTheDocument()

    await user.click(screen.getByRole("tab", { name: "Replay" }))
    expect(
      within(workspace).getByText("Verification pending")
    ).toBeInTheDocument()
    expect(
      within(workspace).getByText(/This run is not complete/)
    ).toBeInTheDocument()
    expect(
      within(workspace).queryByText(
        /canonical bundle survived offline verification/
      )
    ).not.toBeInTheDocument()
  })
})
