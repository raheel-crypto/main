import type { Connection } from "jsforce";
import { escapeSoql } from "./sfReads.js";

export interface ResolvedUser {
  id: string;
  name: string;
}

export type UserResolveResult =
  | { kind: "ok"; user: ResolvedUser }
  | { kind: "not_found"; query: string }
  | { kind: "ambiguous"; query: string; candidates: ResolvedUser[] };

const SELF_TOKENS = new Set([
  "me",
  "myself",
  "i",
  "self",
  "current user",
  "the rep",
]);

export function isSelfReference(value: string): boolean {
  return SELF_TOKENS.has(value.trim().toLowerCase());
}

export async function resolveCurrentUserId(
  conn: Connection
): Promise<string | null> {
  try {
    const ident: any = await conn.identity();
    return ident?.user_id ?? null;
  } catch {
    return null;
  }
}

export async function resolveUserByName(
  conn: Connection,
  query: string
): Promise<UserResolveResult> {
  const q = query.trim();
  if (!q) return { kind: "not_found", query };
  const escaped = escapeSoql(q);
  const res = await conn.query<{ Id: string; Name: string }>(
    `SELECT Id, Name FROM User WHERE IsActive = true AND Name LIKE '%${escaped}%' ORDER BY Name LIMIT 5`
  );
  const rows = (res.records as { Id: string; Name: string }[]) ?? [];
  if (rows.length === 0) return { kind: "not_found", query };
  if (rows.length === 1) {
    return { kind: "ok", user: { id: rows[0].Id, name: rows[0].Name } };
  }
  return {
    kind: "ambiguous",
    query,
    candidates: rows.map((r) => ({ id: r.Id, name: r.Name })),
  };
}

export async function fetchUserName(
  conn: Connection,
  userId: string
): Promise<string | null> {
  if (!userId) return null;
  try {
    const escaped = escapeSoql(userId);
    const res = await conn.query<{ Name: string }>(
      `SELECT Name FROM User WHERE Id = '${escaped}' LIMIT 1`
    );
    const rows = res.records as { Name: string }[];
    return rows[0]?.Name ?? null;
  } catch {
    return null;
  }
}
