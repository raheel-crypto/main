import { Router } from "express";
import { getConnection } from "../services/salesforce.js";
import {
  scanAccountFamilies,
  proposeHierarchy,
  applyHierarchyChanges,
  createGapAccount,
  type AccountFamily,
} from "../services/accountHierarchy.js";

const router = Router();

// In-memory cache of the most recent scan per session — keeps the family payload
// off the wire when proposing a hierarchy and lets us look it up by brand label.
const scanCache = new Map<string, Map<string, AccountFamily>>();

function getCacheKey(req: { sessionID?: string }): string {
  return req.sessionID || "anonymous";
}

router.get("/scan", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const scan = await scanAccountFamilies(conn);

    const familyMap = new Map<string, AccountFamily>();
    for (const f of scan.families) familyMap.set(f.brandLabel, f);
    scanCache.set(getCacheKey(req), familyMap);

    res.json({
      families: scan.families,
      linkedInField: scan.linkedInField,
      totalAccountsScanned: scan.totalAccountsScanned,
    });
  } catch (error: any) {
    console.error("[accountHierarchy] scan error:", error);
    res.status(500).json({ message: error.message });
  }
});

router.post("/propose", async (req, res) => {
  try {
    const { brandLabel, family: bodyFamily } = req.body || {};
    let family: AccountFamily | undefined;
    if (bodyFamily) {
      family = bodyFamily as AccountFamily;
    } else if (brandLabel) {
      family = scanCache.get(getCacheKey(req))?.get(brandLabel);
    }
    if (!family) {
      res.status(400).json({ message: "Family not found. Run /scan first or pass family in body." });
      return;
    }
    const proposal = await proposeHierarchy(family);
    res.json(proposal);
  } catch (error: any) {
    console.error("[accountHierarchy] propose error:", error);
    res.status(500).json({ message: error.message });
  }
});

router.post("/apply", async (req, res) => {
  try {
    const { changes } = req.body || {};
    if (!Array.isArray(changes)) {
      res.status(400).json({ message: "changes array required" });
      return;
    }
    const conn = getConnection(req.session.sf!);
    const result = await applyHierarchyChanges(conn, changes);
    res.json(result);
  } catch (error: any) {
    console.error("[accountHierarchy] apply error:", error);
    res.status(500).json({ message: error.message });
  }
});

router.post("/create-gap", async (req, res) => {
  try {
    const { name, website, billingCountry, description } = req.body || {};
    if (!name) {
      res.status(400).json({ message: "name required" });
      return;
    }
    const conn = getConnection(req.session.sf!);
    const result = await createGapAccount(conn, { name, website, billingCountry, description });
    res.json(result);
  } catch (error: any) {
    console.error("[accountHierarchy] create-gap error:", error);
    res.status(500).json({ message: error.message });
  }
});

export default router;
