import { config } from "../config.js";
import type {
  RogoBatchDataset,
  RogoBatchResult,
  RogoBootstrap,
  RogoCustomer,
  RogoQueryResult,
} from "../types.js";

export class RogoApiError extends Error {
  constructor(
    public code: string,
    message: string,
    public retryable: boolean,
    public httpStatus?: number
  ) {
    super(message);
    this.name = "RogoApiError";
  }
}

const RETRYABLE_CODES = new Set([
  "query_timed_out",
  "snowflake_unavailable",
  "internal_error",
]);

let bootstrapPromise: Promise<RogoBootstrap> | null = null;
let bootstrapValue: RogoBootstrap | null = null;

function authHeader(): Record<string, string> {
  if (!config.rogo.apiKey) {
    throw new RogoApiError("auth_invalid", "ROGO_API_KEY is not set", false);
  }
  return { Authorization: `Bearer ${config.rogo.apiKey}` };
}

async function rogoFetch(pathname: string, init: RequestInit = {}): Promise<any> {
  const res = await fetch(`${config.rogo.baseUrl}${pathname}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...authHeader(),
      ...(init.headers || {}),
    },
  });
  const text = await res.text();
  let parsed: any = null;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    parsed = { error: { code: "internal_error", message: text } };
  }
  if (!res.ok || parsed?.error) {
    const err = parsed?.error ?? {
      code: "internal_error",
      message: `HTTP ${res.status}`,
      retryable: res.status >= 500,
    };
    throw new RogoApiError(
      err.code ?? "internal_error",
      err.message ?? "Rogo API error",
      err.retryable ?? RETRYABLE_CODES.has(err.code),
      res.status
    );
  }
  return parsed;
}

export async function bootstrap(force = false): Promise<RogoBootstrap> {
  if (!force && bootstrapValue) return bootstrapValue;
  if (!force && bootstrapPromise) return bootstrapPromise;
  bootstrapPromise = rogoFetch("/api/start-here", { method: "GET" }).then(
    (data) => {
      bootstrapValue = data as RogoBootstrap;
      return bootstrapValue;
    }
  );
  try {
    return await bootstrapPromise;
  } finally {
    bootstrapPromise = null;
  }
}

export async function query(sql: string): Promise<RogoQueryResult> {
  return rogoFetch("/api/query", {
    method: "POST",
    body: JSON.stringify({ sql }),
  });
}

export async function queryBatch(
  datasets: RogoBatchDataset[],
  onError: "partial" | "fail_fast" = "partial"
): Promise<RogoBatchResult[]> {
  const chunks: RogoBatchDataset[][] = [];
  for (let i = 0; i < datasets.length; i += 10) {
    chunks.push(datasets.slice(i, i + 10));
  }
  const results: RogoBatchResult[] = [];
  for (const chunk of chunks) {
    const r = (await rogoFetch("/api/query/batch", {
      method: "POST",
      body: JSON.stringify({
        datasets: chunk,
        options: { on_error: onError },
      }),
    })) as RogoBatchResult;
    results.push(r);
  }
  return results;
}

export async function lookupRogoCustomer(
  salesforceAccountId: string
): Promise<RogoCustomer | null> {
  const boot = await bootstrap();
  const rows = boot.customer_directory?.rows ?? [];
  const key = config.rogo.directorySfKey;
  for (const row of rows) {
    const v = (row as Record<string, unknown>)[key];
    if (v != null && String(v) === salesforceAccountId) return row;
  }
  return null;
}

export function getBootstrapSync(): RogoBootstrap | null {
  return bootstrapValue;
}

export function clearBootstrapCache(): void {
  bootstrapValue = null;
  bootstrapPromise = null;
}
