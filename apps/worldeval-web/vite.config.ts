import path from "path"
import tailwindcss from "@tailwindcss/vite"
import react from "@vitejs/plugin-react"
import { loadEnv } from "vite"
import { defineConfig } from "vitest/config"

function normalizeBasePath(value: string) {
  const withLeadingSlash = value.startsWith("/") ? value : `/${value}`
  return withLeadingSlash.endsWith("/")
    ? withLeadingSlash
    : `${withLeadingSlash}/`
}

export default defineConfig(({ mode }) => {
  const environment = loadEnv(mode, process.cwd(), "")
  const repositoryName = environment.GITHUB_REPOSITORY?.split("/").at(-1)
  const pagesBase = normalizeBasePath(
    environment.VITE_BASE_PATH || repositoryName || "WorldArena"
  )
  const apiProxyTarget =
    environment.VITE_API_PROXY_TARGET || "http://127.0.0.1:8000"

  return {
    base: mode === "pages" ? pagesBase : "/",
    plugins: [
      {
        name: "pages-entry",
        transformIndexHtml: {
          order: "pre",
          handler(html) {
            return mode === "pages" ? html.replace("/src/main.tsx", "/src/main-pages.tsx") : html
          },
        },
      },
      react(),
      tailwindcss(),
    ],
    server: {
      proxy: {
        "/api": apiProxyTarget,
      },
    },
    test: {
      environment: "jsdom",
      setupFiles: "./src/test-setup.ts",
    },
    resolve: {
      alias: {
        "@": path.resolve(__dirname, "./src"),
      },
    },
  }
})
