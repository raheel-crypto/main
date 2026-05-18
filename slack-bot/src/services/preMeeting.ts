import { appendAudit, insertMeetingRun } from "../db/queries.js";
import { getEvent } from "./googleClient.js";

export interface PreMeetingResult {
  ok: boolean;
  reason?: string;
}

// Stage 2 stub. Replaced by the real brief generator in stage 3.
export async function runPreMeeting(args: {
  slackUserId: string;
  eventId: string;
}): Promise<PreMeetingResult> {
  const { slackUserId, eventId } = args;
  try {
    const event = await getEvent(slackUserId, eventId);
    console.log(
      `[pre-meeting] (stub) ${slackUserId} event=${eventId} title="${event.summary ?? ""}" start=${event.start?.dateTime ?? ""} attendees=${event.attendees?.length ?? 0}`
    );
  } catch (err: any) {
    console.error(`[pre-meeting] getEvent failed:`, err?.message ?? err);
  }
  const ins = await insertMeetingRun({
    slackUserId,
    gcalEventId: eventId,
    phase: "pre",
  });
  if (!ins.inserted) {
    return { ok: true, reason: "already_ran" };
  }
  await appendAudit({
    slackUserId,
    action: "meeting_briefed",
    metadata: { eventId, stub: true },
  });
  return { ok: true, reason: "stub_logged" };
}
