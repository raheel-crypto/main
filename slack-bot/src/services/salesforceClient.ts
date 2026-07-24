import jsforce, { Connection } from "jsforce";
import { config } from "../config.js";
import { getSfTokens, updateSfAccessToken } from "../db/queries.js";

export class SfNotConnectedError extends Error {
  constructor(public slackUserId: string) {
    super(`Salesforce not connected for ${slackUserId}`);
  }
}

export async function getConnectionForUser(
  slackUserId: string
): Promise<Connection> {
  const tokens = await getSfTokens(slackUserId);
  if (!tokens) throw new SfNotConnectedError(slackUserId);

  const oauth2 = new jsforce.OAuth2({
    clientId: config.salesforce.clientId,
    clientSecret: config.salesforce.clientSecret,
    redirectUri: config.salesforce.callbackUrl,
    loginUrl: config.salesforce.loginUrl,
  });

  const conn = new jsforce.Connection({
    oauth2,
    accessToken: tokens.accessToken,
    refreshToken: tokens.refreshToken,
    instanceUrl: tokens.instanceUrl,
  });

  conn.on("refresh", (newAccessToken: string) => {
    updateSfAccessToken(slackUserId, newAccessToken).catch((err) => {
      console.error(`[sf] persist refreshed token failed for ${slackUserId}:`, err);
    });
  });

  return conn;
}
