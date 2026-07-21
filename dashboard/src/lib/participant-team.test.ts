import { describe, expect, it } from "vitest"
import type { EpisodeView } from "@/api"
import { participantTeams, TEAM_COLOURS } from "@/lib/participant-team"

const duo: Pick<EpisodeView, "kind" | "entrants"> = {
  kind: "series",
  entrants: [
    { entrantId: "entrant_0", displayName: "duelist-alpha-v1", model: "duelist-alpha-v1" },
    { entrantId: "entrant_1", displayName: "duelist-bravo-v1", model: "duelist-bravo-v1" },
  ],
}

const trio: Pick<EpisodeView, "kind" | "entrants"> = {
  kind: "trio",
  entrants: [
    { entrantId: "sol", displayName: "Sol", model: "demo-sol-v1" },
    { entrantId: "luna", displayName: "Luna", model: "demo-luna-v1" },
    { entrantId: "terra", displayName: "Terra", model: "demo-terra-v1" },
  ],
}

describe("participant team colours", () => {
  it("follows Alpha and Bravo through the symmetric duo seat swap", () => {
    expect(participantTeams(duo, 0).map((team) => [team.participantId, team.displayName, team.tone])).toEqual([
      ["participant_0", "Alpha", "alpha"],
      ["participant_1", "Bravo", "bravo"],
    ])
    expect(participantTeams(duo, 1).map((team) => [team.participantId, team.displayName, team.tone])).toEqual([
      ["participant_0", "Bravo", "bravo"],
      ["participant_1", "Alpha", "alpha"],
    ])
  })

  it("follows Sol, Luna, and Terra through all cyclic trio rotations", () => {
    expect(participantTeams(trio, 0).map((team) => team.displayName)).toEqual(["Sol", "Luna", "Terra"])
    expect(participantTeams(trio, 1).map((team) => team.displayName)).toEqual(["Terra", "Sol", "Luna"])
    expect(participantTeams(trio, 2).map((team) => team.displayName)).toEqual(["Luna", "Terra", "Sol"])
  })

  it("uses the canonical accessible identity palette", () => {
    expect(TEAM_COLOURS).toMatchObject({
      alpha: "#38bdf8", bravo: "#fb7185", sol: "#fbbf24", luna: "#a78bfa", terra: "#34d399",
    })
  })
})
