import crypto from "crypto";
import jsforce, { Connection } from "jsforce";
import { config } from "../config.js";

const oauth2 = new jsforce.OAuth2({
  clientId: config.salesforce.clientId,
  clientSecret: config.salesforce.clientSecret,
  redirectUri: config.salesforce.callbackUrl,
  loginUrl: config.salesforce.loginUrl,
});

// PKCE helpers
function generateCodeVerifier(): string {
  return crypto.randomBytes(32).toString("base64url");
}

function generateCodeChallenge(verifier: string): string {
  return crypto.createHash("sha256").update(verifier).digest("base64url");
}

export function getAuthorizationUrl(): {
  url: string;
  codeVerifier: string;
} {
  const codeVerifier = generateCodeVerifier();
  const codeChallenge = generateCodeChallenge(codeVerifier);

  const baseUrl = oauth2.getAuthorizationUrl({ scope: "api refresh_token" });
  const url =
    baseUrl +
    `&code_challenge=${codeChallenge}&code_challenge_method=S256`;

  return { url, codeVerifier };
}

export async function handleCallback(
  code: string,
  codeVerifier: string
): Promise<{
  accessToken: string;
  refreshToken: string;
  instanceUrl: string;
  userId: string;
  orgId: string;
  userName: string;
  userEmail: string;
}> {
  // Exchange authorization code for tokens with PKCE verifier
  const params = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    client_id: config.salesforce.clientId,
    client_secret: config.salesforce.clientSecret,
    redirect_uri: config.salesforce.callbackUrl,
    code_verifier: codeVerifier,
  });

  const tokenUrl = `${config.salesforce.loginUrl}/services/oauth2/token`;
  const tokenRes = await fetch(tokenUrl, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: params.toString(),
  });

  if (!tokenRes.ok) {
    const err = await tokenRes.text();
    throw new Error(`Token exchange failed: ${err}`);
  }

  const tokenData = (await tokenRes.json()) as {
    access_token: string;
    refresh_token: string;
    instance_url: string;
    id: string;
  };

  // Get user identity
  const identityRes = await fetch(tokenData.id, {
    headers: { Authorization: `Bearer ${tokenData.access_token}` },
  });

  if (!identityRes.ok) {
    throw new Error("Failed to fetch user identity");
  }

  const identity = (await identityRes.json()) as {
    user_id: string;
    organization_id: string;
    display_name: string;
    email: string;
  };

  return {
    accessToken: tokenData.access_token,
    refreshToken: tokenData.refresh_token,
    instanceUrl: tokenData.instance_url,
    userId: identity.user_id,
    orgId: identity.organization_id,
    userName: identity.display_name,
    userEmail: identity.email,
  };
}

export function getConnection(session: {
  accessToken: string;
  refreshToken: string;
  instanceUrl: string;
}): Connection {
  return new jsforce.Connection({
    oauth2,
    accessToken: session.accessToken,
    refreshToken: session.refreshToken,
    instanceUrl: session.instanceUrl,
  });
}
