import Anthropic from "@anthropic-ai/sdk";
import { HOOK_SYSTEM_PROMPT } from "./system-prompt";
import { TOOL_DEFINITIONS, TOOL_EXECUTORS } from "./tools";

let _client: Anthropic | null = null;
function getClient(): Anthropic {
  if (_client) return _client;
  _client = new Anthropic();
  return _client;
}

export const HOOK_MODEL = "claude-opus-4-8";
const MAX_TURNS = 10;

export async function askHook(
  userMessage: string,
  history: Anthropic.MessageParam[] = [],
): Promise<{ text: string; finalMessage: Anthropic.Message }> {
  const client = getClient();
  const messages: Anthropic.MessageParam[] = [
    ...history,
    { role: "user", content: userMessage },
  ];

  let finalResponse: Anthropic.Message | null = null;

  for (let turn = 0; turn < MAX_TURNS; turn++) {
    const response = await client.messages.create({
      model: HOOK_MODEL,
      max_tokens: 16000,
      thinking: { type: "adaptive" },
      output_config: { effort: "high" },
      system: [
        {
          type: "text",
          text: HOOK_SYSTEM_PROMPT,
          cache_control: { type: "ephemeral" },
        },
      ],
      tools: TOOL_DEFINITIONS,
      messages,
    });

    finalResponse = response;

    if (response.stop_reason === "end_turn" || response.stop_reason === "max_tokens") {
      break;
    }

    if (response.stop_reason === "tool_use") {
      messages.push({ role: "assistant", content: response.content });

      const toolResults: Anthropic.ToolResultBlockParam[] = [];
      for (const block of response.content) {
        if (block.type !== "tool_use") continue;
        const executor = TOOL_EXECUTORS[block.name];
        const result = executor
          ? await executor(block.input as Record<string, unknown>)
          : JSON.stringify({ error: `Unknown tool: ${block.name}` });
        toolResults.push({
          type: "tool_result",
          tool_use_id: block.id,
          content: result,
        });
      }

      messages.push({ role: "user", content: toolResults });
      continue;
    }

    break;
  }

  if (!finalResponse) {
    throw new Error("Hook agent did not produce a response");
  }

  const text = finalResponse.content
    .filter((b): b is Anthropic.TextBlock => b.type === "text")
    .map((b) => b.text)
    .join("\n\n");

  return { text, finalMessage: finalResponse };
}
