import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import "./index.css"
import { MarketingSite } from "./marketing/marketing-site"

document.title = "WorldEval — Evaluate intelligent agents in worlds"

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <MarketingSite />
  </StrictMode>,
)
