import { ClapperboardIcon, KeyRoundIcon, PlayIcon } from "lucide-react"
import {
  isScriptedDemoTask,
  type EpisodeSetup,
  type OpponentProvider,
  type Provider,
  type ScriptedDemoTaskId,
} from "@/api"
import { OPENAI_MODELS, PROVIDER_MODELS } from "@/data"
import { Button } from "@/components/ui/button"
import { Field, FieldDescription, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"

type Props = { setup: EpisodeSetup; pending: boolean; onChange: (next: EpisodeSetup) => void; onSubmit: () => void }
const tasks: readonly [ScriptedDemoTaskId, string][] = [
  ["orientation-v0", "Stage A Orientation"],
  ["interaction-v0", "Stage B Interaction"],
  ["construction-v0", "Stage C Construction"],
  ["neutral-encounter-v0", "Stage D Neutral Encounter"],
]
const scriptedDemoDescriptions: Record<ScriptedDemoTaskId, string> = {
  "orientation-v0": "Turn toward the marked landmark and reach the visible heading goal.",
  "interaction-v0": "Approach the marked resource, gather it, then return it to the relay.",
  "construction-v0": "Gather materials, deliver them to the relay, and build the visible barricade.",
  "neutral-encounter-v0": "Handle the visible neutral encounter and activate the defended relay.",
}

export function SetupPanel({ setup, pending, onChange, onSubmit }: Props) {
  const isScriptedDemo = setup.controllerMode === "scripted_demo"
  const selectScriptedDemo = () => onChange({
    ...setup,
    controllerMode: "scripted_demo",
    mode: "solo",
    taskId: isScriptedDemoTask(setup.taskId) ? setup.taskId : "construction-v0",
    apiKey: "",
    opponentApiKey: "",
  })
  const selectLiveProvider = () => onChange({ ...setup, controllerMode: "live_provider" })
  const setProvider = (provider: Provider) => onChange({ ...setup, provider, model: PROVIDER_MODELS[provider] })
  const setOpponentProvider = (opponentProvider: OpponentProvider) => onChange({
    ...setup,
    opponentProvider,
    opponentModel: opponentProvider === "scripted" ? "balanced-v1" : PROVIDER_MODELS[opponentProvider],
    opponentApiKey: opponentProvider === "scripted" ? "" : setup.opponentApiKey,
  })
  const modelField = (
    id: string,
    label: string,
    provider: Provider,
    model: string,
    setModel: (model: string) => void,
  ) => <Field>
    <FieldLabel htmlFor={id}>{label}</FieldLabel>
    {provider === "openai" ? <>
      <Select value={model} onValueChange={(value) => value && setModel(value)}>
        <SelectTrigger id={id} className="w-full"><SelectValue /></SelectTrigger>
        <SelectContent><SelectGroup>{OPENAI_MODELS.map((option) => <SelectItem key={option.value} value={option.value}>{option.label}</SelectItem>)}</SelectGroup></SelectContent>
      </Select>
      <FieldDescription>OpenAI Responses · reasoning effort fixed to low.</FieldDescription>
    </> : <Input id={id} value={model} onChange={(event) => setModel(event.target.value)} />}
  </Field>
  const taskField = (description?: string) => <Field>
    <FieldLabel htmlFor="task">Task</FieldLabel>
    <Select value={setup.taskId} onValueChange={(value) => value && onChange({ ...setup, taskId: value })}>
      <SelectTrigger id="task" className="w-full"><SelectValue /></SelectTrigger>
      <SelectContent><SelectGroup>{tasks.map(([value, label]) => <SelectItem key={value} value={value}>{label}</SelectItem>)}</SelectGroup></SelectContent>
    </Select>
    {description ? <FieldDescription className="scripted-demo-task">{description} The script is deterministic and consumes only participant-visible observations.</FieldDescription> : null}
  </Field>
  return <aside className="setup-panel" aria-label="Episode setup">
    <h2 className="section-title">Setup</h2>
    <FieldGroup>
      <Field>
        <FieldLabel id="controller-mode-label">Controller</FieldLabel>
        <div className="controller-mode" role="radiogroup" aria-labelledby="controller-mode-label">
          <Button type="button" variant={isScriptedDemo ? "default" : "outline"} aria-checked={isScriptedDemo} role="radio" onClick={selectScriptedDemo}>
            <ClapperboardIcon />Scripted demo
          </Button>
          <Button type="button" variant={isScriptedDemo ? "outline" : "default"} aria-checked={!isScriptedDemo} role="radio" onClick={selectLiveProvider}>
            <KeyRoundIcon />Live provider
          </Button>
        </div>
        <FieldDescription>{isScriptedDemo
          ? "Credential-free, deterministic hybrid solo demos for Stages A–D. Choose a task below; no model call is made."
          : "Use a session-only provider key. The API requests a validated JSON action or Construction task plan."}</FieldDescription>
      </Field>
      {isScriptedDemo ? <>
        <Field><FieldLabel htmlFor="scripted-run-mode">Workflow</FieldLabel><Select value="solo" disabled><SelectTrigger id="scripted-run-mode" className="w-full"><SelectValue /></SelectTrigger><SelectContent><SelectGroup><SelectItem value="solo">Hybrid solo curriculum</SelectItem></SelectGroup></SelectContent></Select><FieldDescription>Scripted demos are available for the solo curriculum only.</FieldDescription></Field>
        {taskField(scriptedDemoDescriptions[isScriptedDemoTask(setup.taskId) ? setup.taskId : "construction-v0"])}
      </> : <>
        <Field><FieldLabel htmlFor="run-mode">Workflow</FieldLabel><Select value={setup.mode} onValueChange={(value) => onChange({ ...setup, mode: value as "solo" | "duel" })}><SelectTrigger id="run-mode" className="w-full"><SelectValue /></SelectTrigger><SelectContent><SelectGroup><SelectItem value="solo">Hybrid solo curriculum</SelectItem><SelectItem value="duel">Symmetric two-leg 1v1</SelectItem></SelectGroup></SelectContent></Select></Field>
        <Field><FieldLabel htmlFor="provider">Provider</FieldLabel><Select value={setup.provider} onValueChange={(value) => setProvider(value as Provider)}><SelectTrigger id="provider" className="w-full"><SelectValue /></SelectTrigger><SelectContent><SelectGroup><SelectItem value="openai">OpenAI</SelectItem><SelectItem value="anthropic">Anthropic</SelectItem><SelectItem value="gemini">Gemini</SelectItem></SelectGroup></SelectContent></Select></Field>
        {modelField("model", "Model", setup.provider, setup.model, (model) => onChange({ ...setup, model }))}
        <Field><FieldLabel htmlFor="api-key">API key</FieldLabel><Input id="api-key" type="password" autoComplete="off" value={setup.apiKey} onChange={(event) => onChange({ ...setup, apiKey: event.target.value })} /><FieldDescription className="credential-note"><KeyRoundIcon /> Held in backend memory for this session only</FieldDescription></Field>
        {setup.mode === "solo" ? taskField() : <>
          <Field><FieldLabel htmlFor="opponent-provider">Opponent controller</FieldLabel><Select value={setup.opponentProvider} onValueChange={(value) => setOpponentProvider(value as OpponentProvider)}><SelectTrigger id="opponent-provider" className="w-full"><SelectValue /></SelectTrigger><SelectContent><SelectGroup><SelectItem value="scripted">Scripted baseline</SelectItem><SelectItem value="openai">OpenAI</SelectItem><SelectItem value="anthropic">Anthropic</SelectItem><SelectItem value="gemini">Gemini</SelectItem></SelectGroup></SelectContent></Select></Field>
          {setup.opponentProvider === "scripted" ? <Field><FieldLabel htmlFor="opponent-model">Scripted tier</FieldLabel><Select value={setup.opponentModel} onValueChange={(opponentModel) => opponentModel && onChange({ ...setup, opponentModel })}><SelectTrigger id="opponent-model" className="w-full"><SelectValue /></SelectTrigger><SelectContent><SelectGroup><SelectItem value="scout-v1">Scout</SelectItem><SelectItem value="balanced-v1">Balanced</SelectItem><SelectItem value="challenger-v1">Challenger</SelectItem></SelectGroup></SelectContent></Select><FieldDescription>Deterministic and credential-free; consumes only participant-visible observations.</FieldDescription></Field> : <>
            {modelField("opponent-model", "Opponent model", setup.opponentProvider, setup.opponentModel, (opponentModel) => onChange({ ...setup, opponentModel }))}
            <Field><FieldLabel htmlFor="opponent-key">Opponent API key</FieldLabel><Input id="opponent-key" type="password" autoComplete="off" value={setup.opponentApiKey} onChange={(event) => onChange({ ...setup, opponentApiKey: event.target.value })} /></Field>
          </>}
          <Field><FieldLabel>Live-call safety limit</FieldLabel><FieldDescription>The backend stops before exceeding {setup.opponentProvider === "scripted" ? "360" : "720"} paid provider calls. Use Cancel run to stop sooner.</FieldDescription></Field>
        </>}
      </>}
      <Field><FieldLabel htmlFor="seed">Seed</FieldLabel><Input id="seed" inputMode="numeric" value={setup.seed} onChange={(event) => onChange({ ...setup, seed: Number(event.target.value) || 0 })} /><FieldDescription>Integer seed for deterministic authority.</FieldDescription></Field>
    </FieldGroup>
    <Button size="lg" disabled={pending || (!isScriptedDemo && (!setup.apiKey || (setup.mode === "duel" && setup.opponentProvider !== "scripted" && !setup.opponentApiKey)))} onClick={onSubmit} className="start-button"><PlayIcon data-icon="inline-start" />{pending ? "Starting…" : isScriptedDemo ? "Start scripted demo" : setup.mode === "duel" ? "Start two-leg series" : "Start episode"}</Button>
  </aside>
}
