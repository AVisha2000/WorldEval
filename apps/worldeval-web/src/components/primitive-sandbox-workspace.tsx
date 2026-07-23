import { memo, useState } from "react"
import { useMutation, useQuery } from "@tanstack/react-query"
import {
  CheckCircle2Icon,
  CircleAlertIcon,
  DownloadIcon,
  MapIcon,
  PlayIcon,
  RouteIcon,
  ShieldCheckIcon,
} from "lucide-react"
import {
  createPrimitiveSandboxRun,
  getPrimitiveSandbox,
  type PrimitiveSandboxPoint,
  type PrimitiveSandboxRunView,
  type PublicJsonValue,
} from "@/api"
import { Button } from "@/components/ui/button"

type Props = { view: string }
type PublicRecord = { [key: string]: PublicJsonValue }

const DEFAULT_SCENARIO_ID = "tree-chop-interrupted-v0"

export function PrimitiveSandboxWorkspace({ view }: Props) {
  const [selectedScenarioId, setSelectedScenarioId] =
    useState(DEFAULT_SCENARIO_ID)
  const catalog = useQuery({
    queryKey: ["primitive-sandbox"],
    queryFn: getPrimitiveSandbox,
    staleTime: 60 * 60 * 1000,
    retry: false,
  })
  const run = useMutation({ mutationFn: createPrimitiveSandboxRun })
  const selectedScenario =
    catalog.data?.scenarios.find(
      (scenario) => scenario.scenarioId === selectedScenarioId
    ) ?? catalog.data?.scenarios[0]
  const result = run.data
  const evidenceComplete = result?.status === "ready" && result.replay.verified

  const selectScenario = (scenarioId: string) => {
    setSelectedScenarioId(scenarioId)
    run.reset()
  }

  return (
    <section
      className="episode-workspace primitive-sandbox"
      aria-label="WorldArena Primitive Sandbox"
    >
      <header className="primitive-sandbox-header">
        <div>
          <p className="eyebrow">
            Reusable agent-action protocol · deterministic authority
          </p>
          <h2>Primitive Sandbox</h2>
          <p>
            Inspect exactly what the agent knows, then watch bounded plans stop
            for material world changes instead of silently continuing.
          </p>
        </div>
        <span
          className={`status-badge ${evidenceComplete ? "success" : ""}`}
          data-testid="sandbox-completion-status"
        >
          {evidenceComplete
            ? "Verified replay saved"
            : run.isPending
              ? "Running authority"
              : result
                ? "Replay verification pending"
                : "Ready to run"}
        </span>
      </header>

      {catalog.isError ? (
        <p role="alert" className="error-banner">
          The Primitive Sandbox manifest is unavailable or failed
          public-contract validation.
        </p>
      ) : null}
      {run.isError ? (
        <p role="alert" className="error-banner">
          The sandbox run was not accepted. No completion is recorded without a
          verified replay.
        </p>
      ) : null}

      <div
        className="sandbox-protocol-strip"
        aria-label="Primitive Sandbox protocol identity"
      >
        <span>
          <small>Game</small>
          <code>{catalog.data?.gameId ?? "Loading…"}</code>
        </span>
        <span>
          <small>Protocol</small>
          <code>{catalog.data?.protocol ?? "Loading…"}</code>
        </span>
        <span>
          <small>Actions</small>
          <code>{catalog.data?.actionProfile ?? "Loading…"}</code>
        </span>
        <span>
          <small>Decision tempo</small>
          <code>{catalog.data?.decisionProfile ?? "Loading…"}</code>
        </span>
      </div>

      <section
        className="sandbox-scenario-picker"
        aria-labelledby="sandbox-scenarios-title"
      >
        <div className="sandbox-section-heading">
          <div>
            <p className="eyebrow">Scenario contract</p>
            <h3 id="sandbox-scenarios-title">Choose the decision pressure</h3>
          </div>
          <Button
            type="button"
            disabled={!selectedScenario || run.isPending}
            onClick={() =>
              selectedScenario && run.mutate(selectedScenario.scenarioId)
            }
          >
            <PlayIcon data-icon="inline-start" />
            {run.isPending ? "Running…" : "Run deterministic scenario"}
          </Button>
        </div>
        <div className="sandbox-scenario-options">
          {catalog.data?.scenarios.map((scenario) => (
            <button
              type="button"
              key={scenario.scenarioId}
              aria-pressed={
                selectedScenario?.scenarioId === scenario.scenarioId
              }
              onClick={() => selectScenario(scenario.scenarioId)}
            >
              <span>{scenario.label}</span>
              <small>{scenario.objective}</small>
              <code>{scenario.scenarioId}</code>
            </button>
          )) ?? <p className="muted-copy">Loading the two locked scenarios…</p>}
        </div>
      </section>

      {result ? (
        <SandboxView view={view} run={result} complete={evidenceComplete} />
      ) : (
        <div className="sandbox-empty-state">
          <RouteIcon aria-hidden="true" />
          <div>
            <h3>No authority run selected</h3>
            <p>
              Run nominal traversal or the barrier-and-hostile interruption. The
              workspace reports completion only after its replay bundle verifies
              offline.
            </p>
          </div>
        </div>
      )}
    </section>
  )
}

