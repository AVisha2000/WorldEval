import { useState } from "react"
import type { FormEvent } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import {
  CheckCircle2Icon,
  CircleAlertIcon,
  MessageCircleIcon,
  SendIcon,
  ShieldCheckIcon,
  SparklesIcon,
} from "lucide-react"
import {
  acknowledgeConversationBinding,
  createConversationSession,
  getConversationSandbox,
  getConversationSession,
  sendConversationMessage,
  type ConversationSessionView,
} from "@/api"
import { Button } from "@/components/ui/button"

const DEFAULT_SCENARIO_ID = "warehouse-pickup-clarification-v0"

export function ConversationSandboxWorkspace() {
  const queryClient = useQueryClient()
  const [selectedScenarioId, setSelectedScenarioId] = useState(DEFAULT_SCENARIO_ID)
  const [sessionId, setSessionId] = useState<string | null>(null)
  const catalog = useQuery({
    queryKey: ["conversation-sandbox"],
    queryFn: getConversationSandbox,
    staleTime: 60 * 60 * 1000,
    retry: false,
  })
  const session = useQuery({
    queryKey: ["conversation-sandbox", "session", sessionId],
    queryFn: () => getConversationSession(sessionId!),
    enabled: sessionId !== null,
    refetchInterval: (query) => {
      const status = query.state.data?.status
      return status === "planning" || status === "executing" ? 1500 : false
    },
    retry: false,
  })
  const saveSession = (next: ConversationSessionView) => {
    setSessionId(next.sessionId)
    queryClient.setQueryData(["conversation-sandbox", "session", next.sessionId], next)
  }
  const create = useMutation({
    mutationFn: createConversationSession,
    onSuccess: saveSession,
  })
  const send = useMutation({
    mutationFn: ({ activeSessionId, text }: { activeSessionId: string; text: string }) =>
      sendConversationMessage(activeSessionId, text),
    onSuccess: saveSession,
  })
  const acknowledge = useMutation({
    mutationFn: ({ activeSessionId, clarificationId, bindingId }: {
      activeSessionId: string
      clarificationId: string
      bindingId: string
    }) => acknowledgeConversationBinding(activeSessionId, clarificationId, bindingId),
    onSuccess: saveSession,
  })
  const selectedScenario = catalog.data?.scenarios.find(
    (scenario) => scenario.scenarioId === selectedScenarioId
  ) ?? catalog.data?.scenarios[0]
  const activeSession = session.data ?? create.data

  return (
    <section className="episode-workspace conversation-sandbox" aria-label="Conversational Warehouse">
      <header className="conversation-sandbox-header">
        <div>
          <p className="eyebrow">Human language → grounded task → visible plan</p>
          <h2>Conversational Warehouse</h2>
          <p>
            Give the agent a task in plain language. It grounds the objects before
            Godot receives a bounded, replayable action plan.
          </p>
        </div>
        <ReplayStatus session={activeSession} />
      </header>

      {catalog.isError ? (
        <p role="alert" className="error-banner">
          The Conversational Warehouse public contract is unavailable or failed validation.
        </p>
      ) : null}
      {create.isError || send.isError || acknowledge.isError || session.isError ? (
        <p role="alert" className="error-banner">
          The authoritative session could not accept that request. Nothing was silently continued.
        </p>
      ) : null}

      <div className="conversation-protocol-strip" aria-label="Conversational protocol identity">
        <span><small>Game</small><code>{catalog.data?.gameId ?? "Loading…"}</code></span>
        <span><small>Protocol</small><code>{catalog.data?.protocol ?? "Loading…"}</code></span>
        <span><small>Actions</small><code>{catalog.data?.actionProfile ?? "Loading…"}</code></span>
        <span><small>Tempo</small><code>{catalog.data?.decisionProfile ?? "Loading…"}</code></span>
      </div>

      <section className="conversation-session-picker" aria-labelledby="warehouse-session-title">
        <div>
          <p className="eyebrow">Deterministic conversation fixture</p>
          <h3 id="warehouse-session-title">Open a warehouse session</h3>
        </div>
        <div className="conversation-session-actions">
          <select
            aria-label="Warehouse scenario"
            value={selectedScenario?.scenarioId ?? selectedScenarioId}
            onChange={(event) => {
              setSelectedScenarioId(event.target.value)
              setSessionId(null)
              create.reset()
            }}
            disabled={!catalog.data || create.isPending}
          >
            {catalog.data?.scenarios.map((scenario) => (
              <option key={scenario.scenarioId} value={scenario.scenarioId}>{scenario.label}</option>
            ))}
          </select>
          <Button
            type="button"
            disabled={!selectedScenario || create.isPending}
            onClick={() => selectedScenario && create.mutate(selectedScenario.scenarioId)}
          >
            <SparklesIcon data-icon="inline-start" />
            {create.isPending ? "Opening…" : activeSession ? "New session" : "Open session"}
          </Button>
        </div>
        <p>{selectedScenario?.description ?? "Loading public warehouse scenarios…"}</p>
      </section>

      {activeSession ? (
        <ConversationSession
          session={activeSession}
          pending={send.isPending || acknowledge.isPending}
          onSend={(text) => send.mutate({ activeSessionId: activeSession.sessionId, text })}
          onAcknowledge={(clarificationId, bindingId) =>
            acknowledge.mutate({
              activeSessionId: activeSession.sessionId,
              clarificationId,
              bindingId,
            })
          }
        />
      ) : (
        <div className="conversation-empty-state">
          <MessageCircleIcon aria-hidden="true" />
          <div>
            <h3>No conversational task yet</h3>
            <p>Open a session, then try “Pick up that box and take it to loading bay B.”</p>
          </div>
        </div>
      )}
    </section>
  )
}

