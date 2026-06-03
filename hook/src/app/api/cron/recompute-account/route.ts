import { NextResponse } from "next/server";
import { getAccountWithOpps } from "@/lib/salesforce/soql";
import { diffVsStored } from "@/lib/arr/recompute";
import { crossValidate } from "@/lib/arr/cross_validate";
import { sql } from "@/lib/db/client";
import { syncAccountEvents } from "@/lib/salesforce/ledger";

export const runtime = "nodejs";

export async function POST(req: Request) {
  const auth = req.headers.get("authorization");
  if (auth !== `Bearer ${process.env.CRON_SECRET}`) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  const { accountId, runId } = (await req.json()) as { accountId: string; runId: number };

  try {
    const { account, opps, ofes } = await getAccountWithOpps(accountId);
    const gap = diffVsStored(account, opps, Number(process.env.HOOK_GAP_THRESHOLD_USD ?? 1));
    const ofeGaps = crossValidate(opps, ofes);

    if (!gap.matches) {
      await sql`
        INSERT INTO gaps (run_id, account_id, account_name, stored_arr, expected_arr, gap_usd)
        VALUES (${runId}, ${account.Id}, ${account.Name}, ${gap.storedArr}, ${gap.result.expectedArr}, ${gap.gap})
      `;
    }

    try {
      await syncAccountEvents(accountId, gap.result);
    } catch (err) {
      console.error(`ledger sync failed for ${accountId}`, err);
    }

    return NextResponse.json({ matches: gap.matches, gap, ofeGaps });
  } catch (err) {
    return NextResponse.json(
      { matches: false, error: err instanceof Error ? err.message : String(err) },
      { status: 500 },
    );
  }
}
