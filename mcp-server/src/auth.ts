#!/usr/bin/env node

/**
 * One-time OAuth login helper for the Salesforce MCP server.
 * Opens your browser to authenticate with Salesforce (supports MFA),
 * then saves tokens to ~/.sf_mcp_tokens.json for the MCP server to use.
 *
 * Usage: node auth.js
 */

import http from "http";
import open from "open";
import crypto from "crypto";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const TOKEN_FILE = path.join(
  process.env.HOME || process.env.USERPROFILE || ".",
  ".sf_mcp_tokens.json"
);

const CLIENT_ID = process.env.SF_CLIENT_ID || "";
const CLIENT_SECRET = process.env.SF_CLIENT_SECRET || "";
const LOGIN_URL = process.env.SF_LOGIN_URL || "https://login.salesforce.com";
const PORT = 9876;
const REDIRECT_URI = `http://localhost:${PORT}/callback`;

if (!CLIENT_ID || !CLIENT_SECRET) {
  console.error("\nMissing credentials. Run with:\n");
  console.error(
    `  SF_CLIENT_ID=your_client_id SF_CLIENT_SECRET=your_client_secret SF_LOGIN_URL=https://rogo.my.salesforce.com node auth.js\n`
  );
  process.exit(1);
}

// PKCE
const codeVerifier = crypto.randomBytes(32).toString("base64url");
const codeChallenge = crypto
  .createHash("sha256")
  .update(codeVerifier)
  .digest("base64url");

const authUrl =
  `${LOGIN_URL}/services/oauth2/authorize?` +
  `response_type=code` +
  `&client_id=${CLIENT_ID}` +
  `&redirect_uri=${encodeURIComponent(REDIRECT_URI)}` +
  `&scope=${encodeURIComponent("api refresh_token")}` +
  `&code_challenge=${codeChallenge}` +
  `&code_challenge_method=S256`;

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || "/", `http://localhost:${PORT}`);

  if (url.pathname !== "/callback") {
    res.writeHead(404);
    res.end("Not found");
    return;
  }

  const code = url.searchParams.get("code");
  const error = url.searchParams.get("error");

  if (error) {
    res.writeHead(200, { "Content-Type": "text/html" });
    res.end(
      `<h2>Authentication failed</h2><p>${url.searchParams.get("error_description") || error}</p>`
    );
    server.close();
    process.exit(1);
  }

  if (!code) {
    res.writeHead(400);
    res.end("Missing authorization code");
    return;
  }

  try {
    // Exchange code for tokens
    const tokenParams = new URLSearchParams({
      grant_type: "authorization_code",
      code,
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      redirect_uri: REDIRECT_URI,
      code_verifier: codeVerifier,
    });

    const tokenRes = await fetch(
      `${LOGIN_URL}/services/oauth2/token`,
      {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: tokenParams.toString(),
      }
    );

    if (!tokenRes.ok) {
      const errText = await tokenRes.text();
      throw new Error(`Token exchange failed: ${errText}`);
    }

    const tokens = (await tokenRes.json()) as {
      access_token: string;
      refresh_token: string;
      instance_url: string;
      id: string;
    };

    // Save tokens
    const tokenData = {
      accessToken: tokens.access_token,
      refreshToken: tokens.refresh_token,
      instanceUrl: tokens.instance_url,
      clientId: CLIENT_ID,
      clientSecret: CLIENT_SECRET,
      loginUrl: LOGIN_URL,
      savedAt: new Date().toISOString(),
    };

    fs.writeFileSync(TOKEN_FILE, JSON.stringify(tokenData, null, 2));

    console.log(`\nTokens saved to ${TOKEN_FILE}`);
    console.log(`Instance URL: ${tokens.instance_url}`);
    console.log(`\nYou can now use the MCP server. Restart Claude Desktop to connect.\n`);

    res.writeHead(200, { "Content-Type": "text/html" });
    res.end(`
      <html>
        <body style="font-family: system-ui; text-align: center; padding: 60px;">
          <h2 style="color: #22c55e;">Salesforce Connected!</h2>
          <p>Tokens saved. You can close this tab and restart Claude Desktop.</p>
          <p style="color: #888; font-size: 14px;">Instance: ${tokens.instance_url}</p>
        </body>
      </html>
    `);
  } catch (err: any) {
    console.error("Error:", err.message);
    res.writeHead(200, { "Content-Type": "text/html" });
    res.end(`<h2>Error</h2><p>${err.message}</p>`);
  }

  setTimeout(() => {
    server.close();
    process.exit(0);
  }, 1000);
});

server.listen(PORT, () => {
  console.log(`\nOpening browser for Salesforce login...`);
  console.log(`(If it doesn't open, go to: ${authUrl})\n`);

  // Try to open the browser
  import("child_process").then((cp) => {
    cp.exec(`open "${authUrl}"`);
  });
});
