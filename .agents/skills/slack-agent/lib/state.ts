import { Redis } from "@upstash/redis";

const redis = new Redis({
  url: process.env.quote_bot_KV_REST_API_URL ?? process.env.KV_REST_API_URL ?? "",
  token: process.env.quote_bot_KV_REST_API_TOKEN ?? process.env.KV_REST_API_TOKEN ?? "",
});

const DEFAULT_TTL_SECONDS = 60 * 60;

/**
 * Stash any JSON-serializable value under a short auto-generated ID.
 * Returns the ID — use it in Slack interactive component `value` fields
 * (150-char limit) to carry context across user interactions.
 */
export async function stash<T>(value: T, ttlSeconds = DEFAULT_TTL_SECONDS): Promise<string> {
  const id = generateId();
  await redis.set(`s:${id}`, JSON.stringify(value), { ex: ttlSeconds });
  return id;
}

/** Stash under a caller-provided key. Useful for view_id, opportunity_id, etc. */
export async function stashAt<T>(key: string, value: T, ttlSeconds = DEFAULT_TTL_SECONDS): Promise<void> {
  await redis.set(`s:${key}`, JSON.stringify(value), { ex: ttlSeconds });
}

export async function retrieve<T>(id: string): Promise<T | null> {
  const raw = await redis.get<string | T>(`s:${id}`);
  if (!raw) return null;
  return typeof raw === "string" ? (JSON.parse(raw) as T) : raw;
}

export async function drop(id: string): Promise<void> {
  await redis.del(`s:${id}`);
}

function generateId(): string {
  return Math.random().toString(36).slice(2, 8) + Math.random().toString(36).slice(2, 8);
}
