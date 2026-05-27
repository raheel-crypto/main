import crypto from "node:crypto";
import { config } from "../config.js";
import { RED_TEAM_HTTP_TIMEOUT_MS } from "../constants.js";
import {
  ArbiterVerdictSchema,
  type ArbiterVerdict,
  type RedTeamIntelPackRequest,
} from "../types.js";

export class ArbiterClientError extends Error {
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
 * POST an intel pack to the Python `/arbiter` endpoint and parse the
 * structured `ArbiterVerdict` response. Shares HMAC + secret + URL with
 * the Red Team endpoint (same Vercel project, different route).
 *
 * Throws `ArbiterClientError` on transport / HTTP / shape failures so
 * callers can audit cleanly.
 */
export async function evaluateArbiter(
  pack: RedTeamIntelPackRequest
): Promise<ArbiterVerdict> {
  if (!config.redTeam.url) {
    throw new ArbiterClientError("RED_TEAM_AGENT_URL not configured");
  }
  if (!config.redTeam.secret) {
    throw new ArbiterClientError("RED_TEAM_AGENT_SECRET not configured");
  }

  const body = JSON.stringify(pack);
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const signature = signBody(body, timestamp, config.redTeam.secret);

  const url = config.redTeam.url.replace(/\/+$/, "") + "/arbiter";

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
    throw new ArbiterClientError(
      `arbiter fetch failed: ${err?.message ?? err}`
    );
  } finally {
    clearTimeout(timer);
  }

  const responseText = await res.text();
  if (!res.ok) {
    throw new ArbiterClientError(
      `arbiter ${res.status}: ${responseText.slice(0, 400)}`,
      res.status
    );
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(responseText);
  } catch {
    throw new ArbiterClientError(
      `arbiter returned non-JSON: ${responseText.slice(0, 200)}`
    );
  }
  const result = ArbiterVerdictSchema.safeParse(parsed);
  if (!result.success) {
    throw new ArbiterClientError(
      `arbiter response failed schema: ${result.error.message.slice(0, 400)}`
    );
  }
  return result.data;
}
