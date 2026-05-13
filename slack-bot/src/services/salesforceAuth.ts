import crypto from "node:crypto";
import { config } from "../config.js";
import {
  consumeOauthState,
  insertOauthState,
  upsertSfTokens,
} from "../db/queries.js";

function b64url(buf: Buffer): string {
  return buf.toString("base64url");
}

function sign(slackUserId: string, nonce: string): string {
  return b64url(
    crypto
      .createHmac("sha256", config.oauthStateSecret)
      .update(`${slackUserId}.${nonce}`)
      .digest()
  );
}

export function buildAuthorizationUrl(slackUserId: string): {
  url: string;
  state: string;
  codeVerifier: string;
} {
  const codeVerifier = b64url(crypto.randomBytes(32));
  const codeChallenge = b64url(
    crypto.createHash("sha256").update(codeVerifier).digest()
  );
  const nonce = b64url(crypto.randomBytes(16));
  const sig = sign(slackUserId, nonce);
  const state = `${slackUserId}:${nonce}:${sig}`;

  const params = new URLSearchParams({
    response_type: "code",
    client_id: config.salesforce.clientId,
    redirect_uri: config.salesforce.callbackUrl,
    scope: "api refresh_token",
    code_challenge: codeChallenge,
    code_challenge_method: "S256",
    state,
  });

  return {
    url: `${config.salesforce.loginUrl}/services/oauth2/authorize?${params}`,
    state,
    codeVerifier,
  };
}

export async function startAuthorization(slackUserId: string): Promise<string> {
  const { url, state, codeVerifier } = buildAuthorizationUrl(slackUserId);
  await insertOauthState(state, slackUserId, codeVerifier);
  return url;
}

export function verifyState(state: string): string | null {
  const parts = state.split(":");
  if (parts.length !== 3) return null;
  const [slackUserId, nonce, sig] = parts;
  const expected = sign(slackUserId, nonce);
  const a = Buffer.from(sig);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return null;
  if (!crypto.timingSafeEqual(a, b)) return null;
  return slackUserId;
}

export async function completeAuthorization(
  code: string,
  state: string
): Promise<{ slackUserId: string; sfUserEmail: string | null }> {
  const slackUserId = verifyState(state);
  if (!slackUserId) throw new Error("Invalid OAuth state");

  const row = await consumeOauthState(state);
  if (!row) throw new Error("OAuth state expired or already used");

  const params = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    client_id: config.salesforce.clientId,
    client_secret: config.salesforce.clientSecret,
    redirect_uri: config.salesforce.callbackUrl,
    code_verifier: row.codeVerifier,
  });

  const tokenRes = await fetch(
    `${config.salesforce.loginUrl}/services/oauth2/token`,
    {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: params.toString(),
    }
  );
  if (!tokenRes.ok) {
    const err = await tokenRes.text();
    throw new Error(`SF token exchange failed: ${err}`);
  }
  const tokenData = (await tokenRes.json()) as {
    access_token: string;
    refresh_token: string;
    instance_url: string;
    id: string;
  };

  let sfUserId: string | null = null;
  let sfUserEmail: string | null = null;
  try {
    const identRes = await fetch(tokenData.id, {
      headers: { Authorization: `Bearer ${tokenData.access_token}` },
    });
    if (identRes.ok) {
      const ident = (await identRes.json()) as {
        user_id: string;
        email: string;
      };
      sfUserId = ident.user_id;
      sfUserEmail = ident.email;
    }
  } catch {}

  await upsertSfTokens({
    slackUserId,
    accessToken: tokenData.access_token,
    refreshToken: tokenData.refresh_token,
    instanceUrl: tokenData.instance_url,
    sfUserId,
    sfUserEmail,
    environment: "production",
  });

  return { slackUserId, sfUserEmail };
}
