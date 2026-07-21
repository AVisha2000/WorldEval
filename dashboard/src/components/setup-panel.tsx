import {
  ArchiveIcon,
  CheckCircle2Icon,
  ChevronRightIcon,
  ClapperboardIcon,
  FolderClosedIcon,
  FolderOpenIcon,
  KeyRoundIcon,
  PlayIcon,
} from "lucide-react"
import {
  DEMO_SCENARIOS,
  DEMO_DUO_GAMES,
  DEMO_TRIO_ENTRANTS,
  DEMO_TRIO_GAMES,
  type DemoDuoGameId,
  type DemoTrioGameId,
  isDemoScenario,
  type DemoScenarioId,
  type EpisodeSetup,
  type OpponentProvider,
  type Provider,
} from "@/api"
import { OPENAI_MODELS, PROVIDER_MODELS } from "@/data"
import { Button } from "@/components/ui/button"
import { Field, FieldDescription, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"

type Props = {
  setup: EpisodeSetup
  pending: boolean
  onChange: (next: EpisodeSetup) => void
  onSubmit: () => void
  onQuickStart: () => void
  onTeamQuickStart: () => void
  onRtsQuickStart: () => void
  onMazeQuickStart: () => void
}
const tasks = [
  ["orientation-v0", "Stage A Orientation"],
  ["interaction-v0", "Stage B Interaction"],
  ["construction-v0", "Stage C Construction"],
  ["neutral-encounter-v0", "Stage D Neutral Encounter"],
] as const
const demoScenarios = Object.entries(DEMO_SCENARIOS) as [
  DemoScenarioId,
  (typeof DEMO_SCENARIOS)[DemoScenarioId],
][]
const demoDuoGames = Object.entries(DEMO_DUO_GAMES) as [
  DemoDuoGameId,
  (typeof DEMO_DUO_GAMES)[DemoDuoGameId],
][]
const demoTrioGames = Object.entries(DEMO_TRIO_GAMES) as [
  DemoTrioGameId,
  (typeof DEMO_TRIO_GAMES)[DemoTrioGameId],
][]
const scriptedDemoDescriptions: Record<DemoScenarioId, string> = {
  "orientation-v0": "Turn toward the marked landmark and reach the visible heading goal.",
  "interaction-v0": "Approach the marked resource, gather it, then return it to the relay.",
  "construction-v0": "Gather materials, deliver them to the relay, and build the visible barricade.",
  "neutral-encounter-v0": "Handle the visible neutral encounter and activate the defended relay.",
  "multi-action-demo-v0": "Watch one continuous run turn, walk, gather, carry, deposit, build, and celebrate.",
  "movement-maze-v0": "Validate walking, turning, reversing, collision handling, and ordered checkpoint navigation.",
  "operator-action-course-v0": "Validate the full operator action vocabulary through a deterministic authority-backed course.",
}

const labyrinthEntrants = [
  { name: "Sol", model: "demo-sol-v1", tone: "sol" },
  { name: "Terra", model: "demo-terra-v1", tone: "terra" },
  { name: "Luna", model: "demo-luna-v1", tone: "luna" },
] as const

type DemoLibraryProps = Pick<Props, "pending" | "onQuickStart" | "onTeamQuickStart" | "onRtsQuickStart" | "onMazeQuickStart"> & {
  mode: EpisodeSetup["mode"]
  onSelectMode: (mode: EpisodeSetup["mode"]) => void
}

function DemoLibrary({
  mode,
  pending,
  onMazeQuickStart,
  onQuickStart,
  onRtsQuickStart,
  onSelectMode,
  onTeamQuickStart,
}: DemoLibraryProps) {
  return (
    <section className="demo-library" aria-labelledby="pre-run-saves-title">
      <header className="demo-library-header">
        <div>
          <FieldLabel id="pre-run-saves-title">Pre-run saves</FieldLabel>
          <p>Finished, deterministic showcases. Play instantly without an API key.</p>
        </div>
        <span><CheckCircle2Icon />Ready</span>
      </header>

      <article className="saved-demo saved-demo--maze">
        <div className="saved-demo-path"><ArchiveIcon /><code>/saves/labyrinth-run.mp4</code></div>
        <h3>Labyrinth Run</h3>
        <p>Three private mazes, one verified podium, and a complete spatial-reasoning breakdown.</p>
        <div className="saved-demo-entrants" aria-label="Labyrinth Run models">
          {labyrinthEntrants.map((entrant) => (
            <span className={`saved-demo-entrant saved-demo-entrant--${entrant.tone}`} key={entrant.model}>
              <i aria-hidden="true" />
              <b>{entrant.name}</b>
              <small>{entrant.model}</small>
            </span>
          ))}
        </div>
        <Button type="button" size="lg" disabled={pending} onClick={onMazeQuickStart} className="saved-demo-action saved-demo-action--maze">
          <PlayIcon data-icon="inline-start" />Play Labyrinth Run
        </Button>
      </article>

      <article className="saved-demo saved-demo--rts">
        <div className="saved-demo-path"><ArchiveIcon /><code>/saves/mini-rts-skirmish.mp4</code></div>
        <h3>Mini RTS Skirmish</h3>
        <p>Blue Command and Red Legion gather, build, arm, and fight through the verified deterministic broadcast.</p>
        <Button type="button" size="lg" disabled={pending} onClick={onRtsQuickStart} className="saved-demo-action saved-demo-action--rts">
          <PlayIcon data-icon="inline-start" />Run RTS Skirmish
        </Button>
      </article>

      <div className="demo-file-browser" aria-label="Configurable deterministic demos">
        <div className="demo-file-browser-heading"><FolderOpenIcon /><code>/demos/</code><span>No key</span></div>
        <button type="button" aria-pressed={mode === "solo"} onClick={() => onSelectMode("solo")}>
          <FolderClosedIcon /><span><b>solo/</b><small>7 stages and action courses</small></span><ChevronRightIcon />
        </button>
        <button type="button" aria-pressed={mode === "duel"} onClick={() => onSelectMode("duel")}>
          <FolderClosedIcon /><span><b>duo/</b><small>6 symmetric two-agent games</small></span><ChevronRightIcon />
        </button>
        <button type="button" aria-pressed={mode === "trio"} onClick={() => onSelectMode("trio")}>
          <FolderClosedIcon /><span><b>trio/</b><small>2 Sol, Terra, and Luna games</small></span><ChevronRightIcon />
        </button>
        <div className="demo-file-actions">
          <Button type="button" variant="ghost" disabled={pending} onClick={onQuickStart}>Run solo preset</Button>
          <Button type="button" variant="ghost" disabled={pending} onClick={onTeamQuickStart}>Run duo preset</Button>
        </div>
      </div>
    </section>
  )
}

export function SetupPanel({ setup, pending, onChange, onSubmit, onQuickStart, onTeamQuickStart, onRtsQuickStart, onMazeQuickStart }: Props) {
  const isScriptedDemo = setup.controllerMode === "scripted_demo"
  const selectScriptedDemo = () => onChange({
    ...setup,
    controllerMode: "scripted_demo",
    scenarioId: isDemoScenario(setup.scenarioId) ? setup.scenarioId : "construction-v0",
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
  const taskField = () => <Field>
    <FieldLabel htmlFor="task">Task</FieldLabel>
    <Select value={setup.taskId} onValueChange={(value) => value && onChange({ ...setup, taskId: value })}>
      <SelectTrigger id="task" className="w-full"><SelectValue /></SelectTrigger>
      <SelectContent><SelectGroup>{tasks.map(([value, label]) => <SelectItem key={value} value={value}>{label}</SelectItem>)}</SelectGroup></SelectContent>
    </Select>
  </Field>
  const demoScenarioField = <Field>
    <FieldLabel htmlFor="demo-scenario">Demo scenario</FieldLabel>
    <Select value={setup.scenarioId} onValueChange={(value) => value && onChange({ ...setup, scenarioId: value })}>
      <SelectTrigger id="demo-scenario" className="w-full"><SelectValue /></SelectTrigger>
      <SelectContent><SelectGroup>{demoScenarios.map(([value, scenario]) => <SelectItem key={value} value={value}>{scenario.displayLabel}</SelectItem>)}</SelectGroup></SelectContent>
    </Select>
    <FieldDescription className="scripted-demo-task">{scriptedDemoDescriptions[isDemoScenario(setup.scenarioId) ? setup.scenarioId : "construction-v0"]} The script is deterministic and consumes only participant-visible observations.</FieldDescription>
  </Field>
  return <aside className="setup-panel" aria-label="Episode setup">
    <h2 className="section-title">Setup</h2>
    <FieldGroup>
      <Field>
        <FieldLabel id="controller-mode-label">Run source</FieldLabel>
        <div className="controller-mode" role="radiogroup" aria-labelledby="controller-mode-label">
          <Button type="button" variant={isScriptedDemo ? "default" : "outline"} aria-checked={isScriptedDemo} role="radio" onClick={selectScriptedDemo}>
            <ClapperboardIcon />Pre-run saves
          </Button>
          <Button type="button" variant={isScriptedDemo ? "outline" : "default"} aria-checked={!isScriptedDemo} role="radio" onClick={selectLiveProvider}>
            <KeyRoundIcon />Live games
          </Button>
        </div>
        <FieldDescription>{isScriptedDemo
          ? "Saved highlights and local deterministic fixtures. No credentials or provider network calls."
          : "Connect real models with session-only provider keys. Live games never use the pre-run showcase files."}</FieldDescription>
      </Field>
      {isScriptedDemo ? <DemoLibrary
        mode={setup.mode}
        pending={pending}
        onMazeQuickStart={onMazeQuickStart}
        onQuickStart={onQuickStart}
        onRtsQuickStart={onRtsQuickStart}
        onSelectMode={(mode) => onChange({ ...setup, mode })}
        onTeamQuickStart={onTeamQuickStart}
      /> : null}
      {isScriptedDemo ? <>
        <Field><FieldLabel htmlFor="scripted-run-mode">Selected demo folder</FieldLabel><Select value={setup.mode} onValueChange={(value) => onChange({ ...setup, mode: value as "solo" | "duel" | "trio" })}><SelectTrigger id="scripted-run-mode" className="w-full"><SelectValue /></SelectTrigger><SelectContent><SelectGroup><SelectItem value="solo">/demos/solo</SelectItem><SelectItem value="duel">/demos/duo</SelectItem><SelectItem value="trio">/demos/trio</SelectItem></SelectGroup></SelectContent></Select><FieldDescription>Choose a fixture below, then run it locally through the normal authority path.</FieldDescription></Field>
        {setup.mode === "solo" ? demoScenarioField : setup.mode === "trio" ? <>
          <Field><FieldLabel htmlFor="demo-trio-game">Trio game</FieldLabel><Select value={setup.trioTaskId ?? "trio-relay-v0"} onValueChange={(value) => value && onChange({ ...setup, trioTaskId: value as DemoTrioGameId })}><SelectTrigger id="demo-trio-game" className="w-full"><SelectValue /></SelectTrigger><SelectContent><SelectGroup>{demoTrioGames.map(([value, game]) => <SelectItem key={value} value={value}>{game.displayLabel}</SelectItem>)}</SelectGroup></SelectContent></Select><FieldDescription>{DEMO_TRIO_GAMES[setup.trioTaskId ?? "trio-relay-v0"].description} Every entrant occupies each seat and spawn once.</FieldDescription></Field>
          <Field><FieldLabel>Demo entrants</FieldLabel><div className="demo-duel-entrants" aria-label="Demo trio entrants">{DEMO_TRIO_ENTRANTS.map((entrant) => <span key={entrant.model}>{entrant.displayName} · {entrant.model}</span>)}</div><FieldDescription>Exactly three independent participant-visible policies; no keys, network calls, or spectator observations.</FieldDescription></Field>
          <Field><FieldLabel>Authority timing</FieldLabel><Input value="3 cyclic legs · fixed 10-tick joint windows" readOnly aria-label="Demo trio timing" /><FieldDescription>Sol, Luna, and Terra decide concurrently. A failed participant gets neutral input without stalling or replacing the other decisions.</FieldDescription></Field>
        </> : <>
          <Field><FieldLabel htmlFor="demo-duo-game">Duo game</FieldLabel><Select value={setup.duoTaskId ?? "central-relay-v0"} onValueChange={(value) => value && onChange({ ...setup, duoTaskId: value as DemoDuoGameId })}><SelectTrigger id="demo-duo-game" className="w-full"><SelectValue /></SelectTrigger><SelectContent><SelectGroup>{demoDuoGames.map(([value, game]) => <SelectItem key={value} value={value}>{game.displayLabel}</SelectItem>)}</SelectGroup></SelectContent></Select><FieldDescription>{DEMO_DUO_GAMES[setup.duoTaskId ?? "central-relay-v0"].description} Every game runs two fixed-window legs with seats swapped.</FieldDescription></Field>
          <Field><FieldLabel>Demo entrants</FieldLabel><div className="demo-duel-entrants" aria-label="Demo duel entrants">{DEMO_DUO_GAMES[setup.duoTaskId ?? "central-relay-v0"].models.map((model, index) => <span key={model}>{index === 0 ? "Alpha" : "Bravo"} · {model}</span>)}</div><FieldDescription>Two independent participant-visible mock-LLM policies; no API keys or network calls.</FieldDescription></Field>
          <Field><FieldLabel>Authority timing</FieldLabel><Input value={(setup.duoTaskId ?? "central-relay-v0") === "central-relay-v0" ? "Central Relay · relay hold or knockout" : `${DEMO_DUO_GAMES[setup.duoTaskId ?? "central-relay-v0"].displayLabel} · fixed 10-tick windows`} readOnly aria-label="Demo duel task" /><FieldDescription>Two seat-swapped legs use fixed 10-tick joint windows. Invalid input becomes recorded neutral progress for only that seat and cannot stall time.</FieldDescription></Field>
        </>}
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
    <Button size="lg" disabled={pending || (!isScriptedDemo && (!setup.apiKey || (setup.mode === "duel" && setup.opponentProvider !== "scripted" && !setup.opponentApiKey)))} onClick={onSubmit} className="start-button"><PlayIcon data-icon="inline-start" />{pending ? "Starting…" : isScriptedDemo && setup.mode === "trio" ? "Run selected trio demo" : isScriptedDemo && setup.mode === "duel" ? "Run selected duo demo" : isScriptedDemo ? "Run selected solo demo" : setup.mode === "duel" ? "Start live two-leg game" : "Start live game"}</Button>
  </aside>
}
