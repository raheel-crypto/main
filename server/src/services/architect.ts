import Anthropic from "@anthropic-ai/sdk";
import { Connection } from "jsforce";
import { config } from "../config.js";
import { getConnection } from "./salesforce.js";
import { listSFMcpTools, callSFMcpTool } from "./sfMcpClient.js";

const client = new Anthropic({ apiKey: config.anthropic.apiKey });

const SYSTEM_PROMPT = `You are a senior Salesforce architect assistant embedded in an org visualization tool. You help admins redesign and improve their Salesforce org.

You have access to tools that let you READ and WRITE to the user's Salesforce org. Always explain what you're about to do before doing it. For destructive operations (delete, deactivate), always confirm with the user first.

Your expertise includes:
- Object and field design (data model)
- Flow design and optimization
- Profile and permission set architecture (least privilege principle)
- Validation rules and data quality
- Salesforce Well-Architected Framework (Trusted, Easy, Adaptable)

When redesigning something:
1. First analyze the current state by querying the org
2. Explain what you found and what you recommend
3. Present a clear plan with specific changes
4. Only execute changes when the user confirms

Always follow Salesforce best practices:
- Use permission sets over profiles where possible
- Prefer record-triggered flows over workflow rules
- Keep flows bulkified and efficient
- Use custom metadata types instead of hardcoded values
- Apply least-privilege security model`;

const TOOLS: Anthropic.Tool[] = [
  {
    name: "sf_query",
    description: "Execute a SOQL query to read data from Salesforce.",
    input_schema: {
      type: "object" as const,
      properties: {
        soql: { type: "string", description: "The SOQL query" },
      },
      required: ["soql"],
    },
  },
  {
    name: "sf_tooling_query",
    description: "Execute a Tooling API SOQL query for metadata like Flows, ApexClasses, ValidationRules.",
    input_schema: {
      type: "object" as const,
      properties: {
        soql: { type: "string", description: "The Tooling API SOQL query" },
      },
      required: ["soql"],
    },
  },
  {
    name: "sf_describe_object",
    description: "Get full metadata for a Salesforce object including all fields and relationships.",
    input_schema: {
      type: "object" as const,
      properties: {
        objectName: { type: "string", description: "API name of the object" },
      },
      required: ["objectName"],
    },
  },
  {
    name: "sf_create_field",
    description: "Create a new custom field on an object.",
    input_schema: {
      type: "object" as const,
      properties: {
        objectName: { type: "string" },
        fieldName: { type: "string", description: "Without __c suffix" },
        label: { type: "string" },
        type: { type: "string", enum: ["Text", "TextArea", "LongTextArea", "Number", "Currency", "Percent", "Date", "DateTime", "Checkbox", "Email", "Phone", "Url", "Picklist", "MultiselectPicklist", "Lookup", "MasterDetail", "Formula"] },
        description: { type: "string" },
        required: { type: "boolean" },
        length: { type: "number" },
        precision: { type: "number" },
        scale: { type: "number" },
        picklistValues: { type: "array", items: { type: "string" } },
        referenceTo: { type: "string" },
        formula: { type: "string" },
      },
      required: ["objectName", "fieldName", "label", "type"],
    },
  },
  {
    name: "sf_create_validation_rule",
    description: "Create a validation rule on an object.",
    input_schema: {
      type: "object" as const,
      properties: {
        objectName: { type: "string" },
        ruleName: { type: "string" },
        errorConditionFormula: { type: "string" },
        errorMessage: { type: "string" },
        description: { type: "string" },
        active: { type: "boolean" },
      },
      required: ["objectName", "ruleName", "errorConditionFormula", "errorMessage"],
    },
  },
  {
    name: "sf_toggle_validation_rule",
    description: "Enable or disable a validation rule.",
    input_schema: {
      type: "object" as const,
      properties: {
        objectName: { type: "string" },
        ruleName: { type: "string" },
        active: { type: "boolean" },
      },
      required: ["objectName", "ruleName", "active"],
    },
  },
  {
    name: "sf_assign_permission_set",
    description: "Assign a permission set to a user.",
    input_schema: {
      type: "object" as const,
      properties: {
        userId: { type: "string" },
        permissionSetId: { type: "string" },
      },
      required: ["userId", "permissionSetId"],
    },
  },
  {
    name: "sf_remove_permission_set",
    description: "Remove a permission set from a user.",
    input_schema: {
      type: "object" as const,
      properties: {
        userId: { type: "string" },
        permissionSetId: { type: "string" },
      },
      required: ["userId", "permissionSetId"],
    },
  },
  {
    name: "sf_activate_flow",
    description: "Activate or deactivate a flow version.",
    input_schema: {
      type: "object" as const,
      properties: {
        flowId: { type: "string" },
        active: { type: "boolean" },
      },
      required: ["flowId", "active"],
    },
  },
  {
    name: "sf_deploy_metadata",
    description: "Deploy metadata (create, update, or delete) via the Metadata API.",
    input_schema: {
      type: "object" as const,
      properties: {
        metadataType: { type: "string" },
        metadata: { type: "object" },
        operation: { type: "string", enum: ["create", "update", "delete"] },
      },
      required: ["metadataType", "metadata", "operation"],
    },
  },
];

