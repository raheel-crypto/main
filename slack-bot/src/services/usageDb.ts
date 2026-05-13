import { config } from "../config.js";
import type { RogoBatchDataset, UsageRow } from "../types.js";
import {
  bootstrap as rogoBootstrap,
  lookupRogoCustomer,
  queryBatch,
} from "./rogoClient.js";

export interface UsageProvider {
  getUsageForAccounts(
    accountIds: string[],
    asOf: string
  ): Promise<UsageRow[]>;
}

class NoopUsageProvider implements UsageProvider {
  async getUsageForAccounts(): Promise<UsageRow[]> {
    return [];
  }
}

function escapeSql(value: string): string {
  return value.replace(/'/g, "''");
}

function buildAccountSql(rogoKey: string, sfAccountId: string): string {
  const joinCol = config.rogo.customerJoinColumn;
  const table = config.rogo.customerTable;
  return `SELECT *, '${escapeSql(sfAccountId)}' AS _sf_account_id
            FROM ${table}
           WHERE ${joinCol} = '${escapeSql(rogoKey)}'
           LIMIT 1`;
}

function isUsageMetric(column: string, value: unknown): boolean {
  if (value === null || value === undefined) return false;
  if (column.startsWith("_")) return false;
  if (typeof value !== "number" || !Number.isFinite(value)) return false;
  const lower = column.toLowerCase();
  if (lower.endsWith("_id") || lower.endsWith("_sha256")) return false;
  return true;
}

class RogoUsageProvider implements UsageProvider {
  async getUsageForAccounts(
    accountIds: string[],
    asOf: string
  ): Promise<UsageRow[]> {
    if (accountIds.length === 0) return [];

    let directoryRows;
    try {
      const boot = await rogoBootstrap();
      directoryRows = boot.customer_directory?.rows ?? [];
    } catch (err: any) {
      console.error("[rogo] bootstrap failed:", err.message);
      return [];
    }
    if (directoryRows.length === 0) {
      console.warn("[rogo] customer_directory is empty");
      return [];
    }

    const matched: { sfAccountId: string; rogoKey: string }[] = [];
    for (const sfAccountId of accountIds) {
      const row = await lookupRogoCustomer(sfAccountId);
      if (!row) continue;
      const rogoKey = (row as Record<string, unknown>)[
        config.rogo.directoryCustomerKey
      ];
      if (rogoKey == null) continue;
      matched.push({ sfAccountId, rogoKey: String(rogoKey) });
    }
    if (matched.length === 0) return [];

    const datasets: RogoBatchDataset[] = matched.map((m) => ({
      id: m.sfAccountId,
      sql: buildAccountSql(m.rogoKey, m.sfAccountId),
      label: `usage:${m.sfAccountId}`,
      max_rows: 1,
    }));

    let batches;
    try {
      batches = await queryBatch(datasets, "partial");
    } catch (err: any) {
      console.error("[rogo] queryBatch failed:", err.message);
      return [];
    }

    const out: UsageRow[] = [];
    for (const batch of batches) {
      for (const ds of batch.datasets) {
        if (ds.status !== "ok" || !ds.columns || !ds.rows || ds.rows.length === 0) {
          if (ds.status === "error") {
            console.warn(
              `[rogo] dataset ${ds.id} failed: ${ds.error?.code} ${ds.error?.message}`
            );
          }
          continue;
        }
        const row = ds.rows[0];
        for (let i = 0; i < ds.columns.length; i++) {
          const col = ds.columns[i];
          const value = row[i];
          if (!isUsageMetric(col, value)) continue;
          out.push({
            accountId: ds.id,
            metric: col,
            value: value as number,
            asOf,
          });
        }
      }
    }
    return out;
  }
}

let provider: UsageProvider | null = null;

export function getUsageProvider(): UsageProvider {
  if (provider) return provider;
  if (config.rogo.apiKey) {
    provider = new RogoUsageProvider();
  } else {
    provider = new NoopUsageProvider();
  }
  return provider;
}
