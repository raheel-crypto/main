import { createPool, sql, type VercelPool } from "@vercel/postgres";
import { config } from "../config.js";

let pool: VercelPool | null = null;

export function getPool(): VercelPool {
  if (pool) return pool;
  if (!config.postgres.url) {
    throw new Error("POSTGRES_URL not set");
  }
  pool = createPool({ connectionString: config.postgres.url });
  return pool;
}

export { sql };
