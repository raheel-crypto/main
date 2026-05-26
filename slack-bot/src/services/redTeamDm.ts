import type { WebClient } from "@slack/web-api";
import { runRedTeamEval } from "./redTeamHandler.js";

const SF_OPP_ID_PATTERN = /^006[a-zA-Z0-9]{12}([a-zA-Z0-9]{3})?$/;

export async function runRedTeamFromDm(args: {
  slackUserId: string;
  channelId: string;
  oppRef: string;
  slack: WebClient;
}): Promise<void> {
  const { slackUserId, channelId, oppRef, slack } = args;
  const trimmed = oppRef.trim();

  if (!trimmed) {
    await slack.chat.postMessage({
      channel: channelId,
      text: "Usage: `red team <opportunity id>` — paste the 15 or 18-char SF Opportunity Id (starts with `006`).",
    });
    return;
  }

  if (!SF_OPP_ID_PATTERN.test(trimmed)) {
    await slack.chat.postMessage({
      channel: channelId,
      text: `\`${trimmed}\` doesn't look like a Salesforce Opportunity Id. Paste the 15 or 18-char Id from the SF URL — it starts with \`006\`.`,
    });
    return;
  }

  const placeholder = await slack.chat.postMessage({
    channel: channelId,
    text: `:hourglass_flowing_sand: Running Red Team eval on \`${trimmed}\`…`,
  });
  const ts = placeholder.ts!;

  let summary: string;
  try {
    const result = await runRedTeamEval({
      slackUserId,
      opportunityId: trimmed,
      triggerEvent: "manual",
    });

    const n = result.personasInvoked ?? 0;
    const triggers = (result.firedTriggers ?? []).join(", ") || "(none)";

    switch (result.reason) {
      case "surfaced":
        summary = `:white_check_mark: Done — card sent to <@${result.slackUserId}> · ${n} persona${n === 1 ? "" : "s"} fired · triggers: ${triggers}.`;
        break;
      case "shadow_mode":
        summary = `:eye: Shadow mode on — eval completed, ${n} persona${n === 1 ? "" : "s"} would have fired (no DM). Audit row written. Set \`RED_TEAM_SHADOW_MODE=false\` and redeploy to see the card.`;
        break;
      case "muted":
        summary = ":mute: This opp is muted for you — wait for the mute to expire or remove it from the `red_team_mutes` table.";
        break;
      case "cooldown":
        summary = ":snowflake: Cooled down — the agent recently evaluated this opp. Wait for the cooldown to expire or clear the row in `red_team_cooldowns`.";
        break;
      case "no_personas_fired":
        summary = `:no_entry_sign: No personas fired. Triggers evaluated: ${triggers}. Check the trigger rules in \`config/triggers.yaml\`.`;
        break;
      case "sf_not_connected":
        summary = ":warning: Connect Salesforce first via `/standup connect`.";
        break;
      case "opp_not_found":
        summary = `:warning: Couldn't find opp \`${trimmed}\`. Check the Id and your SF access.`;
        break;
      case "agent_not_configured":
        summary = ":warning: Red Team agent isn't configured — set `RED_TEAM_AGENT_URL` and `RED_TEAM_AGENT_SECRET` on the slack-bot project and redeploy.";
        break;
      case "agent_call_failed":
        summary = ":x: The Python agent rejected the call. Check Vercel logs on the red-team-agent project.";
        break;
      case "intel_pack_failed":
        summary = ":x: Couldn't assemble the intel pack (SF or Gong fetch failed). Check Vercel logs on slack-bot.";
        break;
      default:
        summary = `:warning: ${result.reason}`;
    }
  } catch (err: any) {
    summary = `:x: Eval failed: ${String(err?.message ?? err).slice(0, 200)}`;
  }

  await slack.chat.update({
    channel: channelId,
    ts,
    text: summary,
  });
}
