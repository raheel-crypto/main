import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

let cached: string | null = null;

export function loadSystemPrompt(): string {
  if (cached) return cached;
  // From compiled lib/, the prompts/ folder is two up. Vercel includes it via includeFiles.
  const path = join(__dirname, "..", "prompts", "system.md");
  cached = readFileSync(path, "utf-8");
  return cached;
}
