import { DateTime } from "luxon";
import { getCallsForUserToday } from "../src/services/gong.js";
import { getConnectionForUser } from "../src/services/salesforceClient.js";
import { buildContext } from "../src/services/opportunityContext.js";
import { getUsageProvider } from "../src/services/usageDb.js";
import { getUser } from "../src/db/queries.js";

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
  if (kind === "usage") {
    const ids = (rest[0] || "").split(",").filter(Boolean);
    const rows = await getUsageProvider().getUsageForAccounts(
      ids,
      DateTime.now().toISODate()!
    );
    console.log(JSON.stringify(rows, null, 2));
    return;
  }
  console.error("usage: probe <gong|sf|usage> <args...>");
  process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