function SandboxView({
  view,
  run,
  complete,
}: {
  view: string
  run: PrimitiveSandboxRunView
  complete: boolean
}) {
  if (view === "timeline") return <SandboxTimeline run={run} />
  if (view === "result") return <SandboxResult run={run} complete={complete} />
  if (view === "evaluation") return <SandboxEvaluation run={run} />
  if (view === "replay") return <SandboxReplay run={run} complete={complete} />
  return <SandboxRun run={run} />
}

function SandboxRun({ run }: { run: PrimitiveSandboxRunView }) {
  return (
    <div className="sandbox-run-view">
      <div
        className="sandbox-status-strip"
        aria-label="Current sandbox boundary"
      >
        <span>
          <small>Observation</small>
          <strong>#{run.observationSeq}</strong>
        </span>
        <span>
          <small>Authority tick</small>
          <strong>{run.tick} / 200</strong>
        </span>
        <span>
          <small>Current lease</small>
          <strong>{leaseSummary(run.activeLease)}</strong>
        </span>
        <span>
          <small>Replay</small>
          <strong>
            {run.replay.verified ? "Offline verified" : "Pending"}
          </strong>
        </span>
      </div>

      <div className="sandbox-run-grid">
        <div className="sandbox-world-column">
          <SandboxGrid run={run} />
          <div className="sandbox-contract-grid">
            <PublicContractCard
              eyebrow="Agent onboarding"
              title="What the agent knows at reset"
              value={run.onboarding}
            />
            <PublicContractCard
              eyebrow="Active objective"
              title="Success, safety, and fallback"
              value={run.objective}
            />
          </div>
        </div>
        <SandboxPlan plan={run.plan} />
      </div>
    </div>
  )
}

const SandboxGrid = memo(function SandboxGrid({
  run,
}: {
  run: PrimitiveSandboxRunView
}) {
  const { grid } = run
  return (
    <figure className="sandbox-grid-card">
      <figcaption>
        <div>
          <p className="eyebrow">Player-visible world state</p>
          <h3>
            Semantic grid · {grid.width} × {grid.height}
          </h3>
        </div>
        <MapIcon aria-hidden="true" />
      </figcaption>
      <div className="sandbox-grid-stage">
        <svg
          viewBox={`0 0 ${grid.width} ${grid.height}`}
          role="img"
          aria-label={`30 by 25 semantic grid. Agent at ${coordinate(grid.agent)}, base at ${coordinate(grid.base)}, tree at ${coordinate(grid.tree)}${grid.barrier ? `, barrier at ${coordinate(grid.barrier)}` : ""}${grid.enemy ? `, enemy at ${coordinate(grid.enemy)}` : ""}.`}
          data-grid-width={grid.width}
          data-grid-height={grid.height}
        >
          <defs>
            <pattern
              id="primitive-sandbox-grid"
              width="1"
              height="1"
              patternUnits="userSpaceOnUse"
            >
              <path
                d="M 1 0 L 0 0 0 1"
                fill="none"
                stroke="currentColor"
                strokeWidth="0.035"
              />
            </pattern>
          </defs>
          <rect
            width={grid.width}
            height={grid.height}
            className="sandbox-grid-surface"
          />
          <line
            x1={grid.agent.x + 0.5}
            y1={grid.agent.y + 0.5}
            x2={grid.tree.x + 0.5}
            y2={grid.tree.y + 0.5}
            className="sandbox-target-line"
          />
          <GridMarker kind="base" point={grid.base} />
          <GridMarker kind="tree" point={grid.tree} />
          {grid.barrier ? (
            <GridMarker kind="barrier" point={grid.barrier} />
          ) : null}
          {grid.enemy ? <GridMarker kind="enemy" point={grid.enemy} /> : null}
          <GridMarker kind="agent" point={grid.agent} />
        </svg>
      </div>
      <ul className="sandbox-grid-legend" aria-label="Semantic grid legend">
        <li data-marker="agent">
          <i />
          Agent <code>{coordinate(grid.agent)}</code>
        </li>
        <li data-marker="base">
          <i />
          Base <code>{coordinate(grid.base)}</code>
        </li>
        <li data-marker="tree">
          <i />
          Target tree <code>{coordinate(grid.tree)}</code>
        </li>
        {grid.barrier ? (
          <li data-marker="barrier">
            <i />
            Barrier <code>{coordinate(grid.barrier)}</code>
          </li>
        ) : null}
        {grid.enemy ? (
          <li data-marker="enemy">
            <i />
            Hostile <code>{coordinate(grid.enemy)}</code>
          </li>
        ) : null}
      </ul>
    </figure>
  )
})

