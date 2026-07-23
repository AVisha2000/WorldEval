import { StrictMode } from "react"
import { createRoot } from "react-dom/client"

import "./index.css"

const root = createRoot(document.getElementById("root")!)
const isPublicSite = import.meta.env.MODE === "pages"

async function bootstrap() {
  if (isPublicSite) {
    const { MarketingSite } = await import("./marketing/marketing-site")
    document.title = "WorldEval — Evaluate intelligent agents in worlds"
    root.render(
      <StrictMode>
        <MarketingSite />
      </StrictMode>
    )
    return
  }

  const [
    { default: App },
    { QueryClient, QueryClientProvider },
    { ThemeProvider },
  ] = await Promise.all([
    import("./App.tsx"),
    import("@tanstack/react-query"),
    import("@/components/theme-provider.tsx"),
  ])
  const queryClient = new QueryClient()
  document.title = "WorldArena Controller Lab"
  root.render(
    <StrictMode>
      <ThemeProvider defaultTheme="dark">
        <QueryClientProvider client={queryClient}>
          <App />
        </QueryClientProvider>
      </ThemeProvider>
    </StrictMode>
  )
}

void bootstrap()