function ConversationSession({
  session,
  pending,
  onSend,
  onAcknowledge,
}: {
  session: ConversationSessionView
  pending: boolean
  onSend: (text: string) => void
  onAcknowledge: (clarificationId: string, bindingId: string) => void
}) {
  const [draft, setDraft] = useState("")
  const clarification = session.grounding.clarification
  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const text = draft.trim()
    if (!text || pending) return
    onSend(text)
    setDraft("")
  }
  return (
    <div className="conversation-layout">
      <section className="conversation-chat" aria-label="Task conversation">
        <header>
          <div><p className="eyebrow">Authoritative chat status</p><h3>{formatConversationStatus(session.status)}</h3></div>
          <code>{session.sessionId}</code>
        </header>
        <ol className="conversation-message-list" aria-live="polite">
          {session.messages.map((message) => (
            <li key={message.messageId} data-role={message.role}>
              <span>{message.role === "user" ? "You" : message.role === "agent" ? "Agent" : "World"}</span>
              <p>{message.text}</p>
            </li>
          ))}
        </ol>
        {clarification ? (
          <aside className="conversation-clarification" aria-label="Clarification required">
            <CircleAlertIcon aria-hidden="true" />
            <div>
              <strong>{clarification.prompt}</strong>
              <div className="conversation-clarification-options">
                {clarification.options.map((option) => (
                  <Button
                    key={option.bindingId}
                    type="button"
                    variant="outline"
                    disabled={pending}
                    onClick={() => onAcknowledge(clarification.clarificationId, option.bindingId)}
                  >
                    <span>{option.label}</span>
                    {option.detail ? <small>{option.detail}</small> : null}
                  </Button>
                ))}
              </div>
            </div>
          </aside>
        ) : null}
        <form className="conversation-composer" onSubmit={submit}>
          <label htmlFor="conversation-command">Tell the agent what to do</label>
          <div>
            <textarea
              id="conversation-command"
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
              disabled={pending || session.status === "completed" || session.status === "failed"}
              maxLength={2000}
              placeholder="Pick up that box and take it to loading bay B."
              rows={3}
            />
            <Button type="submit" disabled={!draft.trim() || pending || session.status === "completed" || session.status === "failed"}>
              <SendIcon data-icon="inline-start" />{pending ? "Sending…" : "Send task"}
            </Button>
          </div>
          <p>Messages become a task proposal, never direct controller code.</p>
        </form>
      </section>
      <aside className="conversation-inspector" aria-label="Grounding and execution inspector">
        <GroundingCard session={session} />
        <ConstraintCard session={session} />
        <PlanCard session={session} />
        <ReceiptCard session={session} />
      </aside>
    </div>
  )
}