function GridMarker({
  kind,
  point,
}: {
  kind: "agent" | "base" | "tree" | "barrier" | "enemy"
  point: PrimitiveSandboxPoint
}) {
  if (kind === "barrier") {
    return (
      <rect
        x={point.x + 0.08}
        y={point.y + 0.08}
        width="0.84"
        height="0.84"
        rx="0.12"
        className="sandbox-marker barrier"
      >
        <title>Barrier at {coordinate(point)}</title>
      </rect>
    )
  }
  if (kind === "enemy") {
    return (
      <path
        d={`M ${point.x + 0.5} ${point.y + 0.06} L ${point.x + 0.94} ${point.y + 0.5} L ${point.x + 0.5} ${point.y + 0.94} L ${point.x + 0.06} ${point.y + 0.5} Z`}
        className="sandbox-marker enemy"
      >
        <title>Hostile at {coordinate(point)}</title>
      </path>
    )
  }
  if (kind === "base") {
    return (
      <rect
        x={point.x + 0.1}
        y={point.y + 0.1}
        width="0.8"
        height="0.8"
        rx="0.16"
        className="sandbox-marker base"
      >
        <title>Base at {coordinate(point)}</title>
      </rect>
    )
  }
  return (
    <circle
      cx={point.x + 0.5}
      cy={point.y + 0.5}
      r={kind === "agent" ? "0.39" : "0.36"}
      className={`sandbox-marker ${kind}`}
    >
      <title>
        {kind === "agent" ? "Agent" : "Target tree"} at {coordinate(point)}
      </title>
    </circle>
  )
}

function PublicContractCard({
  eyebrow,
  title,
  value,
}: {
  eyebrow: string
  title: string
  value: PublicRecord
}) {
  return (
    <article className="sandbox-contract-card">
      <p className="eyebrow">{eyebrow}</p>
      <h3>{title}</h3>
      <dl>
        {Object.entries(value).map(([key, child]) => (
          <div key={key}>
            <dt>{displayKey(key)}</dt>
            <dd>{displayValue(child)}</dd>
          </div>
        ))}
      </dl>
    </article>
  )
}

