import type { IncomingMessage, ServerResponse } from "node:http";
import { startGoogleAuthorization } from "../../../src/services/googleAuth.js";

export default async function handler(
  req: IncomingMessage,
  res: ServerResponse
) {
  try {
    const url = new URL(req.url || "/", "http://localhost");
    const slackUserId = url.searchParams.get("slack_user_id");
    if (!slackUserId) {
      res.statusCode = 400;
      res.end("slack_user_id required");
      return;
    }
    const authUrl = await startGoogleAuthorization(slackUserId);
    res.statusCode = 302;
    res.setHeader("Location", authUrl);
    res.end();
  } catch (err: any) {
    console.error("[oauth/google/start] error:", err);
    res.statusCode = 500;
    res.end(err.message);
  }
}
