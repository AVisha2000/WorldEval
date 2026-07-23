import { describe, expect, it, vi } from "vitest"
import { createPrimitiveSandboxRun, getPrimitiveSandbox } from "@/api"

const catalog = {
  gameId: "worldarena-primitive-sandbox-v0",
  protocol: "worldeval-agent/0.1.0",
  actionProfile: "semantic-grid-actions-v1",
  observationProfile: "semantic-grid-visible-v1",
  decisionProfile: "dynamic-step-locked-v1",
  scenarios: [
    {
      scenarioId: "tree-chop-nominal-v0",
      label: "Nominal",
      objective: "Destroy the tree with the axe.",
    },
    {
      scenarioId: "tree-chop-interrupted-v0",
      label: "Interrupted",
      objective: "Return to base when the target becomes unsafe.",
    },
  ],
}

const run = {
  runId: "sandbox_demo_v0",
  status: "ready",
  scenarioId: "tree-chop-nominal-v0",
  onboarding: { briefing: "Control one worker with semantic actions." },
  objective: { instruction: "Destroy the target tree." },
  grid: {
    width: 30,
    height: 25,
    base: { x: 2, y: 12 },
    agent: { x: 23, y: 12 },
    tree: { x: 23, y: 12 },
  },
  observationSeq: 7,
  tick: 26,
  activeLease: null,
  plan: {
    planId: "tree-v1",
    steps: [{ stepId: "chop", action: "use_tool", status: "completed" }],
  },
  timeline: [
    {
      tick: 26,
      type: "terminal_success",
      label: "The target tree was destroyed.",
    },
  ],
  evaluation: { objectiveOutcome: "tree_destroyed", providerCalls: 0 },
  replay: {
    verified: true,
    bundleUrl: "/api/worldeval/replays/sandbox_demo_v0",
    primaryUrl: "/api/worldeval/replays/sandbox_demo_v0/files/primary",
  },
  raw_output:
    "This extra server field must not survive the allow-listed projection.",
}

function response(value: unknown) {
  return { ok: true, json: async () => value } as Response
}

describe("Primitive Sandbox public API", () => {
  it("loads the catalog and posts only the selected scenario identifier", async () => {
    const fetch = vi.fn(
      async (input: RequestInfo | URL, init?: RequestInit) => {
        void input
        return response(init?.method === "POST" ? run : catalog)
      }
    )
    vi.stubGlobal("fetch", fetch)

    await expect(getPrimitiveSandbox()).resolves.toMatchObject({
      gameId: "worldarena-primitive-sandbox-v0",
      scenarios: [
        { scenarioId: "tree-chop-nominal-v0" },
        { scenarioId: "tree-chop-interrupted-v0" },
      ],
    })
    const result = await createPrimitiveSandboxRun("tree-chop-nominal-v0")
    expect(result).toMatchObject({
      runId: "sandbox_demo_v0",
      grid: { width: 30, height: 25, base: { x: 2, y: 12 } },
      replay: { verified: true },
    })
    expect(JSON.stringify(result)).not.toContain("raw_output")
    expect(fetch.mock.calls).toEqual([
      ["/api/worldeval/sandbox", { cache: "no-store" }],
      [
        "/api/worldeval/sandbox/runs",
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          cache: "no-store",
          body: JSON.stringify({ scenarioId: "tree-chop-nominal-v0" }),
        },
      ],
    ])
  })

  it("fails closed on protected nested fields and unsafe replay paths", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        response({
          ...run,
          onboarding: { ...run.onboarding, prompt: "hidden provider text" },
        })
      )
    )
    await expect(
      createPrimitiveSandboxRun("tree-chop-nominal-v0")
    ).rejects.toThrow("protected field")

    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        response({
          ...run,
          replay: {
            ...run.replay,
            primaryUrl: "/api/worldeval/replays/../protected",
          },
        })
      )
    )
    await expect(
      createPrimitiveSandboxRun("tree-chop-nominal-v0")
    ).rejects.toThrow("invalid")
  })

  it("accepts the locked onboarding schema's legitimate argument nesting", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        response({
          ...run,
          onboarding: {
            action_catalog: {
              actions: [
                {
                  argument_schema: {
                    properties: {
                      target: {
                        oneOf: [
                          {
                            properties: {
                              position: {
                                properties: { x: { type: "integer" } },
                              },
                            },
                          },
                        ],
                      },
                    },
                  },
                },
              ],
            },
          },
        })
      )
    )

    await expect(
      createPrimitiveSandboxRun("tree-chop-nominal-v0")
    ).resolves.toMatchObject({ replay: { verified: true } })
  })
})
