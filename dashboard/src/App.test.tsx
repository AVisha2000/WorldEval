import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { cleanup, render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import App from "@/App"

function response(value: Record<string, unknown>) {
  return { ok: true, json: async () => value } as Response
}

const cachedRtsShowcase = {
  showcase_id: "rts-skirmish-v0",
  task_id: "rts-skirmish-v0",
  label: "WorldArena: Mini RTS — Blue vs Red",
  status: "ready",
  cached: true,
  video: {
    duration_seconds: 150, fps: 30, height: 1080, mime_type: "video/mp4",
    sha256: "b".repeat(64), width: 1920,
  },
  winner: { team: "Blue Command" },
  completion: { outcome: "win", reason: "town_hall_destroyed", tick: 1190 },
  casualties: [
    { at_tick: 850, team: "Blue", unit_id: "blue_0" },
    { at_tick: 880, team: "Red", unit_id: "red_0" },
    { at_tick: 900, team: "Red", unit_id: "red_1" },
    { at_tick: 1020, team: "Red", unit_id: "red_2" },
  ],
  highlights: [
    { at_seconds: 0, label: "Workers deploy" },
    { at_seconds: 80, label: "Bridge battle" },
    { at_seconds: 145, label: "Blue victory" },
  ],
}

const cachedRtsEvaluation = {
  showcase_id: "rts-skirmish-v0",
  task_id: "rts-skirmish-v0",
  completion: cachedRtsShowcase.completion,
  metrics: [
    { id: "economy", label: "Economy", value: "Workers spread across wood and ore" },
    { id: "determinism", label: "Determinism", value: "Replay verified" },
  ],
  verification: {
    manifest_sha256: "c".repeat(64), replay_sha256: "d".repeat(64),
    video_sha256: "e".repeat(64), final_state_sha256: "f".repeat(64), state: "verified",
  },
}

const cachedMazeShowcase = {
  showcase_id: "trio-maze-race-v0",
  task_id: "trio-maze-race-v0",
  label: "WorldArena: Labyrinth Run",
  tagline: "Three agents. The same maze. No shared vision. One memory-limited race.",
  status: "ready",
  cached: true,
  video: { duration_seconds: 72, fps: 30, height: 1080, mime_type: "video/mp4", sha256: "1".repeat(64), width: 1920 },
  entrants: [
    { participant_id: "participant_0", entrant_id: "sol", display_name: "Sol", model: "demo-sol-v1", color: "#fbbf24", lane: "gold", style: "Right-first depth-first search" },
    { participant_id: "participant_1", entrant_id: "luna", display_name: "Luna", model: "demo-luna-v1", color: "#a78bfa", lane: "purple", style: "Cautious left-first search" },
    { participant_id: "participant_2", entrant_id: "terra", display_name: "Terra", model: "demo-terra-v1", color: "#34d399", lane: "green", style: "Forward-biased landmark search" },
  ],
  winner: { participant_id: "participant_0", display_name: "Sol" },
  result: {
    winner_id: "participant_0", winner: "Sol",
    finish_order: ["participant_0", "participant_2", "participant_1"], completion_tick: 584,
    reason: "all_racers_finished",
    explanation: "Sol won by eliminating exhausted branches more efficiently. Terra recovered from two incorrect branches. Luna completed the maze but travelled the longest route.",
  },
  timeline: [
    { at_seconds: 0, participant_id: "broadcast", kind: "title", label: "Three identical private maze lanes" },
    { at_seconds: 49, participant_id: "participant_0", kind: "finish", label: "Sol reaches the exit first at 44.8 seconds" },
    { at_seconds: 66, participant_id: "broadcast", kind: "result", label: "Winner calling card and spatial-reasoning metrics" },
  ],
}

const cachedMazeEvaluation = {
  showcase_id: "trio-maze-race-v0",
  task_id: "trio-maze-race-v0",
  scope: "trio_maze_race",
  summary: cachedMazeShowcase.result.explanation,
  participants: [
    ["participant_0", "Sol", "demo-sol-v1", "#fbbf24", 1, 448, "44.8", 64, 9375, 1],
    ["participant_2", "Terra", "demo-terra-v1", "#34d399", 2, 536, "53.6", 84, 7142, 2],
    ["participant_1", "Luna", "demo-luna-v1", "#a78bfa", 3, 584, "58.4", 104, 5769, 3],
  ].map(([participant_id, display_name, model, color, place, finish_tick, completion_seconds, distance_cells, path_efficiency_basis_points, dead_ends_entered]) => ({
    participant_id, display_name, model, color, place, finish_tick, completion_seconds,
    distance_cells, shortest_path_cells: 60, path_efficiency_basis_points,
    unique_corridor_cells: 61, repeated_corridor_cells: Number(distance_cells) - 60,
    passages_explored: Number(place) * 2 + 4, dead_ends_entered,
    successful_backtracks: dead_ends_entered, collisions: 0, invalid_decisions: 0,
    idle_thinking_ticks: 180,
  })),
  verification: {
    state: "verified", deterministic: true, map_sha256: "2".repeat(64),
    final_state_sha256: "3".repeat(64), manifest_sha256: "4".repeat(64),
    replay_sha256: "5".repeat(64), video_sha256: "6".repeat(64),
  },
}

const crossroadsPlacements = [
  { placement: 1, entrant_id: "participant_1", faction_id: "luna", display_name: "Luna" },
  { placement: 2, entrant_id: "participant_0", faction_id: "sol", display_name: "Sol" },
  { placement: 3, entrant_id: "participant_2", faction_id: "terra", display_name: "Terra" },
]

const crossroadsEliminations = [
  { order: 1, faction_id: "terra", eliminated_by: "sol", round: 25, event_id: "terra_eliminated" },
  { order: 2, faction_id: "sol", eliminated_by: "luna", round: 29, event_id: "sol_eliminated" },
]

const crossroadsBeatIds = [
  "opening_reveal", "sol_introduction", "terra_introduction", "luna_introduction",
  "terra_claims_crossroads", "sol_prepares_assault", "luna_observes", "crossroads_clash",
  "sol_takes_crossroads", "two_front_march", "terra_counterpunch", "sol_breaches_terra",
  "terra_eliminated", "exposed_sol_overview", "luna_strikes", "sol_eliminated",
  "verified_result",
]

const crossroadsEventIds = [
  "", "", "", "", "event_4", "event_5", "event_6", "event_7", "event_8", "event_9",
  "event_10", "event_11", "terra_falls", "terra_falls", "event_14", "sol_falls", "sol_falls",
]

const cachedCrossroadsShowcase = {
  showcase_id: "crossroads-conquest-v0",
  task_id: "crossroads-conquest-v0",
  title: "WorldArena: Crossroads Conquest",
  tagline: "Three strongholds. One crossroads. Last faction standing.",
  status: "ready", cached: true, verified: true,
  entrants: [
    { entrant_id: "participant_0", faction_id: "sol", display_name: "Sol", glyph: "△", color: "#fbbf24", policy_id: "crossroads-conquest-demo-v1" },
    { entrant_id: "participant_1", faction_id: "luna", display_name: "Luna", glyph: "○", color: "#a78bfa", policy_id: "crossroads-conquest-demo-v1" },
    { entrant_id: "participant_2", faction_id: "terra", display_name: "Terra", glyph: "□", color: "#34d399", policy_id: "crossroads-conquest-demo-v1" },
  ],
  winner: { entrant_id: "participant_1", faction_id: "luna", display_name: "Luna" },
  placements: crossroadsPlacements,
  elimination_order: crossroadsEliminations,
  timeline: [
    [0, 0, "Map reveal"], [12, 1, "Sol prepares siege"], [19, 1, "Terra eyes the center"],
    [26, 1, "Luna scouts"], [33, 10, "Terra claims the center"], [44, 11, "Sol prepares its assault"],
    [55, 12, "Luna holds fire"], [65, 16, "The Crossroads clash begins"],
    [78, 20, "Sol takes the center"], [90, 22, "Two fronts open"],
    [102, 24, "Terra's counterpunch lands"], [114, 25, "Sol breaches Terra"],
    [126, 25, "Terra eliminated"], [137, 26, "Luna stages west"],
    [146, 27, "Luna strikes"], [158, 29, "Sol eliminated"], [169, 29, "Luna wins"],
  ].map(([at_seconds, round, label], index) => ({
    beat_id: crossroadsBeatIds[index], at_seconds, round,
    frame_index: Math.max(0, index - 3), event_id: crossroadsEventIds[index],
    kind: index < 4 ? "editorial" : "authority_event", editorial: index < 4, label,
  })),
  video: { duration_seconds: 180, fps: 30, height: 1080, mime_type: "video/mp4", sha256: "7".repeat(64), width: 1920 },
  authority: { protocol: "world-arena/0.4", seed: 424242, policy_id: "crossroads-conquest-demo-v1", map_id: "tri_13_v1", rules_id: "arena-v0.4" },
}

const cachedCrossroadsEvaluation = {
  showcase_id: "crossroads-conquest-v0", task_id: "crossroads-conquest-v0",
  scope: "crossroads_conquest",
  outcome: {
    winner: cachedCrossroadsShowcase.winner,
    placements: crossroadsPlacements,
    elimination_order: crossroadsEliminations,
  },
  verification: {
    state: "verified", deterministic: true, deterministic_runs: 2, order_rejections: 0,
    luna_first_hostile_round: 26, manifest_sha256: "8".repeat(64),
    replay_sha256: "9".repeat(64), evaluation_sha256: "a".repeat(64),
    video_sha256: "7".repeat(64), normalized_trace_sha256: "b".repeat(64),
    final_state_sha256: "c".repeat(64),
  },
  factions: [
    { faction_id: "sol", placement: 2, core_hp: 0, eliminated_round: 29, eliminated_by: "luna", strongholds_destroyed: 1 },
    { faction_id: "luna", placement: 1, core_hp: 1000, eliminated_round: null, eliminated_by: null, strongholds_destroyed: 1 },
    { faction_id: "terra", placement: 3, core_hp: 0, eliminated_round: 25, eliminated_by: "sol", strongholds_destroyed: 0 },
  ],
}

function lifecycleFetch() {
  return vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input)
    if (url.endsWith("/showcases/rts-skirmish-v0/evaluation")) return response(cachedRtsEvaluation)
    if (url.endsWith("/showcases/rts-skirmish-v0")) return response(cachedRtsShowcase)
    if (url.endsWith("/showcases/trio-maze-race-v0/evaluation")) return response(cachedMazeEvaluation)
    if (url.endsWith("/showcases/trio-maze-race-v0")) return response(cachedMazeShowcase)
    if (url.endsWith("/showcases/crossroads-conquest-v0/evaluation")) return response(cachedCrossroadsEvaluation)
    if (url.endsWith("/showcases/crossroads-conquest-v0")) return response(cachedCrossroadsShowcase)
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

async function selectLiveProvider(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole("radio", { name: "Live games" }))
}

