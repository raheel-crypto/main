import { neon } from "@neondatabase/serverless";

let _sql: ReturnType<typeof neon> | null = null;

function getSql(): ReturnType<typeof neon> {
  if (_sql) return _sql;
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is not set");
  _sql = neon(url);
  return _sql;
}

// Lazy proxy: defers neon() until the first query so module import (which
// runs during Next.js build's page-data-collection phase) doesn't require
// DATABASE_URL to be set.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export const sql: ReturnType<typeof neon> = ((
  strings: TemplateStringsArray,
  ...values: unknown[]
) => (getSql() as any)(strings, ...values)) as any;
