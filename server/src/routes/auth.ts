import { Router } from "express";
import {
  getAuthorizationUrl,
  handleCallback,
} from "../services/salesforce.js";
import { config } from "../config.js";

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