function GroundingCard({ session }: { session: ConversationSessionView }) {
  return <article className="conversation-inspector-card">
    <p className="eyebrow">Grounding · revision {session.grounding.intentRevision}</p>
    <h3>{formatGroundingState(session.grounding.state)}</h3>
    <p>{session.grounding.taskSummary ?? "No task has been grounded yet."}</p>
    <ul className="conversation-binding-list">
      {session.grounding.bindings.map((binding) => <li key={binding.bindingId} data-state={binding.status}>
        <span>{binding.label}</span><small>{binding.status.replaceAll("_", " ")}</small>
        {binding.detail ? <p>{binding.detail}</p> : null}
      </li>)}
    </ul>
  </article>
}

function ConstraintCard({ session }: { session: ConversationSessionView }) {
  return <article className="conversation-inspector-card">
    <p className="eyebrow">Active intent constraints</p>
    <ul className="conversation-constraint-list">
      {session.constraints.length ? session.constraints.map((constraint) => <li key={constraint.constraintId} data-kind={constraint.kind} data-state={constraint.state}>
        <span>{constraint.label}</span><small>{constraint.kind} · {constraint.state}</small>
      </li>) : <li className="conversation-empty-row">Constraints appear after a task is grounded.</li>}
    </ul>
  </article>
}

function PlanCard({ session }: { session: ConversationSessionView }) {
  return <article className="conversation-inspector-card">
    <p className="eyebrow">Visible plan</p>
    <h3>{session.plan ? session.plan.status : "No active plan"}</h3>
    {session.plan ? <ol className="conversation-plan-list">
      {session.plan.steps.map((step) => <li key={step.stepId} data-state={step.state}><i aria-hidden="true" /><span>{step.label}</span><small>{step.state}</small></li>)}
    </ol> : <p>The agent must bind the task before proposing authority actions.</p>}
  </article>
}

function ReceiptCard({ session }: { session: ConversationSessionView }) {
  const latest = session.receipts.slice(-4).reverse()
  return <article className="conversation-inspector-card">
    <p className="eyebrow">Authority receipts</p>
    <ul className="conversation-receipt-list">
      {latest.length ? latest.map((receipt) => <li key={receipt.receiptId} data-state={receipt.state}>
        <small>{receipt.state.replaceAll("_", " ")}</small><span>{receipt.label}</span>
      </li>) : <li className="conversation-empty-row">No action receipt yet.</li>}
    </ul>
  </article>
}

function ReplayStatus({ session }: { session?: ConversationSessionView }) {
  const ready = session?.replay.state === "ready" && session.replay.verified
  return <span className={`status-badge ${ready ? "success" : ""}`} data-testid="conversation-replay-status">
    {ready ? <CheckCircle2Icon /> : <ShieldCheckIcon />}
    {ready ? "Verified replay saved" : session ? session.replay.state.replaceAll("_", " ") : "Ready for a task"}
  </span>
}

function formatConversationStatus(status: ConversationSessionView["status"]): string {
  return status.replaceAll("_", " ")
}

function formatGroundingState(state: ConversationSessionView["grounding"]["state"]): string {
  return state === "ambiguous" ? "Clarification required" : state.replaceAll("_", " ")
}
