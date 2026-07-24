import type { IncomingMessage, ServerResponse } from "node:http";
import { config } from "../../src/config.js";
import { runPreMeeting } from "../../src/services/preMeeting.js";
import { runPostMeeting } from "../../src/services/postMeeting.js";

async function readJson(req: IncomingMessage): Promise<any> {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (err) {
        reject(err);
      }
    });
    req.on("error", reject);
  });
}

export default async function handler(
  req: IncomingMessage,
  res: ServerResponse
) {
  if (req.method !== "POST") {
    res.statusCode = 405;
    res.end("Method Not Allowed");
    return;
  }
  const secret = req.headers["x-internal-secret"];
  if (secret !== config.internalSecret) {
    res.statusCode = 401;
    res.end("Unauthorized");
    return;
  }
  try {
    const body = (await readJson(req)) as {
      slackUserId?: string;
      eventId?: string;
      phase?: "pre" | "post";
    };
    if (!body.slackUserId || !body.eventId || !body.phase) {
      res.statusCode = 400;
      res.end("slackUserId, eventId, phase required");
      return;
    }
    console.log(
      `[calendar/run] ${body.phase} for ${body.slackUserId} event=${body.eventId}`
    );
    let result;
    if (body.phase === "pre") {
      result = await runPreMeeting({
        slackUserId: body.slackUserId,
        eventId: body.eventId,
      });
    } else {
      result = await runPostMeeting({
        slackUserId: body.slackUserId,
        eventId: body.eventId,
      });
    }
    res.statusCode = 200;
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify(result));
  } catch (err: any) {
    console.error("[calendar/run] error:", err);
    res.statusCode = 500;
    res.end(JSON.stringify({ error: err.message }));
  }
}
