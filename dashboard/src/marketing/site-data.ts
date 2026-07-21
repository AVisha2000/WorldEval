export const CONTROLLER_LAB_URL = "https://lab.openai-buildweek.lissan.dev/"

export function getControllerLabUrl(
  value = import.meta.env.VITE_CONTROLLER_LAB_URL || CONTROLLER_LAB_URL
): string {
  if (!value?.trim()) return CONTROLLER_LAB_URL
  try {
    const url = new URL(value.trim())
    const localHostnames = new Set([
      "localhost",
      "127.0.0.1",
      "0.0.0.0",
      "[::1]",
      "::1",
    ])
    if (
      !["http:", "https:"].includes(url.protocol) ||
      localHostnames.has(url.hostname)
    )
      return CONTROLLER_LAB_URL
    return url.toString()
  } catch {
    return CONTROLLER_LAB_URL
  }
}

export const REPOSITORY_URL = "https://github.com/AVisha2000/WorldEval"
export const DOCUMENTATION_URL = `${REPOSITORY_URL}#readme`
