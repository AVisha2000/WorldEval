import { CheckCircle2Icon, CircleDashedIcon, ShieldAlertIcon } from "lucide-react"
import type { ReadinessView } from "@/api"

type Props = {
  readiness?: ReadinessView
  unavailable: boolean
}

function readableCode(code: string | null) {
  return code === null ? "Verified" : code.replaceAll("_", " ")
}

export function ReadinessPanel({ readiness, unavailable }: Props) {
  const passed = readiness?.gates.filter((gate) => gate.passed).length ?? 0
  const total = readiness?.gates.length ?? 6
  return (
    <section className="readiness-panel" aria-label="Certification readiness">
      <div className="readiness-summary">
        <span className="section-title">Certification</span>
        <strong>{unavailable ? "Status unavailable" : `${passed}/${total} gates verified`}</strong>
        <small>
          {readiness?.ready_for_promotion
            ? "Ready for capability promotion"
            : "Runtime capabilities remain unreleased"}
        </small>
      </div>
      <div className="readiness-gates">
        {readiness?.gates.map((gate) => (
          <div className={gate.passed ? "readiness-gate passed" : "readiness-gate"} key={gate.id}>
            {gate.passed ? <CheckCircle2Icon /> : <CircleDashedIcon />}
            <span><b>{gate.label}</b><small>{readableCode(gate.code)}</small></span>
          </div>
        )) ?? (
          <div className="readiness-gate unavailable">
            <ShieldAlertIcon />
            <span><b>Readiness report</b><small>Local status API unavailable</small></span>
          </div>
        )}
      </div>
      {readiness?.source_fingerprint ? (
        <code title={readiness.source_fingerprint}>
          source {readiness.source_fingerprint.slice(0, 12)}
        </code>
      ) : null}
    </section>
  )
}
