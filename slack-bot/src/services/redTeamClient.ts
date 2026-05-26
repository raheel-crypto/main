import crypto from "node:crypto";
import { config } from "../config.js";
import { RED_TEAM_HTTP_TIMEOUT_MS } from "../constants.js";
import {
  RedTeamRunResultSchema,
  type RedTeamIntelPackRequest,
  type RedTeamRunResult,
} from "../types.js";

export class RedTeamClientError extends Error {
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
 * POST an intel pack to the external Red Team Python service and parse the
 * structured response. Validates the response against `RedTeamRunResultSchema`.
 *
 * Throws `RedTeamClientError` on transport, HTTP, or shape errors so callers
 * can audit the failure and decide whether to retry.
 */
export async function evaluateRedTeam(
  pack: RedTeamIntelPackRequest
): Promise<RedTeamRunResult> {
  if (!config.redTeam.url) {
    throw new RedTeamClientError("RED_TEAM_AGENT_URL not configured");
  }
  if (!config.redTeam.secret) {
    throw new RedTeamClientError("RED_TEAM_AGENT_SECRET not configured");
  }

  const body = JSON.stringify(pack);
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const signature = signBody(body, timestamp, config.redTeam.secret);

  const url = config.redTeam.url.replace(/\/+$/, "") + "/evaluate";

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
    throw new RedTeamClientError(
      `red-team agent fetch failed: ${err?.message ?? err}`
    );
  } finally {
    clearTimeout(timer);
  }

  const responseText = await res.text();
  if (!res.ok) {
    throw new RedTeamClientError(
      `red-team agent ${res.status}: ${responseText.slice(0, 400)}`,
      res.status
    );
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(responseText);
  } catch (err: any) {
    throw new RedTeamClientError(
      `red-team agent returned non-JSON: ${responseText.slice(0, 200)}`
    );
  }
  const result = RedTeamRunResultSchema.safeParse(parsed);
  if (!result.success) {
    throw new RedTeamClientError(
      `red-team agent response failed schema: ${result.error.message.slice(0, 400)}`
    );
  }
  return result.data;
}
