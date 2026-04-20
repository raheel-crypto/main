import { Router } from "express";
import { getConnection } from "../services/salesforce.js";
import { runFullCleanupScan } from "../services/cleanupScanner.js";
import { architectChat } from "../services/architect.js";

const router = Router();

router.get("/scan", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const findings = await runFullCleanupScan(conn);
    res.json(findings);
  } catch (error: any) {
    console.error("Error running cleanup scan:", error);
    res.status(500).json({ message: error.message });
  }
});

router.post("/architect", async (req, res) => {
  try {
    const { messages } = req.body;
    if (!messages || !Array.isArray(messages)) {
      res.status(400).json({ message: "messages array required" });
      return;
    }
    const response = await architectChat(req.session.sf!, messages, req.session.mcpToken);
    res.json(response);
  } catch (error: any) {
    console.error("Error in architect chat:", error);
    res.status(500).json({ message: error.message });
  }
});

export default router;
