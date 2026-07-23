import { describe, expect, it, vi } from "vitest"
import {
  acknowledgeConversationBinding,
  createConversationSession,
  getConversationSandbox,
  getConversationSession,
  sendConversationMessage,
} from "@/api"

const catalog = {
  gameId: "worldarena-conversational-warehouse-v0",
  protocol: "worldeval-conversation-agent/0.1.0",
  actionProfile: "semantic-warehouse-actions-v1",
  observationProfile: "semantic-warehouse-visible-v1",
  decisionProfile: "dynamic-step-locked-v1",
  scenarios: [{
    scenarioId: "warehouse-pickup-clarification-v0",
    label: "Pick up a box",
    description: "Two visible boxes require an explicit clarification before the agent can move.",
  }],
}

const session = {
  sessionId: "conversation_session_01",
  scenarioId: "warehouse-pickup-clarification-v0",
  status: "clarification_required",
  messages: [
    { messageId: "m_1", role: "user", text: "Pick up that box." },
    { messageId: "m_2", role: "agent", text: "Which blue box do you mean?" },
  ],
  grounding: {
    intentRevision: 1,
    state: "ambiguous",
    taskSummary: "Pick up one of two visible blue boxes.",
    bindings: [
      { bindingId: "box_a", label: "Blue box beside forklift", status: "candidate" },
      { bindingId: "box_b", label: "Blue box by loading bay B", status: "candidate" },
    ],
    clarification: {
      clarificationId: "clarify_box",
      prompt: "Which blue box should I pick up?",
      options: [
        { bindingId: "box_a", label: "The one beside the forklift" },
        { bindingId: "box_b", label: "The one by loading bay B" },
      ],
    },
  },
  constraints: [{
    constraintId: "safe_1",
    label: "Do not pick up an unbound object.",
    kind: "safety",
    state: "active",
  }],
  plan: null,
  receipts: [{ receiptId: "r_1", label: "Movement lease withheld until grounding completes.", state: "neutral_noop" }],
  replay: { state: "not_started", runId: null, verified: false, bundleUrl: null },
  raw_provider_output: "This must be rejected, not merely hidden.",
}

function response(value: unknown) {
  return { ok: true, json: async () => value } as Response
}

describe("Conversational Warehouse public API", () => {
  it("uses the small explicit session/message/acknowledgement contract", async () => {
    const cleanSession = { ...session }
    delete (cleanSession as Record<string, unknown>).raw_provider_output
    const fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      return response(url.endsWith("conversation-sandbox") ? catalog : cleanSession)
    })
    vi.stubGlobal("fetch", fetch)

    await expect(getConversationSandbox()).resolves.toMatchObject({ gameId: catalog.gameId })
    await expect(createConversationSession(catalog.scenarios[0].scenarioId)).resolves.toMatchObject({ sessionId: "conversation_session_01" })
    await expect(getConversationSession("conversation_session_01")).resolves.toMatchObject({ grounding: { state: "ambiguous" } })
    await expect(sendConversationMessage("conversation_session_01", "The one beside the forklift.")).resolves.toMatchObject({ status: "clarification_required" })
    await expect(acknowledgeConversationBinding("conversation_session_01", "clarify_box", "box_a")).resolves.toMatchObject({ sessionId: "conversation_session_01" })

    expect(fetch.mock.calls).toEqual([
      ["/api/worldeval/conversation-sandbox", { cache: "no-store" }],
      ["/api/worldeval/conversation-sandbox/sessions", {
        method: "POST", headers: { "Content-Type": "application/json" }, cache: "no-store",
        body: JSON.stringify({ scenarioId: "warehouse-pickup-clarification-v0" }),
      }],
      ["/api/worldeval/conversation-sandbox/sessions/conversation_session_01", { cache: "no-store" }],
      ["/api/worldeval/conversation-sandbox/sessions/conversation_session_01/messages", {
        method: "POST", headers: { "Content-Type": "application/json" }, cache: "no-store",
        body: JSON.stringify({ text: "The one beside the forklift." }),
      }],
      ["/api/worldeval/conversation-sandbox/sessions/conversation_session_01/acknowledge", {
        method: "POST", headers: { "Content-Type": "application/json" }, cache: "no-store",
        body: JSON.stringify({ clarificationId: "clarify_box", bindingId: "box_a" }),
      }],
    ])
  })

  it("fails closed when a server projection contains private model data", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => response(session)))
    await expect(createConversationSession("warehouse-pickup-clarification-v0")).rejects.toThrow("protected field")
  })

  it("requires an explicit acknowledgement for an ambiguous grounding", async () => {
    const missingClarification = {
      ...session,
      grounding: { ...session.grounding, clarification: null },
    }
    delete (missingClarification as Record<string, unknown>).raw_provider_output
    vi.stubGlobal("fetch", vi.fn(async () => response(missingClarification)))
    await expect(createConversationSession("warehouse-pickup-clarification-v0")).rejects.toThrow("clarification")
  })
})
