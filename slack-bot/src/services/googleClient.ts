import {
  getGcTokens,
  updateGcAccessToken,
} from "../db/queries.js";
import { refreshAccessToken } from "./googleAuth.js";
import type { GcalEvent } from "../types.js";

export class GcNotConnectedError extends Error {
  constructor(public slackUserId: string) {
    super(`Google Calendar not connected for ${slackUserId}`);
  }
}

const CALENDAR_BASE = "https://www.googleapis.com/calendar/v3";
const REFRESH_SLOP_MS = 60_000;

async function getValidAccessToken(slackUserId: string): Promise<string> {
  const tokens = await getGcTokens(slackUserId);
  if (!tokens) throw new GcNotConnectedError(slackUserId);
  const expiresAtMs = Date.parse(tokens.expiresAt);
  if (Number.isFinite(expiresAtMs) && expiresAtMs > Date.now() + REFRESH_SLOP_MS) {
    return tokens.accessToken;
  }
  const refreshed = await refreshAccessToken(tokens.refreshToken);
  await updateGcAccessToken(slackUserId, refreshed.accessToken, refreshed.expiresAtIso);
  return refreshed.accessToken;
}

async function gcalFetch(
  slackUserId: string,
  path: string,
  init: RequestInit = {}
): Promise<Response> {
  let accessToken = await getValidAccessToken(slackUserId);
  let res = await fetch(`${CALENDAR_BASE}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
  if (res.status === 401) {
    const tokens = await getGcTokens(slackUserId);
    if (!tokens) throw new GcNotConnectedError(slackUserId);
    const refreshed = await refreshAccessToken(tokens.refreshToken);
    await updateGcAccessToken(slackUserId, refreshed.accessToken, refreshed.expiresAtIso);
    accessToken = refreshed.accessToken;
    res = await fetch(`${CALENDAR_BASE}${path}`, {
      ...init,
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
        ...(init.headers || {}),
      },
    });
  }
  return res;
}

export async function listEvents(
  slackUserId: string,
  timeMinIso: string,
  timeMaxIso: string,
  opts: { maxResults?: number; calendarId?: string } = {}
): Promise<GcalEvent[]> {
  const calendarId = opts.calendarId ?? "primary";
  const params = new URLSearchParams({
    timeMin: timeMinIso,
    timeMax: timeMaxIso,
    singleEvents: "true",
    orderBy: "startTime",
    maxResults: String(opts.maxResults ?? 50),
  });
  const res = await gcalFetch(
    slackUserId,
    `/calendars/${encodeURIComponent(calendarId)}/events?${params}`
  );
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`gcal listEvents failed: ${res.status} ${text}`);
  }
  const data = (await res.json()) as { items?: GcalEvent[] };
  return data.items ?? [];
}

export async function getEvent(
  slackUserId: string,
  eventId: string,
  opts: { calendarId?: string } = {}
): Promise<GcalEvent> {
  const calendarId = opts.calendarId ?? "primary";
  const res = await gcalFetch(
    slackUserId,
    `/calendars/${encodeURIComponent(calendarId)}/events/${encodeURIComponent(eventId)}`
  );
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`gcal getEvent failed: ${res.status} ${text}`);
  }
  return (await res.json()) as GcalEvent;
}
