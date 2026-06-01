import crypto from "node:crypto";
import { config } from "../config.js";
import { RED_TEAM_HTTP_TIMEOUT_MS } from "../constants.js";
import {
  ArbiterChatResponseSchema,
  type ArbiterChatRequest,
  type ArbiterChatResponse,
} from "../types.js";

export class ArbiterChatClientError extends Error {
  constructor(
    message: string,
    public status?: number
  ) {
    super(message);
  }
}

function signBody(body: string, timestamp: string, secret: string): string {
  return crypto
    .createHmac("sha256", secret)
    .update(`${timestamp}.${body}`)
    .digest("hex");
}

/**
 * POST a follow-up question to the Python `/arbiter/chat` endpoint. Shares
 * HMAC + secret + URL with `/arbiter` (same Vercel project, different route).
 *
 * The Python service is stateless — Merlin owns the conversation row in
 * `verdict_conversations` / `verdict_conversation_turns` and passes whatever
 * snapshot the moderator needs in the body each turn.
 */
export async function callArbiterChat(
  req: ArbiterChatRequest
): Promise<ArbiterChatResponse> {
  if (!config.redTeam.url) {
    throw new ArbiterChatClientError("RED_TEAM_AGENT_URL not configured");
  }
  if (!config.redTeam.secret) {
    throw new ArbiterChatClientError("RED_TEAM_AGENT_SECRET not configured");
  }

  const body = JSON.stringify(req);
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const signature = signBody(body, timestamp, config.redTeam.secret);

  const url = config.redTeam.url.replace(/\/+$/, "") + "/arbiter/chat";

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), RED_TEAM_HTTP_TIMEOUT_MS);
  let res: Response;
  try {
    res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-RedTeam-Signature": signature,
        "X-RedTeam-Timestamp": timestamp,
      },
      body,
      signal: ctrl.signal,
    });
  } catch (err: any) {
    throw new ArbiterChatClientError(
      `arbiter/chat fetch failed: ${err?.message ?? err}`
    );
  } finally {
    clearTimeout(timer);
  }

  const responseText = await res.text();
  if (!res.ok) {
    throw new ArbiterChatClientError(
      `arbiter/chat ${res.status}: ${responseText.slice(0, 400)}`,
      res.status
    );
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(responseText);
  } catch {
    throw new ArbiterChatClientError(
      `arbiter/chat returned non-JSON: ${responseText.slice(0, 200)}`
    );
  }
  const result = ArbiterChatResponseSchema.safeParse(parsed);
  if (!result.success) {
    throw new ArbiterChatClientError(
      `arbiter/chat response failed schema: ${result.error.message.slice(0, 400)}`
    );
  }
  return result.data;
}
