import { App, ExpressReceiver } from "@slack/bolt";
import { config } from "../config.js";
import { registerCommands } from "./commands.js";
import {
  registerConfigSubmit,
  registerInteractivity,
} from "./interactivity.js";

let cached: { app: App; receiver: ExpressReceiver } | null = null;

export function getApp(): { app: App; receiver: ExpressReceiver } {
  if (cached) return cached;
  const receiver = new ExpressReceiver({
    signingSecret: config.slack.signingSecret,
    endpoints: { events: "/api/slack/events" },
    processBeforeResponse: true,
  });
  const app = new App({
    token: config.slack.botToken,
    receiver,
    processBeforeResponse: true,
  });
  registerCommands(app);
  registerInteractivity(app);
  registerConfigSubmit(app);
  cached = { app, receiver };
  return cached;
}
