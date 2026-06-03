import { NextResponse } from "next/server";
import { verifyHmac } from "@/lib/hmac";
import { getAccountWithOpps } from "@/lib/salesforce/soql";
import { diffVsStored } from "@/lib/arr/recompute";
import { crossValidate, formatOfeGapsForPrompt } from "@/lib/arr/cross_validate";
import { askHook } from "@/lib/claude/agent";
import { slack, REVOPS_CHANNEL } from "@/lib/slack/client";
import { issueBlocks } from "@/lib/slack/blocks";
import { sql } from "@/lib/db/client";
import { syncAccountEvents } from "@/lib/salesforce/ledger";

export const runtime = "nodejs";

export async function POST(req: Request) {
  const body = await req.text();
  const sig = req.headers.get("x-hook-signature") ?? "";
  const secret = process.env.SF_CALLOUT_HMAC_SECRET ?? "";

  if (!verifyHmac(body, sig, secret)) {
    return NextResponse.json({ error: "invalid signature" }, { status: 401 });
  }

  const { accountId } = JSON.parse(body) as { accountId: string };

  const { account, opps, ofes } = await getAccountWithOpps(accountId);
  const gap = diffVsStored(account, opps, Number(process.env.HOOK_GAP_THRESHOLD_USD ?? 1));
  const ofeGaps = crossValidate(opps, ofes);

  const runRows = (await sql`
    INSERT INTO runs (trigger_kind, account_id, accounts_checked, gaps_found, finished_at)
    VALUES ('opp_changed', ${accountId}, 1, ${gap.matches ? 0 : 1}, NOW())
    RETURNING id
  `) as { id: number }[];
  const runId = runRows[0]!.id;

  // Maintain the ARR_Event__c ledger. Logged but non-fatal: gap detection +
  // Slack post are higher priority. Next weekly run reconciles on failure.
  try {
    await syncAccountEvents(accountId, gap.result);
  } catch (err) {
    console.error(`ledger sync failed for ${accountId}`, err);
  }

  // For v1, only post when §2 says there's a gap. OFE-only gaps (where §2
  // reconciles but contract disagrees with opp) are still computed and
  // available to Hook via tools, but don't auto-trigger a Slack post.
  if (gap.matches) {
    return NextResponse.json({ ok: true, gap: 0, ofeGaps: ofeGaps.length });
  }

  const { text } = await askHook(
    `An opportunity on account ${account.Name} (${account.Id}) just changed. The recompute shows stored=${gap.storedArr}, expected=${gap.result.expectedArr}, gap=${gap.gap}. Use diff_vs_stored and last_audit to investigate, then explain the most likely cause (cite the §6.6 category) and suggest a PROPOSED FIX (dry-run only).${formatOfeGapsForPrompt(ofeGaps)}`,
  );

  const post = await slack.chat.postMessage({
    channel: REVOPS_CHANNEL,
    blocks: issueBlocks(gap, text),
    text: `ARR gap on ${account.Name}: ${gap.gap}`,
  });

  await sql`
    INSERT INTO gaps (run_id, account_id, account_name, stored_arr, expected_arr, gap_usd, category, slack_message_ts)
    VALUES (${runId}, ${account.Id}, ${account.Name}, ${gap.storedArr}, ${gap.result.expectedArr}, ${gap.gap}, NULL, ${post.ts ?? null})
  `;

  if (post.ts) {
    await sql`
      INSERT INTO slack_threads (thread_ts, channel_id, account_id, run_id, context)
      VALUES (${post.ts}, ${REVOPS_CHANNEL}, ${account.Id}, ${runId}, ${JSON.stringify({ kind: "issue" })})
    `;
  }

  return NextResponse.json({ ok: true, gap: gap.gap, threadTs: post.ts });
}
