import dotenv from "dotenv";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.resolve(__dirname, "../../.env") });

export const config = {
  port: parseInt(process.env.PORT || "3001", 10),
  sessionSecret: process.env.SESSION_SECRET || "dev-secret-change-me",
  clientUrl: process.env.CLIENT_URL || "http://localhost:5173",
  salesforce: {
    clientId: process.env.SF_CLIENT_ID || "",
    clientSecret: process.env.SF_CLIENT_SECRET || "",
    callbackUrl:
      process.env.SF_CALLBACK_URL || "http://localhost:3001/auth/callback",
    loginUrl: process.env.SF_LOGIN_URL || "https://login.salesforce.com",
  },
  anthropic: {
    apiKey: process.env.ANTHROPIC_API_KEY || "",
  },
};
