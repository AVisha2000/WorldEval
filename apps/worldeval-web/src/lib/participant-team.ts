import type { EpisodeView, ParticipantId, PublicEntrant } from "@/api"

export type TeamTone = "alpha" | "bravo" | "sol" | "luna" | "terra" | "neutral"

export type ParticipantTeam = {
  participantId: ParticipantId
  entrantId: string
  displayName: string
  model: string
  tone: TeamTone
}

// These are identity colours, never seat colours.  A participant's colour follows its entrant
// through the symmetric duo swap and the cyclic trio rotations.
export const TEAM_COLOURS: Record<TeamTone, string> = {
  alpha: "#38bdf8",
  bravo: "#fb7185",
  sol: "#fbbf24",
  luna: "#a78bfa",
  terra: "#34d399",
  neutral: "#94a3b8",
}

const DEMO_DUO_ENTRANTS: PublicEntrant[] = [
  { entrantId: "entrant_0", displayName: "Alpha", model: "demo-alpha" },
  { entrantId: "entrant_1", displayName: "Bravo", model: "demo-bravo" },
]

const DEMO_TRIO_ENTRANTS: PublicEntrant[] = [
  { entrantId: "sol", displayName: "Sol", model: "demo-sol-v1" },
  { entrantId: "luna", displayName: "Luna", model: "demo-luna-v1" },
  { entrantId: "terra", displayName: "Terra", model: "demo-terra-v1" },
]

function teamTone(entrant: PublicEntrant): TeamTone {
  const identity = `${entrant.entrantId} ${entrant.displayName} ${entrant.model}`.toLowerCase()
  if (identity.includes("alpha")) return "alpha"
  if (identity.includes("bravo")) return "bravo"
  if (identity.includes("sol")) return "sol"
  if (identity.includes("luna")) return "luna"
  if (identity.includes("terra")) return "terra"
  return "neutral"
}

function demoName(entrant: PublicEntrant, tone: TeamTone): string {
  if (tone === "alpha") return "Alpha"
  if (tone === "bravo") return "Bravo"
  if (tone === "sol") return "Sol"
  if (tone === "luna") return "Luna"
  if (tone === "terra") return "Terra"
  return entrant.displayName
}

/**
 * Projects only public roster identity onto a currently visible participant seat. The schedules
 * are canonical: duo leg N swaps both entrants; trio leg N rotates entrants cyclically.
 */
export function participantTeams(
  episode: Pick<EpisodeView, "kind" | "entrants">,
  legIndex: number | null | undefined,
): ParticipantTeam[] {
  if (episode.kind === "episode") return []
  const leg = legIndex ?? 0
  const roster = episode.kind === "trio"
    ? episode.entrants?.length === 3 ? episode.entrants : DEMO_TRIO_ENTRANTS
    : episode.entrants?.length === 2 ? episode.entrants : DEMO_DUO_ENTRANTS
  const participantCount = episode.kind === "trio" ? 3 : 2

  return Array.from({ length: participantCount }, (_, seat) => {
    // Duo: leg 0 [A, B], leg 1 [B, A]. Trio: p_i receives entrant_(i - leg) modulo 3.
    const entrantIndex = episode.kind === "trio"
      ? (seat - leg + participantCount) % participantCount
      : (seat + leg) % participantCount
    const entrant = roster[entrantIndex]
    const tone = teamTone(entrant)
    return {
      participantId: `participant_${seat}` as ParticipantId,
      entrantId: entrant.entrantId,
      displayName: demoName(entrant, tone),
      model: entrant.model,
      tone,
    }
  })
}

export function participantTeam(
  episode: Pick<EpisodeView, "kind" | "entrants">,
  participantId: ParticipantId,
  legIndex: number | null | undefined,
): ParticipantTeam | undefined {
  return participantTeams(episode, legIndex).find((team) => team.participantId === participantId)
}