function SandboxPlan({ plan }: { plan: PublicRecord | null }) {
  const stepValues = plan?.steps ?? plan?.proposedSteps ?? plan?.proposed_steps
  const steps = Array.isArray(stepValues)
    ? stepValues.filter(isPublicRecord)
    : []
  const currentStepId = plan
    ? textValue(plan, "currentStepId", "current_step_id", "activeStepId")
    : null
  return (
    <aside
      className="sandbox-plan-card"
      aria-label="Submitted plan and proposed steps"
    >
      <header>
        <div>
          <p className="eyebrow">Submitted action plan</p>
          <h3>
            {plan
              ? (textValue(plan, "planId", "plan_id") ?? "Validated plan")
              : "No active plan"}
          </h3>
        </div>
        <RouteIcon aria-hidden="true" />
      </header>
      {plan ? (
        <div className="sandbox-plan-meta">
          <span>
            <small>Policy</small>
            <code>
              {textValue(plan, "executionPolicy", "execution_policy") ??
                "confirm_each_boundary"}
            </code>
          </span>
          <span>
            <small>Source observation</small>
            <strong>
              #
              {numberValue(
                plan,
                "sourceObservationSeq",
                "source_observation_seq"
              ) ?? "—"}
            </strong>
          </span>
        </div>
      ) : null}
      {steps.length ? (
        <ol className="sandbox-plan-steps">
          {steps.map((step, index) => {
            const stepId =
              textValue(step, "stepId", "step_id") ?? `step-${index + 1}`
            const actionValue = isPublicRecord(step.action) ? step.action : null
            const action =
              typeof step.action === "string"
                ? step.action
                : actionValue
                  ? textValue(
                      actionValue,
                      "type",
                      "actionId",
                      "action_id",
                      "actionType",
                      "action_type"
                    )
                  : textValue(
                      step,
                      "actionId",
                      "action_id",
                      "actionType",
                      "action_type",
                      "type"
                    )
            const status =
              textValue(step, "status", "state") ??
              (stepId === currentStepId ? "authorized" : "proposed")
            const args = actionValue?.arguments ?? step.arguments ?? step.args
            return (
              <li key={stepId} data-step-status={status}>
                <span>{index + 1}</span>
                <div>
                  <strong>{action ?? "Action"}</strong>
                  <small>{displayValue(args ?? "No arguments")}</small>
                </div>
                <code>{status}</code>
              </li>
            )
          })}
        </ol>
      ) : (
        <p className="muted-copy">
          The terminal boundary has no remaining proposed steps.
        </p>
      )}
      <p className="sandbox-plan-rule">
        <ShieldCheckIcon aria-hidden="true" /> Only the current lease is
        authorized. Silence never continues this plan.
      </p>
    </aside>
  )
}

function SandboxTimeline({ run }: { run: PrimitiveSandboxRunView }) {
  return (
    <section
      className="sandbox-tab-panel"
      aria-label="Primitive Sandbox interrupt and receipt timeline"
    >
      <div className="sandbox-section-heading">
        <div>
          <p className="eyebrow">Decision boundaries</p>
          <h3>Interrupt and receipt timeline</h3>
        </div>
        <span className="sandbox-count">{run.timeline.length} events</span>
      </div>
      <ol className="sandbox-timeline">
        {run.timeline.map((event, index) => {
          const kind =
            textValue(event, "type", "kind", "event") ?? "state update"
          const label =
            textValue(event, "label", "detail", "summary", "receipt") ??
            displayValue(event)
          const tick = numberValue(event, "tick", "atTick", "at_tick")
          return (
            <li key={`${tick ?? "event"}-${index}`} data-event-kind={kind}>
              <span className="sandbox-timeline-node" />
              <time>
                {tick === null ? `Event ${index + 1}` : `Tick ${tick}`}
              </time>
              <div>
                <strong>{displayKey(kind)}</strong>
                <p>{label}</p>
              </div>
            </li>
          )
        })}
      </ol>
    </section>
  )
}

function SandboxResult({
  run,
  complete,
}: {
  run: PrimitiveSandboxRunView
  complete: boolean
}) {
  const outcome =
    textValue(
      run.evaluation,
      "objectiveOutcome",
      "objective_outcome",
      "outcome"
    ) ?? "Terminal boundary reached"
  return (
    <section
      className="sandbox-tab-panel sandbox-result-card"
      aria-label="Primitive Sandbox result"
    >
      <div
        className={`sandbox-result-icon ${complete ? "complete" : "pending"}`}
      >
        {complete ? (
          <CheckCircle2Icon aria-hidden="true" />
        ) : (
          <CircleAlertIcon aria-hidden="true" />
        )}
      </div>
      <p className="eyebrow">Authority result</p>
      <h3>{displayKey(outcome)}</h3>
      <p>
        {complete
          ? "Evidence complete: the terminal replay is sealed, saved, and independently verified with provider calls disabled."
          : "The simulation returned a result, but completion remains withheld until its replay verifies."}
      </p>
      <dl className="sandbox-result-details">
        <div>
          <dt>Run ID</dt>
          <dd>
            <code>{run.runId}</code>
          </dd>
        </div>
        <div>
          <dt>Scenario</dt>
          <dd>
            <code>{run.scenarioId}</code>
          </dd>
        </div>
        <div>
          <dt>Terminal tick</dt>
          <dd>{run.tick}</dd>
        </div>
        <div>
          <dt>Replay gate</dt>
          <dd>{run.replay.verified ? "Passed" : "Not passed"}</dd>
        </div>
      </dl>
    </section>
  )
}