describe("Controller dashboard", () => {
  beforeEach(() => {
    localStorage.clear()
    vi.stubGlobal("fetch", vi.fn(async () => response({})))
    vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:participant-frame")
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined)
  })
  afterEach(() => {
    cleanup()
    document.body.removeAttribute("style")
  })
  it("defaults to the credential-free scripted solo demos", () => {
    render(<QueryClientProvider client={new QueryClient()}><App /></QueryClientProvider>)
    expect(screen.getByRole("heading", { name: /WorldArena Mini RTS Arena/i })).toBeInTheDocument()
    expect(screen.queryByLabelText("API key")).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Run selected solo demo" })).toBeEnabled()
    expect(screen.getByRole("combobox", { name: "Selected demo folder" })).toBeEnabled()
    expect(screen.getByRole("radio", { name: "Pre-run saves" })).toBeChecked()
    expect(screen.getByRole("combobox", { name: "Demo scenario" })).toHaveTextContent("construction-v0")
    expect(screen.getByRole("tab", { name: "Timeline" })).toBeInTheDocument()
    expect(screen.getByRole("tab", { name: "Replay" })).toBeInTheDocument()
    expect(screen.getByText("Configure a hybrid solo episode")).toBeInTheDocument()
  })
  it("quick starts the keyless multi-action solo showcase through the ordinary Demo API flow", async () => {
    const user = userEvent.setup()
    const fetch = lifecycleFetch()
    vi.stubGlobal("fetch", fetch)
    renderApp()

    expect(screen.getByText(/No credentials or provider network calls/i)).toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: "Run solo preset" }))

    const post = fetch.mock.calls.find(
      ([input, init]) => String(input).endsWith("/episodes") && init?.method === "POST"
    )
    expect(post).toBeDefined()
    const payload = JSON.parse(String(post?.[1]?.body))
    expect(payload).toMatchObject({
      provider: "demo",
      model: "construction-demo-v1",
      scenario_id: "multi-action-demo-v0",
      task_id: "construction-v0",
      maximum_episode_ticks: 1300,
    })
    expect(JSON.stringify(payload)).not.toMatch(/api_key|credential/)
  })
  it("quick starts the coloured Alpha versus Bravo Central Relay team demo without credentials", async () => {
    const user = userEvent.setup()
    const fetch = lifecycleFetch()
    vi.stubGlobal("fetch", fetch)
    renderApp()

    expect(screen.getByLabelText("Configurable deterministic demos")).toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: "Run duo preset" }))

    const post = fetch.mock.calls.find(
      ([input, init]) => String(input).endsWith("/series") && init?.method === "POST"
    )
    expect(post).toBeDefined()
    const payload = JSON.parse(String(post?.[1]?.body))
    expect(payload).toMatchObject({
      task_id: "central-relay-v0",
      entrants: [
        { provider: "demo", model: "duelist-alpha-v1" },
        { provider: "demo", model: "duelist-bravo-v1" },
      ],
    })
    expect(JSON.stringify(payload)).not.toMatch(/api_key|credential/)
  })
  it("opens the featured RTS Skirmish MVP from the cached local showcase without starting a run", async () => {
    const user = userEvent.setup()
    const fetch = lifecycleFetch()
    vi.stubGlobal("fetch", fetch)
    renderApp()

    expect(screen.getByText(/Blue Command and Red Legion gather, build, arm, and fight/i)).toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: "Run RTS Skirmish" }))

    expect(screen.getByRole("heading", { name: "Blue Command vs Red Legion" })).toBeInTheDocument()
    expect(screen.getByText(/saved authority-verified demo/i)).toBeInTheDocument()
    expect(screen.getByLabelText("Cached RTS skirmish showcase").querySelector("video"))
      .toHaveAttribute("src", "/api/embodiment/showcases/rts-skirmish-v0/video")
    await waitFor(() => expect(fetch).toHaveBeenCalledWith(
      "/api/embodiment/showcases/rts-skirmish-v0", { cache: "force-cache" }
    ))
    const post = fetch.mock.calls.find(([, init]) => init?.method === "POST")
    expect(post).toBeUndefined()
  })
  it("renders each RTS showcase tab from cached safe metadata only", async () => {
    const user = userEvent.setup()
    const fetch = lifecycleFetch()
    vi.stubGlobal("fetch", fetch)
    renderApp()

    await user.click(screen.getByRole("button", { name: "Run RTS Skirmish" }))
    await user.click(screen.getByRole("tab", { name: "Timeline" }))
    expect(await screen.findByText("Cinematic timeline")).toBeInTheDocument()
    expect(screen.getByText("Bridge battle")).toBeInTheDocument()
    await user.click(screen.getByRole("tab", { name: "Result" }))
    expect(screen.getByText("Blue Command wins")).toBeInTheDocument()
    expect(screen.getByText(/Tick 1020/)).toBeInTheDocument()
    await user.click(screen.getByRole("tab", { name: "Evaluation" }))
    expect(await screen.findByText("Verified evaluation")).toBeInTheDocument()
    expect(screen.getByText("Workers spread across wood and ore")).toBeInTheDocument()
    await user.click(screen.getByRole("tab", { name: "Replay" }))
    expect(await screen.findByText("Replay identity")).toBeInTheDocument()
    expect(screen.getByText(/Manifest, replay, final state, and video hashes verified/)).toBeInTheDocument()
    expect(fetch.mock.calls.some(([url]) => String(url).includes(".replay.json"))).toBe(false)
    expect(fetch.mock.calls.some(([, init]) => init?.method === "POST")).toBe(false)
  })
  it("opens Labyrinth Run as a second cached highlight with a model key, podium, metrics, and winner rationale", async () => {
    const user = userEvent.setup()
    const fetch = lifecycleFetch()
    vi.stubGlobal("fetch", fetch)
    renderApp()

    await user.click(screen.getByRole("button", { name: "Play Labyrinth Run" }))
    expect(await screen.findByRole("heading", { name: "WorldArena: Labyrinth Run" })).toBeInTheDocument()
    await waitFor(() => expect(screen.getByLabelText("Model colour key")).toHaveTextContent("Sol · demo-sol-v1"))
    expect(screen.getByLabelText("Model colour key")).toHaveTextContent("Luna · demo-luna-v1")
    expect(screen.getByLabelText("Model colour key")).toHaveTextContent("Terra · demo-terra-v1")
    expect(screen.getByLabelText("Cached Trio Maze Race showcase").querySelector("video"))
      .toHaveAttribute("src", "/api/embodiment/showcases/trio-maze-race-v0/video")
    await user.click(screen.getByRole("tab", { name: "Result" }))
    expect(await screen.findByText("Sol wins the Labyrinth Run")).toBeInTheDocument()
    expect(screen.getByText(/Terra recovered from two incorrect branches/)).toBeInTheDocument()
    expect(screen.getByText("44.8s · 64 cells")).toBeInTheDocument()
    await user.click(screen.getByRole("tab", { name: "Evaluation" }))
    expect(await screen.findByText("Spatial-reasoning evaluation")).toBeInTheDocument()
    expect(screen.getByText("93.75%")).toBeInTheDocument()
    await user.click(screen.getByRole("tab", { name: "Replay" }))
    expect(await screen.findByText(/Python package and Godot authority agree/)).toBeInTheDocument()
    expect(fetch.mock.calls.some(([, init]) => init?.method === "POST")).toBe(false)
  })
  it("opens Crossroads Conquest as the third cached highlight and lazy-loads its evaluation", async () => {
    const user = userEvent.setup()
    const fetch = lifecycleFetch()
    vi.stubGlobal("fetch", fetch)
    renderApp()

    await user.click(screen.getByRole("button", { name: "Run Crossroads Conquest" }))
    expect(await screen.findByRole("heading", { name: "WorldArena: Crossroads Conquest" })).toBeInTheDocument()
    expect(screen.getByLabelText("Cached Crossroads Conquest showcase").querySelector("video"))
      .toHaveAttribute("src", "/api/embodiment/showcases/crossroads-conquest-v0/video")
    await waitFor(() => expect(fetch).toHaveBeenCalledWith(
      "/api/embodiment/showcases/crossroads-conquest-v0", { cache: "force-cache" }
    ))
    const evaluationRequests = () => fetch.mock.calls.filter(([url]) =>
      String(url).endsWith("/showcases/crossroads-conquest-v0/evaluation")
    )
    expect(evaluationRequests()).toHaveLength(0)

    await user.click(screen.getByRole("tab", { name: "Timeline" }))
    expect(await screen.findByText("Broadcast timeline")).toBeInTheDocument()
    expect(screen.getByText("Terra claims the center")).toBeInTheDocument()
    expect(evaluationRequests()).toHaveLength(0)

    await user.click(screen.getByRole("tab", { name: "Result" }))
    expect(screen.getByText("Luna wins")).toBeInTheDocument()
    expect(screen.getByText("Sol eliminated Terra · Luna eliminated Sol")).toBeInTheDocument()
    expect(screen.getByText("Round 25")).toBeInTheDocument()
    expect(evaluationRequests()).toHaveLength(0)

    await user.click(screen.getByRole("tab", { name: "Evaluation" }))
    expect(await screen.findByText("Authority-derived evaluation")).toBeInTheDocument()
    expect(await screen.findByText("identical authority runs")).toBeInTheDocument()
    expect(screen.getByText("rejected orders")).toBeInTheDocument()
    expect(evaluationRequests()).toHaveLength(1)

    await user.click(screen.getByRole("tab", { name: "Replay" }))
    expect(await screen.findByText("Immutable replay identity")).toBeInTheDocument()
    expect(screen.getAllByText("crossroads-conquest-demo-v1")).toHaveLength(4)
    expect(evaluationRequests()).toHaveLength(1)
    expect(fetch.mock.calls.some(([url]) => String(url).includes(".replay.json"))).toBe(false)
    expect(fetch.mock.calls.some(([, init]) => init?.method === "POST")).toBe(false)
  })
  it("launches the keyless scripted 1v1 with exactly two Demo policies", async () => {
    const user = userEvent.setup()
    const fetch = lifecycleFetch()
    vi.stubGlobal("fetch", fetch)
    renderApp()

    await user.click(screen.getByRole("combobox", { name: "Selected demo folder" }))
    await user.click(await screen.findByRole("option", { name: "/demos/duo" }))
    expect(screen.queryByLabelText("API key")).not.toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: "Run selected duo demo" }))

    const post = fetch.mock.calls.find(([input, init]) => String(input).endsWith("/series") && init?.method === "POST")
    expect(post).toBeDefined()
    const payload = JSON.parse(String(post?.[1]?.body))
    expect(payload.entrants).toEqual([
      { provider: "demo", model: "duelist-alpha-v1" },
      { provider: "demo", model: "duelist-bravo-v1" },
    ])
    expect(JSON.stringify(payload)).not.toContain("api_key")
  })
  it("selects a simple duo game and launches its exact independent Demo policies", async () => {
    const user = userEvent.setup()
    const fetch = lifecycleFetch()
    vi.stubGlobal("fetch", fetch)
    renderApp()

    await user.click(screen.getByRole("combobox", { name: "Selected demo folder" }))
    await user.click(await screen.findByRole("option", { name: "/demos/duo" }))
    await user.click(screen.getByRole("combobox", { name: "Duo game" }))
    await user.click(await screen.findByRole("option", { name: "Checkpoint Race" }))
    expect(screen.getByLabelText("Demo duel entrants")).toHaveTextContent("checkpoint-racer-alpha-v1")
    expect(screen.getByLabelText("Demo duel entrants")).toHaveTextContent("checkpoint-racer-bravo-v1")
    expect(screen.queryByLabelText("API key")).not.toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: "Run selected duo demo" }))

    const post = fetch.mock.calls.find(([input, init]) => String(input).endsWith("/series") && init?.method === "POST")
    const payload = JSON.parse(String(post?.[1]?.body))
    expect(payload.task_id).toBe("duo-checkpoint-race-v0")
    expect(payload.entrants).toEqual([
      { provider: "demo", model: "checkpoint-racer-alpha-v1" },
      { provider: "demo", model: "checkpoint-racer-bravo-v1" },
    ])
  })
  it("offers Resource Relay with its exact independent Demo policies", async () => {
    const user = userEvent.setup()
    const fetch = lifecycleFetch()
    vi.stubGlobal("fetch", fetch)
    renderApp()

    await user.click(screen.getByRole("combobox", { name: "Selected demo folder" }))
    await user.click(await screen.findByRole("option", { name: "/demos/duo" }))
    await user.click(screen.getByRole("combobox", { name: "Duo game" }))
    await user.click(await screen.findByRole("option", { name: "Frontier Resource Relay" }))
    expect(screen.getByLabelText("Demo duel entrants")).toHaveTextContent(
      "resource-relay-alpha-v1"
    )
    expect(screen.getByLabelText("Demo duel entrants")).toHaveTextContent(
      "resource-relay-bravo-v1"
    )
    await user.click(screen.getByRole("button", { name: "Run selected duo demo" }))

    const post = fetch.mock.calls.find(
      ([input, init]) => String(input).endsWith("/series") && init?.method === "POST"
    )
    const payload = JSON.parse(String(post?.[1]?.body))
    expect(payload.task_id).toBe("duo-resource-relay-v0")
    expect(payload.entrants).toEqual([
      { provider: "demo", model: "resource-relay-alpha-v1" },
      { provider: "demo", model: "resource-relay-bravo-v1" },
    ])
  })
  it("omits certification readiness from the dashboard", () => {
    const fetch = lifecycleFetch()
    vi.stubGlobal("fetch", fetch)
    renderApp()

    expect(screen.queryByLabelText("Certification readiness")).not.toBeInTheDocument()
    expect(fetch.mock.calls.some(([input]) => String(input).endsWith("/certification/readiness"))).toBe(false)
  })
  it("keeps the credential in component state and never browser storage", async () => {
    const user = userEvent.setup()
    render(<QueryClientProvider client={new QueryClient()}><App /></QueryClientProvider>)
    await selectLiveProvider(user)
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

    await selectLiveProvider(user)
    await user.type(screen.getByLabelText("API key"), secret)
    await user.click(screen.getByRole("button", { name: "Start live game" }))

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

    await selectLiveProvider(user)
    await user.click(screen.getByRole("combobox", { name: "Workflow" }))
    await user.click(await screen.findByRole("option", { name: "Symmetric two-leg 1v1" }))
    expect(screen.getByText("Configure a symmetric two-leg series")).toBeInTheDocument()
    expect(screen.getByText(/Scripted opponents require no key/)).toBeInTheDocument()
    expect(screen.getByLabelText("Scripted tier")).toBeInTheDocument()
    expect(screen.queryByLabelText("Opponent API key")).not.toBeInTheDocument()
    await user.type(screen.getByLabelText("API key"), secret)
    await user.click(screen.getByRole("button", { name: "Start live two-leg game" }))

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

    await selectLiveProvider(user)
    await user.type(screen.getByLabelText("API key"), "polling-session-secret")
    await user.click(screen.getByRole("button", { name: "Start live game" }))

    expect(await screen.findByText("● running")).toBeInTheDocument()
    expect(await screen.findByText("● success", {}, { timeout: 2500 })).toBeInTheDocument()
    expect(statusReads).toBeGreaterThanOrEqual(2)
  })

  it("defers the public timeline request until the Timeline view opens", async () => {
    const user = userEvent.setup()
    let timelineReads = 0
    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (init?.method === "POST") {
        return response({
          config: { task_id: "construction-v0" },
          episode_id: "ep_deferred_timeline",
          state: "running",
        })
      }
      if (url.endsWith("/frame")) {
        return new Response(null, { status: 204, headers: { "X-Frame-State": "loading" } })
      }
      if (url.endsWith("/timeline")) {
        timelineReads += 1
        return response({
          events: [{
            kind: "action_receipts",
            value: {
              observation_seq: 1,
              participants: {
                participant_0: {
                  action_id: "task_gather_materials_1",
                  codes: ["accepted"],
                  disposition: "accepted",
                  start_tick: 1,
                  end_tick: 2,
                },
              },
            },
          }],
        })
      }
      return response({
        config: { task_id: "construction-v0" },
        episode_id: "ep_deferred_timeline",
        state: "running",
      })
    }))
    renderApp()

    await user.click(screen.getByRole("button", { name: "Run selected solo demo" }))
    expect(await screen.findByText("● running")).toBeInTheDocument()
    expect(timelineReads).toBe(0)

    await user.click(screen.getByRole("tab", { name: "Timeline" }))
    await waitFor(() => expect(timelineReads).toBe(1))
    expect(await screen.findByText("task_gather_materials_1")).toBeInTheDocument()
  })

  it("shows the current participant frame and retains a finished player-visible view", async () => {
    const user = userEvent.setup()
    let statusReads = 0
    const framePng = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10])
    const fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
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

    await selectLiveProvider(user)
    await user.type(screen.getByLabelText("API key"), "camera-session-secret")
    await user.click(screen.getByRole("button", { name: "Start live game" }))

    expect(await screen.findByRole("img", { name: "Active participant Godot camera frame" })).toHaveAttribute(
      "src",
      "blob:participant-frame",
    )
    expect(screen.getByText(/Participant-visible pixels only/)).toBeInTheDocument()
    expect(screen.queryByText("camera-session-secret")).not.toBeInTheDocument()
    expect(await screen.findByText("● success", {}, { timeout: 2500 })).toBeInTheDocument()
    expect(await screen.findByText("Finished")).toBeInTheDocument()
    expect(screen.getByText("Observation 2")).toBeInTheDocument()
    expect(screen.getByLabelText("Authority tick")).toHaveTextContent("Tick 2")
  })
})
