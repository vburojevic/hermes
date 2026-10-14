"use node";

// Sends one validated push to APNs over HTTP/2 with token auth (the team key from Infisical
// /shared/apple: APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID). Logs status only, never a payload or token.
import crypto from "node:crypto";
import http2 from "node:http2";
import { v } from "convex/values";
import { internalAction } from "./_generated/server";

const HOSTS = { production: "https://api.push.apple.com", development: "https://api.sandbox.push.apple.com" };

let cachedJwt: { token: string; at: number } | null = null;
const sessions = new Map<string, http2.ClientHttp2Session>();

function privateKey(): string {
  const raw = process.env.APNS_KEY_P8 ?? "";
  if (!raw) throw new Error("APNS_KEY_P8 is not set");
  return raw.includes("\\n") ? raw.replace(/\\n/g, "\n") : raw;
}

/** ES256 provider token; Apple wants it refreshed between 20 and 60 minutes. */
function providerToken(): string {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && now - cachedJwt.at < 40 * 60) return cachedJwt.token;
  const keyId = process.env.APNS_KEY_ID;
  const teamId = process.env.APNS_TEAM_ID;
  if (!keyId || !teamId) throw new Error("APNS_KEY_ID / APNS_TEAM_ID are not set");
  const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const unsigned = `${encode({ alg: "ES256", kid: keyId })}.${encode({ iss: teamId, iat: now })}`;
  const signature = crypto.sign("sha256", Buffer.from(unsigned), { key: privateKey(), dsaEncoding: "ieee-p1363" });
  cachedJwt = { token: `${unsigned}.${signature.toString("base64url")}`, at: now };
  return cachedJwt.token;
}

function session(origin: string): http2.ClientHttp2Session {
  const existing = sessions.get(origin);
  if (existing && !existing.closed && !existing.destroyed) return existing;
  const fresh = http2.connect(origin);
  fresh.on("error", () => sessions.delete(origin));
  fresh.on("close", () => sessions.delete(origin));
  fresh.setTimeout(5 * 60_000, () => fresh.close());
  sessions.set(origin, fresh);
  return fresh;
}

export const send = internalAction({
  args: {
    token: v.string(),
    environment: v.union(v.literal("development"), v.literal("production")),
    topic: v.string(),
    push_type: v.union(v.literal("alert"), v.literal("background"), v.literal("liveactivity")),
    priority: v.union(v.literal(5), v.literal(10)),
    collapse_id: v.optional(v.string()),
    expiration: v.optional(v.number()),
    payload: v.any(),
  },
  handler: async (_ctx, push): Promise<{ status: number; reason?: string; apns_id?: string }> => {
    // APNS_HOST_OVERRIDE points a local test run at a fake APNs (plain HTTP/2).
    const origin = process.env.APNS_HOST_OVERRIDE || HOSTS[push.environment];
    const headers: http2.OutgoingHttpHeaders = {
      ":method": "POST",
      ":path": `/3/device/${push.token}`,
      authorization: `bearer ${providerToken()}`,
      "apns-topic": push.topic,
      "apns-push-type": push.push_type,
      "apns-priority": String(push.priority),
      "content-type": "application/json",
    };
    if (push.collapse_id) headers["apns-collapse-id"] = push.collapse_id;
    if (push.expiration !== undefined) headers["apns-expiration"] = String(push.expiration);
    const body = JSON.stringify(push.payload);

    const attempt = () =>
      new Promise<{ status: number; reason?: string; apns_id?: string }>((resolve, reject) => {
        const request = session(origin).request(headers);
        let status = 0;
        let apnsId: string | undefined;
        let text = "";
        request.setEncoding("utf8");
        request.setTimeout(10_000, () => request.close(http2.constants.NGHTTP2_CANCEL));
        request.on("response", (response) => {
          status = Number(response[":status"] ?? 0);
          apnsId = response["apns-id"] as string | undefined;
        });
        request.on("data", (chunk) => (text += chunk));
        request.on("end", () => {
          let reason: string | undefined;
          try {
            reason = text ? (JSON.parse(text).reason as string | undefined) : undefined;
          } catch {
            reason = undefined;
          }
          resolve({ status, ...(reason ? { reason } : {}), ...(apnsId ? { apns_id: apnsId } : {}) });
        });
        request.on("error", reject);
        request.end(body);
      });

    let result;
    try {
      result = await attempt();
    } catch {
      sessions.delete(origin); // a dead connection: retry once on a fresh one
      result = await attempt();
    }
    console.log(`apns ${push.push_type} ${push.environment} -> ${result.status}${result.reason ? ` ${result.reason}` : ""}`);
    return result;
  },
});