function SandboxEvaluation({ run }: { run: PrimitiveSandboxRunView }) {
  return (
    <section
      className="sandbox-tab-panel"
      aria-label="Primitive Sandbox evaluation"
    >
      <div className="sandbox-section-heading">
        <div>
          <p className="eyebrow">No LLM judge</p>
          <h3>Authority-derived evaluation</h3>
        </div>
        <span className="sandbox-count">Tick {run.tick}</span>
      </div>
      <div className="sandbox-evaluation-grid">
        {Object.entries(run.evaluation).map(([key, value]) => (
          <article key={key}>
            <small>{displayKey(key)}</small>
            <strong>{displayValue(value)}</strong>
          </article>
        ))}
      </div>
    </section>
  )
}

function SandboxReplay({
  run,
  complete,
}: {
  run: PrimitiveSandboxRunView
  complete: boolean
}) {
  return (
    <section
      className="sandbox-tab-panel sandbox-replay-panel"
      aria-label="Primitive Sandbox replay verification"
    >
      <div className="sandbox-section-heading">
        <div>
          <p className="eyebrow">Replay-first transaction</p>
          <h3>Saved replay evidence</h3>
        </div>
        <span
          className={`sandbox-verification ${run.replay.verified ? "verified" : "pending"}`}
        >
          {run.replay.verified ? <CheckCircle2Icon /> : <CircleAlertIcon />}
          {run.replay.verified ? "Offline verified" : "Verification pending"}
        </span>
      </div>
      <p>
        {complete
          ? "This run is complete because its canonical bundle survived offline verification. Media can be regenerated from replay and is not part of this gate."
          : "This run is not complete. A terminal result alone cannot satisfy the evidence gate."}
      </p>
      <div className="sandbox-replay-actions">
        <a
          href={run.replay.bundleUrl}
          download
          aria-label={`Download replay bundle ${run.runId}`}
        >
          <DownloadIcon aria-hidden="true" />
          <span>
            <strong>Replay bundle</strong>
            <small>{run.runId}</small>
          </span>
        </a>
        <a
          href={run.replay.primaryUrl}
          download
          aria-label={`Download primary replay ${run.runId}`}
        >
          <DownloadIcon aria-hidden="true" />
          <span>
            <strong>Primary authority replay</strong>
            <small>Allow-listed public artifact</small>
          </span>
        </a>
      </div>
    </section>
  )
}

function coordinate(point: PrimitiveSandboxPoint): string {
  return `(${point.x}, ${point.y})`
}

function isPublicRecord(
  value: PublicJsonValue | undefined
): value is PublicRecord {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function textValue(record: PublicRecord, ...keys: string[]): string | null {
  for (const key of keys) {
    if (typeof record[key] === "string") return record[key]
  }
  return null
}

function numberValue(record: PublicRecord, ...keys: string[]): number | null {
  for (const key of keys) {
    if (typeof record[key] === "number") return record[key]
  }
  return null
}

function leaseSummary(lease: PublicRecord | null): string {
  if (!lease) return "Closed"
  const remaining = numberValue(
    lease,
    "remainingTicks",
    "remaining_ticks",
    "leaseTicks",
    "lease_ticks",
    "leaseTicksRemaining",
    "lease_ticks_remaining"
  )
  const status = textValue(lease, "status", "state")
  if (remaining !== null) return `${remaining} ticks · ${status ?? "active"}`
  return status ? displayKey(status) : "Boundary open"
}

function displayKey(value: string): string {
  const normalized = value
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replaceAll("_", " ")
    .replaceAll("-", " ")
  return normalized.charAt(0).toUpperCase() + normalized.slice(1)
}

function displayValue(value: PublicJsonValue | undefined): string {
  if (value === undefined || value === null) return "—"
  if (typeof value === "boolean") return value ? "Yes" : "No"
  if (typeof value === "string" || typeof value === "number")
    return String(value)
  if (Array.isArray(value))
    return value.map((child) => displayValue(child)).join(" · ")
  return Object.entries(value)
    .map(([key, child]) => `${displayKey(key)}: ${displayValue(child)}`)
    .join(" · ")
}
