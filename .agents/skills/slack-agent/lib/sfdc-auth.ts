import { createSign } from "node:crypto";

interface CachedToken {
  access_token: string;
  instance_url: string;
  expires_at: number;
}

let cached: CachedToken | null = null;

/**
 * Get a Salesforce access token using JWT Bearer flow.
 * Caches the token for 50 minutes (SFDC tokens last ~2h, refresh well before).
 */
export async function getSFDCAccessToken(): Promise<{
  accessToken: string;
  instanceUrl: string;
}> {
  if (cached && Date.now() < cached.expires_at) {
    return { accessToken: cached.access_token, instanceUrl: cached.instance_url };
  }

  const consumerKey = required("SFDC_CONSUMER_KEY");
  const username = required("SFDC_USERNAME");
  const loginUrl = required("SFDC_LOGIN_URL");
  const privateKey = required("SFDC_PRIVATE_KEY");

  // Build the JWT
  const header = base64UrlEncode(JSON.stringify({ alg: "RS256" }));
  const now = Math.floor(Date.now() / 1000);
  const payload = base64UrlEncode(
    JSON.stringify({
      iss: consumerKey,
      sub: username,
      aud: "https://login.salesforce.com",
      exp: now + 300,
    }),
  );

  const signingInput = `${header}.${payload}`;
  const signer = createSign("RSA-SHA256");
  signer.update(signingInput);
  const signature = signer.sign(privateKey, "base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

  const jwt = `${signingInput}.${signature}`;

  // Exchange the JWT for an access token
  const res = await fetch(`${loginUrl}/services/oauth2/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }).toString(),
  });

  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`SFDC JWT auth failed: ${res.status} ${errText}`);
  }

  const data = (await res.json()) as { access_token: string; instance_url: string };

  cached = {
    access_token: data.access_token,
    instance_url: data.instance_url,
    expires_at: Date.now() + 50 * 60 * 1000,
  };

  return { accessToken: data.access_token, instanceUrl: data.instance_url };
}

function base64UrlEncode(input: string): string {
  return Buffer.from(input).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env var: ${name}`);
  return v;
}
