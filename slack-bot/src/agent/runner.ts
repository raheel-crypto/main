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
  /**
   * Called after each turn that produces tool_use blocks, before the tools
   * are dispatched. Caller can use it to update a Slack placeholder message
   * with friendly progress text. Fire-and-forget; errors are swallowed so a
   * failed progress update never derails the agent run.
   */
  onToolUse?: (
    args: { toolNames: string[]; iter: number }
  ) => Promise<void> | void;
}

export async function runAgent(input: RunAgentInput): Promise<RunAgentResult> {
  const {
    system,
    userMessage,
    ctx,
    maxTokens = 4096,
    toolNames,
    maxIterations = MAX_TOOL_ITERATIONS,
    onToolUse,
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

    if (onToolUse && toolUseBlocks.length > 0) {
      Promise.resolve(
        onToolUse({
          toolNames: toolUseBlocks.map((b) => b.name),
          iter,
        })
      ).catch((err) =>
        console.warn("[agent] onToolUse callback failed:", err?.message ?? err)
      );
    }

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

  if (response.stop_reason === "tool_use" && iter >= maxIterations) {
    console.warn(
      `[agent] hit maxIterations=${maxIterations}; forcing final JSON emission without tools`
    );
    const lastToolUses = response.content.filter(
      (b): b is Anthropic.ToolUseBlock => b.type === "tool_use"
    );
    messages.push({ role: "assistant", content: response.content });
    messages.push({
      role: "user",
      content: [
        ...lastToolUses.map((tu) => ({
          type: "tool_result" as const,
          tool_use_id: tu.id,
          content: JSON.stringify({
            error: "max_iterations_reached",
            message:
              "You hit the tool-call limit. Do not request more tools. Emit your final JSON answer now using only the data already gathered.",
          }),
        })),
        {
          type: "text" as const,
          text:
            "You've reached the maximum tool-call limit. Stop calling tools. " +
            "Emit your final JSON answer right now using only the data you've already gathered. " +
            "If a field has no data, set it to null. Output JSON only — no prose, no markdown fences, no commentary.",
        },
      ],
    });
    response = await anthropic.messages.create({
      model: MODEL,
      max_tokens: maxTokens,
      system,
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
