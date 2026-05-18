import type { IncomingMessage, ServerResponse } from "node:http";
import { completeGoogleAuthorization } from "../../../src/services/googleAuth.js";

const SUCCESS_HTML = `<!doctype html>
<meta charset="utf-8" />
<title>Google Calendar connected</title>
<body style="font-family: system-ui; text-align: center; padding: 60px;">
  <h2 style="color: #22c55e;">Google Calendar connected.</h2>
  <p>You can close this tab and return to Slack. Run <code>/subscriptions</code> to choose pre- and post-meeting briefs.</p>
</body>`;

export default async function handler(
  req: IncomingMessage,
  res: ServerResponse
) {
  try {
    const url = new URL(req.url || "/", "http://localhost");
    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state");
    const errorParam = url.searchParams.get("error");
    if (errorParam) {
      res.statusCode = 400;
      res.setHeader("Content-Type", "text/html; charset=utf-8");
      res.end(`<h2>Google connection cancelled</h2><p>${escapeHtml(errorParam)}</p>`);
      return;
    }
    if (!code || !state) {
      res.statusCode = 400;
      res.end("Missing code or state");
      return;
    }
    await completeGoogleAuthorization(code, state);
    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.end(SUCCESS_HTML);
  } catch (err: any) {
    console.error("[oauth/google/callback] error:", err);
    res.statusCode = 400;
    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.end(
      `<h2>Google connection failed</h2><p>${escapeHtml(err.message)}</p>`
    );
  }
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!
  );
}
