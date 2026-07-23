import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { afterEach, describe, expect, it, vi } from "vitest"
import { ConversationSandboxWorkspace } from "@/components/conversation-sandbox-workspace"

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

const waiting = {
  sessionId: "conversation_session_01",
  scenarioId: "warehouse-pickup-clarification-v0",
  status: "awaiting_message",
  messages: [],
  grounding: { intentRevision: 0, state: "unbound", taskSummary: null, bindings: [], clarification: null },
  constraints: [], plan: null, receipts: [],
  replay: { state: "not_started", runId: null, verified: false, bundleUrl: null },
}

const ambiguous = {
  ...waiting,
  status: "clarification_required",
  messages: [{ messageId: "m_1", role: "agent", text: "Which blue box do you mean?" }],
  grounding: {
    intentRevision: 1,
    state: "ambiguous",
    taskSummary: "Pick up one of two visible blue boxes.",
    bindings: [{ bindingId: "box_a", label: "Blue box beside forklift", status: "candidate" }],
    clarification: {
      clarificationId: "clarify_box",
      prompt: "Which blue box should I pick up?",
      options: [{ bindingId: "box_a", label: "The one beside the forklift" }],
    },
  },
  constraints: [{ constraintId: "safe_1", label: "Do not pick up an unbound object.", kind: "safety", state: "active" }],
  receipts: [{ receiptId: "r_1", label: "Movement lease withheld until grounding completes.", state: "neutral_noop" }],
}

function response(value: unknown) { return { ok: true, json: async () => value } as Response }

function renderWorkspace() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  render(<QueryClientProvider client={queryClient}><ConversationSandboxWorkspace /></QueryClientProvider>)
}

describe("Conversational Warehouse workspace", () => {
  afterEach(() => vi.unstubAllGlobals())

  it("grounds chat through an explicit clarification before showing execution", async () => {
    let postedMessage = false
    const fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      void init
      const url = String(input)
      if (url.endsWith("conversation-sandbox")) return response(catalog)
      if (url.endsWith("/messages")) { postedMessage = true; return response(ambiguous) }
      if (url.endsWith("/acknowledge")) return response({
        ...ambiguous,
        status: "executing",
        grounding: { ...ambiguous.grounding, state: "bound", clarification: null },
        plan: { planId: "plan_1", status: "leased", steps: [{ stepId: "pick", label: "Pick up the selected box", state: "active" }] },
      })
      return response(postedMessage ? ambiguous : waiting)
    })
    vi.stubGlobal("fetch", fetch)
    const user = userEvent.setup()
    renderWorkspace()

    await user.click(await screen.findByRole("button", { name: "Open session" }))
    const textarea = await screen.findByRole("textbox", { name: "Tell the agent what to do" })
    await user.type(textarea, "Pick up that box.")
    await user.click(screen.getByRole("button", { name: "Send task" }))
    expect(await screen.findByText("Which blue box should I pick up?")).toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: /The one beside the forklift/ }))
    await waitFor(() => expect(screen.getByText("Pick up the selected box")).toBeInTheDocument())

    expect(fetch.mock.calls.some(([, init]) => (init as RequestInit | undefined)?.body === JSON.stringify({ text: "Pick up that box." }))).toBe(true)
    expect(fetch.mock.calls.some(([, init]) => (init as RequestInit | undefined)?.body === JSON.stringify({ clarificationId: "clarify_box", bindingId: "box_a" }))).toBe(true)
  })
})