// Execute a tool call against the Salesforce org
async function executeTool(
  conn: Connection,
  toolName: string,
  input: any
): Promise<string> {
  try {
    switch (toolName) {
      case "sf_query": {
        const result = await conn.query(input.soql);
        return JSON.stringify({ totalSize: result.totalSize, records: result.records }, null, 2);
      }
      case "sf_tooling_query": {
        const result = await conn.tooling.query(input.soql);
        return JSON.stringify({ totalSize: result.totalSize, records: result.records }, null, 2);
      }
      case "sf_describe_object": {
        const desc = await conn.describe(input.objectName);
        return JSON.stringify({
          name: desc.name,
          label: desc.label,
          fields: desc.fields.map((f) => ({
            name: f.name, label: f.label, type: f.type,
            custom: f.custom, required: !f.nillable && !f.defaultedOnCreate,
            referenceTo: f.referenceTo, calculatedFormula: f.calculatedFormula,
          })),
          childRelationships: desc.childRelationships?.filter((r) => r.relationshipName)
            .map((r) => ({ child: r.childSObject, field: r.field })),
        }, null, 2);
      }
      case "sf_create_field": {
        const metadata: any = {
          fullName: `${input.objectName}.${input.fieldName}__c`,
          label: input.label,
          type: input.type,
          description: input.description || "",
          required: input.required || false,
        };
        if (["Text"].includes(input.type)) metadata.length = input.length || 255;
        if (["Number", "Currency", "Percent"].includes(input.type)) {
          metadata.precision = input.precision || 18;
          metadata.scale = input.scale || 2;
        }
        if (input.picklistValues) {
          metadata.valueSet = {
            restricted: false,
            valueSetDefinition: {
              sorted: false,
              value: input.picklistValues.map((v: string) => ({ fullName: v, default: false, label: v })),
            },
          };
        }
        if (input.referenceTo) {
          metadata.referenceTo = input.referenceTo;
          metadata.relationshipLabel = input.label;
          metadata.relationshipName = input.fieldName;
        }
        if (input.formula) metadata.formula = input.formula;
        await conn.metadata.create("CustomField", metadata);
        return `Field ${input.objectName}.${input.fieldName}__c created successfully.`;
      }
      case "sf_create_validation_rule": {
        await conn.metadata.create("ValidationRule", {
          fullName: `${input.objectName}.${input.ruleName}`,
          active: input.active !== false,
          description: input.description || "",
          errorConditionFormula: input.errorConditionFormula,
          errorMessage: input.errorMessage,
        } as any);
        return `Validation rule ${input.objectName}.${input.ruleName} created.`;
      }
      case "sf_toggle_validation_rule": {
        await conn.metadata.update("ValidationRule", {
          fullName: `${input.objectName}.${input.ruleName}`,
          active: input.active,
        } as any);
        return `Validation rule ${input.ruleName} ${input.active ? "enabled" : "disabled"}.`;
      }
      case "sf_assign_permission_set": {
        await conn.sobject("PermissionSetAssignment").create({
          AssigneeId: input.userId,
          PermissionSetId: input.permissionSetId,
        });
        return `Permission set assigned.`;
      }
      case "sf_remove_permission_set": {
        const result = await conn.query(
          `SELECT Id FROM PermissionSetAssignment WHERE AssigneeId = '${input.userId}' AND PermissionSetId = '${input.permissionSetId}'`
        );
        const id = (result.records as any)?.[0]?.Id;
        if (!id) return "Assignment not found.";
        await conn.sobject("PermissionSetAssignment").delete(id);
        return "Permission set removed.";
      }
      case "sf_activate_flow": {
        await conn.tooling.update("Flow", { Id: input.flowId, Status: input.active ? "Active" : "Obsolete" } as any);
        return `Flow ${input.flowId} ${input.active ? "activated" : "deactivated"}.`;
      }
      case "sf_deploy_metadata": {
        const op = input.operation;
        if (op === "create") await conn.metadata.create(input.metadataType as any, input.metadata);
        else if (op === "update") await conn.metadata.update(input.metadataType as any, input.metadata);
        else await conn.metadata.delete(input.metadataType as any, input.metadata.fullName);
        return `Metadata ${op} completed.`;
      }
      default:
        return `Unknown tool: ${toolName}`;
    }
  } catch (err: any) {
    return `Error: ${err.message}`;
  }
}

