import Anthropic from "@anthropic-ai/sdk";
import { config } from "../config.js";
import type {
  AIExplanation,
  FlowDetailParsed,
  ApexDetailParsed,
} from "../types/index.js";

const client = new Anthropic({ apiKey: config.anthropic.apiKey });

const FLOW_SYSTEM_PROMPT = `You are a Salesforce expert assistant. You analyze Salesforce Flow definitions and explain them in clear, plain English for Salesforce admins.

When analyzing a flow, provide:
1. A concise summary (2-3 sentences) of what this flow does
2. A detailed step-by-step walkthrough of each element
3. What triggers the flow and under what conditions
4. All objects and fields involved, organized by object
5. Any potential issues, best practices violations, or improvement suggestions

Format your response as JSON with this structure:
{
  "summary": "Brief description of what the flow does",
  "details": "Detailed markdown-formatted explanation with element-by-element breakdown",
  "objectsAndFields": [{"object": "Account", "fields": ["Name", "Industry"]}],
  "suggestions": ["Suggestion 1", "Suggestion 2"]
}`;

const APEX_SYSTEM_PROMPT = `You are a Salesforce expert assistant. You analyze Apex classes and explain them in clear, plain English for Salesforce admins and developers.

When analyzing an Apex class, provide:
1. A concise summary (2-3 sentences) of what this class does
2. A detailed explanation of each method and its purpose
3. How the class is triggered (trigger, schedulable, batchable, REST, etc.)
4. All objects and fields used in SOQL queries and DML operations
5. Code quality observations and improvement suggestions

Format your response as JSON with this structure:
{
  "summary": "Brief description of what the class does",
  "details": "Detailed markdown-formatted explanation with method-by-method breakdown",
  "objectsAndFields": [{"object": "Account", "fields": ["Name", "Industry"]}],
  "suggestions": ["Suggestion 1", "Suggestion 2"]
}`;

export async function explainFlow(
  flow: FlowDetailParsed
): Promise<AIExplanation> {
  const userMessage = `Analyze this Salesforce Flow:

Name: ${flow.label} (${flow.name})
Type: ${flow.type}
Trigger: ${flow.triggerType || "None"} on ${flow.triggerObject || "N/A"}
Status: ${flow.status}

Elements:
${JSON.stringify(flow.elements, null, 2)}

Variables:
${JSON.stringify(flow.variables, null, 2)}

Referenced Objects: ${flow.referencedObjects.join(", ") || "None"}
Referenced Fields: ${flow.referencedFields.join(", ") || "None"}`;

  const response = await client.messages.create({
    model: "claude-sonnet-4-20250514",
    max_tokens: 4096,
    system: FLOW_SYSTEM_PROMPT,
    messages: [{ role: "user", content: userMessage }],
  });

  const text =
    response.content[0].type === "text" ? response.content[0].text : "";
  return parseAIResponse(text);
}

export async function explainApex(
  apex: ApexDetailParsed
): Promise<AIExplanation> {
  // Truncate very large classes to avoid token limits
  const body =
    apex.body.length > 50000 ? apex.body.substring(0, 50000) + "\n// ... truncated" : apex.body;

  const userMessage = `Analyze this Salesforce Apex class:

Name: ${apex.name}
API Version: ${apex.apiVersion}
Is Test Class: ${apex.isTest}
Is Trigger: ${apex.isTrigger}
Annotations: ${apex.annotations.join(", ") || "None"}

SOQL Queries Found:
${apex.soqlQueries.join("\n") || "None"}

DML Operations Found:
${apex.dmlOperations.join(", ") || "None"}

Source Code:
\`\`\`apex
${body}
\`\`\``;

  const response = await client.messages.create({
    model: "claude-sonnet-4-20250514",
    max_tokens: 4096,
    system: APEX_SYSTEM_PROMPT,
    messages: [{ role: "user", content: userMessage }],
  });

  const text =
    response.content[0].type === "text" ? response.content[0].text : "";
  return parseAIResponse(text);
}

function parseAIResponse(text: string): AIExplanation {
  try {
    // Try to extract JSON from the response
    const jsonMatch = text.match(/\{[\s\S]*\}/);
    if (jsonMatch) {
      const parsed = JSON.parse(jsonMatch[0]);
      return {
        summary: parsed.summary || "",
        details: parsed.details || "",
        objectsAndFields: parsed.objectsAndFields || [],
        suggestions: parsed.suggestions || [],
      };
    }
  } catch {
    // Fall back to treating the whole response as the explanation
  }

  return {
    summary: text.substring(0, 200),
    details: text,
    objectsAndFields: [],
    suggestions: [],
  };
}
