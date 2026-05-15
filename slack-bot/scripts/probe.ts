import { DateTime } from "luxon";
import { getCallsForUserToday } from "../src/services/gong.js";
import { getConnectionForUser } from "../src/services/salesforceClient.js";
import { buildContext } from "../src/services/opportunityContext.js";
import { getUsageProvider } from "../src/services/usageDb.js";
import {
  bootstrap as rogoBootstrap,
  lookupRogoCustomer,
} from "../src/services/rogoClient.js";
import { getRecentBuySignalAccountIds, getUser } from "../src/db/queries.js";
import { runAgent } from "../src/agent/runner.js";
import { BRIEF_SYSTEM, QA_SYSTEM } from "../src/agent/prompts.js";
import {
  BUY_SIGNAL_DEDUP_DAYS,
  BUY_SIGNAL_LOOKBACK_DAYS,
  BUY_SIGNAL_MAX_CARDS_PER_RUN,
  BUY_SIGNAL_SUBJECT_PATTERN,
} from "../src/constants.js";
import {
  fetchAccountIdsWithOpenOpp,
  fetchAccountsOwnedBy,
  fetchPositiveApolloCalls,
} from "../src/services/sfReads.js";
import { recommendBuySignal } from "../src/services/buySignalRecommender.js";

async function main() {
  const [_, __, kind, ...rest] = process.argv;
  if (kind === "gong") {
    const email = rest[0];
    const tz = rest[1] || "America/Los_Angeles";
    const from = DateTime.now().setZone(tz).startOf("day").toUTC().toISO()!;
    const to = DateTime.now().toUTC().toISO()!;
    const calls = await getCallsForUserToday(email, from, to);
    console.log(JSON.stringify(calls, null, 2));
    return;
  }
  if (kind === "sf") {
    const slackUserId = rest[0];
    const user = await getUser(slackUserId);
    if (!user) throw new Error(`No user row for ${slackUserId}`);
    const conn = await getConnectionForUser(slackUserId);
    const ident = await conn.identity();
    const ctx = await buildContext({
      conn,
      sfUserId: (ident as any).user_id,
      email: user.email,
      timezone: user.timezone,
    });
    console.log(JSON.stringify(ctx, null, 2));
    return;
  }
  if (kind === "usage" || kind === "rogo-usage") {
    const ids = (rest[0] || "").split(",").filter(Boolean);
    const rows = await getUsageProvider().getUsageForAccounts(
      ids,
      DateTime.now().toISODate()!
    );
    console.log(JSON.stringify(rows, null, 2));
    return;
  }
  if (kind === "rogo-bootstrap") {
    const boot = await rogoBootstrap(true);
    const directory = boot.customer_directory;
    const sample = (directory?.rows ?? []).slice(0, 3);
    const sampleKeys = sample[0] ? Object.keys(sample[0]) : [];
    console.log(
      JSON.stringify(
        {
          contract_version: boot.contract_version,
          database: boot.database,
          available_schemas: boot.available_schemas,
          guardrails: boot.guardrails,
          data_model_doc: boot.data_model_doc
            ? {
                bytes: boot.data_model_doc.bytes,
                content_sha256: boot.data_model_doc.content_sha256,
              }
            : null,
          customer_directory: {
            row_count: directory?.row_count,
            content_sha256: directory?.content_sha256,
            refreshed_at: directory?.refreshed_at,
            column_names: sampleKeys,
            sample_rows: sample,
          },
        },
        null,
        2
      )
    );
    return;
  }
  if (kind === "rogo-customer") {
    const sfAccountId = rest[0];
    if (!sfAccountId) {
      console.error("usage: probe rogo-customer <salesforce_account_id>");
      process.exit(1);
    }
    const row = await lookupRogoCustomer(sfAccountId);
    console.log(JSON.stringify(row, null, 2));
    return;
  }
  if (kind === "agent") {
    const mode = rest[0];
    const slackUserId = rest[1];
    const message = rest.slice(2).join(" ");
    if (!mode || !slackUserId || !message) {
      console.error(
        "usage: probe agent <brief|qa> <slack_user_id> <message...>"
      );
      process.exit(1);
    }
    const user = await getUser(slackUserId);
    if (!user) throw new Error(`No user row for ${slackUserId}`);
    const conn = await getConnectionForUser(slackUserId);
    const today = DateTime.now().setZone(user.timezone).toISODate();
    const result = await runAgent({
      system: mode === "brief" ? BRIEF_SYSTEM : QA_SYSTEM,
      userMessage:
        mode === "brief"
          ? `Generate a pre-meeting brief for the Salesforce account whose name matches: "${message}". Today is ${today} (${user.timezone}).`
          : `Today is ${today} (${user.timezone}).\n\n${message}`,
      ctx: {
        conn,
        slackUserId,
        userEmail: user.email,
        userTimezone: user.timezone,
        instanceUrl: conn.instanceUrl!,
      },
    });
    console.log(
      JSON.stringify(
        {
          stopReason: result.stopReason,
          toolCalls: result.toolCalls.map((c) => ({
            name: c.name,
            input: c.input,
            result: c.result.slice(0, 500),
          })),
          finalText: result.finalText,
        },
        null,
        2
      )
    );
    return;
  }
  if (kind === "buy-signals") {
    const slackUserId = rest[0];
    if (!slackUserId) {
      console.error("usage: probe buy-signals <slack_user_id>");
      process.exit(1);
    }
    const user = await getUser(slackUserId);
    if (!user) throw new Error(`No user row for ${slackUserId}`);
    const conn = await getConnectionForUser(slackUserId);
    const ident = await conn.identity();
    const sfUserId = (ident as any).user_id as string;

    const owned = await fetchAccountsOwnedBy(conn, sfUserId);
    const accountIds = owned.map((a) => a.id);
    const sinceIso = DateTime.utc()
      .minus({ days: BUY_SIGNAL_LOOKBACK_DAYS })
      .toISODate()!;
    const [calls, withOpenOpp, dedupSet] = await Promise.all([
      fetchPositiveApolloCalls(
        conn,
        accountIds,
        sinceIso,
        BUY_SIGNAL_SUBJECT_PATTERN
      ),
      fetchAccountIdsWithOpenOpp(conn, accountIds),
      getRecentBuySignalAccountIds(slackUserId, BUY_SIGNAL_DEDUP_DAYS),
    ]);

    const nameById = new Map(owned.map((a) => [a.id, a.name]));
    const byAccount = new Map<string, typeof calls>();
    for (const c of calls) {
      if (withOpenOpp.has(c.accountId)) continue;
      if (dedupSet.has(c.accountId)) continue;
      if (!nameById.has(c.accountId)) continue;
      const arr = byAccount.get(c.accountId) ?? [];
      arr.push(c);
      byAccount.set(c.accountId, arr);
    }

    const candidates = [...byAccount.entries()]
      .map(([accountId, accountCalls]) => ({ accountId, calls: accountCalls }))
      .sort((a, b) => {
        const da = a.calls[0]?.activityDate ?? "";
        const db = b.calls[0]?.activityDate ?? "";
        return db.localeCompare(da);
      })
      .slice(0, BUY_SIGNAL_MAX_CARDS_PER_RUN);

    const todayIso = DateTime.utc().toISODate()!;
    const recs = await Promise.all(
      candidates.map(async (c) => {
        const rec = await recommendBuySignal({
          accountId: c.accountId,
          accountName: nameById.get(c.accountId)!,
          industry: null,
          calls: c.calls,
          todayIso,
        });
        return { accountId: c.accountId, accountName: nameById.get(c.accountId)!, callCount: c.calls.length, rec };
      })
    );

    console.log(
      JSON.stringify(
        {
          accountsOwned: owned.length,
          callsFound: calls.length,
          accountsWithOpenOpp: withOpenOpp.size,
          dedupedFromRecent: dedupSet.size,
          candidateAccounts: candidates.length,
          recommendations: recs,
        },
        null,
        2
      )
    );
    return;
  }
  console.error(
    "usage: probe <gong|sf|usage|rogo-bootstrap|rogo-customer|rogo-usage|agent|buy-signals> <args...>"
  );
  process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
