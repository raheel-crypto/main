import crypto from "node:crypto";
import { config } from "../config.js";
import {
  consumeGcOauthState,
  insertGcOauthState,
  upsertGcTokens,
} from "../db/queries.js";

const AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token";
const USERINFO_ENDPOINT = "https://openidconnect.googleapis.com/v1/userinfo";

const SCOPES = [
  "https://www.googleapis.com/auth/calendar.events.readonly",
  "https://www.googleapis.com/auth/userinfo.email",
  "openid",
];

function b64url(buf: Buffer): string {
  return buf.toString("base64url");
}

function sign(slackUserId: string, nonce: string): string {
  return b64url(
    crypto
      .createHmac("sha256", config.oauthStateSecret)
      .update(`google.${slackUserId}.${nonce}`)
      .digest()
  );
}

export function buildGoogleAuthorizationUrl(slackUserId: string): {
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
    client_id: config.google.clientId,
    redirect_uri: config.google.callbackUrl,
    scope: SCOPES.join(" "),
    code_challenge: codeChallenge,
    code_challenge_method: "S256",
    access_type: "offline",
    prompt: "consent",
    include_granted_scopes: "true",
    state,
  });
  return {
    url: `${AUTH_ENDPOINT}?${params}`,
    state,
    codeVerifier,
  };
}

export async function startGoogleAuthorization(
  slackUserId: string
): Promise<string> {
  const { url, state, codeVerifier } = buildGoogleAuthorizationUrl(slackUserId);
  await insertGcOauthState(state, slackUserId, codeVerifier);
  return url;
}

function verifyState(state: string): string | null {
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

export async function completeGoogleAuthorization(
  code: string,
  state: string
): Promise<{ slackUserId: string; googleEmail: string | null }> {
  const slackUserId = verifyState(state);
  if (!slackUserId) throw new Error("Invalid Google OAuth state");

  const row = await consumeGcOauthState(state);
  if (!row) throw new Error("OAuth state expired or already used");

  const params = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    client_id: config.google.clientId,
    client_secret: config.google.clientSecret,
    redirect_uri: config.google.callbackUrl,
    code_verifier: row.codeVerifier,
  });

  const tokenRes = await fetch(TOKEN_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: params.toString(),
  });
  if (!tokenRes.ok) {
    const err = await tokenRes.text();
    throw new Error(`Google token exchange failed: ${err}`);
  }
  const tokenData = (await tokenRes.json()) as {
    access_token: string;
    refresh_token?: string;
    expires_in: number;
    scope: string;
    token_type: string;
    id_token?: string;
  };
  if (!tokenData.refresh_token) {
    throw new Error(
      "Google did not return a refresh_token. Revoke the app at myaccount.google.com/permissions and reconnect."
    );
  }

  let googleEmail: string | null = null;
  try {
    const userinfoRes = await fetch(USERINFO_ENDPOINT, {
      headers: { Authorization: `Bearer ${tokenData.access_token}` },
    });
    if (userinfoRes.ok) {
      const ui = (await userinfoRes.json()) as { email?: string };
      googleEmail = ui.email ?? null;
    }
  } catch {}

  const expiresAt = new Date(
    Date.now() + tokenData.expires_in * 1000
  ).toISOString();

  await upsertGcTokens({
    slackUserId,
    accessToken: tokenData.access_token,
    refreshToken: tokenData.refresh_token,
    expiresAt,
    googleEmail,
  });

  return { slackUserId, googleEmail };
}

export async function refreshAccessToken(
  refreshToken: string
): Promise<{ accessToken: string; expiresAtIso: string }> {
  const params = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: refreshToken,
    client_id: config.google.clientId,
    client_secret: config.google.clientSecret,
  });
  const res = await fetch(TOKEN_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: params.toString(),
  });
  if (!res.ok) {
    const err = await res.text();
    throw new Error(`Google refresh failed: ${err}`);
  }
  const data = (await res.json()) as {
    access_token: string;
    expires_in: number;
  };
  const expiresAtIso = new Date(Date.now() + data.expires_in * 1000).toISOString();
  return { accessToken: data.access_token, expiresAtIso };
}
