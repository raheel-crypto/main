import type { IncomingMessage, ServerResponse } from "node:http";
import { getApp } from "../../src/slack/app.js";

export default async function handler(
  req: IncomingMessage,
  res: ServerResponse
) {
  const { receiver } = getApp();
  await receiver.app(req as any, res as any);
}
