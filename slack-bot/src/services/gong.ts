import { config } from "../config.js";
import type { GongCall } from "../types.js";

function basicAuthHeader(): string {
  if (!config.gong.accessKey || !config.gong.accessKeySecret) return "";
  const token = Buffer.from(
    `${config.gong.accessKey}:${config.gong.accessKeySecret}`
  ).toString("base64");
  return `Basic ${token}`;
}

async function gongFetch(
  pathname: string,
  init: RequestInit = {},
  attempt = 0
): Promise<Response> {
  const auth = basicAuthHeader();
  if (!auth) throw new Error("Gong credentials not configured");

  const res = await fetch(`${config.gong.baseUrl}${pathname}`, {
    ...init,
    headers: {
      Authorization: auth,
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });

  if ((res.status === 429 || res.status >= 500) && attempt < 3) {
    const retryAfter = parseInt(res.headers.get("Retry-After") || "0", 10);
    const delay = retryAfter > 0 ? retryAfter * 1000 : 500 * 2 ** attempt;
    await new Promise((r) => setTimeout(r, delay));
    return gongFetch(pathname, init, attempt + 1);
  }
  return res;
}

export async function getCallsForUserToday(
  userEmail: string,
  fromIso: string,
  toIso: string
): Promise<GongCall[]> {
  if (!config.gong.accessKey) return [];

  const body = {
    filter: {
      fromDateTime: fromIso,
      toDateTime: toIso,
    },
    contentSelector: {
      context: "Extended",
      exposedFields: {
        parties: true,
        content: { brief: true },
      },
    },
  };

  const res = await gongFetch("/v2/calls/extensive", {
    method: "POST",
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Gong /v2/calls/extensive failed: ${res.status} ${text}`);
  }
  const data = (await res.json()) as {
    calls?: {
      metaData: {
        id: string;
        title: string;
        started: string;
        duration: number;
        url: string;
      };
      parties?: { emailAddress?: string; affiliation?: string }[];
      content?: { brief?: string };
    }[];
  };

  const calls = data.calls ?? [];
  const lower = userEmail.toLowerCase();
  return calls
    .filter((c) =>
      (c.parties || []).some(
        (p) => (p.emailAddress || "").toLowerCase() === lower
      )
    )
    .map((c) => ({
      id: c.metaData.id,
      title: c.metaData.title,
      startedAt: c.metaData.started,
      durationSeconds: c.metaData.duration,
      participants: (c.parties || [])
        .map((p) => p.emailAddress || "")
        .filter(Boolean),
      brief: c.content?.brief || null,
      callUrl: c.metaData.url || null,
    }));
}
