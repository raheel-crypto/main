import { Router } from "express";
import { listSFMcpTools, callSFMcpTool } from "../services/sfMcpClient.js";

const router = Router();

// GET /api/sf-mcp/tools — list tools available from Salesforce Hosted MCP
router.get("/tools", async (req, res) => {
  try {
    const tools = await listSFMcpTools(req.session.sf!.accessToken);
    res.json({ tools, connected: true });
  } catch (error: any) {
    console.error("[sf-mcp] Error listing tools:", error.message);
    res.json({
      tools: [],
      connected: false,
      error: error.message,
    });
  }
});

// POST /api/sf-mcp/call — call a specific Salesforce Hosted MCP tool
router.post("/call", async (req, res) => {
  try {
    const { toolName, toolArgs } = req.body;
    if (!toolName) {
      res.status(400).json({ message: "toolName is required" });
      return;
    }
    const result = await callSFMcpTool(
      req.session.sf!.accessToken,
      toolName,
      toolArgs || {}
    );
    res.json({ result });
  } catch (error: any) {
    console.error("[sf-mcp] Error calling tool:", error.message);
    res.status(500).json({ message: error.message });
  }
});

export default router;
