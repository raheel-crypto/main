import jsforce, { Connection } from "jsforce";
import { config } from "../config.js";

const oauth2 = new jsforce.OAuth2({
  clientId: config.salesforce.clientId,
  clientSecret: config.salesforce.clientSecret,
  redirectUri: config.salesforce.callbackUrl,
  loginUrl: config.salesforce.loginUrl,
});

export function getAuthorizationUrl(): string {
  return oauth2.getAuthorizationUrl({ scope: "api refresh_token" });
}

export async function handleCallback(
  code: string
): Promise<{
  accessToken: string;
  refreshToken: string;
  instanceUrl: string;
  userId: string;
  orgId: string;
  userName: string;
  userEmail: string;
}> {
  const conn = new jsforce.Connection({ oauth2 });
  await conn.authorize(code);

  const identity = await conn.identity();

  return {
    accessToken: conn.accessToken!,
    refreshToken: conn.refreshToken!,
    instanceUrl: conn.instanceUrl,
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
