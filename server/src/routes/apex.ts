import { Router } from "express";
import { getConnection } from "../services/salesforce.js";
import { listApexClasses, getApexDetail } from "../services/apexAnalyzer.js";
import { explainApex } from "../services/ai.js";

const router = Router();

router.get("/", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const classes = await listApexClasses(conn);
    res.json(classes);
  } catch (error: any) {
    console.error("Error listing apex classes:", error);
    res.status(500).json({ message: error.message });
  }
});

router.get("/:id", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const detail = await getApexDetail(conn, req.params.id);
    res.json(detail);
  } catch (error: any) {
    console.error("Error getting apex detail:", error);
    res.status(500).json({ message: error.message });
  }
});

router.post("/:id/explain", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const detail = await getApexDetail(conn, req.params.id);
    const explanation = await explainApex(detail);
    res.json(explanation);
  } catch (error: any) {
    console.error("Error explaining apex:", error);
    res.status(500).json({ message: error.message });
  }
});

export default router;
