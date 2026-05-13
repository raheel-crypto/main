import type { IncomingMessage, ServerResponse } from "node:http";
import { completeAuthorization } from "../../../src/services/salesforceAuth.js";

const SUCCESS_HTML = `<!doctype html>
<meta charset="utf-8" />
<title>Salesforce connected</title>
<body style="font-family: system-ui; text-align: center; padding: 60px;">
  <h2 style="color: #22c55e;">Salesforce connected.</h2>
  <p>You can close this tab and return to Slack. Run <code>/standup</code> to test.</p>
</body>`;

export default async function handler(
  req: IncomingMessage,
  res: ServerResponse
) {
  try {
    const url = new URL(req.url || "/", "http://localhost");
    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state");
    if (!code || !state) {
      res.statusCode = 400;
      res.end("Missing code or state");
      return;
    }
    await completeAuthorization(code, state);
    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.end(SUCCESS_HTML);
  } catch (err: any) {
    console.error("[oauth/sf/callback] error:", err);
    res.statusCode = 400;
    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.end(
      `<h2>Salesforce connection failed</h2><p>${escapeHtml(err.message)}</p>`
    );
  }
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!
  );
}
