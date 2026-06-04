import { NextResponse, after } from "next/server";
import { getAllCustomerAccountIds } from "@/lib/salesforce/soql";
import { sql } from "@/lib/db/client";
import { slack, REVOPS_CHANNEL } from "@/lib/slack/client";
import { weeklyDigestBlocks } from "@/lib/slack/blocks";
import type { GapResult } from "@/lib/arr/recompute";

export const runtime = "nodejs";

function resolveOrigin(req: Request): string {
  const fwd = req.headers.get("x-forwarded-host");
  if (fwd) return `https://${fwd}`;
  return new URL(req.url).origin;
}

export async function GET(req: Request) {
  const auth = req.headers.get("authorization");
  const isCron = req.headers.get("x-vercel-cron") !== null;
  if (auth !== `Bearer ${process.env.CRON_SECRET}` && !isCron) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  const runRows = (await sql`
    INSERT INTO runs (trigger_kind) VALUES ('weekly') RETURNING id
  `) as { id: number }[];
  const runId = runRows[0]!.id;

  const accountIds = await getAllCustomerAccountIds();
  const origin = resolveOrigin(req);

  // Return immediately so the caller (Vercel Cron, or Hook on demand) gets a
  // fast ack. The fan-out and digest post run in after() — bound by the
  // function's maxDuration but not the caller's.
  after(async () => {
    try {
      await runSweep(runId, accountIds, origin);
    } catch (err) {
      console.error("weekly sweep failed", err);
    }
  });

  return NextResponse.json({
    runId,
    accountsToCheck: accountIds.length,
    status: "running",
    estimatedSeconds: 90,
  });
}

async function runSweep(runId: number, accountIds: string[], origin: string) {
  const fanout = await Promise.allSettled(
    accountIds.map((accountId) =>
      fetch(`${origin}/api/cron/recompute-account`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${process.env.CRON_SECRET}`,
        },
        body: JSON.stringify({ accountId, runId }),
      }).then((r) => r.json() as Promise<{ matches: boolean; gap?: GapResult }>),
    ),
  );

  const gaps: GapResult[] = [];
  let matchCount = 0;
  for (const r of fanout) {
    if (r.status === "fulfilled") {
      if (r.value.matches) matchCount += 1;
      else if (r.value.gap) gaps.push(r.value.gap);
    }
  }

  const lastWeek = (await sql`
    SELECT DISTINCT account_id FROM gaps
    WHERE created_at > NOW() - INTERVAL '14 days' AND created_at < NOW() - INTERVAL '7 days'
  `) as { account_id: string }[];
  const lastWeekIds = new Set(lastWeek.map((r) => r.account_id));
  const currentIds = new Set(gaps.map((g) => g.account.Id));
  const newSinceLastWeek = [...currentIds].filter((id) => !lastWeekIds.has(id)).length;
  const resolvedSinceLastWeek = [...lastWeekIds].filter((id) => !currentIds.has(id)).length;

  const post = await slack.chat.postMessage({
    channel: REVOPS_CHANNEL,
    blocks: weeklyDigestBlocks({
      totalAccounts: accountIds.length,
      matchCount,
      gaps,
      newSinceLastWeek,
      resolvedSinceLastWeek,
    }),
    text: `Hook sweep — ${gaps.length} issue(s) found`,
  });

  await sql`
    UPDATE runs SET finished_at = NOW(), accounts_checked = ${accountIds.length},
                    gaps_found = ${gaps.length}, digest_message_ts = ${post.ts ?? null}
    WHERE id = ${runId}
  `;
}
