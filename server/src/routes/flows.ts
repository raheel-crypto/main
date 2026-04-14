import { Router } from "express";
import { getConnection } from "../services/salesforce.js";
import { listFlows, getFlowDetail } from "../services/flowAnalyzer.js";
import { explainFlow, assessFlowArchitecture } from "../services/ai.js";

const router = Router();

router.get("/", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const flows = await listFlows(conn);
    res.json(flows);
  } catch (error: any) {
    console.error("Error listing flows:", error);
    res.status(500).json({ message: error.message });
  }
});

router.get("/:id", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const detail = await getFlowDetail(conn, req.params.id);
    res.json(detail);
  } catch (error: any) {
    console.error("Error getting flow detail:", error);
    res.status(500).json({ message: error.message });
  }
});

router.post("/:id/explain", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const detail = await getFlowDetail(conn, req.params.id);
    const explanation = await explainFlow(detail);
    res.json(explanation);
  } catch (error: any) {
    console.error("Error explaining flow:", error);
    res.status(500).json({ message: error.message });
  }
});

router.post("/:id/assess", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const detail = await getFlowDetail(conn, req.params.id);
    const assessment = await assessFlowArchitecture(detail);
    res.json(assessment);
  } catch (error: any) {
    console.error("Error assessing flow:", error);
    res.status(500).json({ message: error.message });
  }
});

export default router;
