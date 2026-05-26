import { config } from "../config.js";
import type { GongCall, RedTeamGongTranscriptSegment } from "../types.js";

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

interface GongCallExtensiveResponse {
  calls?: {
    metaData?: {
      id?: string;
      title?: string | null;
      started?: string | null;
      duration?: number | null;
      url?: string | null;
    };
    parties?: {
      name?: string | null;
      emailAddress?: string | null;
      affiliation?: string | null;
      title?: string | null;
      speakerId?: string | null;
    }[];
    content?: { brief?: string | null };
  }[];
}

export interface GongCallExtensive {
  callId: string;
  title: string | null;
  startedAt: string | null;
  durationSec: number | null;
  url: string | null;
  brief: string | null;
  parties: {
    name: string | null;
    email: string | null;
    affiliation: string | null;
    title: string | null;
    speakerId: string | null;
  }[];
}

/**
 * Fetch extensive metadata for specific call ids. Used by the red-team intel
 * pack to enrich call data we already learned about via webhooks or transcript
 * fetches.
 */
export async function getCallsExtensive(
  callIds: string[]
): Promise<GongCallExtensive[]> {
  if (callIds.length === 0 || !config.gong.accessKey) return [];
  const body = {
    filter: { callIds },
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
  const data = (await res.json()) as GongCallExtensiveResponse;
  return (data.calls ?? []).map((c) => ({
    callId: c.metaData?.id ?? "",
    title: c.metaData?.title ?? null,
    startedAt: c.metaData?.started ?? null,
    durationSec:
      typeof c.metaData?.duration === "number" ? c.metaData.duration : null,
    url: c.metaData?.url ?? null,
    brief: c.content?.brief ?? null,
    parties: (c.parties ?? []).map((p) => ({
      name: p.name ?? null,
      email: p.emailAddress ?? null,
      affiliation: p.affiliation ?? null,
      title: p.title ?? null,
      speakerId: p.speakerId ?? null,
    })),
  }));
}

interface GongTranscriptResponse {
  callTranscripts?: {
    callId: string;
    transcript?: {
      speakerId?: string | null;
      topic?: string | null;
      sentences?: { start?: number; end?: number; text?: string }[];
    }[];
  }[];
}

/**
 * Fetch verbatim speaker segments for a single Gong call via
 * `POST /v2/calls/transcript`. Returns null when transcription is unavailable
 * (call too recent, not transcribed, etc.).
 *
 * Speaker names come back as ids; callers should join against
 * `getCallsExtensive` parties (by `speakerId`) if they need display names.
 */
export async function getCallTranscript(
  callId: string,
  opts: { partySpeakers?: { speakerId: string | null; name: string | null; affiliation: string | null }[] } = {}
): Promise<RedTeamGongTranscriptSegment[] | null> {
  if (!callId || !config.gong.accessKey) return null;
  const body = {
    filter: { callIds: [callId] },
  };
  const res = await gongFetch("/v2/calls/transcript", {
    method: "POST",
    body: JSON.stringify(body),
  });
  if (res.status === 404) return null;
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Gong /v2/calls/transcript failed: ${res.status} ${text}`);
  }
  const data = (await res.json()) as GongTranscriptResponse;
  const wrap = (data.callTranscripts ?? []).find((c) => c.callId === callId);
  if (!wrap || !Array.isArray(wrap.transcript)) return null;

  const speakerLookup = new Map<
    string,
    { name: string | null; affiliation: string | null }
  >();
  for (const p of opts.partySpeakers ?? []) {
    if (!p.speakerId) continue;
    speakerLookup.set(p.speakerId, {
      name: p.name,
      affiliation: p.affiliation,
    });
  }

  const segments: RedTeamGongTranscriptSegment[] = [];
  for (const block of wrap.transcript) {
    const sid = block.speakerId ?? null;
    const meta = sid ? speakerLookup.get(sid) ?? null : null;
    const sentences = block.sentences ?? [];
    if (sentences.length === 0) continue;
    const text = sentences
      .map((s) => (typeof s.text === "string" ? s.text.trim() : ""))
      .filter(Boolean)
      .join(" ");
    if (!text) continue;
    const startSec =
      typeof sentences[0].start === "number" ? sentences[0].start / 1000 : null;
    const last = sentences[sentences.length - 1];
    const endSec =
      typeof last.end === "number" ? last.end / 1000 : startSec;
    segments.push({
      speakerId: sid,
      speakerName: meta?.name ?? null,
      speakerAffiliation: meta?.affiliation ?? "Unknown",
      text,
      startSec,
      endSec,
    });
  }
  return segments;
}
