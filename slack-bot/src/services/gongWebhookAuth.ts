import type { IncomingMessage } from "node:http";
import crypto from "node:crypto";
import { config } from "../config.js";

export const JWT_TIMESTAMP_TOLERANCE_SECONDS = 300;

export interface VerifyResult {
  ok: boolean;
  mode: "jwt" | "url_token" | "open";
  reason?: string;
  payload?: Record<string, unknown>;
}

function base64UrlDecode(input: string): Buffer {
  const pad = input.length % 4 === 0 ? "" : "=".repeat(4 - (input.length % 4));
  return Buffer.from(input.replace(/-/g, "+").replace(/_/g, "/") + pad, "base64");
}

function timingSafeEqualStr(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ab.length !== bb.length) return false;
  return crypto.timingSafeEqual(ab, bb);
}

function getBearerToken(req: IncomingMessage): string | null {
  const raw =
    (req.headers["authorization"] as string | undefined) ??
    (req.headers["x-gong-signature"] as string | undefined) ??
    (req.headers["x-gong-jwt"] as string | undefined);
  if (!raw) return null;
  const m = raw.match(/^\s*Bearer\s+(.+)\s*$/i);
  return m ? m[1] : raw.trim();
}

function verifyHs256(
  signed: string,
  signature: Buffer,
  secret: string
): boolean {
  const expected = crypto.createHmac("sha256", secret).update(signed).digest();
  if (expected.length !== signature.length) return false;
  return crypto.timingSafeEqual(expected, signature);
}

function publicKeyCandidates(input: string): string[] {
  const trimmed = input.trim();
  if (trimmed.startsWith("-----BEGIN")) return [trimmed];
  const body = trimmed.replace(/\s+/g, "");
  const wrapped = body.match(/.{1,64}/g)?.join("\n") ?? body;
  return [
    `-----BEGIN PUBLIC KEY-----\n${wrapped}\n-----END PUBLIC KEY-----`,
    `-----BEGIN RSA PUBLIC KEY-----\n${wrapped}\n-----END RSA PUBLIC KEY-----`,
  ];
}

function verifyRs256(
  signed: string,
  signature: Buffer,
  pem: string
): boolean {
  for (const candidate of publicKeyCandidates(pem)) {
    try {
      const ok = crypto
        .createVerify("RSA-SHA256")
        .update(signed)
        .verify(candidate, signature);
      if (ok) return true;
    } catch {
      // try next candidate
    }
  }
  return false;
}

export function verifyJwt(
  token: string,
  opts: { publicKey?: string; sharedSecret?: string }
): VerifyResult {
  const parts = token.split(".");
  if (parts.length !== 3) {
    return { ok: false, mode: "jwt", reason: "bad_jwt_shape" };
  }
  const [h, p, s] = parts;
  let header: { alg?: string; typ?: string };
  let payload: Record<string, unknown>;
  let signature: Buffer;
  try {
    header = JSON.parse(base64UrlDecode(h).toString("utf8"));
    payload = JSON.parse(base64UrlDecode(p).toString("utf8"));
    signature = base64UrlDecode(s);
  } catch (err) {
    return { ok: false, mode: "jwt", reason: "bad_jwt_encoding" };
  }

  const signed = `${h}.${p}`;
  const alg = (header.alg || "").toUpperCase();
  let signatureOk = false;
  if (alg === "HS256" && opts.sharedSecret) {
    signatureOk = verifyHs256(signed, signature, opts.sharedSecret);
  } else if (alg === "RS256" && opts.publicKey) {
    signatureOk = verifyRs256(signed, signature, opts.publicKey);
  } else {
    return {
      ok: false,
      mode: "jwt",
      reason: `unsupported_alg:${alg || "none"}`,
      payload,
    };
  }
  if (!signatureOk) {
    return { ok: false, mode: "jwt", reason: "signature_mismatch", payload };
  }

  const nowSec = Math.floor(Date.now() / 1000);
  const iat =
    typeof payload.iat === "number" ? (payload.iat as number) : null;
  const exp =
    typeof payload.exp === "number" ? (payload.exp as number) : null;
  if (iat !== null && Math.abs(nowSec - iat) > JWT_TIMESTAMP_TOLERANCE_SECONDS) {
    return {
      ok: false,
      mode: "jwt",
      reason: `iat_out_of_tolerance:${nowSec - iat}s`,
      payload,
    };
  }
  if (exp !== null && nowSec > exp) {
    return { ok: false, mode: "jwt", reason: "token_expired", payload };
  }
  return { ok: true, mode: "jwt", payload };
}

export function verifyGongWebhookAuth(req: IncomingMessage): VerifyResult {
  const { jwtPublicKey, jwtSecret, webhookToken } = config.gong;
  if (jwtPublicKey || jwtSecret) {
    const token = getBearerToken(req);
    if (!token) {
      return { ok: false, mode: "jwt", reason: "missing_jwt" };
    }
    return verifyJwt(token, {
      publicKey: jwtPublicKey || undefined,
      sharedSecret: jwtSecret || undefined,
    });
  }
  if (webhookToken) {
    let queryToken = "";
    try {
      const url = new URL(req.url || "", "http://localhost");
      queryToken = url.searchParams.get("token") ?? "";
    } catch {}
    const headerToken =
      (req.headers["x-gong-token"] as string | undefined) ?? "";
    const provided = headerToken || queryToken;
    if (!provided) {
      return { ok: false, mode: "url_token", reason: "missing_token" };
    }
    if (!timingSafeEqualStr(provided, webhookToken)) {
      return { ok: false, mode: "url_token", reason: "token_mismatch" };
    }
    return { ok: true, mode: "url_token" };
  }
  return { ok: true, mode: "open" };
}
