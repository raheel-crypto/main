import { Router } from "express";
import { listSFMcpTools, callSFMcpTool } from "../services/sfMcpClient.js";

const router = Router();

function getMcpToken(req: any): string {
  return req.session.mcpToken || req.session.sf!.accessToken;
}

function getInstanceUrl(req: any): string {
  return req.session.sf!.instanceUrl;
}

// POST /api/sf-mcp/token — store a custom MCP access token in the session
router.post("/token", (req, res) => {
  const { accessToken } = req.body;
  if (!accessToken) {
    res.status(400).json({ message: "accessToken required" });
    return;
  }
  req.session.mcpToken = accessToken;
  res.json({ ok: true });
});

// DELETE /api/sf-mcp/token — clear the custom MCP token
router.delete("/token", (req, res) => {
  delete req.session.mcpToken;
  res.json({ ok: true });
});

// GET /api/sf-mcp/tools — list tools available from Salesforce Hosted MCP
router.get("/tools", async (req, res) => {
  try {
    const tools = await listSFMcpTools(getMcpToken(req), getInstanceUrl(req));
    res.json({ tools, connected: true, usingCustomToken: !!req.session.mcpToken });
  } catch (error: any) {
    console.error("[sf-mcp] Error listing tools:", error.message);
    res.json({
      tools: [],
      connected: false,
      usingCustomToken: !!req.session.mcpToken,
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
    const result = await callSFMcpTool(getMcpToken(req), getInstanceUrl(req), toolName, toolArgs || {});
    res.json({ result });
  } catch (error: any) {
    console.error("[sf-mcp] Error calling tool:", error.message);
    res.status(500).json({ message: error.message });
  }
});

export default router;
