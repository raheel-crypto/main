import { config } from "../config.js";
import type { UsageRow } from "../types.js";

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

class HttpUsageProvider implements UsageProvider {
  constructor(
    private url: string,
    private token: string
  ) {}

  async getUsageForAccounts(
    accountIds: string[],
    asOf: string
  ): Promise<UsageRow[]> {
    if (accountIds.length === 0) return [];
    const res = await fetch(this.url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(this.token ? { Authorization: `Bearer ${this.token}` } : {}),
      },
      body: JSON.stringify({ accountIds, asOf }),
    });
    if (!res.ok) {
      throw new Error(`usage api ${res.status}: ${await res.text()}`);
    }
    const data = (await res.json()) as { rows?: UsageRow[] };
    return data.rows ?? [];
  }
}

let provider: UsageProvider | null = null;

export function getUsageProvider(): UsageProvider {
  if (provider) return provider;
  if (config.usage.url) {
    provider = new HttpUsageProvider(config.usage.url, config.usage.token);
  } else {
    provider = new NoopUsageProvider();
  }
  return provider;
}
