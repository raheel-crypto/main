import crypto from "node:crypto";
import { config } from "../config.js";
import { RED_TEAM_HTTP_TIMEOUT_MS } from "../constants.js";
import {
  NextMovesResponseSchema,
  type NextMovesRequest,
  type NextMovesResponse,
} from "../types.js";

export class NextMovesClientError extends Error {
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
 * POST a NextMovesRequest to the Python `/blue/next-moves` endpoint.
 * Reuses the same HMAC + secret + URL as `/arbiter` and `/arbiter/chat`.
 */
export async function callBlueNextMoves(
  req: NextMovesRequest
): Promise<NextMovesResponse> {
  if (!config.redTeam.url) {
    throw new NextMovesClientError("RED_TEAM_AGENT_URL not configured");
  }
  if (!config.redTeam.secret) {
    throw new NextMovesClientError("RED_TEAM_AGENT_SECRET not configured");
  }

  const body = JSON.stringify(req);
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const signature = signBody(body, timestamp, config.redTeam.secret);

  const url = config.redTeam.url.replace(/\/+$/, "") + "/blue/next-moves";

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
    throw new NextMovesClientError(
      `blue/next-moves fetch failed: ${err?.message ?? err}`
    );
  } finally {
    clearTimeout(timer);
  }

  const responseText = await res.text();
  if (!res.ok) {
    throw new NextMovesClientError(
      `blue/next-moves ${res.status}: ${responseText.slice(0, 400)}`,
      res.status
    );
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(responseText);
  } catch {
    throw new NextMovesClientError(
      `blue/next-moves returned non-JSON: ${responseText.slice(0, 200)}`
    );
  }
  const result = NextMovesResponseSchema.safeParse(parsed);
  if (!result.success) {
    throw new NextMovesClientError(
      `blue/next-moves response failed schema: ${result.error.message.slice(0, 400)}`
    );
  }
  return result.data;
}
