import { Router } from "express";
import crypto from "crypto";
import {
  getAuthorizationUrl,
  handleCallback,
} from "../services/salesforce.js";
import { config } from "../config.js";

function generateCodeVerifier() {
  return crypto.randomBytes(32).toString("base64url");
}
function generateCodeChallenge(v: string) {
  return crypto.createHash("sha256").update(v).digest("base64url");
}

const router = Router();

router.get("/login", (req, res) => {
  const { url, codeVerifier } = getAuthorizationUrl();

  // Store the PKCE code verifier in the session for the callback
  (req.session as any).codeVerifier = codeVerifier;
  req.session.save(() => {
    res.redirect(url);
  });
});

router.get("/callback", async (req, res) => {
  try {
    const code = req.query.code as string;
    if (!code) {
      res.redirect(`${config.clientUrl}?error=no_code`);
      return;
    }

    const codeVerifier = (req.session as any).codeVerifier;
    if (!codeVerifier) {
      res.redirect(`${config.clientUrl}?error=missing_code_verifier`);
      return;
    }

    const sfData = await handleCallback(code, codeVerifier);
    req.session.sf = sfData;
    delete (req.session as any).codeVerifier;

    res.redirect(config.clientUrl);
  } catch (error: any) {
    console.error("OAuth callback error:", error);
    res.redirect(
      `${config.clientUrl}?error=${encodeURIComponent(error.message)}`
    );
  }
});

router.get("/status", (req, res) => {
  if (req.session.sf) {
    res.json({
      authenticated: true,
      user: {
        name: req.session.sf.userName,
        email: req.session.sf.userEmail,
        orgId: req.session.sf.orgId,
        instanceUrl: req.session.sf.instanceUrl,
      },
    });
  } else {
    res.json({ authenticated: false });
  }
});

// MCP OAuth routes — uses the External Client App credentials to get an sfap_api token
router.get("/mcp-login", (req, res) => {
  if (!config.mcpApp.clientId) {
    res.status(400).json({ message: "SF_MCP_CLIENT_ID not configured" });
    return;
  }
  const instanceUrl = req.session.sf?.instanceUrl;
  if (!instanceUrl) {
    res.redirect(`${config.clientUrl}/sf-mcp?error=not_logged_in`);
    return;
  }

  const codeVerifier = generateCodeVerifier();
  const codeChallenge = generateCodeChallenge(codeVerifier);
  (req.session as any).mcpCodeVerifier = codeVerifier;

  const params = new URLSearchParams({
    response_type: "code",
    client_id: config.mcpApp.clientId,
    redirect_uri: config.mcpApp.callbackUrl,
    scope: "mcp_api",
    code_challenge: codeChallenge,
    code_challenge_method: "S256",
  });

  req.session.save(() => {
    res.redirect(`${instanceUrl}/services/oauth2/authorize?${params}`);
  });
});

router.get("/mcp-callback", async (req, res) => {
  try {
    const code = req.query.code as string;
    if (!code) {
      res.redirect(`${config.clientUrl}/sf-mcp?error=no_code`);
      return;
    }

    const codeVerifier = (req.session as any).mcpCodeVerifier;
    const instanceUrl = req.session.sf?.instanceUrl;
    if (!codeVerifier || !instanceUrl) {
      res.redirect(`${config.clientUrl}/sf-mcp?error=session_lost`);
      return;
    }

    const params = new URLSearchParams({
      grant_type: "authorization_code",
      code,
      client_id: config.mcpApp.clientId,
      client_secret: config.mcpApp.clientSecret,
      redirect_uri: config.mcpApp.callbackUrl,
      code_verifier: codeVerifier,
    });

    const tokenRes = await fetch(`${instanceUrl}/services/oauth2/token`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: params.toString(),
    });

    if (!tokenRes.ok) {
      const err = await tokenRes.text();
      console.error("[mcp-callback] Token exchange failed:", err);
      res.redirect(`${config.clientUrl}/sf-mcp?error=${encodeURIComponent("Token exchange failed")}`);
      return;
    }

    const tokenData = (await tokenRes.json()) as { access_token: string };
    req.session.mcpToken = tokenData.access_token;
    delete (req.session as any).mcpCodeVerifier;

    res.redirect(`${config.clientUrl}/sf-mcp?mcpConnected=true`);
  } catch (err: any) {
    console.error("[mcp-callback] Error:", err);
    res.redirect(`${config.clientUrl}/sf-mcp?error=${encodeURIComponent(err.message)}`);
  }
});

// GET /auth/mcp-status — whether External Client App is configured and connected
router.get("/mcp-status", (req, res) => {
  res.json({
    configured: !!config.mcpApp.clientId,
    connected: !!req.session.mcpToken,
  });
});

router.post("/logout", (req, res) => {
  req.session.destroy((err) => {
    if (err) {
      res.status(500).json({ message: "Failed to logout" });
      return;
    }
    res.json({ message: "Logged out" });
  });
});

export default router;
