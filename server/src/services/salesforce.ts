import crypto from "crypto";
import jsforce, { Connection } from "jsforce";
import { config } from "../config.js";

export type SFEnvironment = "production" | "sandbox";

function getCredentials(env: SFEnvironment) {
  if (env === "sandbox" && config.sandbox.clientId) {
    return {
      clientId: config.sandbox.clientId,
      clientSecret: config.sandbox.clientSecret,
      loginUrl: "https://test.salesforce.com",
    };
  }
  return {
    clientId: config.salesforce.clientId,
    clientSecret: config.salesforce.clientSecret,
    loginUrl: env === "sandbox" ? "https://test.salesforce.com" : config.salesforce.loginUrl,
  };
}

function generateCodeVerifier(): string {
  return crypto.randomBytes(32).toString("base64url");
}

function generateCodeChallenge(verifier: string): string {
  return crypto.createHash("sha256").update(verifier).digest("base64url");
}

export function getAuthorizationUrl(env: SFEnvironment): {
  url: string;
  codeVerifier: string;
} {
  const creds = getCredentials(env);
  const codeVerifier = generateCodeVerifier();
  const codeChallenge = generateCodeChallenge(codeVerifier);

  const params = new URLSearchParams({
    response_type: "code",
    client_id: creds.clientId,
    redirect_uri: config.salesforce.callbackUrl,
    scope: "api refresh_token",
    code_challenge: codeChallenge,
    code_challenge_method: "S256",
  });

  const url = `${creds.loginUrl}/services/oauth2/authorize?${params}`;
  return { url, codeVerifier };
}

export async function handleCallback(
  code: string,
  codeVerifier: string,
  env: SFEnvironment
): Promise<{
  accessToken: string;
  refreshToken: string;
  instanceUrl: string;
  userId: string;
  orgId: string;
  userName: string;
  userEmail: string;
  environment: SFEnvironment;
}> {
  const creds = getCredentials(env);

  const params = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    client_id: creds.clientId,
    client_secret: creds.clientSecret,
    redirect_uri: config.salesforce.callbackUrl,
    code_verifier: codeVerifier,
  });

  const tokenUrl = `${creds.loginUrl}/services/oauth2/token`;
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
    environment: env,
  };
}

export function getConnection(session: {
  accessToken: string;
  refreshToken: string;
  instanceUrl: string;
}): Connection {
  const oauth2 = new jsforce.OAuth2({
    clientId: config.salesforce.clientId,
    clientSecret: config.salesforce.clientSecret,
    redirectUri: config.salesforce.callbackUrl,
    loginUrl: config.salesforce.loginUrl,
  });

  return new jsforce.Connection({
    oauth2,
    accessToken: session.accessToken,
    refreshToken: session.refreshToken,
    instanceUrl: session.instanceUrl,
  });
}
