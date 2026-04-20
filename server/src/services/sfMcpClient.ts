import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const SF_MCP_URL = "https://api.salesforce.com/platform/mcp/v1/platform/sobject-reads";

export interface SFMcpTool {
  name: string;
  description: string;
  inputSchema: Record<string, any>;
}

async function createMcpClient(accessToken: string): Promise<Client> {
  const transport = new StreamableHTTPClientTransport(new URL(SF_MCP_URL), {
    requestInit: {
      headers: {
        Authorization: `Bearer ${accessToken}`,
      },
    },
  });

  const client = new Client(
    { name: "sf-visualizer", version: "1.0.0" },
    { capabilities: {} }
  );

  await client.connect(transport);
  return client;
}

export async function listSFMcpTools(accessToken: string): Promise<SFMcpTool[]> {
  const client = await createMcpClient(accessToken);
  try {
    const { tools } = await client.listTools();
    return (tools || []).map((t) => ({
      name: t.name,
      description: t.description || t.name,
      inputSchema: (t.inputSchema as Record<string, any>) || { type: "object", properties: {} },
    }));
  } finally {
    await client.close();
  }
}

export async function callSFMcpTool(
  accessToken: string,
  toolName: string,
  toolArgs: Record<string, any>
): Promise<string> {
  const client = await createMcpClient(accessToken);
  try {
    const result = await client.callTool({ name: toolName, arguments: toolArgs });
    const content = result.content;
    if (Array.isArray(content)) {
      const text = content
        .filter((c: any) => c.type === "text")
        .map((c: any) => c.text)
        .join("\n");
      return text || JSON.stringify(result);
    }
    return JSON.stringify(result, null, 2);
  } finally {
    await client.close();
  }
}
