import Anthropic from "@anthropic-ai/sdk";
import { HOOK_SYSTEM_PROMPT } from "./system-prompt";
import { HOOK_TOOLS } from "./tools";

export const anthropic = new Anthropic();

export const HOOK_MODEL = "claude-opus-4-8";

export async function askHook(
  userMessage: string,
  history: Anthropic.Beta.Messages.BetaMessageParam[] = [],
): Promise<{ text: string; finalMessage: Anthropic.Beta.Messages.BetaMessage }> {
  const finalMessage = await anthropic.beta.messages.toolRunner({
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
    tools: HOOK_TOOLS,
    messages: [...history, { role: "user", content: userMessage }],
  });

  const text = finalMessage.content
    .filter((b): b is Anthropic.Beta.Messages.BetaTextBlock => b.type === "text")
    .map((b) => b.text)
    .join("\n\n");

  return { text, finalMessage };
}
