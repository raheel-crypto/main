import { describe, expect, it } from "vitest";
import { recomputeAccount, diffVsStored } from "./recompute";
import type { AccountRecord, OpportunityRecord } from "./types";

const customer = (overrides: Partial<AccountRecord> = {}): AccountRecord => ({
  Id: "001A",
  Name: "Test Account",
  ARR__c: 0,
  Account_Status__c: "Customer",
  Churn_Date__c: null,
  ...overrides,
});

const opp = (overrides: Partial<OpportunityRecord>): OpportunityRecord => ({
  Id: `O-${Math.random()}`,
  AccountId: "001A",
  Annual_Recurring_Revenue__c: 0,
  Type: "New Business",
  CloseDate: "2024-01-01",
  IsWon: true,
  ...overrides,
});

describe("recomputeAccount", () => {
  it("Cordis pattern: renewal rebaselines, doesn't stack", () => {
    const result = recomputeAccount(customer({ ARR__c: 6000 }), [
      opp({ Type: "New Business", Annual_Recurring_Revenue__c: 12000, CloseDate: "2022-01-01" }),
      opp({ Type: "Renewal", Annual_Recurring_Revenue__c: 6000, CloseDate: "2023-01-01" }),
      opp({ Type: "Renewal", Annual_Recurring_Revenue__c: 6000, CloseDate: "2024-01-01" }),
    ]);
    expect(result.expectedArr).toBe(6000);
  });

  it("William Blair pattern: same-day renewal + upsell, renewal processed first", () => {
    const result = recomputeAccount(customer(), [
      opp({ Type: "New Business", Annual_Recurring_Revenue__c: 270000, CloseDate: "2023-01-01" }),
      opp({ Type: "Renewal", Annual_Recurring_Revenue__c: 270000, CloseDate: "2024-01-01" }),
      opp({ Type: "Upsell", Annual_Recurring_Revenue__c: 230000, CloseDate: "2024-01-01" }),
    ]);
    expect(result.expectedArr).toBe(500000);
  });

  it("Moelis pattern: same-day restructure absorbed by renewal", () => {
    const result = recomputeAccount(customer(), [
      opp({ Type: "New Business", Annual_Recurring_Revenue__c: 570000, CloseDate: "2023-01-01" }),
      opp({ Type: "Renewal", Annual_Recurring_Revenue__c: 500000, CloseDate: "2024-01-01" }),
      opp({ Type: "Contract Restructure", Annual_Recurring_Revenue__c: -570000, CloseDate: "2024-01-01" }),
    ]);
    expect(result.expectedArr).toBe(500000);
  });

  it("Stifel pattern: pilot with real ARR counts as ARR", () => {
    const result = recomputeAccount(customer(), [
      opp({ Type: "Pilot", Annual_Recurring_Revenue__c: 100000, CloseDate: "2023-06-01" }),
      opp({ Type: "New Business", Annual_Recurring_Revenue__c: 1055000, CloseDate: "2023-12-01" }),
    ]);
    expect(result.expectedArr).toBe(1155000);
  });

  it("Unpaid pilot at $0 is a no-op", () => {
    const result = recomputeAccount(customer(), [
      opp({ Type: "Pilot", Annual_Recurring_Revenue__c: 0, CloseDate: "2023-06-01" }),
      opp({ Type: "New Business", Annual_Recurring_Revenue__c: 50000, CloseDate: "2024-01-01" }),
    ]);
    expect(result.expectedArr).toBe(50000);
  });

  it("Former Customer with prior ARR emits churn event and zeroes", () => {
    const result = recomputeAccount(
      customer({
        Account_Status__c: "Former Customer",
        Churn_Date__c: "2024-06-01",
      }),
      [opp({ Type: "New Business", Annual_Recurring_Revenue__c: 23000, CloseDate: "2023-01-01" })],
    );
    expect(result.expectedArr).toBe(0);
    const churnEvent = result.events.find((e) => e.eventType === "Churn");
    expect(churnEvent).toBeDefined();
    expect(churnEvent?.delta).toBe(-23000);
  });

  it("Prospect with closed-won deal: status gate forces ARR = 0", () => {
    const result = recomputeAccount(
      customer({ Account_Status__c: "Prospect" }),
      [opp({ Type: "Pilot", Annual_Recurring_Revenue__c: 4500, CloseDate: "2024-01-01" })],
    );
    expect(result.expectedArr).toBe(0);
  });

  it("Downsell delta uses already-negative ARR", () => {
    const result = recomputeAccount(customer(), [
      opp({ Type: "New Business", Annual_Recurring_Revenue__c: 100000, CloseDate: "2023-01-01" }),
      opp({ Type: "Downsell", Annual_Recurring_Revenue__c: -20000, CloseDate: "2024-01-01" }),
    ]);
    expect(result.expectedArr).toBe(80000);
  });

  it("Mid-cycle restructure (not on renewal date) applies as a real delta", () => {
    const result = recomputeAccount(customer(), [
      opp({ Type: "New Business", Annual_Recurring_Revenue__c: 100000, CloseDate: "2023-01-01" }),
      opp({ Type: "Contract Restructure", Annual_Recurring_Revenue__c: -10000, CloseDate: "2023-06-01" }),
    ]);
    expect(result.expectedArr).toBe(90000);
  });
});

describe("diffVsStored", () => {
  it("matches within threshold", () => {
    const result = diffVsStored(customer({ ARR__c: 50000 }), [
      opp({ Type: "New Business", Annual_Recurring_Revenue__c: 50000 }),
    ]);
    expect(result.matches).toBe(true);
    expect(result.gap).toBe(0);
  });

  it("flags non-trivial gaps", () => {
    const result = diffVsStored(customer({ ARR__c: 100000 }), [
      opp({ Type: "New Business", Annual_Recurring_Revenue__c: 50000 }),
    ]);
    expect(result.matches).toBe(false);
    expect(result.gap).toBe(50000);
  });
});

// TODO: replace these synthetic fixtures with a snapshot of all 325 accounts
// from the prod SOQL pull. Target: 317/325 reconcile under §2.
