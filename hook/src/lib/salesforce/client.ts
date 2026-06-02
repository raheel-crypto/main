import jsforce from "jsforce";
import jwt from "jsonwebtoken";
import { sql } from "@/lib/db/client";

interface CachedToken {
  access_token: string;
  instance_url: string;
  expires_at: number;
}

let cached: CachedToken | null = null;

async function loadCachedToken(): Promise<CachedToken | null> {
  if (cached && cached.expires_at > Date.now() + 60_000) return cached;
  const rows = (await sql`
    SELECT access_token, instance_url, expires_at
    FROM sf_token_cache
    WHERE id = 'singleton' AND expires_at > NOW() + INTERVAL '1 minute'
    LIMIT 1
  `) as CachedToken[];
  if (rows.length > 0) {
    cached = rows[0]!;
    return cached;
  }
  return null;
}

async function persistToken(token: CachedToken): Promise<void> {
  cached = token;
  await sql`
    INSERT INTO sf_token_cache (id, access_token, instance_url, expires_at)
    VALUES ('singleton', ${token.access_token}, ${token.instance_url}, to_timestamp(${token.expires_at / 1000}))
    ON CONFLICT (id) DO UPDATE SET
      access_token = EXCLUDED.access_token,
      instance_url = EXCLUDED.instance_url,
      expires_at = EXCLUDED.expires_at
  `;
}

async function mintToken(): Promise<CachedToken> {
  const loginUrl = process.env.SF_LOGIN_URL ?? "https://login.salesforce.com";
  const clientId = process.env.SF_CLIENT_ID!;
  const username = process.env.SF_USERNAME!;
  const privateKey = process.env.SF_PRIVATE_KEY!;

  const assertion = jwt.sign(
    {
      iss: clientId,
      sub: username,
      aud: loginUrl,
      exp: Math.floor(Date.now() / 1000) + 180,
    },
    privateKey,
    { algorithm: "RS256" },
  );

  const res = await fetch(`${loginUrl}/services/oauth2/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });

  if (!res.ok) throw new Error(`SF token mint failed: ${res.status} ${await res.text()}`);
  const body = (await res.json()) as { access_token: string; instance_url: string };
  return {
    access_token: body.access_token,
    instance_url: body.instance_url,
    expires_at: Date.now() + 2 * 60 * 60 * 1000,
  };
}

export async function getSalesforceConnection(): Promise<jsforce.Connection> {
  let token = await loadCachedToken();
  if (!token) {
    token = await mintToken();
    await persistToken(token);
  }
  return new jsforce.Connection({
    instanceUrl: token.instance_url,
    accessToken: token.access_token,
  });
}
