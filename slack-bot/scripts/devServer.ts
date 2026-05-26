import http from "node:http";
import { config } from "../src/config.js";
import slackEvents from "../api/slack/events.js";
import oauthStart from "../api/oauth/sf/start.js";
import oauthCallback from "../api/oauth/sf/callback.js";
import googleOauthStart from "../api/oauth/google/start.js";
import googleOauthCallback from "../api/oauth/google/callback.js";
import cronTick from "../api/cron/tick.js";
import standupRun from "../api/standup/run.js";
import calendarRun from "../api/calendar/run.js";
import nooksWebhook from "../api/nooks/webhook.js";
import gongWebhook from "../api/gong/webhook.js";
import redTeamSweep from "../api/red-team/sweep.js";
import redTeamRunForUser from "../api/red-team/run-for-user.js";
import health from "../api/health.js";

const routes: Record<string, any> = {
  "/api/slack/events": slackEvents,
  "/api/oauth/sf/start": oauthStart,
  "/api/oauth/sf/callback": oauthCallback,
  "/api/oauth/google/start": googleOauthStart,
  "/api/oauth/google/callback": googleOauthCallback,
  "/api/cron/tick": cronTick,
  "/api/standup/run": standupRun,
  "/api/calendar/run": calendarRun,
  "/api/nooks/webhook": nooksWebhook,
  "/api/gong/webhook": gongWebhook,
  "/api/red-team/sweep": redTeamSweep,
  "/api/red-team/run-for-user": redTeamRunForUser,
  "/api/health": health,
};

const port = parseInt(process.env.PORT || "3002", 10);

http
  .createServer((req, res) => {
    const url = new URL(req.url || "/", `http://localhost:${port}`);
    const handler = routes[url.pathname];
    if (!handler) {
      res.statusCode = 404;
      res.end("Not found");
      return;
    }
    Promise.resolve(handler(req, res)).catch((err) => {
      console.error("[devServer] handler error:", err);
      if (!res.writableEnded) {
        res.statusCode = 500;
        res.end(err.message);
      }
    });
  })
  .listen(port, () => {
    console.log(`slack-bot dev server on http://localhost:${port}`);
    console.log(`Public URL (set STANDUP_PUBLIC_URL): ${config.publicUrl}`);
  });
