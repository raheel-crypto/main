import Anthropic from "@anthropic-ai/sdk";
import { config } from "../config.js";
import { MODEL, MAX_TOOL_ITERATIONS } from "../constants.js";
import {
  ALL_TOOLS,
  AgentToolCtx,
  TOOL_DEFINITIONS,
  dispatchToolCall,
} from "./tools.js";

let client: Anthropic | null = null;
function getClient(): Anthropic {
  if (!client) client = new Anthropic({ apiKey: config.anthropic.apiKey });
  return client;
}

export interface AgentToolCall {
  name: string;
  input: unknown;
  result: string;
}

export interface RunAgentResult {
  finalText: string;
  toolCalls: AgentToolCall[];
  stopReason: string | null;
}

export interface RunAgentInput {
  system: string;
  userMessage: string;
  ctx: AgentToolCtx;
  maxTokens?: number;
  toolNames?: string[];
  maxIterations?: number;
}

export async function runAgent(input: RunAgentInput): Promise<RunAgentResult> {
  const {
    system,
    userMessage,
    ctx,
    maxTokens = 4096,
    toolNames,
    maxIterations = MAX_TOOL_ITERATIONS,
  } = input;

  const tools = toolNames
    ? TOOL_DEFINITIONS.filter((t) => toolNames.includes(t.name))
    : TOOL_DEFINITIONS;

  const messages: Anthropic.MessageParam[] = [
    { role: "user", content: userMessage },
  ];
  const toolCalls: AgentToolCall[] = [];

  const anthropic = getClient();
  let response = await anthropic.messages.create({
    model: MODEL,
    max_tokens: maxTokens,
    system,
    tools,
    messages,
  });

  let iter = 0;
  while (response.stop_reason === "tool_use" && iter < maxIterations) {
    iter++;
    const assistantContent = response.content;
    const toolUseBlocks = assistantContent.filter(
      (b): b is Anthropic.ToolUseBlock => b.type === "tool_use"
    );

    const toolResults: Anthropic.ToolResultBlockParam[] = [];
    for (const tu of toolUseBlocks) {
      const isKnown = ALL_TOOLS.some((t) => t.name === tu.name);
      const result = isKnown
        ? await dispatchToolCall(tu.name, tu.input, ctx)
        : JSON.stringify({ error: `Unknown tool: ${tu.name}` });
      toolCalls.push({ name: tu.name, input: tu.input, result });
      toolResults.push({
        type: "tool_result",
        tool_use_id: tu.id,
        content: result,
      });
    }

    messages.push({ role: "assistant", content: assistantContent });
    messages.push({ role: "user", content: toolResults });

    response = await anthropic.messages.create({
      model: MODEL,
      max_tokens: maxTokens,
      system,
      tools,
      messages,
    });
  }

  const finalParts: string[] = [];
  for (const b of response.content) {
    if (b.type === "text") finalParts.push(b.text);
  }

  return {
    finalText: finalParts.join("\n").trim(),
    toolCalls,
    stopReason: response.stop_reason ?? null,
  };
}