export interface ChatMessage {
  role: "user" | "assistant";
  content: string;
  toolCalls?: { name: string; input: any; result: string }[];
}

export async function architectChat(
  session: { accessToken: string; refreshToken: string; instanceUrl: string },
  messages: { role: "user" | "assistant"; content: string }[],
  mcpToken?: string
): Promise<ChatMessage> {
  const conn = getConnection(session);
  const mcpAccessToken = mcpToken || session.accessToken;

  // Load Salesforce Hosted MCP tools alongside our custom tools
  let sfMcpToolNames = new Set<string>();
  let sfMcpAnthropicTools: Anthropic.Tool[] = [];
  try {
    const mcpTools = await listSFMcpTools(mcpAccessToken);
    sfMcpToolNames = new Set(mcpTools.map((t) => t.name));
    sfMcpAnthropicTools = mcpTools.map((t) => ({
      name: t.name,
      description: `[Salesforce Official MCP] ${t.description}`,
      input_schema: t.inputSchema as Anthropic.Tool["input_schema"],
    }));
    if (mcpTools.length > 0) {
      console.log(`[architect] SF MCP connected: ${mcpTools.map((t) => t.name).join(", ")}`);
    }
  } catch (e: any) {
    console.log(`[architect] SF MCP not available: ${e.message}`);
  }

  const allTools = [...TOOLS, ...sfMcpAnthropicTools];

  // Build Anthropic messages
  const anthropicMessages: Anthropic.MessageParam[] = messages.map((m) => ({
    role: m.role,
    content: m.content,
  }));

  let response = await client.messages.create({
    model: "claude-sonnet-5",
    max_tokens: 8192,
    system: SYSTEM_PROMPT,
    tools: allTools,
    messages: anthropicMessages,
  });

  const toolCalls: { name: string; input: any; result: string }[] = [];
  let textParts: string[] = [];

  // Handle tool use loop
  while (response.stop_reason === "tool_use") {
    const assistantContent = response.content;
    const toolUseBlocks = assistantContent.filter(
      (b): b is Anthropic.ContentBlockParam & { type: "tool_use"; id: string; name: string; input: any } =>
        b.type === "tool_use"
    );
    const textBlocks = assistantContent.filter(
      (b): b is Anthropic.TextBlock => b.type === "text"
    );

    for (const tb of textBlocks) {
      textParts.push(tb.text);
    }

    // Execute all tool calls — route to SF MCP or our own tools
    const toolResults: Anthropic.ToolResultBlockParam[] = [];
    for (const tool of toolUseBlocks) {
      console.log(`[architect] Executing tool: ${tool.name}`);
      let result: string;
      if (sfMcpToolNames.has(tool.name)) {
        result = await callSFMcpTool(mcpAccessToken, tool.name, tool.input).catch(
          (e: any) => `SF MCP error: ${e.message}`
        );
      } else {
        result = await executeTool(conn, tool.name, tool.input);
      }
      toolCalls.push({ name: tool.name, input: tool.input, result });
      toolResults.push({
        type: "tool_result",
        tool_use_id: tool.id,
        content: result,
      });
    }

    // Continue the conversation with tool results
    anthropicMessages.push({ role: "assistant", content: assistantContent as any });
    anthropicMessages.push({ role: "user", content: toolResults as any });

    response = await client.messages.create({
      model: "claude-sonnet-5",
      max_tokens: 8192,
      system: SYSTEM_PROMPT,
      tools: allTools,
      messages: anthropicMessages,
    });
  }

  // Collect final text
  for (const block of response.content) {
    if (block.type === "text") {
      textParts.push(block.text);
    }
  }

  return {
    role: "assistant",
    content: textParts.join("\n"),
    toolCalls: toolCalls.length > 0 ? toolCalls : undefined,
  };
}
