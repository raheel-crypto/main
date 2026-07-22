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

// Repair common issues in AI-generated JSON:
//  - literal newlines/tabs inside string values (should be \n, \t)
//  - unescaped double-quotes inside string values
// Uses look-ahead heuristic: a '"' inside a string is a real terminator only
// if the next non-whitespace char is ',', '}', ']', or end-of-input.
function repairJson(text: string): string {
  let out = "";
  let inString = false;
  let escape = false;

  for (let i = 0; i < text.length; i++) {
    const ch = text[i];

    if (escape) { out += ch; escape = false; continue; }
    if (ch === "\\") { out += ch; escape = true; continue; }

    if (ch === '"') {
      if (!inString) {
        inString = true;
        out += ch;
      } else {
        // Peek ahead past whitespace to see if this is a structural terminator
        let j = i + 1;
        while (j < text.length && /[ \t\n\r]/.test(text[j])) j++;
        const next = j < text.length ? text[j] : "";
        if (next === "" || next === "," || next === "}" || next === "]") {
          inString = false;
          out += ch;
        } else {
          out += '\\"'; // unescaped quote inside string — escape it
        }
      }
      continue;
    }

    if (inString) {
      if (ch === "\n") { out += "\\n"; continue; }
      if (ch === "\r") { out += "\\r"; continue; }
      if (ch === "\t") { out += "\\t"; continue; }
    }

    out += ch;
  }

  return out;
}

function tryParse(repaired: string): AIExplanation | null {
  try {
    const parsed = JSON.parse(repaired);
    if (parsed && typeof parsed === "object" && parsed.summary) {
      return {
        summary: parsed.summary || "",
        details: parsed.details || "",
        objectsAndFields: (parsed.objectsAndFields || []).map((item: any) => ({
          object: item.object || item.pillar || item.name || "",
          fields: item.fields || [],
        })),
        suggestions: parsed.suggestions || [],
      };
    }
  } catch (e) {
    console.log("[ai] JSON.parse failed:", (e as Error).message);
  }
  return null;
}

function parseAIResponse(text: string): AIExplanation {
  // Strip markdown code fences then repair common AI JSON mistakes
  const cleaned = text.replace(/```json\s*/gi, "").replace(/```\s*/g, "").trim();
  const repaired = repairJson(cleaned);

  // Strategy 1: parse the whole repaired text
  const direct = tryParse(repaired);
  if (direct) return direct;

  // Strategy 2: extract the outermost {...} from the repaired text and parse that
  const start = repaired.indexOf("{");
  if (start !== -1) {
    let depth = 0, inStr = false, esc = false, end = -1;
    for (let i = start; i < repaired.length; i++) {
      const ch = repaired[i];
      if (esc) { esc = false; continue; }
      if (ch === "\\") { esc = true; continue; }
      if (ch === '"') { inStr = !inStr; continue; }
      if (!inStr) {
        if (ch === "{") depth++;
        else if (ch === "}") { depth--; if (depth === 0) { end = i; break; } }
      }
    }
    if (end !== -1) {
      const candidate = tryParse(repaired.slice(start, end + 1));
      if (candidate) return candidate;
    }
  }

  console.log("[ai] All parse strategies failed; text[0..300]:", text.substring(0, 300));
  return {
    summary: text.substring(0, 200),
    details: text,
    objectsAndFields: [],
    suggestions: [],
  };
}
