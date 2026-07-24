import { Connection } from "jsforce";
import {
  fetchAccountsByDomain,
  fetchContactsByEmail,
  type AccountByDomainRow,
  type ContactRow,
} from "./sfReads.js";

export type ResolutionSource =
  | "contact_match"
  | "domain_match"
  | "picker_needed";

export interface ResolvedAccount {
  source: ResolutionSource;
  accountId: string | null;
  accountName: string | null;
  candidates: Array<{ id: string; name: string; reason: string }>;
  matchedContacts: ContactRow[];
}

export function emailsToDomains(emails: string[]): string[] {
  const out = new Set<string>();
  for (const e of emails) {
    const d = e.toLowerCase().split("@")[1]?.trim();
    if (d && !COMMON_FREE_DOMAINS.has(d)) {
      out.add(d);
    }
  }
  return Array.from(out);
}

const COMMON_FREE_DOMAINS = new Set([
  "gmail.com",
  "yahoo.com",
  "outlook.com",
  "hotmail.com",
  "icloud.com",
  "me.com",
  "aol.com",
  "proton.me",
  "protonmail.com",
]);

export async function resolveAccount(
  conn: Connection,
  externalEmails: string[]
): Promise<ResolvedAccount> {
  const matchedContacts = await fetchContactsByEmail(conn, externalEmails);

  const accountIdToContacts = new Map<string, ContactRow[]>();
  for (const c of matchedContacts) {
    if (!c.accountId) continue;
    const arr = accountIdToContacts.get(c.accountId) ?? [];
    arr.push(c);
    accountIdToContacts.set(c.accountId, arr);
  }

  if (accountIdToContacts.size === 1) {
    const [[accountId, contacts]] = accountIdToContacts.entries();
    return {
      source: "contact_match",
      accountId,
      accountName: contacts[0]?.accountName ?? null,
      candidates: [
        {
          id: accountId,
          name: contacts[0]?.accountName ?? accountId,
          reason: `Matched ${contacts.length} contact${contacts.length === 1 ? "" : "s"} by email`,
        },
      ],
      matchedContacts,
    };
  }

  const domains = emailsToDomains(externalEmails);
  const byDomain: AccountByDomainRow[] =
    domains.length > 0 ? await fetchAccountsByDomain(conn, domains) : [];

  if (accountIdToContacts.size === 0 && byDomain.length === 1) {
    return {
      source: "domain_match",
      accountId: byDomain[0].id,
      accountName: byDomain[0].name,
      candidates: [
        {
          id: byDomain[0].id,
          name: byDomain[0].name,
          reason: `Website matched ${domains.join(", ")}`,
        },
      ],
      matchedContacts,
    };
  }

  const candidates: Array<{ id: string; name: string; reason: string }> = [];
  const seen = new Set<string>();
  for (const [accountId, contacts] of accountIdToContacts) {
    if (seen.has(accountId)) continue;
    seen.add(accountId);
    candidates.push({
      id: accountId,
      name: contacts[0]?.accountName ?? accountId,
      reason: `Matched ${contacts.length} contact${contacts.length === 1 ? "" : "s"}`,
    });
  }
  for (const acc of byDomain) {
    if (seen.has(acc.id)) continue;
    seen.add(acc.id);
    candidates.push({
      id: acc.id,
      name: acc.name,
      reason: `Website matched ${domains.join(", ")}`,
    });
  }
  return {
    source: "picker_needed",
    accountId: null,
    accountName: null,
    candidates: candidates.slice(0, 5),
    matchedContacts,
  };
}
