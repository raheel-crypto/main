import { DateTime } from "luxon";
import { config } from "../config.js";
import {
  getCalendarEnrolledUsers,
  getGcTokens,
  meetingRunExists,
} from "../db/queries.js";
import { GcNotConnectedError, listEvents } from "./googleClient.js";
import type { GcalAttendee, GcalEvent, UserPrefs } from "../types.js";

const PRE_WINDOW_MIN = 5;
const PRE_WINDOW_MAX = 15;
const POST_WINDOW_MIN = 5;
const POST_WINDOW_MAX = 15;

const POLL_LOOKBACK_MIN = 20;
const POLL_LOOKAHEAD_MIN = 20;

type Phase = "pre" | "post";

export interface CandidateMeeting {
  slackUserId: string;
  eventId: string;
  phase: Phase;
  summary: string | null;
  startIso: string | null;
  endIso: string | null;
  externalDomains: string[];
}

function isExternal(email: string): boolean {
  const domain = email.toLowerCase().split("@")[1];
  if (!domain) return false;
  return !config.calendar.internalDomains.includes(domain);
}

export function externalAttendees(
  event: GcalEvent
): GcalAttendee[] {
  const attendees = event.attendees ?? [];
  return attendees.filter(
    (a) =>
      typeof a.email === "string" &&
      !a.resource &&
      a.responseStatus !== "declined" &&
      isExternal(a.email)
  );
}

export function classifyPhase(
  event: GcalEvent,
  now: DateTime
): Phase | null {
  const start = event.start?.dateTime ? DateTime.fromISO(event.start.dateTime) : null;
  const end = event.end?.dateTime ? DateTime.fromISO(event.end.dateTime) : null;
  if (start) {
    const minsUntilStart = start.diff(now, "minutes").minutes;
    if (minsUntilStart >= PRE_WINDOW_MIN && minsUntilStart <= PRE_WINDOW_MAX) {
      return "pre";
    }
  }
  if (end) {
    const minsSinceEnd = now.diff(end, "minutes").minutes;
    if (minsSinceEnd >= POST_WINDOW_MIN && minsSinceEnd <= POST_WINDOW_MAX) {
      return "post";
    }
  }
  return null;
}

async function scanUser(
  user: UserPrefs,
  now: DateTime
): Promise<CandidateMeeting[]> {
  const tokens = await getGcTokens(user.slackUserId);
  if (!tokens) return [];

  const timeMin = now.minus({ minutes: POLL_LOOKBACK_MIN }).toUTC().toISO()!;
  const timeMax = now.plus({ minutes: POLL_LOOKAHEAD_MIN }).toUTC().toISO()!;

  let events: GcalEvent[];
  try {
    events = await listEvents(user.slackUserId, timeMin, timeMax, {
      maxResults: 50,
    });
  } catch (err: any) {
    if (err instanceof GcNotConnectedError) return [];
    console.error(
      `[calendar] listEvents failed for ${user.slackUserId}:`,
      err?.message ?? err
    );
    return [];
  }

  const out: CandidateMeeting[] = [];
  for (const ev of events) {
    if (!ev.id) continue;
    if (ev.status && ev.status !== "confirmed") continue;
    const phase = classifyPhase(ev, now);
    if (!phase) continue;
    if (phase === "pre" && !user.calendarPreEnabled) continue;
    if (phase === "post" && !user.calendarPostEnabled) continue;

    const externals = externalAttendees(ev);
    if (externals.length === 0) continue;

    const externalDomains = Array.from(
      new Set(
        externals
          .map((a) => a.email.toLowerCase().split("@")[1])
          .filter((d): d is string => Boolean(d))
      )
    );

    const exists = await meetingRunExists(user.slackUserId, ev.id, phase);
    if (exists) continue;

    out.push({
      slackUserId: user.slackUserId,
      eventId: ev.id,
      phase,
      summary: ev.summary ?? null,
      startIso: ev.start?.dateTime ?? null,
      endIso: ev.end?.dateTime ?? null,
      externalDomains,
    });
  }
  return out;
}

export async function findCandidateMeetings(
  now = DateTime.now()
): Promise<CandidateMeeting[]> {
  const users = await getCalendarEnrolledUsers();
  const lists = await Promise.all(users.map((u) => scanUser(u, now)));
  return lists.flat();
}

export async function dispatchCalendarEvents(): Promise<{
  scanned: number;
  triggered: { slackUserId: string; eventId: string; phase: Phase }[];
}> {
  const now = DateTime.now();
  const candidates = await findCandidateMeetings(now);
  const triggered: { slackUserId: string; eventId: string; phase: Phase }[] = [];

  for (const c of candidates) {
    console.log(
      `[calendar] candidate ${c.slackUserId} · ${c.phase} · "${c.summary}" · domains=${c.externalDomains.join(",")}`
    );
    try {
      const res = await fetch(`${config.publicUrl}/api/calendar/run`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-internal-secret": config.internalSecret,
        },
        body: JSON.stringify({
          slackUserId: c.slackUserId,
          eventId: c.eventId,
          phase: c.phase,
        }),
      });
      if (res.ok) {
        triggered.push({
          slackUserId: c.slackUserId,
          eventId: c.eventId,
          phase: c.phase,
        });
      } else {
        const text = await res.text();
        console.error(
          `[calendar] /api/calendar/run failed for ${c.slackUserId} ${c.eventId} ${c.phase}: ${res.status} ${text}`
        );
      }
    } catch (err: any) {
      console.error(
        `[calendar] dispatch error for ${c.slackUserId} ${c.eventId}:`,
        err?.message ?? err
      );
    }
  }

  return { scanned: candidates.length, triggered };
}
