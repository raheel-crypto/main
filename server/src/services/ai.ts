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
    model: "claude-sonnet-5",
    max_tokens: 4096,
    system: FLOW_SYSTEM_PROMPT,
    messages: [{ role: "user", content: userMessage }],
  });

  const text = response.content.find(b => b.type === "text")?.text ?? "";
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
    model: "claude-sonnet-5",
    max_tokens: 4096,
    system: APEX_SYSTEM_PROMPT,
    messages: [{ role: "user", content: userMessage }],
  });

  const text = response.content.find(b => b.type === "text")?.text ?? "";
  return parseAIResponse(text);
}

const WELL_ARCHITECTED_SYSTEM_PROMPT = `You are a senior Salesforce architect specializing in the Salesforce Well-Architected Framework and official Salesforce developer best practices.

You assess Salesforce Flows against these pillars of the Well-Architected Framework:
1. **Trusted** - Security, data integrity, compliance, sharing model respect
2. **Easy** - Maintainability, readability, documentation, admin-friendly design
3. **Adaptable** - Scalability, governor limits awareness, bulk-safe patterns, performance

Also assess against official Salesforce Flow best practices:
- Bulkification: Does the flow handle bulk operations properly? Are there DML/SOQL inside loops?
- Error Handling: Are fault paths defined? Are errors handled gracefully?
- Naming Conventions: Are elements named descriptively following best practices?
- Performance: Are there unnecessary queries? Could queries be consolidated?
- Security: Does the flow run in correct context? Are CRUD/FLS checks needed?
- Hardcoded Values: Are there hardcoded IDs, emails, or values that should be custom metadata/labels?
- Null Handling: Are null checks in place where needed?
- Entry Conditions: Are entry conditions specific enough to avoid unnecessary executions?

Format your response as JSON:
{
  "summary": "Overall assessment in 2-3 sentences",
  "details": "Detailed markdown assessment organized by Well-Architected pillar, with specific element references",
  "objectsAndFields": [{"object": "pillar name", "fields": ["finding 1", "finding 2"]}],
  "suggestions": ["Each suggestion should be a specific, actionable step. Include WHAT to change, WHERE in the flow, and HOW to do it. Reference specific element names."]
}

IMPORTANT: Make suggestions extremely specific and actionable. Instead of "Add error handling", say "Add a Fault path on the 'Update_Account' Record Update element that routes to an 'Error_Handler' Screen element displaying the error message to the user, or to a 'Log_Error' Create Records element that creates a custom Error_Log__c record."`;

export async function assessFlowArchitecture(
  flow: FlowDetailParsed
): Promise<AIExplanation> {
  const userMessage = `Assess this Salesforce Flow against the Salesforce Well-Architected Framework and official developer best practices.

Name: ${flow.label} (${flow.name})
Type: ${flow.type}
Trigger: ${flow.triggerType || "None"} on ${flow.triggerObject || "N/A"}
Status: ${flow.status}

Elements (${flow.elements.length} total):
${JSON.stringify(flow.elements, null, 2)}

Variables:
${JSON.stringify(flow.variables, null, 2)}

Referenced Objects: ${flow.referencedObjects.join(", ") || "None"}
Referenced Fields: ${flow.referencedFields.join(", ") || "None"}

Please provide a thorough assessment with specific, actionable remediation steps for each finding.`;

  const response = await client.messages.create({
    model: "claude-sonnet-5",
    max_tokens: 8192,
    system: WELL_ARCHITECTED_SYSTEM_PROMPT,
    messages: [{ role: "user", content: userMessage }],
  });

  console.log("[ai] Full content structure:", JSON.stringify(response.content));
  const text = response.content.find(b => b.type === "text")?.text ?? "";
  console.log("[ai] Response length:", text.length, "| first 300 chars:", text.substring(0, 300));
  return parseAIResponse(text);
}

function parseAIResponse(text: string): AIExplanation {
  // Strip markdown code fences
  const cleaned = text.replace(/```json\s*/gi, "").replace(/```\s*/g, "").trim();
  console.log("[ai] parseAIResponse cleaned[0..300]:", cleaned.substring(0, 300));

  // Strategy 1: direct JSON.parse on the cleaned string
  try {
    const parsed = JSON.parse(cleaned);
    if (parsed && typeof parsed === "object") {
      return {
        summary: parsed.summary || "",
        details: parsed.details || "",
        objectsAndFields: parsed.objectsAndFields || [],
        suggestions: parsed.suggestions || [],
      };
    }
  } catch (_) {}

  // Strategy 2: extract the outermost {...} block and parse it
  // Use a manual brace counter so nested braces in string values don't mislead us
  const start = cleaned.indexOf("{");
  if (start !== -1) {
    let depth = 0;
    let inString = false;
    let escape = false;
    let end = -1;
    for (let i = start; i < cleaned.length; i++) {
      const ch = cleaned[i];
      if (escape) { escape = false; continue; }
      if (ch === "\\") { escape = true; continue; }
      if (ch === '"') { inString = !inString; continue; }
      if (!inString) {
        if (ch === "{") depth++;
        else if (ch === "}") { depth--; if (depth === 0) { end = i; break; } }
      }
    }
    if (end !== -1) {
      const candidate = cleaned.slice(start, end + 1);
      try {
        const parsed = JSON.parse(candidate);
        return {
          summary: parsed.summary || "",
          details: parsed.details || "",
          objectsAndFields: parsed.objectsAndFields || [],
          suggestions: parsed.suggestions || [],
        };
      } catch (e) {
        console.log("[ai] JSON parse failed:", (e as Error).message);
        console.log("[ai] candidate[0..200]:", candidate.substring(0, 200));
      }
    }
  }

  console.log("[ai] All parse strategies failed, returning raw text");
  return {
    summary: text.substring(0, 200),
    details: text,
    objectsAndFields: [],
    suggestions: [],
  };
}
