import { DateTime } from "luxon";
import { getCallsForUserToday } from "../src/services/gong.js";
import { getConnectionForUser } from "../src/services/salesforceClient.js";
import { buildContext } from "../src/services/opportunityContext.js";
import { getUsageProvider } from "../src/services/usageDb.js";
import {
  bootstrap as rogoBootstrap,
  lookupRogoCustomer,
} from "../src/services/rogoClient.js";
import { getUser } from "../src/db/queries.js";
import { runAgent } from "../src/agent/runner.js";
import { BRIEF_SYSTEM, QA_SYSTEM } from "../src/agent/prompts.js";

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
  console.error(
    "usage: probe <gong|sf|usage|rogo-bootstrap|rogo-customer|rogo-usage|agent> <args...>"
  );
  process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
