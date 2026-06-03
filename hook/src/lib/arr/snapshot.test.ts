import { describe, expect, it } from "vitest";
import accountsRaw from "./__fixtures__/accounts.json";
import oppsRaw from "./__fixtures__/opps.json";
import { diffVsStored } from "./recompute";
import type { AccountRecord, OpportunityRecord } from "./types";

const accounts = accountsRaw as unknown as AccountRecord[];
const opps = oppsRaw as unknown as OpportunityRecord[];

// Production snapshot pulled from Rogo's SF org. Update when re-baselining.
// The §2 algorithm must continue to reconcile EXACTLY this set of accounts.
// Any new mismatch is either a logic bug or a data-quality issue worth investigating.

const KNOWN_EXCEPTIONS: Record<string, { name: string; expectedGap: number; reason: string }> = {
  "001V400000GiBOMIA3": { name: "Arma Partners", expectedGap: -167777, reason: "Duplicate '40 Seats' New Business opps (§8)" },
  "001V400000aQV1sIAG": { name: "Multiples Alternate Asset Management", expectedGap: -130000, reason: "New since audit — investigate" },
  "001V400000C5BIVIA3": { name: "Industrial Growth Partners", expectedGap: 23000, reason: "Stale-on-churn — true error (§8)" },
  "001V400000Wf4tHIAR": { name: "Indeed", expectedGap: -18000, reason: "Type hygiene — Upsells typed as New Business (§8)" },
  "001cv00000YXWYfAAP": { name: "Entrepreneur Equity Partners", expectedGap: -12000, reason: "Type hygiene (§8)" },
  "001cv00000fmH8iAAE": { name: "Alyeska Investment Group", expectedGap: 6000, reason: "New since audit — investigate" },
  "001cv00000a8nutAAA": { name: "Sazun GmbH", expectedGap: -4750, reason: "Restatement (§8)" },
  "001V400000go91YIAQ": { name: "Latimer Partners", expectedGap: -3000, reason: "Trial restated (§8)" },
  "001V400000SVHHNIA5": { name: "Nolan & Associates", expectedGap: 1000, reason: "Immaterial $1k delta (§8)" },
};

describe("§2 regression against production snapshot", () => {
  it("reconciles 325 of 334 accounts exactly", () => {
    let matches = 0;
    const mismatches: { id: string; name: string; gap: number }[] = [];

    for (const account of accounts) {
      const accountOpps = opps.filter((o) => o.AccountId === account.Id);
      const result = diffVsStored(account, accountOpps);
      if (result.matches) {
        matches += 1;
      } else {
        mismatches.push({ id: account.Id, name: account.Name, gap: result.gap });
      }
    }

    expect(matches).toBe(334 - Object.keys(KNOWN_EXCEPTIONS).length);
    expect(mismatches).toHaveLength(Object.keys(KNOWN_EXCEPTIONS).length);
  });

  it("every mismatch is a known exception with the expected gap", () => {
    const surprises: string[] = [];

    for (const account of accounts) {
      const accountOpps = opps.filter((o) => o.AccountId === account.Id);
      const result = diffVsStored(account, accountOpps);
      const known = KNOWN_EXCEPTIONS[account.Id];

      if (!result.matches && !known) {
        surprises.push(`UNEXPECTED MISMATCH: ${account.Name} (${account.Id}) — gap ${result.gap}`);
      }
      if (result.matches && known) {
        surprises.push(`FORMERLY-FAILING ACCOUNT NOW MATCHES: ${account.Name} (${account.Id}) — remove from KNOWN_EXCEPTIONS`);
      }
      if (!result.matches && known && Math.abs(result.gap - known.expectedGap) > 1) {
        surprises.push(`KNOWN EXCEPTION GAP DRIFTED: ${account.Name} (${account.Id}) — was ${known.expectedGap}, now ${result.gap}`);
      }
    }

    expect(surprises).toEqual([]);
  });

  it("every Prospect with closed-won deals lands at $0 via the status gate", () => {
    const prospects = accounts.filter((a) => a.Account_Status__c === "Prospect");
    for (const account of prospects) {
      const accountOpps = opps.filter((o) => o.AccountId === account.Id);
      const result = diffVsStored(account, accountOpps);
      expect(result.result.expectedArr).toBe(0);
    }
  });

  it("every Former Customer lands at $0 via the synthetic churn event", () => {
    const churned = accounts.filter((a) => a.Account_Status__c === "Former Customer");
    for (const account of churned) {
      const accountOpps = opps.filter((o) => o.AccountId === account.Id);
      const result = diffVsStored(account, accountOpps);
      expect(result.result.expectedArr).toBe(0);
    }
  });
});
