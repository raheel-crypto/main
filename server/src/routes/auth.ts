import { Router } from "express";
import crypto from "crypto";
import {
  getAuthorizationUrl,
  handleCallback,
  SFEnvironment,
} from "../services/salesforce.js";
import { config } from "../config.js";

function generateCodeVerifier() {
  return crypto.randomBytes(32).toString("base64url");
}
function generateCodeChallenge(v: string) {
  return crypto.createHash("sha256").update(v).digest("base64url");
}

const router = Router();

// Main login — accepts ?env=sandbox to switch environment
router.get("/login", (req, res) => {
  const env = (req.query.env as string) === "sandbox" ? "sandbox" : "production";
  const { url, codeVerifier } = getAuthorizationUrl(env);

  (req.session as any).codeVerifier = codeVerifier;
  (req.session as any).pendingEnv = env;
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
    const env: SFEnvironment = (req.session as any).pendingEnv || "production";
    if (!codeVerifier) {
      res.redirect(`${config.clientUrl}?error=missing_code_verifier`);
      return;
    }

    const sfData = await handleCallback(code, codeVerifier, env);
    req.session.sf = sfData;
    delete (req.session as any).codeVerifier;
    delete (req.session as any).pendingEnv;
    delete req.session.mcpToken;

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
        environment: req.session.sf.environment || "production",
      },
    });
  } else {
    res.json({ authenticated: false });
  }
});

// Check which environments are configured
router.get("/environments", (_req, res) => {
  res.json({
    production: !!config.salesforce.clientId,
    sandbox: !!(config.sandbox.clientId || config.salesforce.clientId),
  });
});

// MCP OAuth — uses External Client App credentials
router.get("/mcp-login", (req, res) => {
  const env = req.session.sf?.environment || "production";
  const mcpCreds = env === "sandbox" && config.mcpSandbox.clientId
    ? config.mcpSandbox
    : config.mcpApp;

  console.log(`[mcp-login] env=${env}, clientId=${mcpCreds.clientId ? "set" : "MISSING"}, instanceUrl=${req.session.sf?.instanceUrl || "MISSING"}`);

  if (!mcpCreds.clientId) {
    res.status(400).json({ message: "MCP client app not configured for this environment" });
    return;
  }

  const instanceUrl = req.session.sf?.instanceUrl;
  if (!instanceUrl) {
    console.log("[mcp-login] No instanceUrl in session, redirecting with error");
    res.redirect(`${config.clientUrl}/sf-mcp?error=not_logged_in`);
    return;
  }

  const codeVerifier = generateCodeVerifier();
  const codeChallenge = generateCodeChallenge(codeVerifier);
  (req.session as any).mcpCodeVerifier = codeVerifier;

  const redirectUrl = `${instanceUrl}/services/oauth2/authorize`;
  console.log(`[mcp-login] Redirecting to ${redirectUrl}`);

  const params = new URLSearchParams({
    response_type: "code",
    client_id: mcpCreds.clientId,
    redirect_uri: config.mcpApp.callbackUrl,
    scope: "mcp_api",
    code_challenge: codeChallenge,
    code_challenge_method: "S256",
  });

  req.session.save(() => {
    res.redirect(`${redirectUrl}?${params}`);
  });
});

router.get("/mcp-callback", async (req, res) => {
  console.log("[mcp-callback] Hit callback");
  try {
    const code = req.query.code as string;
    if (!code) {
      console.log("[mcp-callback] No code in query params");
      res.redirect(`${config.clientUrl}/sf-mcp?error=no_code`);
      return;
    }

    const codeVerifier = (req.session as any).mcpCodeVerifier;
    const instanceUrl = req.session.sf?.instanceUrl;
    const env = req.session.sf?.environment || "production";
    console.log(`[mcp-callback] codeVerifier=${codeVerifier ? "set" : "MISSING"}, instanceUrl=${instanceUrl || "MISSING"}`);
    if (!codeVerifier || !instanceUrl) {
      console.log("[mcp-callback] Session lost - missing codeVerifier or instanceUrl");
      res.redirect(`${config.clientUrl}/sf-mcp?error=session_lost`);
      return;
    }

    const mcpCreds = env === "sandbox" && config.mcpSandbox.clientId
      ? config.mcpSandbox
      : config.mcpApp;

    const params = new URLSearchParams({
      grant_type: "authorization_code",
      code,
      client_id: mcpCreds.clientId,
      client_secret: mcpCreds.clientSecret,
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

router.get("/mcp-status", (req, res) => {
  const env = req.session.sf?.environment || "production";
  const mcpCreds = env === "sandbox" && config.mcpSandbox.clientId
    ? config.mcpSandbox
    : config.mcpApp;
  res.json({
    configured: !!mcpCreds.clientId,
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
