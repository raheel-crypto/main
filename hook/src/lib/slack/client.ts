import { WebClient } from "@slack/web-api";

export const slack = new WebClient(process.env.SLACK_BOT_TOKEN);

export const REVOPS_CHANNEL = process.env.SLACK_REVOPS_CHANNEL_ID!;
